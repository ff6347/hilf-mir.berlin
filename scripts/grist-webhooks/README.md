# Grist Webhook Testing CLI

Minimal hurl-based scripts to test the Grist webhook API against our instance.

## Prerequisites

- [hurl](https://hurl.dev/) installed (`brew install hurl`)
- `.env` file in the project root with Grist credentials

## Usage

All commands are run via the wrapper script:

```bash
# List tables (smoke test for API connectivity)
./scripts/grist-webhooks/run.sh tables

# List all webhooks (requires owner access)
./scripts/grist-webhooks/run.sh list

# List records from the records table (first 3)
./scripts/grist-webhooks/run.sh records

# Subscribe a webhook (creates a new webhook - use with caution)
# GRIST_WEBHOOK_URL=https://your-endpoint.com ./scripts/grist-webhooks/run.sh subscribe

# Unsubscribe a webhook (destructive - removes a webhook)
# GRIST_WEBHOOK_ID=<id> GRIST_UNSUBSCRIBE_KEY=<key> ./scripts/grist-webhooks/run.sh unsubscribe
```

## Notes

- The API key in `.env` may not have owner access. Some endpoints (list, queue clear) require owner permissions.
- Subscribe and unsubscribe are commented out by default since they modify state.
- All hurl files use variables injected by `run.sh` from the `.env` file.
