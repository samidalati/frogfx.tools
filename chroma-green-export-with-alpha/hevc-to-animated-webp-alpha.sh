#!/bin/bash

# hevc-to-animated-webp-alpha.sh
# Converts an HEVC video with alpha channel to an animated WebP with alpha
# Requires: FFmpeg with libwebp support

set -e

# Default values
INPUT=""
OUTPUT=""
FPS=30
QUALITY=75
SCALE_HEIGHT=""
BUCKET_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 -i <hevc_video> [-o <output>] [-f <fps>] [-q <quality>] [-s <height>] [-b <bucket>]"
    echo ""
    echo "Options:"
    echo "  -i <video>    Input HEVC video file with alpha (required)"
    echo "  -o <file>     Output animated WebP file (default: auto-generated)"
    echo "  -f <fps>      Frame rate for output (default: 30)"
    echo "  -q <quality>  Quality 0-100, lower = smaller file (default: 75)"
    echo "                Recommended: 60-80 for good balance, 50-60 for smaller files"
    echo "  -s <height>   Scale to specified height, maintains aspect ratio (e.g., -s 720)"
    echo "  -b <bucket>   S3 bucket name to upload WebP and HTML (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -i video.mov"
    echo "  $0 -i video.mov -f 30 -q 75 -o output.webp"
    echo "  $0 -i video.mov -s 720 -q 60"
    echo "  $0 -i video.mov -q 60 -b my-bucket-name"
    echo ""
    echo "Note: The script preserves the alpha channel from the HEVC video"
}

# Parse arguments
while getopts "i:o:f:q:s:b:h" opt; do
    case $opt in
        i) INPUT="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        f) FPS="$OPTARG" ;;
        q) QUALITY="$OPTARG" ;;
        s) SCALE_HEIGHT="$OPTARG" ;;
        b) BUCKET_NAME="$OPTARG" ;;
        h) print_usage; exit 0 ;;
        *) print_usage; exit 1 ;;
    esac
done

# Validate input
if [ -z "$INPUT" ]; then
    echo -e "${RED}Error: Input video file is required${NC}"
    print_usage
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo -e "${RED}Error: Input file '$INPUT' does not exist${NC}"
    exit 1
fi

# Check for FFmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}Error: FFmpeg is not installed${NC}"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Check for libwebp support
if ! ffmpeg -encoders 2>/dev/null | grep -q "libwebp"; then
    echo -e "${RED}Error: libwebp encoder not available${NC}"
    echo "FFmpeg must be compiled with --enable-libwebp"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Generate timestamp for output
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Set default output name
if [ -z "$OUTPUT" ]; then
    INPUT_BASE=$(basename "$INPUT" | sed 's/\.[^.]*$//')
    OUTPUT="animated_webp_${INPUT_BASE}_${TIMESTAMP}.webp"
fi

# Ensure output has .webp extension
if [[ ! "$OUTPUT" =~ \.webp$ ]]; then
    OUTPUT="${OUTPUT%.*}.webp"
fi

# Get video info
VIDEO_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
VIDEO_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)

if [ -z "$VIDEO_WIDTH" ] || [ -z "$VIDEO_HEIGHT" ]; then
    echo -e "${RED}Error: Could not read video dimensions${NC}"
    exit 1
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}HEVC to Animated WebP Converter${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Input:     $INPUT"
echo -e "  Resolution: ${VIDEO_WIDTH}x${VIDEO_HEIGHT}"
if [ -n "$SCALE_HEIGHT" ]; then
    echo -e "  Scaling:   ${VIDEO_WIDTH}x${VIDEO_HEIGHT} → ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
fi
echo -e "  Codec:     $VIDEO_CODEC"
echo -e "  Duration:  ${VIDEO_DURATION}s"
echo -e "  FPS:       $FPS"
echo -e "  Quality:   $QUALITY (0-100, lower = smaller file)"
echo -e "  Output:    $OUTPUT"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Convert HEVC to animated WebP with alpha
echo -e "${YELLOW}Converting HEVC to animated WebP with alpha...${NC}"
echo ""

# FFmpeg command to convert HEVC with alpha to animated WebP
# -pix_fmt yuva420p ensures alpha channel is preserved
# -lossless 0 enables lossy compression for smaller file size
# -quality: 0-100, lower = smaller file (default: 75)
# -compression_level 6: maximum compression (slower but better compression)
# -loop 1 makes it play once (no loop), use -loop 0 for infinite loop
ffmpeg -y \
    -i "$INPUT" \
    -c:v libwebp_anim \
    -pix_fmt yuva420p \
    -lossless 0 \
    -quality "$QUALITY" \
    -compression_level 6 \
    -loop 1 \
    -preset default \
    "$OUTPUT"

# Check if output was created
if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Error: Output file was not created${NC}"
    exit 1
fi

OUTPUT_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')

# Count frames (approximate from duration and FPS)
if [ -n "$VIDEO_DURATION" ] && [ -n "$FPS" ]; then
    if command -v bc &> /dev/null; then
        FRAME_COUNT=$(echo "scale=0; $VIDEO_DURATION * $FPS" | bc | cut -d. -f1)
    else
        FRAME_COUNT="N/A"
    fi
else
    FRAME_COUNT="N/A"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Conversion complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Output:   $OUTPUT"
echo -e "  Size:     $OUTPUT_SIZE"
echo -e "  Frames:   $FRAME_COUNT"
echo -e "  FPS:      $FPS"
echo ""

# Verify the output
echo -e "${YELLOW}Verifying output...${NC}"
# WebP dimensions (use output dimensions if scaled, otherwise original)
WEBP_WIDTH="$OUTPUT_WIDTH"
WEBP_HEIGHT="$OUTPUT_HEIGHT"

# Try to get pixel format from ffprobe (may not work for WebP)
WEBP_PIXFMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null || echo "")

echo -e "  Resolution: ${WEBP_WIDTH}x${WEBP_HEIGHT}"
if [ -n "$WEBP_PIXFMT" ]; then
    echo -e "  Pixel fmt:  $WEBP_PIXFMT"
    if [[ "$WEBP_PIXFMT" == *"yuva"* ]] || [[ "$WEBP_PIXFMT" == *"rgba"* ]]; then
        echo -e "${GREEN}✓ Alpha channel preserved (${WEBP_PIXFMT})${NC}"
    else
        echo -e "${YELLOW}⚠ Pixel format: $WEBP_PIXFMT${NC}"
    fi
else
    echo -e "${GREEN}✓ WebP created (alpha should be preserved with yuva420p encoding)${NC}"
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
    S3_WEBP_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    S3_HTML_PATH="${TIMESTAMP}/webp_preview.html"
    
    # Ensure "Block Public Access" is disabled
    echo -e "${YELLOW}Ensuring bucket allows public object access...${NC}"
    if aws s3api get-public-access-block --bucket "$BUCKET_NAME" &>/dev/null; then
        echo -e "${YELLOW}  Disabling 'Block Public Access'...${NC}"
        aws s3api put-public-access-block \
            --bucket "$BUCKET_NAME" \
            --public-access-block-configuration \
            "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>/dev/null
    fi
    
    # Upload WebP
    echo -e "${YELLOW}Uploading WebP to s3://${BUCKET_NAME}/${S3_WEBP_PATH}...${NC}"
    if aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "$S3_WEBP_PATH" \
        --body "$OUTPUT" \
        --content-type "image/webp" \
        --grant-read "uri=http://acs.amazonaws.com/groups/global/AllUsers" 2>/dev/null; then
        echo -e "${GREEN}✓ WebP uploaded with public read access${NC}"
    elif aws s3 cp "$OUTPUT" "s3://${BUCKET_NAME}/${S3_WEBP_PATH}" \
        --content-type "image/webp" \
        --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers 2>/dev/null; then
        echo -e "${GREEN}✓ WebP uploaded with public read access${NC}"
    elif aws s3 cp "$OUTPUT" "s3://${BUCKET_NAME}/${S3_WEBP_PATH}" \
        --content-type "image/webp" 2>/dev/null; then
        echo -e "${YELLOW}⚠ WebP uploaded, setting ACL...${NC}"
        if aws s3api put-object-acl \
            --bucket "$BUCKET_NAME" \
            --key "$S3_WEBP_PATH" \
            --acl public-read 2>/dev/null; then
            echo -e "${GREEN}✓ WebP is now publicly accessible${NC}"
        else
            echo -e "${YELLOW}⚠ Could not set public access${NC}"
        fi
    else
        echo -e "${RED}Error: Failed to upload WebP to S3${NC}"
        exit 1
    fi
    
    # Get bucket region for correct URL
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET_NAME" --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
    if [ "$BUCKET_REGION" = "None" ] || [ -z "$BUCKET_REGION" ]; then
        BUCKET_REGION="us-east-1"
    fi
    
    # Use region-specific URL
    if [ "$BUCKET_REGION" = "us-east-1" ]; then
        WEBP_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_WEBP_PATH}"
    else
        WEBP_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_WEBP_PATH}"
    fi
    
    # Get WebP info for template
    RESOLUTION_DISPLAY="${WEBP_WIDTH}x${WEBP_HEIGHT}"
    
    # Calculate duration from frame count and FPS
    if [ -n "$FRAME_COUNT" ] && [ "$FRAME_COUNT" != "N/A" ] && [ -n "$FPS" ]; then
        if command -v bc &> /dev/null; then
            DURATION_SEC=$(echo "scale=2; $FRAME_COUNT / $FPS" | bc)
            DURATION_DISPLAY="${DURATION_SEC}s"
        else
            DURATION_DISPLAY="${FRAME_COUNT} frames @ ${FPS}fps"
        fi
    else
        DURATION_DISPLAY="N/A"
    fi
    
    # Create ImageDecoder script for WebP (same as frames-to-animated-webp-alpha.sh)
    SCRIPT_CONTENT=$(cat <<'SCRIPT_EOF'
    <script>
        (async function() {
            const canvas = document.getElementById('webpCanvas');
            const ctx = canvas.getContext('2d');
            const img = document.getElementById('webpFallback');
            const webpUrl = '{{WEBP_URL}}';
            
            // Check if ImageDecoder API is available (Chrome 94+, Edge 94+)
            if ('ImageDecoder' in window) {
                try {
                    // Fetch the WebP file
                    const response = await fetch(webpUrl);
                    if (!response.ok) {
                        throw new Error('Failed to fetch WebP');
                    }
                    // Convert to ArrayBuffer (ImageDecoder requires ArrayBuffer, not Blob)
                    const arrayBuffer = await response.arrayBuffer();
                    
                    // Create ImageDecoder
                    const decoder = new ImageDecoder({
                        data: arrayBuffer,
                        type: 'image/webp'
                    });
                    
                    await decoder.decode().then(async (result) => {
                        // Set canvas size
                        canvas.width = result.image.displayWidth;
                        canvas.height = result.image.displayHeight;
                        canvas.classList.add('active');
                        
                        // Draw first frame immediately so canvas is visible
                        ctx.drawImage(result.image, 0, 0);
                        console.log('Canvas size set to:', canvas.width, 'x', canvas.height);
                        console.log('First frame drawn');
                        
                        // Don't rely on frameCount - decode frames sequentially until error
                        console.log('Reported frame count:', decoder.frameCount);
                        console.log('Starting animation (play once)...');
                        
                        let lastFrame = result.image; // Store first frame
                        let hasCompleted = false; // Flag to prevent re-rendering
                        let frameNumber = 0;
                        const animationStartTime = performance.now(); // Track animation start
                        
                        // Function to render a frame
                        async function renderFrame(frameIndex) {
                            // Stop if already completed
                            if (hasCompleted) {
                                return;
                            }
                            
                            try {
                                const frame = await decoder.decode({ frameIndex });
                                const image = frame.image;
                                frameNumber = frameIndex + 1;
                                
                                // Use dynamic delay to mimic specified fps video
                                const delayMs = 1000 / {{FPS}}; // Dynamic FPS
                                
                                // Draw frame to canvas
                                ctx.clearRect(0, 0, canvas.width, canvas.height);
                                ctx.drawImage(image, 0, 0);
                                
                                // Store last frame
                                lastFrame = image;
                                
                                console.log(`Rendering frame ${frameNumber} (delay: ${delayMs.toFixed(2)}ms)`);
                                
                                // Try to decode and render next frame after delay
                                setTimeout(async function() {
                                    if (!hasCompleted) {
                                        try {
                                            // Try to peek at next frame
                                            const nextFrame = await decoder.decode({ frameIndex: frameIndex + 1 });
                                            // Next frame exists, render it
                                            renderFrame(frameIndex + 1);
                                        } catch (nextError) {
                                            // No more frames - animation complete
                                            hasCompleted = true;
                                            const animationEndTime = performance.now();
                                            const totalDuration = animationEndTime - animationStartTime;
                                            const expectedDuration = frameNumber * (1000 / {{FPS}}); // Expected duration at specified FPS
                                            const actualFPS = frameNumber / (totalDuration / 1000);
                                            console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                            console.log(`Animation complete after ${frameNumber} frames`);
                                            console.log(`Total animation duration: ${totalDuration.toFixed(2)}ms (${(totalDuration / 1000).toFixed(2)}s)`);
                                            console.log(`Expected duration at {{FPS}}fps: ${expectedDuration.toFixed(2)}ms (${(expectedDuration / 1000).toFixed(2)}s)`);
                                            console.log(`Actual FPS: ${actualFPS.toFixed(2)}`);
                                            console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                            // Last frame is already drawn, so we're done
                                        }
                                    }
                                }, delayMs);
                                
                            } catch (error) {
                                // No more frames - keep last frame displayed and stop
                                hasCompleted = true;
                                const animationEndTime = performance.now();
                                const totalDuration = animationEndTime - animationStartTime;
                                const expectedDuration = frameNumber * (1000 / {{FPS}}); // Expected duration at specified FPS
                                const actualFPS = frameNumber / (totalDuration / 1000);
                                console.log(`Frame decode error (end): ${error.message}`);
                                console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                console.log(`Animation complete after ${frameNumber} frames`);
                                console.log(`Total animation duration: ${totalDuration.toFixed(2)}ms (${(totalDuration / 1000).toFixed(2)}s)`);
                                console.log(`Expected duration at {{FPS}}fps: ${expectedDuration.toFixed(2)}ms (${(expectedDuration / 1000).toFixed(2)}s)`);
                                console.log(`Actual FPS: ${actualFPS.toFixed(2)}`);
                                console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                if (lastFrame) {
                                    ctx.clearRect(0, 0, canvas.width, canvas.height);
                                    ctx.drawImage(lastFrame, 0, 0);
                                }
                            }
                        }
                        
                        // Start animation from second frame (first is already drawn)
                        // Try to discover if there are more frames
                        setTimeout(async function() {
                            try {
                                const testFrame = await decoder.decode({ frameIndex: 1 });
                                console.log('Found additional frames, starting animation');
                                renderFrame(1);
                            } catch (e) {
                                console.log('Single frame WebP (not animated)');
                                const animationEndTime = performance.now();
                                const totalDuration = animationEndTime - animationStartTime;
                                console.log(`Single frame displayed in ${totalDuration.toFixed(2)}ms`);
                            }
                        }, 100);
                    });
                } catch (error) {
                    console.error('ImageDecoder failed:', error);
                    // Fall back to img element
                    canvas.classList.remove('active');
                    img.classList.remove('fallback-img');
                }
            } else {
                // ImageDecoder not supported - show warning and use canvas workaround
                console.warn('ImageDecoder not supported. Animation will loop. Please use Chrome 94+ or Edge 94+ for play-once functionality.');
                canvas.classList.remove('active');
                img.classList.remove('fallback-img');
                
                // Note: img elements with animated WebP will always loop
                // This is a browser limitation - ImageDecoder API is required for frame-by-frame control
                // Show a message to the user
                const warning = document.createElement('div');
                warning.style.cssText = 'position: fixed; top: 10px; left: 50%; transform: translateX(-50%); background: rgba(255, 193, 7, 0.9); color: #000; padding: 10px 20px; border-radius: 8px; font-size: 12px; z-index: 1000; max-width: 90%; text-align: center;';
                warning.textContent = "⚠️ Your browser doesn't support ImageDecoder API. Animation will loop. Use Chrome 94+ or Edge 94+ for play-once functionality.";
                document.body.appendChild(warning);
                setTimeout(function() { warning.remove(); }, 5000);
            }
        })();
    </script>
SCRIPT_EOF
)
    
    # Replace FPS placeholder in script
    SCRIPT_TEMP=$(mktemp)
    echo "$SCRIPT_CONTENT" | sed "s|{{WEBP_URL}}|${WEBP_URL}|g" | sed "s|{{FPS}}|${FPS}|g" > "$SCRIPT_TEMP"
    
    # Read template and replace placeholders
    TEMPLATE_PATH="$(dirname "$0")/preview-template.html"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo -e "${RED}Error: Template file not found: $TEMPLATE_PATH${NC}"
        exit 1
    fi
    
    # Create temporary HTML file
    HTML_TEMP=$(mktemp)
    # First replace all placeholders except SCRIPT_CONTENT
    sed -e "s|{{TITLE}}|Animated WebP Preview (from HEVC)|g" \
        -e "s|{{DESCRIPTION}}|HEVC video converted to animated WebP with alpha. If the image has transparency, you should see the checkered background through transparent areas|g" \
        -e "s|{{MEDIA_ELEMENT}}|<canvas id=\"webpCanvas\"></canvas><img id=\"webpFallback\" class=\"fallback-img\" src=\"${WEBP_URL}\" alt=\"Animated WebP\">|g" \
        -e "s|{{FILE_TYPE}}|Animated WebP|g" \
        -e "s|{{RESOLUTION}}|${RESOLUTION_DISPLAY}|g" \
        -e "s|{{FPS}}|${FPS}|g" \
        -e "s|{{ENCODING}}|WebP Animation (from HEVC)|g" \
        -e "s|{{DURATION}}|${DURATION_DISPLAY}|g" \
        -e "s|{{MEDIA_URL}}|${WEBP_URL}|g" \
        "$TEMPLATE_PATH" > "$HTML_TEMP"
    
    # Now replace SCRIPT_CONTENT placeholder with actual script content
    awk -v script_file="$SCRIPT_TEMP" '
        /{{SCRIPT_CONTENT}}/ {
            while ((getline line < script_file) > 0) {
                print line
            }
            close(script_file)
            next
        }
        { print }
    ' "$HTML_TEMP" > "${HTML_TEMP}.new" && mv "${HTML_TEMP}.new" "$HTML_TEMP"
    
    # Clean up script temp file
    rm -f "$SCRIPT_TEMP"
    
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
        WEBP_PUBLIC_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_WEBP_PATH}"
        HTML_PUBLIC_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_HTML_PATH}"
    else
        WEBP_PUBLIC_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_WEBP_PATH}"
        HTML_PUBLIC_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_HTML_PATH}"
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Upload complete!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}WebP URL:${NC}"
    echo -e "  ${WEBP_PUBLIC_URL}"
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
    echo "1. Quick test (opens in default viewer):"
    echo "   open \"$OUTPUT\""
    echo ""
    echo "2. Test in browser:"
    echo "   Create an HTML file with:"
    echo "   <img src=\"$OUTPUT\" alt=\"Animated WebP\">"
    echo ""
    echo "3. Animated WebP works in Chrome, Firefox, and Edge"
    echo "   For older browsers, consider using GIF format"
    echo ""
    echo "4. To upload to S3, use the -b option:"
    echo "   $0 -i $INPUT -b my-bucket-name"
    echo ""
fi
