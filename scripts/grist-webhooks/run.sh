#!/usr/bin/env bash
# ABOUTME: Wrapper script that loads .env and runs hurl files against the Grist webhook API.
# ABOUTME: Provides a simple CLI for testing Grist API endpoints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load .env
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
else
  echo "Error: .env file not found at $PROJECT_ROOT/.env"
  exit 1
fi

# Validate required env vars
for var in NEXT_SECRET_GRIST_DOMAIN NEXT_SECRET_GRIST_DOC_ID NEXT_SECRET_GRIST_API_KEY NEXT_SECRET_GRIST_RECORDS_TABLE; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set in .env"
    exit 1
  fi
done

COMMAND="${1:-help}"

HURL_VARS=(
  --variable "domain=$NEXT_SECRET_GRIST_DOMAIN"
  --variable "doc_id=$NEXT_SECRET_GRIST_DOC_ID"
  --variable "api_key=$NEXT_SECRET_GRIST_API_KEY"
  --variable "records_table=$NEXT_SECRET_GRIST_RECORDS_TABLE"
  --variable "labels_table=${NEXT_SECRET_GRIST_LABELS_TABLE:-}"
  --variable "texts_table=${NEXT_SECRET_GRIST_TEXTS_TABLE:-}"
)

run_hurl() {
  local file="$SCRIPT_DIR/hurl/$1.hurl"
  if [[ ! -f "$file" ]]; then
    echo "Error: hurl file not found: $file"
    exit 1
  fi
  hurl "${HURL_VARS[@]}" "${@:2}" "$file"
}

case "$COMMAND" in
  tables)
    echo "Listing tables..."
    run_hurl tables | jq .
    ;;
  list)
    echo "Listing webhooks (requires owner access)..."
    run_hurl list-webhooks | jq .
    ;;
  records)
    echo "Fetching first 3 records from $NEXT_SECRET_GRIST_RECORDS_TABLE..."
    run_hurl list-records | jq .
    ;;
  subscribe)
    if [[ -z "${GRIST_WEBHOOK_URL:-}" ]]; then
      echo "Error: GRIST_WEBHOOK_URL must be set"
      echo "Usage: GRIST_WEBHOOK_URL=https://example.com/hook $0 subscribe"
      exit 1
    fi
    echo "Subscribing webhook to $GRIST_WEBHOOK_URL..."
    echo "WARNING: This creates a webhook on the server."
    read -r -p "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
    run_hurl subscribe --variable "webhook_url=$GRIST_WEBHOOK_URL" | jq .
    ;;
  unsubscribe)
    if [[ -z "${GRIST_WEBHOOK_ID:-}" || -z "${GRIST_UNSUBSCRIBE_KEY:-}" ]]; then
      echo "Error: GRIST_WEBHOOK_ID and GRIST_UNSUBSCRIBE_KEY must be set"
      echo "Usage: GRIST_WEBHOOK_ID=<id> GRIST_UNSUBSCRIBE_KEY=<key> $0 unsubscribe"
      exit 1
    fi
    echo "Unsubscribing webhook $GRIST_WEBHOOK_ID..."
    echo "WARNING: This removes a webhook from the server."
    read -r -p "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
    run_hurl unsubscribe \
      --variable "webhook_id=$GRIST_WEBHOOK_ID" \
      --variable "unsubscribe_key=$GRIST_UNSUBSCRIBE_KEY" | jq .
    ;;
  help|*)
    echo "Grist Webhook Testing CLI"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Safe commands (read-only):"
    echo "  tables     List all tables in the document"
    echo "  list       List all webhooks (requires owner access)"
    echo "  records    Fetch first 3 records from the records table"
    echo ""
    echo "Destructive commands (modify server state):"
    echo "  subscribe    Create a webhook (requires GRIST_WEBHOOK_URL)"
    echo "  unsubscribe  Remove a webhook (requires GRIST_WEBHOOK_ID + GRIST_UNSUBSCRIBE_KEY)"
    echo ""
    echo "Examples:"
    echo "  $0 tables"
    echo "  $0 list"
    echo "  GRIST_WEBHOOK_URL=https://example.com/hook $0 subscribe"
    ;;
esac
