#!/bin/bash

# frames-to-animated-webp-webpmux.sh
# Converts WebP frames into a single animated WebP image using webpmux (no loop)
# Requires: webpmux (part of libwebp tools)
# Usage: ./frames-to-animated-webp-webpmux.sh -i <input_folder> [-f <fps>] [-o <output_file>] [-b <bucket>]

set -e

# Default values
FPS=10
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
    echo "  -f <fps>      Frames per second (default: 10)"
    echo "  -o <file>     Output file name (default: auto-generated)"
    echo "  -b <bucket>   S3 bucket name to upload animated WebP and HTML preview (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 -i ./frames -f 30 -o my_animation.webp"
    echo "  $0 -i ./frames -b my-animation-bucket"
    echo ""
    echo "Note: Input frames should be named sequentially (e.g., frame_00000.webp)"
    echo "      Output is an animated WebP image that plays once (no loop)"
    echo "      Uses webpmux tool instead of FFmpeg"
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

# Expand tilde and resolve path
INPUT_DIR="${INPUT_DIR/#\~/$HOME}"
INPUT_DIR=$(cd "$INPUT_DIR" 2>/dev/null && pwd || echo "$INPUT_DIR")

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
    OUTPUT_FILENAME="animated_webp_${TIMESTAMP}.webp"
    OUTPUT="$OUTPUT_DIR/$OUTPUT_FILENAME"
else
    # If OUTPUT is provided but doesn't contain a path, use default directory
    if [[ "$OUTPUT" != *"/"* ]]; then
        OUTPUT="$OUTPUT_DIR/$OUTPUT"
    fi
    # Ensure output has .webp extension
    if [[ ! "$OUTPUT" =~ \.webp$ ]]; then
        OUTPUT="${OUTPUT%.*}.webp"
    fi
fi

# Check for webpmux
if ! command -v webpmux &> /dev/null; then
    echo -e "${RED}Error: webpmux is not installed${NC}"
    echo "Install with: brew install webp"
    echo "  or download from: https://developers.google.com/speed/webp/download"
    exit 1
fi

# Count WebP files
FRAME_COUNT=$(ls -1 "$INPUT_DIR"/*.webp 2>/dev/null | wc -l | tr -d ' ')

if [ "$FRAME_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No WebP files found in '$INPUT_DIR'${NC}"
    exit 1
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}WebP Frames to Animated WebP (webpmux - No Loop)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Input:   $INPUT_DIR ($FRAME_COUNT frames)"
echo -e "  Output:  $OUTPUT"
echo -e "  Format:  Animated WebP (play once, no loop)"
echo -e "  FPS:     $FPS ${YELLOW}(use -f <fps> to change)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FPS" = "10" ]; then
    echo -e "${YELLOW}⚠ Warning: Using default FPS of 10. If your frames were exported at a different FPS,${NC}"
    echo -e "${YELLOW}   specify it with: -f <fps> (e.g., -f 30 for 30 FPS)${NC}"
    echo ""
fi

# Create a temporary directory for sorted frames
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

echo -e "${YELLOW}Sorting and preparing frames...${NC}"

# Copy and rename frames to ensure proper ordering
# Handle both frame_00000.webp and frame_0.webp naming patterns
counter=0
for file in "$INPUT_DIR"/*.webp; do
    if [ -f "$file" ]; then
        # Pad counter to 6 digits for proper sorting
        new_name=$(printf "frame_%06d.webp" "$counter")
        cp "$file" "$TEMP_DIR/$new_name"
        ((counter++))
    fi
done

# Sort frames by name to ensure correct order
sorted_files=($(ls "$TEMP_DIR"/*.webp | sort))

if [ ${#sorted_files[@]} -eq 0 ]; then
    echo -e "${RED}Error: No frames could be processed${NC}"
    exit 1
fi

echo -e "${GREEN}Processing ${#sorted_files[@]} frames...${NC}"
echo ""

# Calculate frame duration in milliseconds
# Duration = 1000ms / FPS (e.g., 30fps = 33.33ms per frame)
# Use floating point calculation for accuracy, then round
FRAME_DURATION_MS=$(awk "BEGIN {printf \"%.0f\", 1000 / $FPS}")

# Validate FPS is reasonable
if ! awk "BEGIN {exit !($FPS > 0)}" 2>/dev/null; then
    echo -e "${RED}Error: FPS must be greater than 0${NC}"
    exit 1
fi

echo -e "${YELLOW}Creating animated WebP with webpmux...${NC}"
echo -e "${CYAN}  Frame duration: ${FRAME_DURATION_MS}ms per frame${NC}"
echo -e "${CYAN}  Loop count: 1 (play once, no loop)${NC}"
echo ""

# Build webpmux command
# Format: webpmux -frame file.webp +duration+x+y+mi[bi] -frame file2.webp +duration+x+y+mi[bi] ... -o output.webp
# Where:
#   duration = frame duration in milliseconds
#   x, y = position offset (0,0 for all frames)
#   mi = disposal method (0 = clear after display)
#   bi = blend method (b = blend, or omit for no blend)
# We use +0+0+0-b format: duration + x + y + disposal + blend
WEBPMUX_CMD="webpmux"

for frame_file in "${sorted_files[@]}"; do
    # Frame format: +duration+x+y+mi[bi]
    # +${FRAME_DURATION_MS}+0+0+0-b means:
    #   duration: FRAME_DURATION_MS ms
    #   x: 0, y: 0 (no offset)
    #   disposal: 0 (clear after display)
    #   blend: b (blend with previous frame)
    WEBPMUX_CMD="$WEBPMUX_CMD -frame \"$frame_file\" +${FRAME_DURATION_MS}+0+0+0-b"
done

# Add output file
TEMP_OUTPUT="${TEMP_DIR}/temp_animated.webp"
WEBPMUX_CMD="$WEBPMUX_CMD -o \"$TEMP_OUTPUT\""

# Execute webpmux command
echo -e "${YELLOW}Running webpmux...${NC}"
eval $WEBPMUX_CMD

# Check if output file was created
if [ ! -f "$TEMP_OUTPUT" ]; then
    echo -e "${RED}Error: webpmux failed to create output file${NC}"
    exit 1
fi

# Set loop count to 1 (play once, no loop)
# webpmux -set loop 1 input.webp -o output.webp
echo -e "${YELLOW}Setting loop count to 1 (play once)...${NC}"
webpmux -set loop 1 "$TEMP_OUTPUT" -o "$OUTPUT"

# Check if final output file was created
if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Error: Failed to set loop count${NC}"
    exit 1
fi

OUTPUT_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Conversion complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Output:   $OUTPUT"
echo -e "  Size:     $OUTPUT_SIZE"
echo -e "  Frames:   ${#sorted_files[@]}"
echo -e "  FPS:      $FPS"
echo -e "  Loop:     1 (play once, no loop)"
echo ""

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
    # Get path to upload.sh script
    UPLOAD_SCRIPT="$(dirname "$0")/upload.sh"
    
    # S3 paths
    S3_WEBP_PATH="${TIMESTAMP}/$(basename "$OUTPUT")"
    S3_HTML_PATH="${TIMESTAMP}/webp_preview.html"
    
    # Upload animated WebP (suppress verbose output)
    WEBP_URL=$("$UPLOAD_SCRIPT" "$OUTPUT" "$BUCKET_NAME" "$S3_WEBP_PATH" "image/webp" 2>/dev/null | tr -d '\n\r')
    
    # Resolution will be detected by JavaScript in the browser
    RESOLUTION_DISPLAY="Detecting..."
    
    # Calculate duration from frame count and FPS
    if [ -n "$FRAME_COUNT" ] && [ "$FRAME_COUNT" -gt 0 ] && [ -n "$FPS" ]; then
        if command -v bc &> /dev/null; then
            DURATION_SEC=$(echo "scale=2; $FRAME_COUNT / $FPS" | bc)
            DURATION_DISPLAY="${DURATION_SEC}s"
        else
            DURATION_DISPLAY="${FRAME_COUNT} frames @ ${FPS}fps"
        fi
    else
        DURATION_DISPLAY="N/A"
    fi
    
    # Create ImageDecoder script for WebP (play once, no loop)
    # Use a temporary file to avoid heredoc parsing issues with JavaScript parentheses
    SCRIPT_TEMP=$(mktemp)
    cat > "$SCRIPT_TEMP" <<'SCRIPT_EOF'
    <script>
        // Function to update resolution display
        function updateResolution(width, height) {
            const resolutionElement = document.querySelector('.media-info-row:nth-child(2) .media-info-value');
            if (resolutionElement && width > 0 && height > 0) {
                resolutionElement.textContent = width + 'x' + height;
            }
        }
        
        (async function() {
            const canvas = document.getElementById('webpCanvas');
            const ctx = canvas.getContext('2d');
            const img = document.getElementById('webpFallback');
            const webpUrl = '{{WEBP_URL}}';
            
            // Try to get resolution from fallback img if canvas isn't ready
            if (img && img.complete && img.naturalWidth > 0) {
                updateResolution(img.naturalWidth, img.naturalHeight);
            } else if (img) {
                img.onload = function() {
                    updateResolution(this.naturalWidth, this.naturalHeight);
                };
            }
            
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
                        
                        // Update resolution display
                        updateResolution(canvas.width, canvas.height);
                        
                        // Don't rely on frameCount - decode frames sequentially until error
                        console.log('Reported frame count:', decoder.frameCount);
                        console.log('Starting animation (play once, no loop)...');
                        
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
                                
                                // Use dynamic delay to mimic specified FPS
                                const delayMs = 1000 / {{FPS}};
                                
                                // Draw frame to canvas
                                ctx.clearRect(0, 0, canvas.width, canvas.height);
                                ctx.drawImage(image, 0, 0);
                                
                                // Store last frame
                                lastFrame = image;
                                
                                console.log(`Rendering frame ${frameNumber} (delay: ${delayMs.toFixed(2)}ms)`);
                                
                                // Try to decode and render next frame after delay
                                setTimeout(async () => {
                                    if (!hasCompleted) {
                                        try {
                                            // Try to peek at next frame
                                            const nextFrame = await decoder.decode({ frameIndex: frameIndex + 1 });
                                            // Next frame exists, render it
                                            renderFrame(frameIndex + 1);
                                        } catch (nextError) {
                                            // No more frames - animation complete (no loop)
                                            hasCompleted = true;
                                            const animationEndTime = performance.now();
                                            const totalDuration = animationEndTime - animationStartTime;
                                            const expectedDuration = frameNumber * (1000 / {{FPS}});
                                            const actualFPS = frameNumber / (totalDuration / 1000);
                                            console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                            console.log(`Animation complete after ${frameNumber} frames (no loop)`);
                                            console.log(`Total animation duration: ${totalDuration.toFixed(2)}ms (${(totalDuration / 1000).toFixed(2)}s)`);
                                            console.log(`Expected duration at {{FPS}}fps: ${expectedDuration.toFixed(2)}ms (${(expectedDuration / 1000).toFixed(2)}s)`);
                                            console.log(`Actual FPS: ${actualFPS.toFixed(2)}`);
                                            console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                            // Last frame is already drawn, so we're done (no loop)
                                        }
                                    }
                                }, delayMs);
                                
                            } catch (error) {
                                // No more frames - keep last frame displayed and stop (no loop)
                                hasCompleted = true;
                                const animationEndTime = performance.now();
                                const totalDuration = animationEndTime - animationStartTime;
                                const expectedDuration = frameNumber * (1000 / {{FPS}});
                                const actualFPS = frameNumber / (totalDuration / 1000);
                                console.log(`Frame decode error (end): ${error.message}`);
                                console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                console.log(`Animation complete after ${frameNumber} frames (no loop)`);
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
                        setTimeout(async () => {
                            try {
                                const testFrame = await decoder.decode({ frameIndex: 1 });
                                console.log('Found additional frames, starting animation (play once)');
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
                    img.src = webpUrl;
                    img.style.display = 'block';
                    if (img.complete && img.naturalWidth > 0) {
                        updateResolution(img.naturalWidth, img.naturalHeight);
                    } else {
                        img.onload = function() {
                            updateResolution(this.naturalWidth, this.naturalHeight);
                        };
                    }
                }
            } else {
                // ImageDecoder not supported - show warning and use canvas workaround
                console.warn('ImageDecoder not supported. Animation will loop. Please use Chrome 94+ or Edge 94+ for play-once functionality.');
                canvas.classList.remove('active');
                img.classList.remove('fallback-img');
                img.src = webpUrl;
                img.style.display = 'block';
                if (img.complete && img.naturalWidth > 0) {
                    updateResolution(img.naturalWidth, img.naturalHeight);
                } else {
                    img.onload = function() {
                        updateResolution(this.naturalWidth, this.naturalHeight);
                    };
                }
                
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
    SCRIPT_CONTENT=$(cat "$SCRIPT_TEMP")
    rm -f "$SCRIPT_TEMP"
    
    # Read template and replace placeholders
    TEMPLATE_PATH="$(dirname "$0")/preview-template.html"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo -e "${RED}Error: Template file not found: $TEMPLATE_PATH${NC}"
        exit 1
    fi
    
    # Replace WEBP_URL and FPS placeholders in script content and write to temp file
    SCRIPT_TEMP=$(mktemp)
    echo "$SCRIPT_CONTENT" | sed -e "s|{{WEBP_URL}}|${WEBP_URL}|g" -e "s|{{FPS}}|${FPS}|g" > "$SCRIPT_TEMP"
    
    # Escape WEBP_URL for sed
    ESCAPED_WEBP_URL=$(printf '%s\n' "$WEBP_URL" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Create temporary HTML file
    HTML_TEMP=$(mktemp)
    # First replace all placeholders except SCRIPT_CONTENT
    sed -e "s|{{TITLE}}|Animated WebP Preview (No Loop)|g" \
        -e "s|{{DESCRIPTION}}|If the image has transparency, you should see the checkered background through transparent areas. Animation plays once (no loop).|g" \
        -e "s|{{MEDIA_ELEMENT}}|<canvas id=\"webpCanvas\"></canvas><img id=\"webpFallback\" class=\"fallback-img\" src=\"${ESCAPED_WEBP_URL}\" alt=\"Animated WebP\">|g" \
        -e "s|{{FILE_TYPE}}|Animated WebP (No Loop)|g" \
        -e "s|{{RESOLUTION}}|${RESOLUTION_DISPLAY}|g" \
        -e "s|{{FPS}}|${FPS}|g" \
        -e "s|{{ENCODING}}|WebP Animation (webpmux)|g" \
        -e "s|{{DURATION}}|${DURATION_DISPLAY}|g" \
        -e "s|{{MEDIA_URL}}|${ESCAPED_WEBP_URL}|g" \
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
    
    # Upload HTML preview
    echo -e "${YELLOW}Uploading HTML preview to s3://${BUCKET_NAME}/${S3_HTML_PATH}...${NC}"
    HTML_PUBLIC_URL=$("$UPLOAD_SCRIPT" "$HTML_TEMP" "$BUCKET_NAME" "$S3_HTML_PATH" "text/html" | tr -d '\n\r')
    
    # Clean up temp file
    rm -f "$HTML_TEMP"
    
    # Print only the final URLs
    echo ""
    echo -e "${GREEN}Animated WebP URL:${NC}"
    echo -e "  ${WEBP_URL}"
    echo ""
    echo -e "${GREEN}HTML Preview URL:${NC}"
    echo -e "  ${HTML_PUBLIC_URL}"
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
    echo "   Note: Animation is set to play once (no loop)"
    echo "   For older browsers, consider using GIF format"
    echo ""
    echo "4. To upload to S3, use the -b option:"
    echo "   $0 -i $INPUT_DIR -b my-bucket-name"
    echo ""
fi
