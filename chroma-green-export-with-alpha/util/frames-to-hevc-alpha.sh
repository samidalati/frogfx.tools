#!/bin/bash

# frames-to-hevc-alpha.sh
# Converts WebP frames with transparency to video with alpha channel
# Supports: HEVC with Alpha (for iOS/Safari) and ProRes 4444 (universal alpha support)
# Requires: FFmpeg with VideoToolbox support (standard on macOS)

set -e

# Default values
FPS=30
OUTPUT=""
INPUT_DIR=""
FORMAT="hevc"  # hevc or prores
BUCKET_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 -i <input_folder> [-f <fps>] [-o <output_file>] [-t <type>] [-b <bucket>]"
    echo ""
    echo "Options:"
    echo "  -i <folder>   Input folder containing WebP frames (required)"
    echo "  -f <fps>      Frames per second (default: 30)"
    echo "  -o <file>     Output file name (default: auto-generated)"
    echo "  -t <type>     Output type: 'hevc' or 'prores' (default: hevc)"
    echo "                hevc   - HEVC with Alpha (smaller, iOS/Safari compatible)"
    echo "                prores - ProRes 4444 (larger, universal alpha support)"
    echo "  -b <bucket>   S3 bucket name to upload video and HTML preview (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -i ./frames -f 24 -o my_video.mov"
    echo "  $0 -i ./frames -t prores -o my_video_prores.mov"
    echo "  $0 -i ./frames -b my-green-screen-bucket"
    echo ""
    echo "Note: Input frames should be named sequentially (e.g., frame_00000.webp)"
}

# Parse arguments
while getopts "i:f:o:t:b:h" opt; do
    case $opt in
        i) INPUT_DIR="$OPTARG" ;;
        f) FPS="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        t) FORMAT="$OPTARG" ;;
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

# Validate format
if [ "$FORMAT" != "hevc" ] && [ "$FORMAT" != "prores" ]; then
    echo -e "${RED}Error: Invalid format '$FORMAT'. Use 'hevc' or 'prores'${NC}"
    exit 1
fi

# Generate timestamp for output and S3 paths
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Set default output directory
OUTPUT_DIR="$(dirname "$0")/../output"
mkdir -p "$OUTPUT_DIR"

# Set default output name
if [ -z "$OUTPUT" ]; then
    if [ "$FORMAT" == "hevc" ]; then
        OUTPUT_FILENAME="hevc_alpha_${TIMESTAMP}.mov"
    else
        OUTPUT_FILENAME="prores_alpha_${TIMESTAMP}.mov"
    fi
    OUTPUT="$OUTPUT_DIR/$OUTPUT_FILENAME"
else
    # If OUTPUT is provided but doesn't contain a path, use default directory
    if [[ "$OUTPUT" != *"/"* ]]; then
        OUTPUT="$OUTPUT_DIR/$OUTPUT"
    fi
fi

# Check for FFmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}Error: FFmpeg is not installed${NC}"
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
echo -e "${GREEN}Frames to Video with Alpha${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Input:   $INPUT_DIR ($FRAME_COUNT frames)"
echo -e "  Output:  $OUTPUT"
echo -e "  Format:  $FORMAT"
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
echo -e "${YELLOW}Converting frames to $FORMAT with alpha...${NC}"
echo ""

if [ "$FORMAT" == "hevc" ]; then
    # Check if VideoToolbox HEVC encoder is available
    if ffmpeg -encoders 2>/dev/null | grep -q "hevc_videotoolbox"; then
        echo -e "${GREEN}Using hardware-accelerated HEVC encoder (VideoToolbox)${NC}"
        
        # HEVC with alpha using VideoToolbox
        # -alpha_quality 1.0 enables full quality alpha channel
        ffmpeg -y \
            -framerate "$FPS" \
            -i "$PATTERN" \
            -c:v hevc_videotoolbox \
            -alpha_quality 1.0 \
            -tag:v hvc1 \
            "$OUTPUT"
    else
        echo -e "${RED}Error: VideoToolbox HEVC encoder not available${NC}"
        echo -e "HEVC with alpha requires macOS with VideoToolbox support"
        echo -e "Try using ProRes instead: $0 -i $INPUT_DIR -t prores"
        exit 1
    fi
else
    # ProRes 4444 with alpha
    echo -e "${GREEN}Using ProRes 4444 encoder (guaranteed alpha support)${NC}"
    
    ffmpeg -y \
        -framerate "$FPS" \
        -i "$PATTERN" \
        -c:v prores_ks \
        -profile:v 4444 \
        -pix_fmt yuva444p10le \
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
echo -e "  Codec:       $CODEC"
echo -e "  Pixel fmt:   $PIX_FMT"

# Check pixel format for alpha
if [[ "$PIX_FMT" == *"yuva"* ]] || [[ "$PIX_FMT" == *"rgba"* ]] || [[ "$PIX_FMT" == *"bgra"* ]] || [[ "$PIX_FMT" == *"ayuv"* ]]; then
    echo -e "${GREEN}✓ Alpha channel confirmed in pixel format${NC}"
elif [ "$FORMAT" == "hevc" ]; then
    echo -e "${YELLOW}⚠ HEVC stores alpha separately - test in Safari to verify${NC}"
else
    echo -e "${RED}✗ Alpha channel may not be present${NC}"
fi

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
    # Get path to upload.sh script
    UPLOAD_SCRIPT="$(dirname "$0")/upload.sh"
    
    # S3 paths
    S3_VIDEO_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    S3_HTML_PATH="${TIMESTAMP}/hevc_preview.html"
    
    # Upload video (suppress verbose output)
    VIDEO_URL=$("$UPLOAD_SCRIPT" "$OUTPUT" "$BUCKET_NAME" "$S3_VIDEO_PATH" "video/quicktime" 2>/dev/null | tr -d '\n\r')
    
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
    if [ "$FORMAT" == "hevc" ]; then
        ENCODING_DISPLAY="HEVC (VideoToolbox)"
    else
        ENCODING_DISPLAY="ProRes 4444"
    fi
    
    # Format file type
    if [ "$FORMAT" == "hevc" ]; then
        FILE_TYPE_DISPLAY="HEVC/MOV"
    else
        FILE_TYPE_DISPLAY="ProRes/MOV"
    fi
    
    # Read template and replace placeholders
    TEMPLATE_PATH="$(dirname "$0")/preview-template.html"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo -e "${RED}Error: Template file not found: $TEMPLATE_PATH${NC}"
        exit 1
    fi
    
    # Escape VIDEO_URL for sed
    ESCAPED_VIDEO_URL=$(printf '%s\n' "$VIDEO_URL" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Create temporary HTML file
    HTML_TEMP=$(mktemp)
    # Capitalize first letter of FORMAT (bash 3.2 compatible)
    FORMAT_TITLE=$(echo "$FORMAT" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    sed -e "s|{{TITLE}}|${FORMAT_TITLE} Alpha Preview|g" \
        -e "s|{{DESCRIPTION}}|If the video has alpha, you should see the checkered background through transparent areas|g" \
        -e "s|{{MEDIA_ELEMENT}}|<video src=\"${ESCAPED_VIDEO_URL}\" autoplay loop muted playsinline controls></video>|g" \
        -e "s|{{FILE_TYPE}}|${FILE_TYPE_DISPLAY}|g" \
        -e "s|{{RESOLUTION}}|${VIDEO_WIDTH}x${VIDEO_HEIGHT}|g" \
        -e "s|{{FPS}}|${DISPLAY_FPS}|g" \
        -e "s|{{ENCODING}}|${ENCODING_DISPLAY}|g" \
        -e "s|{{DURATION}}|${DURATION_DISPLAY}|g" \
        -e "s|{{MEDIA_URL}}|${ESCAPED_VIDEO_URL}|g" \
        -e "s|{{SCRIPT_CONTENT}}||g" \
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
    echo "3. For iOS Safari, use HEVC format"
    echo "   For universal support (editing, etc.), use ProRes 4444"
    echo ""
    echo "4. To upload to S3, use the -b option:"
    echo "   $0 -i $INPUT_DIR -b my-bucket-name"
    echo ""
fi
