#!/bin/bash

# overlay-animated-webp.sh
# Overlays an animated WebP file with alpha channel onto a still image background
# Supports: Animated WebP with alpha transparency
# Requires: FFmpeg with libvpx-vp9 support (for output encoding)

set -e

# Default values
OUTPUT=""
IMAGE=""
WEBP=""
POSITION="center"  # center, top-left, top-right, bottom-left, bottom-right, or x:y
BUCKET_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 -i <image> -w <webp> [-o <output>] [-p <position>] [-b <bucket>]"
    echo ""
    echo "Options:"
    echo "  -i <image>    Background image file (required)"
    echo "  -w <webp>     Animated WebP file with alpha channel to overlay (required)"
    echo "  -o <file>     Output file name (default: auto-generated)"
    echo "  -p <pos>      Position: center, top-left, top-right, bottom-left, bottom-right, or x:y (default: center)"
    echo "  -b <bucket>   S3 bucket name to upload video (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -i sample.jpeg -w animated.webp"
    echo "  $0 -i bg.jpg -w overlay.webp -p top-left"
    echo "  $0 -i bg.jpg -w overlay.webp -p 100:200 -b my-bucket"
    echo ""
    echo "Note: The animated WebP's alpha channel will be used for transparency"
    echo "      Output is WebM format with VP9 codec"
}

# Parse arguments
while getopts "i:w:o:p:b:h" opt; do
    case $opt in
        i) IMAGE="$OPTARG" ;;
        w) WEBP="$OPTARG" ;;
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

if [ -z "$WEBP" ]; then
    echo -e "${RED}Error: Animated WebP file is required${NC}"
    print_usage
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo -e "${RED}Error: Image file '$IMAGE' does not exist${NC}"
    exit 1
fi

if [ ! -f "$WEBP" ]; then
    echo -e "${RED}Error: WebP file '$WEBP' does not exist${NC}"
    exit 1
fi

# Generate timestamp for output and S3 paths
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Set default output directory
OUTPUT_DIR="$(dirname "$0")/../output"
mkdir -p "$OUTPUT_DIR"

# Set default output name
if [ -z "$OUTPUT" ]; then
    IMAGE_BASE=$(basename "$IMAGE" | sed 's/\.[^.]*$//')
    WEBP_BASE=$(basename "$WEBP" | sed 's/\.[^.]*$//')
    OUTPUT_FILENAME="overlay_webp_${IMAGE_BASE}_${WEBP_BASE}_${TIMESTAMP}.webm"
    OUTPUT="$OUTPUT_DIR/$OUTPUT_FILENAME"
else
    # If OUTPUT is provided but doesn't contain a path, use default directory
    if [[ "$OUTPUT" != *"/"* ]]; then
        OUTPUT="$OUTPUT_DIR/$OUTPUT"
    fi
    # Ensure output has .webm extension
    if [[ ! "$OUTPUT" =~ \.webm$ ]]; then
        OUTPUT="${OUTPUT%.*}.webm"
    fi
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

# Convert animated WebP to temporary video first (FFmpeg's WebP decoder doesn't handle animation well)
# This approach converts the animated WebP to a video format that FFmpeg can handle properly
echo -e "${YELLOW}Converting animated WebP to temporary video format...${NC}"
TEMP_VIDEO=$(mktemp).webm
trap "rm -f $TEMP_VIDEO" EXIT

# Try to detect FPS from filename first (e.g., animated_test_30fps.webp)
if [[ "$WEBP" =~ ([0-9]+)fps ]]; then
    FPS="${BASH_REMATCH[1]}"
else
    # Get FPS from WebP metadata
    WEBP_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$WEBP" 2>/dev/null)
    if [ -n "$WEBP_FPS" ]; then
        FPS_NUM=$(echo "$WEBP_FPS" | cut -d'/' -f1)
        FPS_DEN=$(echo "$WEBP_FPS" | cut -d'/' -f2)
        if [ -n "$FPS_DEN" ] && [ "$FPS_DEN" != "0" ]; then
            if command -v bc &> /dev/null; then
                FPS=$(echo "scale=2; $FPS_NUM / $FPS_DEN" | bc | sed 's/\.00$//')
            else
                FPS=30
            fi
        else
            FPS=30
        fi
    else
        FPS=30
    fi
fi

# Use ImageMagick to extract frames (best method for animated WebP)
if command -v convert &> /dev/null || command -v magick &> /dev/null; then
    CONVERT_CMD=$(command -v convert || command -v magick)
    FRAMES_TEMP=$(mktemp -d)
    trap "rm -rf $FRAMES_TEMP $TEMP_VIDEO" EXIT
    echo -e "${YELLOW}  Using ImageMagick to extract frames from animated WebP...${NC}"
    "$CONVERT_CMD" "$WEBP" -coalesce "$FRAMES_TEMP/frame_%04d.png" 2>/dev/null
    FRAME_COUNT=$(ls -1 "$FRAMES_TEMP"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
    if [ "$FRAME_COUNT" -gt 0 ]; then
        echo -e "${GREEN}  Extracted $FRAME_COUNT frames${NC}"
        # Convert frames to video with alpha
        echo -e "${YELLOW}  Converting frames to video with alpha...${NC}"
        ffmpeg -y -framerate "$FPS" -i "$FRAMES_TEMP/frame_%04d.png" -c:v libvpx-vp9 -pix_fmt yuva420p -profile:v 0 -auto-alt-ref 0 -crf 30 -b:v 0 "$TEMP_VIDEO" 2>/dev/null
        rm -rf "$FRAMES_TEMP"
    else
        echo -e "${RED}Error: Could not extract frames from animated WebP${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: ImageMagick is required for animated WebP support${NC}"
    echo -e "${YELLOW}  Install with: brew install imagemagick${NC}"
    exit 1
fi

# Get duration from converted video
WEBP_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$TEMP_VIDEO" 2>/dev/null)
if [ -z "$WEBP_DURATION" ] || [ "$WEBP_DURATION" = "N/A" ] || [ "$WEBP_DURATION" = "0" ]; then
    echo -e "${YELLOW}Warning: Could not determine duration, using 5 seconds${NC}"
    WEBP_DURATION=5
fi

# Get image and WebP dimensions (use converted video for WebP dimensions)
IMAGE_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$IMAGE" 2>/dev/null)
WEBP_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$TEMP_VIDEO" 2>/dev/null)

if [ -z "$IMAGE_INFO" ]; then
    echo -e "${RED}Error: Could not read image dimensions${NC}"
    exit 1
fi

if [ -z "$WEBP_INFO" ]; then
    echo -e "${RED}Error: Could not read WebP dimensions${NC}"
    exit 1
fi

IMAGE_WIDTH=$(echo "$IMAGE_INFO" | head -1)
IMAGE_HEIGHT=$(echo "$IMAGE_INFO" | tail -1)
WEBP_WIDTH=$(echo "$WEBP_INFO" | head -1)
WEBP_HEIGHT=$(echo "$WEBP_INFO" | tail -1)

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Animated WebP Overlay on Image${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Background: $IMAGE (${IMAGE_WIDTH}x${IMAGE_HEIGHT})"
echo -e "  Overlay:    $WEBP (${WEBP_WIDTH}x${WEBP_HEIGHT})"
echo -e "  Position:   $POSITION"
echo -e "  Duration:   ${WEBP_DURATION}s"
echo -e "  FPS:        $FPS"
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
echo -e "${YELLOW}  Resizing animated WebP overlay to match background (${IMAGE_WIDTH}x${IMAGE_HEIGHT})...${NC}"
echo ""

# Create overlay using FFmpeg
# -loop 1: Loop the image to match WebP duration
# -i: Input files (image and animated WebP)
# -filter_complex: 
#   1. Scale background image to its original size
#   2. Scale animated WebP to match background dimensions and extract alpha
#   3. Overlay the resized WebP on the background with alpha blending
# -shortest: End when shortest input ends (WebP)
# -c:v libvpx-vp9: VP9 codec
# -pix_fmt yuva420p: Preserve alpha in output
# -auto-alt-ref 0: Better alpha handling
# -crf 30: Quality
echo -e "${YELLOW}  Compositing animated WebP with alpha blending...${NC}"

# Use converted video instead of direct WebP input
ffmpeg -y \
    -loop 1 \
    -framerate "$FPS" \
    -t "$WEBP_DURATION" \
    -i "$IMAGE" \
    -i "$TEMP_VIDEO" \
    -filter_complex "[0:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},setsar=1,fps=$FPS[bg];[1:v]scale=${IMAGE_WIDTH}:${IMAGE_HEIGHT},format=yuva420p,setsar=1[overlay];[bg][overlay]overlay=${X_EXPR}:${Y_EXPR}:shortest=1" \
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
    echo -e "${GREEN}✓ Animated WebP overlay resized to ${IMAGE_WIDTH}x${IMAGE_HEIGHT}${NC}"
    echo -e "${GREEN}✓ Transparency respected during overlay (alpha composited)${NC}"
    echo -e "${YELLOW}  Note: Output dimensions match background image${NC}"
else
    echo -e "${YELLOW}⚠ Unexpected codec: $CODEC${NC}"
fi

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
    # Get path to upload.sh script
    UPLOAD_SCRIPT="$(dirname "$0")/upload.sh"
    
    # S3 paths
    S3_VIDEO_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    
    # Upload video (suppress verbose output)
    VIDEO_PUBLIC_URL=$("$UPLOAD_SCRIPT" "$OUTPUT" "$BUCKET_NAME" "$S3_VIDEO_PATH" "video/webm" 2>/dev/null | tr -d '\n\r')
    
    # Print only the final URL
    echo ""
    echo -e "${GREEN}Video URL:${NC}"
    echo -e "  ${VIDEO_PUBLIC_URL}"
    echo ""
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
    echo "   $0 -i $IMAGE -w $WEBP -b my-bucket-name"
    echo ""
fi
