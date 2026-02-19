# ABOUTME: Lists all tables in the Grist document.
# ABOUTME: Smoke test for API connectivity and authentication.

GET {{domain}}/api/docs/{{doc_id}}/tables
Authorization: Bearer {{api_key}}

HTTP 200
