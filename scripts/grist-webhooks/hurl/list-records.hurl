# ABOUTME: Fetches the first 3 records from the records table.
# ABOUTME: Useful for verifying API access and seeing the data shape.

GET {{domain}}/api/docs/{{doc_id}}/tables/{{records_table}}/records?limit=3
Authorization: Bearer {{api_key}}

HTTP 200
