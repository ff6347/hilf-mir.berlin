# ABOUTME: Unsubscribes (removes) a webhook from the records table.
# ABOUTME: Requires webhook_id and unsubscribe_key variables.

POST {{domain}}/api/docs/{{doc_id}}/tables/{{records_table}}/_unsubscribe
Authorization: Bearer {{api_key}}
Content-Type: application/json

{
  "webhookId": "{{webhook_id}}",
  "unsubscribeKey": "{{unsubscribe_key}}"
}

HTTP 200
