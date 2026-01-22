#!/bin/bash

# frames-to-webm-alpha.sh
# Converts WebP frames with transparency to WebM video with alpha channel
# Uses VP9 codec with profile 2 and yuva420p pixel format for alpha support
# Requires: FFmpeg with libvpx-vp9 support

set -e

# Default values
FPS=30
OUTPUT=""
INPUT_DIR=""
BUCKET_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 -i <input_folder> [-f <fps>] [-o <output_file>] [-b <bucket>]"
    echo ""
    echo "Options:"
    echo "  -i <folder>   Input folder containing WebP frames (required)"
    echo "  -f <fps>      Frames per second (default: 30)"
    echo "  -o <file>     Output file name (default: auto-generated)"
    echo "  -b <bucket>   S3 bucket name to upload video and HTML preview (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -i ./frames -f 24 -o my_video.webm"
    echo "  $0 -i ./frames -b my-green-screen-bucket"
    echo ""
    echo "Note: Input frames should be named sequentially (e.g., frame_00000.webp)"
    echo "      Output uses VP9 codec with profile 2 and yuva420p for alpha transparency"
}

# Parse arguments
while getopts "i:f:o:b:h" opt; do
    case $opt in
        i) INPUT_DIR="$OPTARG" ;;
        f) FPS="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        b) BUCKET_NAME="$OPTARG" ;;
        h) print_usage; exit 0 ;;
        *) print_usage; exit 1 ;;
    esac
done

# Validate input
if [ -z "$INPUT_DIR" ]; then
    echo -e "${RED}Error: Input folder is required${NC}"
    print_usage
    exit 1
fi

if [ ! -d "$INPUT_DIR" ]; then
    echo -e "${RED}Error: Input folder '$INPUT_DIR' does not exist${NC}"
    exit 1
fi

# Generate timestamp for output and S3 paths
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Set default output directory
OUTPUT_DIR="$(dirname "$0")/../output"
mkdir -p "$OUTPUT_DIR"

# Set default output name
if [ -z "$OUTPUT" ]; then
    OUTPUT_FILENAME="webm_alpha_${TIMESTAMP}.webm"
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

# Count frames
FRAME_COUNT=$(ls -1 "$INPUT_DIR"/*.webp 2>/dev/null | wc -l | tr -d ' ')

if [ "$FRAME_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No WebP files found in '$INPUT_DIR'${NC}"
    exit 1
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Frames to WebM with Alpha${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Input:   $INPUT_DIR ($FRAME_COUNT frames)"
echo -e "  Output:  $OUTPUT"
    echo -e "  Format:  VP9 with Alpha (Profile 2 preferred, falls back to Profile 0)"
echo -e "  FPS:     $FPS"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Detect frame naming pattern
FIRST_FRAME=$(ls -1 "$INPUT_DIR"/*.webp | head -1)
FRAME_NAME=$(basename "$FIRST_FRAME")

# Try to detect pattern
if [[ "$FRAME_NAME" =~ ^frame_[0-9]+\.webp$ ]]; then
    PATTERN="$INPUT_DIR/frame_%05d.webp"
    echo -e "Detected pattern: frame_XXXXX.webp"
elif [[ "$FRAME_NAME" =~ ^[0-9]+\.webp$ ]]; then
    PATTERN="$INPUT_DIR/%05d.webp"
    echo -e "Detected pattern: XXXXX.webp"
else
    echo -e "${YELLOW}Warning: Non-standard frame naming detected${NC}"
    echo -e "Expected: frame_00000.webp, frame_00001.webp, ..."
    echo -e "Found: $FRAME_NAME"
    PATTERN="$INPUT_DIR/frame_%05d.webp"
fi

echo ""
echo -e "${YELLOW}Converting frames to WebM VP9 with alpha...${NC}"
echo ""

# WebM VP9 with alpha using profile 2 and yuva420p10le
# Note: VP9 profile 2 requires 10-bit input
# -c:v libvpx-vp9: Use VP9 codec
# -vf format=yuva420p10le: Convert input to 10-bit with alpha (required for profile 2)
# -pix_fmt yuva420p10le: 4:2:0 with alpha channel, 10-bit (required for profile 2)
# -profile:v 2: VP9 profile 2 (supports alpha with 10-bit)
# -auto-alt-ref 0: Disable alt-ref for better alpha handling
# -lag-in-frames 16: Number of frames to look ahead
# -crf 30: Quality (lower = better, 0-63, default 31)
# -b:v 0: Use CRF mode (bitrate is variable)
echo -e "${GREEN}Using VP9 encoder with profile 2 and alpha channel (10-bit)${NC}"

# First, check if we can encode with profile 2 (10-bit)
# If that fails, fall back to profile 0 (8-bit) which also supports alpha
if ffmpeg -y \
    -framerate "$FPS" \
    -i "$PATTERN" \
    -vf format=yuva420p10le \
    -c:v libvpx-vp9 \
    -pix_fmt yuva420p10le \
    -profile:v 2 \
    -auto-alt-ref 0 \
    -lag-in-frames 16 \
    -crf 30 \
    -b:v 0 \
    "$OUTPUT" 2>&1 | tee /tmp/ffmpeg_output.log | grep -q "Error\|Failed"; then
    echo -e "${YELLOW}Profile 2 (10-bit) failed, trying profile 0 (8-bit) with alpha...${NC}"
    rm -f "$OUTPUT"
    # Fall back to profile 0 with 8-bit alpha
    ffmpeg -y \
        -framerate "$FPS" \
        -i "$PATTERN" \
        -c:v libvpx-vp9 \
        -pix_fmt yuva420p \
        -profile:v 0 \
        -auto-alt-ref 0 \
        -lag-in-frames 16 \
        -crf 30 \
        -b:v 0 \
        "$OUTPUT"
    echo -e "${YELLOW}Using VP9 profile 0 (8-bit) with alpha${NC}"
else
    echo -e "${GREEN}Successfully encoded with VP9 profile 2 (10-bit)${NC}"
fi

# Check if output was created
if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Error: Output file was not created${NC}"
    exit 1
fi

OUTPUT_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null | cut -d. -f1)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Conversion complete!${NC}"
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

# Check for alpha - VP9 stores alpha in the codec, not always visible in pixel format
# Profile 0 and 2 both support alpha when encoded with yuva420p/yuva420p10le
if [ "$CODEC" = "vp9" ]; then
    if [ "$PROFILE" = "2" ]; then
        echo -e "${GREEN}✓ VP9 Profile 2 confirmed (10-bit with alpha support)${NC}"
        echo -e "${GREEN}✓ Alpha channel should be present (encoded with yuva420p10le)${NC}"
    elif [ "$PROFILE" = "0" ]; then
        echo -e "${GREEN}✓ VP9 Profile 0 confirmed (8-bit with alpha support)${NC}"
        echo -e "${GREEN}✓ Alpha channel should be present (encoded with yuva420p)${NC}"
    else
        echo -e "${YELLOW}⚠ Profile is $PROFILE - alpha support depends on encoding settings${NC}"
    fi
    echo -e "${YELLOW}  Note: Test in browser to verify alpha transparency${NC}"
else
    echo -e "${RED}✗ Unexpected codec: $CODEC${NC}"
fi

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
    # Get path to upload.sh script
    UPLOAD_SCRIPT="$(dirname "$0")/upload.sh"
    
    # S3 paths
    S3_VIDEO_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    S3_HTML_PATH="${TIMESTAMP}/webm_preview.html"
    
    # Upload video (suppress verbose output)
    VIDEO_URL=$("$UPLOAD_SCRIPT" "$OUTPUT" "$BUCKET_NAME" "$S3_VIDEO_PATH" "video/webm" 2>/dev/null | tr -d '\n\r')
    
    # Get video info for template (FPS and duration still from ffprobe, resolution from browser)
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
    if [ "$PROFILE" = "2" ]; then
        ENCODING_DISPLAY="VP9 Profile 2 (10-bit)"
    elif [ "$PROFILE" = "0" ]; then
        ENCODING_DISPLAY="VP9 Profile 0 (8-bit)"
    else
        ENCODING_DISPLAY="VP9 Profile $PROFILE"
    fi
    
    # Read template and replace placeholders
    TEMPLATE_PATH="$(dirname "$0")/preview-template.html"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo -e "${RED}Error: Template file not found: $TEMPLATE_PATH${NC}"
        exit 1
    fi
    
    # Escape VIDEO_URL for sed
    ESCAPED_VIDEO_URL=$(printf '%s\n' "$VIDEO_URL" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Add JavaScript to detect resolution from video element
    RESOLUTION_SCRIPT='<script>
        function updateResolution() {
            const video = document.querySelector("video");
            const resolutionElement = document.querySelector(".media-info-row:nth-child(2) .media-info-value");
            if (video && resolutionElement) {
                const updateRes = () => {
                    if (video.videoWidth > 0 && video.videoHeight > 0) {
                        resolutionElement.textContent = video.videoWidth + "x" + video.videoHeight;
                    }
                };
                if (video.readyState >= 2) {
                    updateRes();
                } else {
                    video.addEventListener("loadedmetadata", updateRes, { once: true });
                }
            }
        }
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", updateResolution);
        } else {
            updateResolution();
        }
    </script>'
    
    # Create temporary HTML file
    HTML_TEMP=$(mktemp)
    sed -e "s|{{TITLE}}|WebM VP9 Alpha Preview|g" \
        -e "s|{{DESCRIPTION}}|If the video has alpha, you should see the checkered background through transparent areas|g" \
        -e "s|{{MEDIA_ELEMENT}}|<video src=\"${ESCAPED_VIDEO_URL}\" autoplay loop muted playsinline controls></video>|g" \
        -e "s|{{FILE_TYPE}}|WebM|g" \
        -e "s|{{RESOLUTION}}|Detecting...|g" \
        -e "s|{{FPS}}|${DISPLAY_FPS}|g" \
        -e "s|{{ENCODING}}|${ENCODING_DISPLAY}|g" \
        -e "s|{{DURATION}}|${DURATION_DISPLAY}|g" \
        -e "s|{{MEDIA_URL}}|${ESCAPED_VIDEO_URL}|g" \
        -e "s|{{SCRIPT_CONTENT}}|${RESOLUTION_SCRIPT}|g" \
        "$TEMPLATE_PATH" > "$HTML_TEMP"
    
    # Upload HTML preview (suppress verbose output)
    HTML_PUBLIC_URL=$("$UPLOAD_SCRIPT" "$HTML_TEMP" "$BUCKET_NAME" "$S3_HTML_PATH" "text/html" 2>/dev/null | tr -d '\n\r')
    
    # Clean up temp file
    rm -f "$HTML_TEMP"
    
    # Print only the final URLs
    echo ""
    echo -e "${GREEN}Video URL:${NC}"
    echo -e "  ${VIDEO_URL}"
    echo ""
    echo -e "${GREEN}HTML Preview URL:${NC}"
    echo -e "  ${HTML_PUBLIC_URL}"
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
    echo "2. Test transparency in browser:"
    echo "   Create an HTML file with:"
    echo "   <video src=\"$OUTPUT\" autoplay loop muted playsinline></video>"
    echo ""
    echo "3. WebM VP9 with alpha works in Chrome, Firefox, and Edge"
    echo "   For iOS Safari, use HEVC format instead"
    echo ""
    echo "4. To upload to S3, use the -b option:"
    echo "   $0 -i $INPUT_DIR -b my-bucket-name"
    echo ""
fi
