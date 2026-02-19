# Grist Webhooks (v1.0.7)

Reverse-engineered documentation for the webhook system in Grist v1.0.7.

## Overview

Grist webhooks allow external services to be notified when rows are added or updated in a table. The system consists of:

- **Trigger configuration** stored in the document's `_grist_Triggers` metatable (inside the document's SQLite)
- **Webhook secrets** (URL + unsubscribe key) stored in the Home DB's `secrets` table (Postgres), never in the document
- **An in-memory event queue** with optional Redis backup for crash recovery
- **A background send loop** that delivers batched events with retry logic

## Supported Event Types

Only two event types exist:

| Event | Fires when |
|-------|-----------|
| `add` | A row is created, or a row's "ready column" flips to `true` for the first time |
| `update` | An already-ready row is modified |

There is **no `delete` event** in v1.0.7.

## API Endpoints

All endpoints are relative to the Grist API base URL.

### Subscribe (Create Webhook)

```
POST /api/docs/:docId/tables/:tableId/_subscribe
```

**Auth**: Document owner only.

**Request body**:

```json
{
  "url": "https://example.com/hook",
  "eventTypes": ["add", "update"],
  "isReadyColumn": "Approved"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string | yes | HTTPS URL to receive webhook POST requests. HTTP only allowed for localhost. Must match `ALLOWED_WEBHOOK_DOMAINS` if set. |
| `eventTypes` | string[] | yes | Array of event types: `"add"` and/or `"update"` |
| `isReadyColumn` | string | no | Column ID that acts as a readiness gate. Only rows where this column is `true` (strict boolean) will trigger events. |

**Response** (200):

```json
{
  "webhookId": "a1b2c3d4-...",
  "triggerId": 3,
  "unsubscribeKey": "e5f6a7b8-..."
}
```

| Field | Description |
|-------|-------------|
| `webhookId` | UUID identifying the webhook. Used internally and needed for the webhooks list endpoint. |
| `triggerId` | Row ID in the `_grist_Triggers` metatable |
| `unsubscribeKey` | UUID required for unsubscribing without owner permissions |

### Unsubscribe (Delete Webhook)

```
POST /api/docs/:docId/tables/:tableId/_unsubscribe
```

**Auth**: Editors with the correct `unsubscribeKey`, or document owners.

**Request body**:

```json
{
  "webhookId": "a1b2c3d4-...",
  "unsubscribeKey": "e5f6a7b8-..."
}
```

**Response** (200):

```json
{ "success": true }
```

This removes:
- The trigger row from `_grist_Triggers`
- The webhook secret from the Home DB

### List Webhooks

```
GET /api/docs/:docId/webhooks
```

**Auth**: Document owner only.

**Response** (200):

```json
[
  {
    "id": "a1b2c3d4-...",
    "fields": {
      "url": "https://example.com/hook",
      "unsubscribeKey": "e5f6a7b8-...",
      "eventTypes": ["add", "update"],
      "isReadyColumn": "Approved",
      "tableId": "MyTable",
      "enabled": true,
      "status": "idle",
      "numWaiting": 0
    }
  }
]
```

| Field | Description |
|-------|-------------|
| `url` | The webhook destination URL |
| `unsubscribeKey` | The key needed to unsubscribe |
| `eventTypes` | Which events trigger this webhook |
| `isReadyColumn` | The readiness gate column (null if none) |
| `tableId` | The watched table |
| `enabled` | Whether the webhook is active |
| `status` | Current status: `idle`, `sending`, `retrying`, `postponed`, `error` |
| `numWaiting` | Number of events queued for this webhook |

### Clear Webhook Queue

```
DELETE /api/docs/:docId/webhooks/queue
```

**Auth**: Document owner only.

Flushes all pending webhook events from the queue. Cancels any in-flight retry attempts.

**Response** (200): empty

## Payload Format

When a webhook fires, Grist sends an HTTP `POST` request with `Content-Type: application/json`. The body is a JSON array of row snapshots:

```json
[
  { "id": 42, "Name": "Alice", "Approved": true, "Amount": 100 },
  { "id": 43, "Name": "Bob",   "Approved": true, "Amount": 200 }
]
```

Key characteristics:

- Each element is the **full current row** at the time of the change (all columns, not just changed ones)
- No before/after diff is included
- Multiple rows changed in the same action bundle are batched together (up to 100 per request)
- Only rows for the **same webhook** are grouped in a single batch
- Only HTTP **200** is treated as success

## Readiness Gate (isReadyColumn)

The `isReadyColumn` is a powerful feature for controlling when webhooks fire:

- When set, events only fire for rows where the column value is strictly `true` (boolean)
- A row whose ready column flips from `false` to `true` is treated as an `"add"` event (even if the row existed before)
- A row that is already ready and gets updated triggers an `"update"` event
- This lets you stage data before "publishing" it via the ready column

When `isReadyColumn` is not set:
- New rows trigger `"add"` events
- Modified existing rows trigger `"update"` events

## Retry and Queue Behavior

### Send Loop

The background send loop runs continuously while the document is open:

1. Pulls events from the front of the FIFO queue
2. Groups consecutive events with the same webhook ID into a batch (max 100)
3. Sends the batch via HTTP POST
4. On success: removes events from queue, marks status `idle`
5. On failure: retries with backoff, then re-appends to queue tail

### Retry Strategy

| Parameter | Default | Description |
|-----------|---------|-------------|
| Max attempts | 20 | Configurable via `GRIST_TRIGGER_MAX_ATTEMPTS` |
| Initial delay | 1 second | |
| Backoff | Exponential (x2) | 1s, 2s, 4s, 8s, 16s, 32s, 64s max |
| Max delay | 64 seconds | |

### Queue Overflow

| Parameter | Default | Description |
|-----------|---------|-------------|
| Max queue size | 1000 | Configurable via `GRIST_MAX_QUEUE_SIZE` |

When the queue reaches max size:
- The `handle()` method blocks (polls every second), applying back-pressure to document writes
- Max retry attempts drops to `min(5, configured max)`
- Failed batches are dropped (status: `"rejected"`) instead of re-queued

### Webhook Statuses

| Status | Meaning |
|--------|---------|
| `idle` | No pending events, last delivery succeeded or no deliveries yet |
| `sending` | Currently delivering a batch |
| `retrying` | Delivery failed, retrying with backoff |
| `postponed` | Delivery failed, batch re-queued to the tail (other webhooks get a turn) |
| `error` | Delivery failed and batch was dropped (during queue overflow) |

### Redis Backup

When `REDIS_URL` is configured, events are also pushed to a Redis list (`webhook-queue-<docId>`). On document startup, the Redis queue is replayed into memory to recover events from crashes.

## Storage Architecture

### Document-level (SQLite metatable)

Trigger configuration is stored in `_grist_Triggers`:

```sql
CREATE TABLE "_grist_Triggers" (
  id             INTEGER PRIMARY KEY,
  tableRef       INTEGER DEFAULT 0,       -- FK to _grist_Tables.id
  eventTypes     TEXT    DEFAULT NULL,     -- Encoded as ["L", "add", "update"]
  isReadyColRef  INTEGER DEFAULT 0,       -- FK to _grist_Tables_column.id (0 = none)
  actions        TEXT    DEFAULT ''        -- JSON: [{"type":"webhook","id":"<uuid>"}]
);
```

### Server-level (Home DB / Postgres)

Webhook secrets are stored in the `secrets` table:

```
Secret entity:
  id:     UUID (= webhookId)
  value:  JSON string of { url, unsubscribeKey }
  docId:  FK to docs table
```

The URL is never stored in the document itself, only in the Home DB.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ALLOWED_WEBHOOK_DOMAINS` | `""` (empty = all blocked) | Comma-separated list of allowed domains for webhook URLs |
| `REDIS_URL` | unset | Redis connection URL for queue persistence across crashes |
| `GRIST_MAX_QUEUE_SIZE` | `1000` | Max events in queue before back-pressure |
| `GRIST_TRIGGER_WAIT_DELAY` | `1000` (ms) | Poll/retry interval in the send loop |
| `GRIST_TRIGGER_MAX_ATTEMPTS` | `20` | Max delivery attempts per batch |

## URL Validation

Webhook URLs must pass validation:

- Must be a valid URL
- Must use HTTPS (HTTP only allowed for `localhost` during development)
- Host must match one of the domains in `ALLOWED_WEBHOOK_DOMAINS`
- If `ALLOWED_WEBHOOK_DOMAINS` is empty/unset, no external webhooks can be created

## Usage Examples

### Create a webhook that fires on new rows

```bash
curl -X POST "https://grist.example.com/api/docs/DOC_ID/tables/MyTable/_subscribe" \
  -H "Authorization: Bearer API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://my-service.com/webhook",
    "eventTypes": ["add"]
  }'
```

### Create a webhook with a readiness gate

```bash
curl -X POST "https://grist.example.com/api/docs/DOC_ID/tables/MyTable/_subscribe" \
  -H "Authorization: Bearer API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://my-service.com/webhook",
    "eventTypes": ["add", "update"],
    "isReadyColumn": "Published"
  }'
```

### List all webhooks

```bash
curl "https://grist.example.com/api/docs/DOC_ID/webhooks" \
  -H "Authorization: Bearer API_KEY"
```

### Delete a webhook

```bash
curl -X POST "https://grist.example.com/api/docs/DOC_ID/tables/MyTable/_unsubscribe" \
  -H "Authorization: Bearer API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "webhookId": "WEBHOOK_ID",
    "unsubscribeKey": "UNSUBSCRIBE_KEY"
  }'
```

### Clear the event queue

```bash
curl -X DELETE "https://grist.example.com/api/docs/DOC_ID/webhooks/queue" \
  -H "Authorization: Bearer API_KEY"
```

## Limitations

- No `delete` event type (only `add` and `update`)
- No payload diff (full row snapshot only, no before/after comparison)
- No webhook editing (must unsubscribe and re-subscribe to change configuration)
- No per-webhook queue management (clearing the queue clears ALL pending events)
- Only HTTP 200 counts as successful delivery (201, 204 etc. are treated as failures)
- Subscribe endpoint requires document owner permissions (editors cannot create webhooks)
