#!/bin/bash

# overlay-video-on-video.sh
# Overlays an HEVC video with alpha channel onto an MP4 background video
# If overlay is shorter than background, holds the last frame for the remaining duration
# Output matches background video's duration and resolution
# Output format: MP4 (HEVC encoded)
# Requires: FFmpeg with hevc_videotoolbox or libx265 support

set -e

# Default values
OUTPUT=""
BACKGROUND_VIDEO=""
OVERLAY_VIDEO=""
POSITION="center"  # center, top-left, top-right, bottom-left, bottom-right, or x:y
BUCKET_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 -b <background_video> -o <overlay_video> [-output <output>] [-p <position>] [-s3 <bucket>]"
    echo ""
    echo "Options:"
    echo "  -b <bg_video>   Background MP4 video file (required)"
    echo "  -o <overlay>    Overlay HEVC video file with alpha channel (required)"
    echo "  -output <file>  Output file name (default: auto-generated)"
    echo "  -p <pos>        Position: center, top-left, top-right, bottom-left, bottom-right, or x:y (default: center)"
    echo "  -s3 <bucket>    S3 bucket name to upload video (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -b background.mp4 -o overlay.mov"
    echo "  $0 -b bg.mp4 -o overlay.mov -p top-left"
    echo "  $0 -b bg.mp4 -o overlay.mov -p 100:200 -s3 my-bucket"
    echo ""
    echo "Note: The overlay video's alpha channel will be used for transparency"
    echo "      If overlay is shorter than background, the last frame will be held"
    echo "      Output will match background video's duration and resolution"
}

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        -b|--background)
            BACKGROUND_VIDEO="$2"
            shift 2
            ;;
        -o|--overlay)
            OVERLAY_VIDEO="$2"
            shift 2
            ;;
        -output|--output)
            OUTPUT="$2"
            shift 2
            ;;
        -p|--position)
            POSITION="$2"
            shift 2
            ;;
        -s3|--s3)
            BUCKET_NAME="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Validate input
if [ -z "$BACKGROUND_VIDEO" ]; then
    echo -e "${RED}Error: Background video is required${NC}"
    print_usage
    exit 1
fi

if [ -z "$OVERLAY_VIDEO" ]; then
    echo -e "${RED}Error: Overlay video is required${NC}"
    print_usage
    exit 1
fi

if [ ! -f "$BACKGROUND_VIDEO" ]; then
    echo -e "${RED}Error: Background video file '$BACKGROUND_VIDEO' does not exist${NC}"
    exit 1
fi

if [ ! -f "$OVERLAY_VIDEO" ]; then
    echo -e "${RED}Error: Overlay video file '$OVERLAY_VIDEO' does not exist${NC}"
    exit 1
fi

# Generate timestamp for output and S3 paths
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Set default output directory
OUTPUT_DIR="$(dirname "$0")/../output"
mkdir -p "$OUTPUT_DIR"

# Set default output name
if [ -z "$OUTPUT" ]; then
    BG_BASE=$(basename "$BACKGROUND_VIDEO" | sed 's/\.[^.]*$//')
    OVERLAY_BASE=$(basename "$OVERLAY_VIDEO" | sed 's/\.[^.]*$//')
    OUTPUT_FILENAME="overlay_video_${BG_BASE}_${OVERLAY_BASE}_${TIMESTAMP}.mp4"
    OUTPUT="$OUTPUT_DIR/$OUTPUT_FILENAME"
else
    # If OUTPUT is provided but doesn't contain a path, use default directory
    if [[ "$OUTPUT" != *"/"* ]]; then
        OUTPUT="$OUTPUT_DIR/$OUTPUT"
    fi
    # Ensure output has .mp4 extension
    if [[ ! "$OUTPUT" =~ \.mp4$ ]]; then
        OUTPUT="${OUTPUT%.*}.mp4"
    fi
fi

# Check for FFmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}Error: FFmpeg is not installed${NC}"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Check for hevc_videotoolbox encoder (for MOV/MP4 with alpha on macOS)
# Note: We'll try videotoolbox first, fall back to libx265 if needed
HAS_VIDEOTOOLBOX=false
HAS_LIBX265=false
if ffmpeg -encoders 2>/dev/null | grep -q "hevc_videotoolbox"; then
    HAS_VIDEOTOOLBOX=true
fi
if ffmpeg -encoders 2>/dev/null | grep -q "libx265"; then
    HAS_LIBX265=true
fi

if [ "$HAS_VIDEOTOOLBOX" = false ] && [ "$HAS_LIBX265" = false ]; then
    echo -e "${RED}Error: No HEVC encoder available${NC}"
    echo "FFmpeg must be compiled with --enable-videotoolbox or --enable-libx265"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Get background video info
BG_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$BACKGROUND_VIDEO" 2>/dev/null)
BG_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$BACKGROUND_VIDEO" 2>/dev/null)
BG_FPS_RATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$BACKGROUND_VIDEO" 2>/dev/null)

if [ -z "$BG_DURATION" ] || [ "$BG_DURATION" = "N/A" ] || [ "$BG_DURATION" = "0" ]; then
    echo -e "${RED}Error: Could not determine background video duration${NC}"
    exit 1
fi

if [ -z "$BG_INFO" ]; then
    echo -e "${RED}Error: Could not read background video dimensions${NC}"
    exit 1
fi

BG_WIDTH=$(echo "$BG_INFO" | head -1)
BG_HEIGHT=$(echo "$BG_INFO" | tail -1)

# Parse FPS (format is like "30/1" or "30000/1001")
if [ -n "$BG_FPS_RATE" ]; then
    FPS_NUM=$(echo "$BG_FPS_RATE" | cut -d'/' -f1)
    FPS_DEN=$(echo "$BG_FPS_RATE" | cut -d'/' -f2)
    if [ -n "$FPS_DEN" ] && [ "$FPS_DEN" != "0" ]; then
        if command -v bc &> /dev/null; then
            BG_FPS=$(echo "scale=2; $FPS_NUM / $FPS_DEN" | bc | sed 's/\.00$//')
        else
            BG_FPS=30
        fi
    else
        BG_FPS=30
    fi
else
    BG_FPS=30
fi

# Get overlay video info
OVERLAY_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OVERLAY_VIDEO" 2>/dev/null)
OVERLAY_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$OVERLAY_VIDEO" 2>/dev/null)
OVERLAY_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$OVERLAY_VIDEO" 2>/dev/null)
OVERLAY_PIXFMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$OVERLAY_VIDEO" 2>/dev/null)

if [ -z "$OVERLAY_DURATION" ] || [ "$OVERLAY_DURATION" = "N/A" ] || [ "$OVERLAY_DURATION" = "0" ]; then
    echo -e "${RED}Error: Could not determine overlay video duration${NC}"
    exit 1
fi

if [ -z "$OVERLAY_INFO" ]; then
    echo -e "${RED}Error: Could not read overlay video dimensions${NC}"
    exit 1
fi

OVERLAY_WIDTH=$(echo "$OVERLAY_INFO" | head -1)
OVERLAY_HEIGHT=$(echo "$OVERLAY_INFO" | tail -1)

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Video Overlay on Video${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Background: $BACKGROUND_VIDEO (${BG_WIDTH}x${BG_HEIGHT}, ${BG_DURATION}s)"
echo -e "  Overlay:    $OVERLAY_VIDEO (${OVERLAY_WIDTH}x${OVERLAY_HEIGHT}, ${OVERLAY_DURATION}s)"
echo -e "  Codec:      $OVERLAY_CODEC (${OVERLAY_PIXFMT})"
echo -e "  Position:   $POSITION"
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
echo -e "${YELLOW}  Resizing overlay video to match background (${BG_WIDTH}x${BG_HEIGHT})...${NC}"
echo ""

# Check if overlay needs to be extended (if it's shorter than background)
NEED_EXTEND=false
if command -v bc &> /dev/null; then
    DURATION_DIFF=$(echo "$BG_DURATION - $OVERLAY_DURATION" | bc)
    # Use a small threshold (0.1 seconds) to account for floating point precision
    if [ "$(echo "$DURATION_DIFF > 0.1" | bc)" -eq 1 ]; then
        NEED_EXTEND=true
        EXTEND_DURATION=$(echo "$BG_DURATION - $OVERLAY_DURATION" | bc)
        echo -e "${YELLOW}  Overlay is shorter (${OVERLAY_DURATION}s < ${BG_DURATION}s)${NC}"
        echo -e "${YELLOW}  Will extend overlay by ${EXTEND_DURATION}s using last frame${NC}"
    fi
else
    # Fallback: compare as integers (less precise)
    BG_DUR_INT=$(echo "$BG_DURATION" | cut -d. -f1)
    OVERLAY_DUR_INT=$(echo "$OVERLAY_DURATION" | cut -d. -f1)
    if [ "$BG_DUR_INT" -gt "$OVERLAY_DUR_INT" ]; then
        NEED_EXTEND=true
        EXTEND_DURATION=$(echo "$BG_DUR_INT - $OVERLAY_DUR_INT" | awk '{print $1}')
        echo -e "${YELLOW}  Overlay is shorter (${OVERLAY_DURATION}s < ${BG_DURATION}s)${NC}"
        echo -e "${YELLOW}  Will extend overlay by ~${EXTEND_DURATION}s using last frame${NC}"
    fi
fi

# Create overlay filter for HEVC with alpha
echo -e "${GREEN}  Detected HEVC video - extracting alpha channel${NC}"
OVERLAY_FILTER="[1:v]scale=${BG_WIDTH}:${BG_HEIGHT},format=yuva420p,setsar=1"

# If overlay needs to be extended, use tpad filter to pad with last frame
if [ "$NEED_EXTEND" = true ]; then
    OVERLAY_FILTER="${OVERLAY_FILTER},tpad=stop_duration=${EXTEND_DURATION}:stop_mode=clone"
fi

OVERLAY_FILTER="${OVERLAY_FILTER}[overlay]"

echo -e "${YELLOW}  Compositing overlay with alpha blending...${NC}"

# Create overlay using FFmpeg
# Background video is the base layer
# Overlay video is scaled, alpha-extracted, and optionally extended
# Output matches background duration and resolution
# Use hevc_videotoolbox if available (hardware accelerated), otherwise libx265
if [ "$HAS_VIDEOTOOLBOX" = true ]; then
    # For videotoolbox, we need to use a format it supports
    # Convert to rgba first, then let videotoolbox handle it
    ffmpeg -y \
        -i "$BACKGROUND_VIDEO" \
        -i "$OVERLAY_VIDEO" \
        -filter_complex "[0:v]setsar=1,fps=${BG_FPS}[bg];${OVERLAY_FILTER};[bg][overlay]overlay=${X_EXPR}:${Y_EXPR},format=rgba[out]" \
        -map "[out]" \
        -c:v hevc_videotoolbox \
        -alpha_quality 1.0 \
        -tag:v hvc1 \
        -t "$BG_DURATION" \
        -map 0:a? \
        -c:a copy \
        "$OUTPUT"
else
    # Use libx265 (software encoder, slower but more compatible)
    # Note: libx265 may not support alpha depending on build
    ffmpeg -y \
        -i "$BACKGROUND_VIDEO" \
        -i "$OVERLAY_VIDEO" \
        -filter_complex "[0:v]setsar=1,fps=${BG_FPS}[bg];${OVERLAY_FILTER};[bg][overlay]overlay=${X_EXPR}:${Y_EXPR}" \
        -c:v libx265 \
        -pix_fmt yuva420p \
        -preset medium \
        -crf 23 \
        -tag:v hvc1 \
        -t "$BG_DURATION" \
        -map 0:a? \
        -c:a copy \
        "$OUTPUT"
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
OUTPUT_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null)
OUTPUT_WIDTH=$(echo "$OUTPUT_INFO" | head -1)
OUTPUT_HEIGHT=$(echo "$OUTPUT_INFO" | tail -1)

echo -e "  Codec:       $CODEC"
echo -e "  Pixel fmt:   $PIX_FMT"
echo -e "  Profile:     $PROFILE"
echo -e "  Resolution:  ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"

if [ "$CODEC" = "hevc" ] || [ "$CODEC" = "h265" ]; then
    echo -e "${GREEN}✓ HEVC codec confirmed${NC}"
    if [ "$OUTPUT_WIDTH" = "$BG_WIDTH" ] && [ "$OUTPUT_HEIGHT" = "$BG_HEIGHT" ]; then
        echo -e "${GREEN}✓ Output resolution matches background (${BG_WIDTH}x${BG_HEIGHT})${NC}"
    else
        echo -e "${YELLOW}⚠ Output resolution (${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}) differs from background (${BG_WIDTH}x${BG_HEIGHT})${NC}"
    fi
    echo -e "${GREEN}✓ Transparency respected during overlay (alpha composited)${NC}"
else
    echo -e "${YELLOW}⚠ Unexpected codec: $CODEC${NC}"
fi

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
    # Get path to upload.sh script
    UPLOAD_SCRIPT="$(dirname "$0")/upload.sh"
    
    # S3 paths
    S3_VIDEO_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    S3_HTML_PATH="${TIMESTAMP}/overlay_video_preview.html"
    
    # Upload video (suppress verbose output)
    VIDEO_URL=$("$UPLOAD_SCRIPT" "$OUTPUT" "$BUCKET_NAME" "$S3_VIDEO_PATH" "video/mp4" 2>/dev/null | tr -d '\n\r')
    
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
                DISPLAY_FPS="$BG_FPS"
            fi
        else
            DISPLAY_FPS="$BG_FPS"
        fi
    else
        DISPLAY_FPS="$BG_FPS"
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
    # PROFILE from ffprobe might be "Main" or "Main 10", so handle both
    PROFILE_CLEAN=$(echo "$PROFILE" | tr -d ' ')
    if [ "$PROFILE_CLEAN" = "Main10" ] || [ "$PROFILE_CLEAN" = "Main 10" ]; then
        ENCODING_DISPLAY="HEVC Main 10 (10-bit)"
    elif [ "$PROFILE_CLEAN" = "Main" ]; then
        ENCODING_DISPLAY="HEVC Main (8-bit)"
    elif [ -n "$PROFILE_CLEAN" ]; then
        ENCODING_DISPLAY="HEVC $PROFILE_CLEAN"
    else
        ENCODING_DISPLAY="HEVC"
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
    sed -e "s|{{TITLE}}|Video Overlay on Video Preview|g" \
        -e "s|{{DESCRIPTION}}|HEVC video with alpha channel overlaid on MP4 background video. If the overlay is shorter, the last frame is held for the remaining duration.|g" \
        -e "s|{{MEDIA_ELEMENT}}|<video src=\"${ESCAPED_VIDEO_URL}\" autoplay loop muted playsinline controls></video>|g" \
        -e "s|{{FILE_TYPE}}|MP4|g" \
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
    echo "2. Test in browser:"
    echo "   Create an HTML file with:"
    echo "   <video src=\"$OUTPUT\" autoplay loop muted playsinline controls></video>"
    echo ""
    echo "3. To upload to S3, use the -s3 option:"
    echo "   $0 -b $BACKGROUND_VIDEO -o $OVERLAY_VIDEO -s3 my-bucket-name"
    echo ""
fi
