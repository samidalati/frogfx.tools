#!/bin/bash

# upload.sh
# Uploads a file to S3 with public read access
# Usage: upload.sh <file_path> <bucket_name> <s3_key_path> [content_type]
# Returns: Public URL of uploaded file (printed to stdout)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 <file_path> <bucket_name> <s3_key_path> [content_type]"
    echo ""
    echo "Arguments:"
    echo "  file_path      Local file path to upload"
    echo "  bucket_name    S3 bucket name"
    echo "  s3_key_path    S3 key path (e.g., '20260122_131604/video.mov')"
    echo "  content_type   Optional content type (default: auto-detect)"
    echo ""
    echo "Returns: Public URL of uploaded file (printed to stdout)"
    echo ""
    echo "Example:"
    echo "  $0 ./video.mov my-bucket 20260122_131604/video.mov video/quicktime"
}

# Parse arguments
if [ $# -lt 3 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    print_usage
    exit 1
fi

FILE_PATH="$1"
BUCKET_NAME="$2"
S3_KEY_PATH="$3"
CONTENT_TYPE="${4:-}"

# Validate file exists
if [ ! -f "$FILE_PATH" ]; then
    echo -e "${RED}Error: File '$FILE_PATH' does not exist${NC}" >&2
    exit 1
fi

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}" >&2
    echo "Install with: brew install awscli" >&2
    exit 1
fi

# Auto-detect content type if not provided
if [ -z "$CONTENT_TYPE" ]; then
    case "$FILE_PATH" in
        *.mov|*.MOV)
            CONTENT_TYPE="video/quicktime"
            ;;
        *.mp4|*.MP4)
            CONTENT_TYPE="video/mp4"
            ;;
        *.webm|*.WEBM)
            CONTENT_TYPE="video/webm"
            ;;
        *.webp|*.WEBP)
            CONTENT_TYPE="image/webp"
            ;;
        *.jpg|*.jpeg|*.JPG|*.JPEG)
            CONTENT_TYPE="image/jpeg"
            ;;
        *.png|*.PNG)
            CONTENT_TYPE="image/png"
            ;;
        *.html|*.HTML)
            CONTENT_TYPE="text/html"
            ;;
        *)
            CONTENT_TYPE="application/octet-stream"
            ;;
    esac
fi

# Ensure "Block Public Access" is disabled (required for object-level public access)
if aws s3api get-public-access-block --bucket "$BUCKET_NAME" &>/dev/null; then
    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
        "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>/dev/null || true
fi

# Upload file with public read grant
# Try using s3api put-object with grants (more reliable than ACL)
# Redirect stdout to suppress progress output, keep stderr for errors
if aws s3api put-object \
    --bucket "$BUCKET_NAME" \
    --key "$S3_KEY_PATH" \
    --body "$FILE_PATH" \
    --content-type "$CONTENT_TYPE" \
    --grant-read "uri=http://acs.amazonaws.com/groups/global/AllUsers" 2>/dev/null; then
    echo -e "${GREEN}✓ File uploaded with public read access${NC}" >&2
elif aws s3 cp "$FILE_PATH" "s3://${BUCKET_NAME}/${S3_KEY_PATH}" \
    --content-type "$CONTENT_TYPE" \
    --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers \
    >/dev/null 2>&1; then
    echo -e "${GREEN}✓ File uploaded with public read access${NC}" >&2
elif aws s3 cp "$FILE_PATH" "s3://${BUCKET_NAME}/${S3_KEY_PATH}" \
    --content-type "$CONTENT_TYPE" \
    >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ File uploaded, setting ACL...${NC}" >&2
    # Try to set ACL after upload
    if aws s3api put-object-acl \
        --bucket "$BUCKET_NAME" \
        --key "$S3_KEY_PATH" \
        --acl public-read 2>/dev/null; then
        echo -e "${GREEN}✓ File is now publicly accessible${NC}" >&2
    else
        echo -e "${YELLOW}⚠ Could not set public access${NC}" >&2
    fi
else
    echo -e "${RED}Error: Failed to upload file to S3${NC}" >&2
    exit 1
fi

# Get bucket region for correct URL
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET_NAME" --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
# Handle us-east-1 which returns null
if [ "$BUCKET_REGION" = "None" ] || [ -z "$BUCKET_REGION" ]; then
    BUCKET_REGION="us-east-1"
fi

# Generate and print public URL
if [ "$BUCKET_REGION" = "us-east-1" ]; then
    PUBLIC_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_KEY_PATH}"
else
    PUBLIC_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_KEY_PATH}"
fi

# Print URL to stdout (for script usage)
echo "$PUBLIC_URL"
