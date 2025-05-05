#!/bin/bash
set -e

# Configuration
source_account="$SA1"
dest_account="$SA2"
container_name="testcontainer-$RANDOM"
num_blobs=100
temp_file="blob_content.tmp"

echo "Starting blob operations..."
echo "Source Account: $source_account"
echo "Destination Account: $dest_account"
echo "Container Name: $container_name"
echo "Number of Blobs: $num_blobs"

# Validate parameters
if [ -z "$source_account" ] || [ -z "$dest_account" ]; then
  echo "Error: Storage account names not provided"
  exit 1
fi

# Get token with detailed error handling
echo "Getting managed identity token..."
token_response=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/")
if [ -z "$token_response" ]; then
  echo "Error: Empty response when requesting token"
  exit 1
fi

access_token=$(echo "$token_response" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
if [ -z "$access_token" ]; then
  echo "Error: Could not extract access token from response"
  echo "Response: $token_response"
  exit 1
fi

# Headers
auth_header="Authorization: Bearer $access_token"
version_header="x-ms-version: 2020-04-08"

# Create containers with better error handling
for account in "$source_account" "$dest_account"; do
  container_url="https://${account}.blob.core.windows.net/${container_name}?restype=container"
  echo "Creating container in $account..."
  response=$(curl -X PUT "$container_url" -H "$auth_header" -H "$version_header" -H "Content-Length: 0" -i -s)
  status_code=$(echo "$response" | head -n 1 | cut -d' ' -f2)
  
  # 201 = Created, 409 = Already exists (acceptable)
  if [ "$status_code" = "201" ] || [ "$status_code" = "409" ]; then
    echo "Container creation succeeded (HTTP $status_code)"
  else
    echo "Error creating container in $account. Status: $status_code"
    echo "Response: $response"
    # Continue anyway - the container might exist
  fi
done

# Process blobs
successful_copies=0
for i in $(seq 1 $num_blobs); do
  blob_name="blob${i}.txt"
  source_blob_url="https://${source_account}.blob.core.windows.net/${container_name}/${blob_name}"
  dest_blob_url="https://${dest_account}.blob.core.windows.net/${container_name}/${blob_name}"

  echo "Processing blob $i/$num_blobs: $blob_name"

  # Create and upload to source
  echo "Creating content for $blob_name..."
  echo "Test content for blob $i generated on $(date)" > "$temp_file"
  content_length=$(wc -c < "$temp_file")

  echo "Uploading to source account..."
  response=$(curl -X PUT "$source_blob_url" \
    -H "$auth_header" \
    -H "$version_header" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Length: $content_length" \
    --data-binary "@$temp_file" \
    -i -s)
  status_code=$(echo "$response" | head -n 1 | cut -d' ' -f2)
  
  if [ "$status_code" != "201" ]; then
    echo "Error uploading to source. Status: $status_code"
    echo "Response: $response"
    continue  # Skip to next blob
  fi
  
  # Try direct upload instead of copy to avoid the 409 error
  echo "Uploading directly to destination account..."
  response=$(curl -X PUT "$dest_blob_url" \
    -H "$auth_header" \
    -H "$version_header" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Length: $content_length" \
    --data-binary "@$temp_file" \
    -i -s)
  status_code=$(echo "$response" | head -n 1 | cut -d' ' -f2)
  
  if [ "$status_code" = "201" ]; then
    echo "Success: Direct upload to destination (HTTP 201)"
    successful_copies=$((successful_copies + 1))
  else
    echo "Error: Direct upload failed. Status: $status_code"
    echo "Response: $response"
    
    # Only attempt copy if direct upload failed
    echo "Attempting server-side copy as fallback..."
    # First delete if exists
    curl -X DELETE "$dest_blob_url" -H "$auth_header" -H "$version_header" -s >/dev/null
    
    response=$(curl -X PUT "$dest_blob_url" \
      -H "$auth_header" \
      -H "$version_header" \
      -H "x-ms-copy-source: $source_blob_url" \
      -H "Content-Length: 0" \
      -i -s)
    status_code=$(echo "$response" | head -n 1 | cut -d' ' -f2)
    
    if [ "$status_code" = "202" ]; then  # 202 = Accepted (async operation started)
      echo "Success: Copy initiated (HTTP 202)"
      successful_copies=$((successful_copies + 1))
    else
      echo "Error: Copy operation failed. Status: $status_code"
      echo "Response: $response"
    fi
  fi
  
  # Progress report for every 10 blobs
  if [ $((i % 10)) -eq 0 ]; then
    echo "Progress: $i/$num_blobs complete, $successful_copies successful"
  fi
done

rm -f "$temp_file"
echo "Operation complete. Successfully processed $successful_copies out of $num_blobs blobs."