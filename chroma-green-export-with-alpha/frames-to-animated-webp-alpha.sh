#!/bin/bash

# frames-to-animated-webp-alpha.sh
# Converts WebP frames into a single animated WebP image (similar to GIF)
# Requires: FFmpeg with WebP support
# Usage: ./frames-to-animated-webp-alpha.sh -i <input_folder> [-f <fps>] [-o <output_file>] [-b <bucket>]

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
    echo "      Output is an animated WebP image (similar to GIF but better compression)"
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

# Set default output name
if [ -z "$OUTPUT" ]; then
    OUTPUT="animated_webp_${TIMESTAMP}.webp"
fi

# Ensure output has .webp extension
if [[ ! "$OUTPUT" =~ \.webp$ ]]; then
    OUTPUT="${OUTPUT%.*}.webp"
fi

# Check for FFmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}Error: FFmpeg is not installed${NC}"
    echo "Install with: brew install ffmpeg"
    exit 1
fi

# Count WebP files
FRAME_COUNT=$(ls -1 "$INPUT_DIR"/*.webp 2>/dev/null | wc -l | tr -d ' ')

if [ "$FRAME_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No WebP files found in '$INPUT_DIR'${NC}"
    exit 1
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}WebP Frames to Animated WebP${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Input:   $INPUT_DIR ($FRAME_COUNT frames)"
echo -e "  Output:  $OUTPUT"
echo -e "  Format:  Animated WebP"
echo -e "  FPS:     $FPS"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

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

# Use ffmpeg to create animated WebP
# -framerate: input frame rate
# -i: input pattern
# -loop: number of loops (0 = infinite)
# -lossless: use lossless compression (0 = lossy, better compression)
# -compression_level: 0-6, higher = better compression but slower
echo -e "${YELLOW}Creating animated WebP...${NC}"

ffmpeg -y \
    -framerate "$FPS" \
    -i "$TEMP_DIR/frame_%06d.webp" \
    -loop 0 \
    -lossless 0 \
    -compression_level 6 \
    "$OUTPUT" 2>&1 | grep -E "(frame|Duration|Stream|Output)" || true

# Check if output file was created
if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}Error: Output file was not created${NC}"
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
echo ""

# Upload to S3 if bucket name provided
if [ -n "$BUCKET_NAME" ]; then
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
    
    # Ensure "Block Public Access" is disabled (required for object-level public access)
    echo -e "${YELLOW}Ensuring bucket allows public object access...${NC}"
    if aws s3api get-public-access-block --bucket "$BUCKET_NAME" &>/dev/null; then
        echo -e "${YELLOW}  Disabling 'Block Public Access'...${NC}"
        aws s3api put-public-access-block \
            --bucket "$BUCKET_NAME" \
            --public-access-block-configuration \
            "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>/dev/null
    fi
    
    # Upload animated WebP with public read grant
    echo -e "${YELLOW}Uploading animated WebP to s3://${BUCKET_NAME}/${S3_WEBP_PATH}...${NC}"
    # Try using s3api put-object with grants (more reliable than ACL)
    if aws s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "$S3_WEBP_PATH" \
        --body "$OUTPUT" \
        --content-type "image/webp" \
        --grant-read "uri=http://acs.amazonaws.com/groups/global/AllUsers" 2>/dev/null; then
        echo -e "${GREEN}✓ Animated WebP uploaded with public read access${NC}"
    elif aws s3 cp "$OUTPUT" "s3://${BUCKET_NAME}/${S3_WEBP_PATH}" \
        --content-type "image/webp" \
        --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers 2>/dev/null; then
        echo -e "${GREEN}✓ Animated WebP uploaded with public read access${NC}"
    elif aws s3 cp "$OUTPUT" "s3://${BUCKET_NAME}/${S3_WEBP_PATH}" \
        --content-type "image/webp" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Animated WebP uploaded, setting ACL...${NC}"
        # Try to set ACL after upload
        if aws s3api put-object-acl \
            --bucket "$BUCKET_NAME" \
            --key "$S3_WEBP_PATH" \
            --acl public-read 2>/dev/null; then
            echo -e "${GREEN}✓ Animated WebP is now publicly accessible${NC}"
        else
            echo -e "${YELLOW}⚠ Could not set public access${NC}"
        fi
    else
        echo -e "${RED}Error: Failed to upload animated WebP to S3${NC}"
        exit 1
    fi
    
    # Create HTML preview page
    WEBP_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_WEBP_PATH}"
    
    # Get bucket region for correct URL
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET_NAME" --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
    # Handle us-east-1 which returns null
    if [ "$BUCKET_REGION" = "None" ] || [ -z "$BUCKET_REGION" ]; then
        BUCKET_REGION="us-east-1"
    fi
    
    # Use region-specific URL
    if [ "$BUCKET_REGION" = "us-east-1" ]; then
        WEBP_URL="https://${BUCKET_NAME}.s3.amazonaws.com/${S3_WEBP_PATH}"
    else
        WEBP_URL="https://${BUCKET_NAME}.s3.${BUCKET_REGION}.amazonaws.com/${S3_WEBP_PATH}"
    fi
    
    # Create temporary HTML file
    HTML_TEMP=$(mktemp)
    cat > "$HTML_TEMP" <<HTML_EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Animated WebP Preview</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        html, body {
            height: 100%;
            width: 100%;
            overflow: hidden;
        }
        
        body {
            background: linear-gradient(45deg, #ff00ff 25%, #00ffff 25%, #00ffff 50%, #ff00ff 50%, #ff00ff 75%, #00ffff 75%);
            background-size: 40px 40px;
            height: 100vh;
            width: 100vw;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 10px;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
        }
        
        .header {
            flex-shrink: 0;
            text-align: center;
            margin-bottom: 10px;
        }
        
        h1 {
            color: white;
            text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.5);
            font-size: clamp(16px, 3vw, 24px);
            margin-bottom: 5px;
        }
        
        .info {
            color: white;
            text-shadow: 1px 1px 2px rgba(0, 0, 0, 0.5);
            font-size: clamp(12px, 2vw, 14px);
            max-width: 90vw;
        }
        
        .image-container {
            flex: 1;
            display: flex;
            align-items: center;
            justify-content: center;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 12px;
            padding: 10px;
            box-shadow: 0 10px 40px rgba(0, 0, 0, 0.3);
            max-width: calc(100vw - 20px);
            max-height: calc(100vh - 200px);
            min-height: 0;
        }
        
        img, video, canvas {
            max-width: 100%;
            max-height: 100%;
            width: auto;
            height: auto;
            display: block;
            border-radius: 8px;
            background: transparent;
            object-fit: contain;
        }
        
        canvas {
            border: 2px solid rgba(255, 255, 255, 0.3);
        }
        
        .fallback-img {
            display: none;
        }
        
        #webpCanvas {
            display: none;
        }
        
        #webpCanvas.active {
            display: block;
        }
        
        .url-info {
            flex-shrink: 0;
            margin-top: 10px;
            padding: 10px;
            background: rgba(0, 0, 0, 0.3);
            border-radius: 8px;
            color: white;
            font-size: clamp(10px, 1.5vw, 12px);
            max-width: calc(100vw - 20px);
            word-break: break-all;
            overflow: hidden;
        }
        
        .url-info strong {
            display: block;
            margin-bottom: 5px;
            color: #ffeb3b;
        }
        
        .url-info a {
            color: #4fc3f7;
            text-decoration: none;
        }
        
        .url-info a:hover {
            text-decoration: underline;
        }
        
        @media (max-height: 600px) {
            .header {
                margin-bottom: 5px;
            }
            
            h1 {
                font-size: 14px;
                margin-bottom: 2px;
            }
            
            .info {
                font-size: 11px;
            }
            
            .image-container {
                max-height: calc(100vh - 120px);
                padding: 5px;
            }
            
            .url-info {
                margin-top: 5px;
                padding: 5px;
                font-size: 10px;
            }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Animated WebP Preview</h1>
        <p class="info">If the image has transparency, you should see the checkered background through transparent areas</p>
    </div>
    
    <div class="image-container">
        <canvas id="webpCanvas"></canvas>
        <img id="webpFallback" class="fallback-img" src="${WEBP_URL}" alt="Animated WebP">
    </div>
    <script>
        (async function() {
            const canvas = document.getElementById('webpCanvas');
            const ctx = canvas.getContext('2d');
            const img = document.getElementById('webpFallback');
            const webpUrl = '${WEBP_URL}';
            
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
                                
                                // Use dynamic delay to mimic 30fps video (33.33ms per frame)
                                // Always use 30fps timing for consistent playback
                                const delayMs = 1000 / 30; // Exactly 33.33...ms for 30fps
                                
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
                                            // No more frames - animation complete
                                            hasCompleted = true;
                                            const animationEndTime = performance.now();
                                            const totalDuration = animationEndTime - animationStartTime;
                                            const expectedDuration = frameNumber * (1000 / 30); // Expected duration at 30fps
                                            const actualFPS = frameNumber / (totalDuration / 1000);
                                            console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                            console.log(`Animation complete after ${frameNumber} frames`);
                                            console.log(`Total animation duration: ${totalDuration.toFixed(2)}ms (${(totalDuration / 1000).toFixed(2)}s)`);
                                            console.log(`Expected duration at 30fps: ${expectedDuration.toFixed(2)}ms (${(expectedDuration / 1000).toFixed(2)}s)`);
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
                                const expectedDuration = frameNumber * (1000 / 30); // Expected duration at 30fps
                                const actualFPS = frameNumber / (totalDuration / 1000);
                                console.log(`Frame decode error (end): ${error.message}`);
                                console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
                                console.log(`Animation complete after ${frameNumber} frames`);
                                console.log(`Total animation duration: ${totalDuration.toFixed(2)}ms (${(totalDuration / 1000).toFixed(2)}s)`);
                                console.log(`Expected duration at 30fps: ${expectedDuration.toFixed(2)}ms (${(expectedDuration / 1000).toFixed(2)}s)`);
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
                warning.textContent = '⚠️ Your browser doesn\'t support ImageDecoder API. Animation will loop. Use Chrome 94+ or Edge 94+ for play-once functionality.';
                document.body.appendChild(warning);
                setTimeout(() => warning.remove(), 5000);
            }
        })();
    </script>
    
    <div class="url-info">
        <strong>Image URL:</strong>
        <a href="${WEBP_URL}" target="_blank">${WEBP_URL}</a>
    </div>
</body>
</html>
HTML_EOF
    
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
    echo -e "${GREEN}Animated WebP URL:${NC}"
    echo -e "  ${WEBP_PUBLIC_URL}"
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
                --key "$S3_WEBP_PATH" \
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
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${WEBP_PUBLIC_URL}" 2>/dev/null || echo "000")
    
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
    echo "   $0 -i $INPUT_DIR -b my-bucket-name"
    echo ""
fi
