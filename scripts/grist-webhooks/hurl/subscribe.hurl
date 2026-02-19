# ABOUTME: Subscribes a webhook to the records table for add and update events.
# ABOUTME: Requires owner access. The webhook_url variable must be provided.

POST {{domain}}/api/docs/{{doc_id}}/tables/{{records_table}}/_subscribe
Authorization: Bearer {{api_key}}
Content-Type: application/json

{
  "url": "{{webhook_url}}",
  "eventTypes": ["add", "update"]
}

HTTP 200
