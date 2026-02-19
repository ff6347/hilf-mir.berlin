# ABOUTME: Lists all webhooks configured on the Grist document.
# ABOUTME: Requires owner-level access to the document.

GET {{domain}}/api/docs/{{doc_id}}/webhooks
Authorization: Bearer {{api_key}}
