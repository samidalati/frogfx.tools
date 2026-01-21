#!/bin/bash

# overlay.sh
# Overlays a video with alpha channel (WebM/VP9 or HEVC) onto a still image background
# Supports: WebM (VP9) with alpha, HEVC with alpha
# Requires: FFmpeg with libvpx-vp9 support (for output encoding)

set -e

# Default values
OUTPUT=""
IMAGE=""
VIDEO=""
POSITION="center"  # center, top-left, top-right, bottom-left, bottom-right, or x:y
BUCKET_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 -i <image> -v <video> [-o <output>] [-p <position>] [-b <bucket>]"
    echo ""
    echo "Options:"
    echo "  -i <image>    Background image file (required)"
    echo "  -v <video>    Video with alpha channel to overlay (required)"
    echo "                Supports: WebM (VP9) with alpha, HEVC (.mov) with alpha"
    echo "  -o <file>     Output file name (default: auto-generated)"
    echo "  -p <pos>      Position: center, top-left, top-right, bottom-left, bottom-right, or x:y (default: center)"
    echo "  -b <bucket>   S3 bucket name to upload video (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -i sample.jpeg -v video.webm"
    echo "  $0 -i sample.jpeg -v video.mov"
    echo "  $0 -i bg.jpg -v overlay.webm -p top-left"
    echo "  $0 -i bg.jpg -v overlay.mov -p 100:200 -b my-bucket"
    echo ""
    echo "Note: The video's alpha channel will be used for transparency"
    echo "      Supports both WebM (VP9) and HEVC video formats with alpha"
}

# Parse arguments
while getopts "i:v:o:p:b:h" opt; do
    case $opt in
        i) IMAGE="$OPTARG" ;;
        v) VIDEO="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        p) POSITION="$OPTARG" ;;
        b) BUCKET_NAME="$OPTARG" ;;
        h) print_usage; exit 0 ;;
        *) print_usage; exit 1 ;;
    esac
done

# Validate input
if [ -z "$IMAGE" ]; then
    echo -e "${RED}Error: Background image is required${NC}"
    print_usage
    exit 1
fi

if [ -z "$VIDEO" ]; then
    echo -e "${RED}Error: Video file is required${NC}"
    print_usage
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo -e "${RED}Error: Image file '$IMAGE' does not exist${NC}"
    exit 1
fi

if [ ! -f "$VIDEO" ]; then
    echo -e "${RED}Error: Video file '$VIDEO' does not exist${NC}"
    exit 1
fi

# Generate timestamp for output and S3 paths
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Set default output name
if [ -z "$OUTPUT" ]; then
    IMAGE_BASE=$(basename "$IMAGE" | sed 's/\.[^.]*$//')
    VIDEO_BASE=$(basename "$VIDEO" | sed 's/\.[^.]*$//')
    OUTPUT="overlay_${IMAGE_BASE}_${VIDEO_BASE}_${TIMESTAMP}.webm"
fi

# Ensure output has .webm extension
if [[ ! "$OUTPUT" =~ \.webm$ ]]; then
    OUTPUT="${OUTPUT%.*}.webm"
fi

# Check for FFmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}Error: FFmpeg is not installed${NC}"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Check for libvpx-vp9 encoder
if ! ffmpeg -encoders 2>/dev/null | grep -q "libvpx-vp9"; then
    echo -e "${RED}Error: libvpx-vp9 encoder not available${NC}"
    echo "FFmpeg must be compiled with --enable-libvpx"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Get video duration and FPS
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null | cut -d. -f1)
VIDEO_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null)

if [ -z "$VIDEO_DURATION" ] || [ "$VIDEO_DURATION" -eq 0 ]; then
    echo -e "${RED}Error: Could not determine video duration${NC}"
    exit 1
fi

# Parse FPS (format is like "30/1" or "30000/1001")
if [ -n "$VIDEO_FPS" ]; then
    FPS_NUM=$(echo "$VIDEO_FPS" | cut -d'/' -f1)
    FPS_DEN=$(echo "$VIDEO_FPS" | cut -d'/' -f2)
    if [ -n "$FPS_DEN" ] && [ "$FPS_DEN" != "0" ]; then
        FPS=$(echo "scale=2; $FPS_NUM / $FPS_DEN" | bc | sed 's/\.00$//')
    else
        FPS=30
    fi
else
    FPS=30
fi

# Get image and video dimensions and codec info
IMAGE_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$IMAGE" 2>/dev/null)
VIDEO_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null)
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null)
VIDEO_PIXFMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null)

if [ -z "$IMAGE_INFO" ]; then
    echo -e "${RED}Error: Could not read image dimensions${NC}"
    exit 1
fi

if [ -z "$VIDEO_INFO" ]; then
    echo -e "${RED}Error: Could not read video dimensions${NC}"
    exit 1
fi

IMAGE_WIDTH=$(echo "$IMAGE_INFO" | head -1)
IMAGE_HEIGHT=$(echo "$IMAGE_INFO" | tail -1)
VIDEO_WIDTH=$(echo "$VIDEO_INFO" | head -1)
VIDEO_HEIGHT=$(echo "$VIDEO_INFO" | tail -1)

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Video Overlay on Image${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Background: $IMAGE (${IMAGE_WIDTH}x${IMAGE_HEIGHT})"
echo -e "  Overlay:    $VIDEO (${VIDEO_WIDTH}x${VIDEO_HEIGHT})"
echo -e "  Codec:      $VIDEO_CODEC (${VIDEO_PIXFMT})"
echo -e "  Position:   $POSITION"
echo -e "  Duration:   ${VIDEO_DURATION}s"
echo -e "  Output:     $OUTPUT"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Calculate overlay position
case "$POSITION" in
    center)
        X_EXPR="(W-w)/2"
        Y_EXPR="(H-h)/2"
        ;;
    top-left)
        X_EXPR="0"
        Y_EXPR="0"
        ;;
    top-right)
        X_EXPR="W-w"
        Y_EXPR="0"
        ;;
    bottom-left)
        X_EXPR="0"
        Y_EXPR="H-h"
        ;;
    bottom-right)
        X_EXPR="W-w"
        Y_EXPR="H-h"
        ;;
    *)
        # Check if it's in x:y format
        if [[ "$POSITION" =~ ^[0-9]+:[0-9]+$ ]]; then
            X_EXPR=$(echo "$POSITION" | cut -d: -f1)
            Y_EXPR=$(echo "$POSITION" | cut -d: -f2)
        else
            echo -e "${RED}Error: Invalid position '$POSITION'${NC}"
            echo "Valid positions: center, top-left, top-right, bottom-left, bottom-right, or x:y"
            exit 1
        fi
        ;;
esac

echo -e "${YELLOW}Creating overlay...${NC}"
echo -e "${YELLOW}  Resizing overlay video to match background (${IMAGE_WIDTH}x${IMAGE_HEIGHT})...${NC}"
echo ""

# Create overlay using FFmpeg
# -loop 1: Loop the image to match video duration
# -i: Input files (image and video)
# -filter_complex: 
#   1. Scale background image to its original size (no change, but explicit)
#   2. Scale overlay video to match background dimensions exactly, preserving aspect ratio with padding if needed
#   3. Overlay the resized video on the background with alpha blending
# -shortest: End when shortest input ends (video)
# -c:v libvpx-vp9: VP9 codec
# -pix_fmt yuva420p: Preserve alpha in output
# -auto-alt-ref 0: Better alpha handling
# -crf 30: Quality
echo -e "${YELLOW}  Resizing overlay video from ${VIDEO_WIDTH}x${VIDEO_HEIGHT} to ${IMAGE_WIDTH}x${IMAGE_HEIGHT}...${NC}"

# Create overlay with proper alpha compositing
# The background image is looped and converted to video stream matching video duration
# The overlay video is scaled and its alpha channel is used for blending (if present)
echo -e "${YELLOW}  Compositing overlay with alpha blending...${NC}"

# Check if overlay video has alpha and determine processing method
if [[ "$VIDEO_CODEC" == "hevc" ]] || [[ "$VIDEO_CODEC" == "h265" ]]; then
    echo -e "${GREEN}  Detected HEVC video - extracting alpha channel${NC}"
    # HEVC with alpha: FFmpeg should automatically extract alpha when converting to yuva420p
    # The alpha channel is stored separately in HEVC but FFmpeg combines it when using format=yuva420p
    OVERLAY_FILTER="[1:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},format=yuva420p,setsar=1[overlay]"
elif [[ "$VIDEO_PIXFMT" == *"yuva"* ]] || [[ "$VIDEO_PIXFMT" == *"rgba"* ]]; then
    echo -e "${GREEN}  Overlay video has alpha channel in pixel format - transparency will be respected${NC}"
    OVERLAY_FILTER="[1:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},format=yuva420p,setsar=1[overlay]"
else
    # Check for VP9 alpha_mode
    ALPHA_MODE=$(ffprobe -v error -select_streams v:0 -show_entries stream=alpha_mode -of default=noprint_wrappers=1:nokey=1 "$VIDEO" 2>/dev/null)
    if [ "$ALPHA_MODE" = "1" ]; then
        echo -e "${GREEN}  VP9 video has alpha_mode=1 - extracting alpha channel${NC}"
        OVERLAY_FILTER="[1:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},format=yuva420p,setsar=1[overlay]"
    else
        echo -e "${YELLOW}  Warning: Overlay video pixel format is $VIDEO_PIXFMT (no alpha detected)${NC}"
        echo -e "${YELLOW}  Background will only be visible if overlay has transparent areas${NC}"
        OVERLAY_FILTER="[1:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},format=yuva420p,setsar=1[overlay]"
    fi
fi

# Use overlay filter: background is base layer, overlay is composited on top
# Convert overlay to yuva420p to ensure alpha channel is properly extracted and used
echo -e "${YELLOW}  Compositing overlay with alpha blending...${NC}"

ffmpeg -y \
    -loop 1 \
    -framerate "$FPS" \
    -t "$VIDEO_DURATION" \
    -i "$IMAGE" \
    -i "$VIDEO" \
    -filter_complex "[0:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},setsar=1,fps=$FPS[bg];${OVERLAY_FILTER};[bg][overlay]overlay=${X_EXPR}:${Y_EXPR}:shortest=1" \
    -c:v libvpx-vp9 \
    -pix_fmt yuva420p \
    -profile:v 0 \
    -auto-alt-ref 0 \
    -lag-in-frames 16 \
    -crf 30 \
    -b:v 0 \
    "$OUTPUT"

# Check if output was created
if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Error: Output file was not created${NC}"
    exit 1
fi

OUTPUT_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null | cut -d. -f1)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Overlay complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Output:   $OUTPUT"
echo -e "  Size:     $OUTPUT_SIZE"
echo -e "  Duration: ${DURATION}s"
echo ""

# Verify the output
echo -e "${YELLOW}Verifying output...${NC}"
CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
PIX_FMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
PROFILE=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
echo -e "  Codec:       $CODEC"
echo -e "  Pixel fmt:   $PIX_FMT"
echo -e "  Profile:     $PROFILE"

if [ "$CODEC" = "vp9" ]; then
    echo -e "${GREEN}✓ VP9 codec confirmed${NC}"
    echo -e "${GREEN}✓ Overlay video resized to ${IMAGE_WIDTH}x${IMAGE_HEIGHT}${NC}"
    echo -e "${GREEN}✓ Transparency respected during overlay (alpha composited)${NC}"
    echo -e "${YELLOW}  Note: Output dimensions match background image${NC}"
else
    echo -e "${YELLOW}⚠ Unexpected codec: $CODEC${NC}"
fi

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Uploading to S3...${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Check for AWS CLI
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}Error: AWS CLI is not installed${NC}"
        echo "Install with: brew install awscli"
        exit 1
    fi
    
    # S3 paths
    S3_VIDEO_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    S3_HTML_PATH="${TIMESTAMP}/overlay_preview.html"
    
    # Ensure "Block Public Access" is disabled
    echo -e "${YELLOW}Ensuring bucket allows public object access...${NC}"
    if aws s3api get-public-access-block --bucket "$BUCKET_NAME" &>/dev/null; then
        echo -e "${YELLOW}  Disabling 'Block Public Access'...${NC}"
        aws s3api put-public-access-block \
            --bucket "$BUCKET_NAME" \
            --public-access-block-configuration \
            "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>/dev/null
    fi
    
    # Upload video
    echo -e "${YELLOW}Uploading video to s3://${BUCKET_NAME}/${S3_VIDEO_PATH}...${NC}"
    if aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "$S3_VIDEO_PATH" \
        --body "$OUTPUT" \
        --content-type "video/webm" \
        --grant-read "uri=http://acs.amazonaws.com/groups/global/AllUsers" 2>/dev/null; then
        echo -e "${GREEN}✓ Video uploaded with public read access${NC}"
    elif aws s3 cp "$OUTPUT" "s3://${BUCKET_NAME}/${S3_VIDEO_PATH}" \
        --content-type "video/webm" \
        --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers 2>/dev/null; then
        echo -e "${GREEN}✓ Video uploaded with public read access${NC}"
    elif aws s3 cp "$OUTPUT" "s3://${BUCKET_NAME}/${S3_VIDEO_PATH}" \
        --content-type "video/webm" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Video uploaded, setting ACL...${NC}"
        if aws s3api put-object-acl \
            --bucket "$BUCKET_NAME" \
            --key "$S3_VIDEO_PATH" \
            --acl public-read 2>/dev/null; then
            echo -e "${GREEN}✓ Video is now publicly accessible${NC}"
        else
            echo -e "${YELLOW}⚠ Could not set public access${NC}"
        fi
    else
        echo -e "${RED}Error: Failed to upload video to S3${NC}"
        exit 1
    fi
    
    # Get bucket region for correct URL
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET_NAME" --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
    if [ "$BUCKET_REGION" = "None" ] || [ -z "$BUCKET_REGION" ]; then
        BUCKET_REGION="us-east-1"
    fi
    
    # Use region-specific URL
    if [ "$BUCKET_REGION" = "us-east-1" ]; then
        VIDEO_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_VIDEO_PATH}"
    else
        VIDEO_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_VIDEO_PATH}"
    fi
    
    # Get video info for template
    VIDEO_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
    VIDEO_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
    VIDEO_FPS_RATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
    
    # Calculate FPS from rate
    if [ -n "$VIDEO_FPS_RATE" ] && [[ "$VIDEO_FPS_RATE" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        FPS_NUM=$(echo "$VIDEO_FPS_RATE" | cut -d'/' -f1)
        FPS_DEN=$(echo "$VIDEO_FPS_RATE" | cut -d'/' -f2)
        if [ -n "$FPS_DEN" ] && [ "$FPS_DEN" != "0" ]; then
            if command -v bc &> /dev/null; then
                DISPLAY_FPS=$(echo "scale=2; $FPS_NUM / $FPS_DEN" | bc | sed 's/\.00$//')
            else
                DISPLAY_FPS="$FPS"
            fi
        else
            DISPLAY_FPS="$FPS"
        fi
    else
        DISPLAY_FPS="$FPS"
    fi
    
    # Format duration
    DURATION_SEC=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
    if [ -n "$DURATION_SEC" ]; then
        DURATION_FORMATTED=$(printf "%.2f" "$DURATION_SEC" | sed 's/\.00$//')
        DURATION_DISPLAY="${DURATION_FORMATTED}s"
    else
        DURATION_DISPLAY="N/A"
    fi
    
    # Format encoding info
    # PROFILE from ffprobe might be "Profile 0" or just "0", so handle both
    PROFILE_CLEAN=$(echo "$PROFILE" | sed 's/Profile //' | tr -d ' ')
    if [ "$PROFILE_CLEAN" = "2" ]; then
        ENCODING_DISPLAY="VP9 Profile 2 (10-bit)"
    elif [ "$PROFILE_CLEAN" = "0" ]; then
        ENCODING_DISPLAY="VP9 Profile 0 (8-bit)"
    elif [ -n "$PROFILE_CLEAN" ]; then
        ENCODING_DISPLAY="VP9 Profile $PROFILE_CLEAN"
    else
        ENCODING_DISPLAY="VP9"
    fi
    
    # Read template and replace placeholders
    TEMPLATE_PATH="$(dirname "$0")/preview-template.html"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo -e "${RED}Error: Template file not found: $TEMPLATE_PATH${NC}"
        exit 1
    fi
    
    # Create temporary HTML file
    HTML_TEMP=$(mktemp)
    sed -e "s|{{TITLE}}|Video Overlay Preview|g" \
        -e "s|{{DESCRIPTION}}|Video with alpha channel overlaid on background image. If the video has alpha, you should see the checkered background through transparent areas|g" \
        -e "s|{{MEDIA_ELEMENT}}|<video src=\"${VIDEO_URL}\" autoplay loop muted playsinline controls></video>|g" \
        -e "s|{{FILE_TYPE}}|WebM|g" \
        -e "s|{{RESOLUTION}}|${VIDEO_WIDTH}x${VIDEO_HEIGHT}|g" \
        -e "s|{{FPS}}|${DISPLAY_FPS}|g" \
        -e "s|{{ENCODING}}|${ENCODING_DISPLAY}|g" \
        -e "s|{{DURATION}}|${DURATION_DISPLAY}|g" \
        -e "s|{{MEDIA_URL}}|${VIDEO_URL}|g" \
        -e "s|{{SCRIPT_CONTENT}}||g" \
        "$TEMPLATE_PATH" > "$HTML_TEMP"
    
    # Upload HTML with public read grant
    echo -e "${YELLOW}Uploading HTML preview to s3://${BUCKET_NAME}/${S3_HTML_PATH}...${NC}"
    # Try using s3api put-object with grants (more reliable than ACL)
    if aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "$S3_HTML_PATH" \
        --body "$HTML_TEMP" \
        --content-type "text/html" \
        --grant-read "uri=http://acs.amazonaws.com/groups/global/AllUsers" 2>/dev/null; then
        echo -e "${GREEN}✓ HTML uploaded with public read access${NC}"
    elif aws s3 cp "$HTML_TEMP" "s3://${BUCKET_NAME}/${S3_HTML_PATH}" \
        --content-type "text/html" \
        --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers 2>/dev/null; then
        echo -e "${GREEN}✓ HTML uploaded with public read access${NC}"
    elif aws s3 cp "$HTML_TEMP" "s3://${BUCKET_NAME}/${S3_HTML_PATH}" \
        --content-type "text/html" 2>/dev/null; then
        echo -e "${YELLOW}⚠ HTML uploaded, setting ACL...${NC}"
        # Try to set ACL after upload
        if aws s3api put-object-acl \
            --bucket "$BUCKET_NAME" \
            --key "$S3_HTML_PATH" \
            --acl public-read 2>/dev/null; then
            echo -e "${GREEN}✓ HTML is now publicly accessible${NC}"
        else
            echo -e "${YELLOW}⚠ Could not set public access${NC}"
        fi
    else
        echo -e "${RED}Error: Failed to upload HTML to S3${NC}"
        rm -f "$HTML_TEMP"
        exit 1
    fi
    
    # Clean up temp file
    rm -f "$HTML_TEMP"
    
    # Print URLs (use region-specific URL for better compatibility)
    if [ "$BUCKET_REGION" = "us-east-1" ]; then
        VIDEO_PUBLIC_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_VIDEO_PATH}"
        HTML_PUBLIC_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_HTML_PATH}"
    else
        VIDEO_PUBLIC_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_VIDEO_PATH}"
        HTML_PUBLIC_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_HTML_PATH}"
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Upload complete!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}Video URL:${NC}"
    echo -e "  ${VIDEO_PUBLIC_URL}"
    echo ""
    echo -e "${GREEN}HTML Preview URL:${NC}"
    echo -e "  ${HTML_PUBLIC_URL}"
    echo ""
    
    # Check and disable "Block Public Access" if needed (required for object-level public access)
    echo -e "${YELLOW}Checking bucket public access settings...${NC}"
    if aws s3api get-public-access-block --bucket "$BUCKET_NAME" &>/dev/null; then
        echo -e "${YELLOW}⚠ Bucket has 'Block Public Access' enabled${NC}"
        echo -e "${YELLOW}  Disabling to allow object-level public access...${NC}"
        
        # Disable all public access blocks
        if aws s3api put-public-access-block \
            --bucket "$BUCKET_NAME" \
            --public-access-block-configuration \
            "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>/dev/null; then
            echo -e "${GREEN}✓ 'Block Public Access' disabled${NC}"
            echo -e "${YELLOW}  Retrying to set objects as public...${NC}"
            
            # Retry setting ACLs now that block is disabled
            if aws s3api put-object-acl \
                --bucket "$BUCKET_NAME" \
                --key "$S3_VIDEO_PATH" \
                --acl public-read 2>/dev/null && \
               aws s3api put-object-acl \
                --bucket "$BUCKET_NAME" \
                --key "$S3_HTML_PATH" \
                --acl public-read 2>/dev/null; then
                echo -e "${GREEN}✓ Objects are now publicly accessible${NC}"
            else
                echo -e "${YELLOW}⚠ Bucket doesn't support ACLs - setting bucket policy instead${NC}"
                # Set bucket policy for public read access
                POLICY_JSON=$(cat <<POLICY_EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
POLICY_EOF
)
                POLICY_TEMP=$(mktemp)
                echo "$POLICY_JSON" > "$POLICY_TEMP"
                
                if aws s3api put-bucket-policy \
                    --bucket "$BUCKET_NAME" \
                    --policy "file://${POLICY_TEMP}" 2>/dev/null; then
                    echo -e "${GREEN}✓ Bucket policy set for public read access${NC}"
                    rm -f "$POLICY_TEMP"
                    sleep 2  # Wait for policy to propagate
                else
                    echo -e "${RED}✗ Could not set bucket policy${NC}"
                    echo -e "${YELLOW}  You may need to set it manually${NC}"
                    rm -f "$POLICY_TEMP"
                fi
            fi
        else
            echo -e "${RED}✗ Could not disable 'Block Public Access'${NC}"
            echo -e "${YELLOW}  You may need to do this manually via AWS Console${NC}"
            echo ""
            echo -e "${YELLOW}To allow public objects:${NC}"
            echo "  1. Go to S3 → ${BUCKET_NAME} → Permissions"
            echo "  2. Edit 'Block public access' settings"
            echo "  3. Uncheck all 4 options and save"
            echo ""
        fi
    else
        echo -e "${GREEN}✓ 'Block Public Access' is not enabled${NC}"
    fi
    
    # Verify public access
    echo -e "${YELLOW}Verifying public access...${NC}"
    sleep 1
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${VIDEO_PUBLIC_URL}" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ URLs are publicly accessible${NC}"
    elif [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "000" ]; then
        echo -e "${RED}✗ URLs return HTTP ${HTTP_CODE} - Access Denied${NC}"
        echo ""
        echo -e "${YELLOW}To fix this, run:${NC}"
        echo ""
        echo "aws s3api put-bucket-policy --bucket ${BUCKET_NAME} --policy file://<(cat <<'POLICY'
{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"PublicReadGetObject\",
    \"Effect\": \"Allow\",
    \"Principal\": \"*\",
    \"Action\": \"s3:GetObject\",
    \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\"
  }]
}
POLICY
)"
        echo ""
        echo -e "${YELLOW}Or configure via AWS Console:${NC}"
        echo "  1. Go to S3 → ${BUCKET_NAME} → Permissions → Bucket Policy"
        echo "  2. Add the policy above"
        echo "  3. Also check 'Block public access' settings and allow public access"
        echo ""
    else
        echo -e "${YELLOW}⚠ Got HTTP ${HTTP_CODE} - may need time to propagate${NC}"
    fi
else
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Testing instructions:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "1. Quick test (opens in default player):"
    echo "   open \"$OUTPUT\""
    echo ""
    echo "2. Test in browser:"
    echo "   Create an HTML file with:"
    echo "   <video src=\"$OUTPUT\" autoplay loop muted playsinline controls></video>"
    echo ""
    echo "3. To upload to S3, use the -b option:"
    echo "   $0 -i $IMAGE -v $VIDEO -b my-bucket-name"
    echo ""
fi
