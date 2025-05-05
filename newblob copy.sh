#!/bin/bash
source_account=$SA1
dest_account=$SA2
container_name="testcontainer"

token=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/" | jq -r '.access_token')

# Create containers
curl -X PUT "https://${source_account}.blob.core.windows.net/${container_name}?restype=container" -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08"
curl -X PUT "https://${dest_account}.blob.core.windows.net/${container_name}?restype=container" -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08"

# For each blob - download then upload approach instead of copy
for i in {1..1}; do
  content="Test content $i"
  echo "$content" > blob.txt
  
  # Upload to source
  curl -X PUT "https://${source_account}.blob.core.windows.net/${container_name}/blob${i}.txt" -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08" -H "x-ms-blob-type: BlockBlob" --data-binary "@blob.txt"
  
  # Download from source and upload to destination directly
  curl -s -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08" "https://${source_account}.blob.core.windows.net/${container_name}/blob${i}.txt" | \
  curl -X PUT "https://${dest_account}.blob.core.windows.net/${container_name}/blob${i}.txt" -H "Authorization: Bearer $token" -H "x-ms-version: 2020-04-08" -H "x-ms-blob-type: BlockBlob" --data-binary @-
done