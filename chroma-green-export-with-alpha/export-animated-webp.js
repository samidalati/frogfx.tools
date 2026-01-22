/**
 * Animated WebP Export Module
 * Exports video as a single animated WebP file with transparency
 */

async function exportAnimatedWebP(video, videoCanvas, applyChromaKey, redrawFrame, seekAndWait, downloadBlob, getTimestamp, progressBarFill, progressText, previewBtn, isExporting) {
    // Check if WebPXMux is available
    if (typeof WebPXMux === 'undefined') {
        throw new Error('WebPXMux library not loaded. Please refresh the page.');
    }

    const duration = video.duration;
    const fpsSelect = document.getElementById('exportFps');
    const fps = fpsSelect ? parseInt(fpsSelect.value) || 30 : 30;
    let totalFrames = Math.floor(duration * fps);
    const frameDuration = 1000 / fps; // Duration per frame in milliseconds
    
    // Store dimensions
    const canvasWidth = video.videoWidth;
    const canvasHeight = video.videoHeight;
    
    if (canvasWidth === 0 || canvasHeight === 0) {
        throw new Error('Video dimensions not available');
    }
    
    // Use fixed batch size of 50 frames to avoid memory issues
    const maxFramesPerBatch = 50;
    
    // Use full resolution - no downscaling
    const exportWidth = canvasWidth;
    const exportHeight = canvasHeight;
    
    // Create export canvas
    const exportCanvas = document.createElement('canvas');
    const exportCtx = exportCanvas.getContext('2d', { willReadFrequently: true });
    exportCanvas.width = exportWidth;
    exportCanvas.height = exportHeight;
    
    // Initialize WebPXMux
    progressText.textContent = 'Initializing WebP encoder...';
    progressBarFill.style.width = '5%';
    
    let xmux;
    try {
        // Create WebPXMux instance with WASM path
        // The library requires the WASM file path as a string parameter
        if (typeof WebPXMux !== 'function') {
            throw new Error('WebPXMux is not a function');
        }
        
        // Provide WASM path from CDN
        const wasmPath = 'https://cdn.jsdelivr.net/npm/webpxmux@0.0.2/dist/webpxmux.wasm';
        xmux = WebPXMux(wasmPath);
        
        // Wait for WASM runtime to be ready
        if (typeof xmux.waitRuntime === 'function') {
            await xmux.waitRuntime();
        } else if (typeof xmux.ready === 'function') {
            await xmux.ready();
        }
    } catch (e) {
        console.error('WebPXMux initialization error:', e);
        throw new Error('Failed to initialize WebP encoder: ' + e.message);
    }
    
    // Pause video and reset to start
    video.pause();
    await seekAndWait(video, 0);
    
    // Wait for video to be ready
    while (video.readyState < 2) {
        await new Promise(resolve => setTimeout(resolve, 10));
    }
    
    // Ensure videoCanvas has correct dimensions by redrawing first frame
    redrawFrame();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    
    // Collect all frames
    const frames = [];
    
    for (let i = 0; i < totalFrames; i++) {
        if (!isExporting) break;
        
        // Update progress
        const progress = ((i + 1) / totalFrames) * 90; // Reserve 10% for encoding
        progressBarFill.style.width = progress + '%';
        progressText.textContent = `Capturing frame ${i + 1} of ${totalFrames}...`;
        
        // Seek to frame time
        const frameTime = i / fps;
        await seekAndWait(video, frameTime);
        
        // Wait for video to be ready to draw
        while (video.readyState < 2) {
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        
        // Wait a bit more to ensure frame is fully decoded
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        
        // Capture frame with chroma key applied
        exportCtx.clearRect(0, 0, exportCanvas.width, exportCanvas.height);
        exportCtx.drawImage(video, 0, 0, exportWidth, exportHeight);
        
        // Apply chroma key
        const frameImageData = exportCtx.getImageData(0, 0, exportCanvas.width, exportCanvas.height);
        const processedData = applyChromaKey(frameImageData);
        
        // Use processedData directly - no need to get ImageData again
        const data = processedData.data;
        const width = processedData.width;
        const height = processedData.height;
        
        // Validate dimensions match export dimensions
        if (width !== exportWidth || height !== exportHeight) {
            console.warn(`Frame ${i} dimensions mismatch: expected ${exportWidth}x${exportHeight}, got ${width}x${height}`);
        }
        
        // Convert ImageData to Uint32Array in 0xRRGGBBAA format
        // Ensure we use the correct dimensions from processedData
        const pixelCount = width * height;
        const rgba = new Uint32Array(pixelCount);
        
        // Validate data length
        if (data.length !== pixelCount * 4) {
            throw new Error(`Frame ${i} data length mismatch: expected ${pixelCount * 4}, got ${data.length}`);
        }
        
        for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
                const pixelIdx = y * width + x;
                const dataIdx = pixelIdx * 4;
                const r = data[dataIdx];
                const g = data[dataIdx + 1];
                const b = data[dataIdx + 2];
                const a = data[dataIdx + 3];
                // Format: 0xRRGGBBAA (big-endian)
                rgba[pixelIdx] = (r << 24) | (g << 16) | (b << 8) | a;
            }
        }
        
        // Validate rgba array size
        if (rgba.length !== pixelCount) {
            throw new Error(`Frame ${i} rgba array size mismatch: expected ${pixelCount}, got ${rgba.length}`);
        }
        
        // Add frame to collection
        frames.push({
            duration: frameDuration,
            isKeyframe: i === 0, // First frame is keyframe
            rgba: rgba
        });
    }
    
    if (!isExporting) {
        progressText.textContent = 'Export cancelled';
        return;
    }
    
    // Frame capture complete - update progress immediately to show encoding is starting
    // This prevents the progress bar from appearing frozen
    progressText.textContent = 'Starting encoding...';
    progressBarFill.style.width = '90%';
    
    // Force a visual update by triggering a reflow
    void progressBarFill.offsetWidth;
    
    // Encode animated WebP in batches (50 frames per batch)
    if (frames.length === 0) {
        throw new Error('No frames captured');
    }
    
    try {
        const frameWidth = exportWidth;
        const frameHeight = exportHeight;
        
        // Validate all frames have correct size
        for (let i = 0; i < frames.length; i++) {
            const expectedSize = frameWidth * frameHeight;
            if (frames[i].rgba.length !== expectedSize) {
                throw new Error(`Frame ${i} has incorrect size: expected ${expectedSize}, got ${frames[i].rgba.length}`);
            }
        }
        
        // Calculate number of batches
        const numBatches = Math.ceil(frames.length / maxFramesPerBatch);
        const batchSize = maxFramesPerBatch;
        
        console.log(`[Animated WebP Export] Starting batch encoding:`);
        console.log(`  - Total frames: ${frames.length}`);
        console.log(`  - Batch size: ${batchSize} frames`);
        console.log(`  - Number of batches: ${numBatches}`);
        console.log(`  - Resolution: ${frameWidth}x${frameHeight}`);
        
        // Progress tracking for encoding phase
        let encodingProgress = 90;
        let progressInterval = null;
        let targetProgress = 90;
        
        // Start progress animation for encoding phase
        const startEncodingProgress = (targetPercent) => {
            if (progressInterval) clearInterval(progressInterval);
            targetProgress = targetPercent;
            progressInterval = setInterval(() => {
                if (encodingProgress < targetProgress) {
                    encodingProgress = Math.min(targetProgress, encodingProgress + 0.5);
                    progressBarFill.style.width = encodingProgress + '%';
                }
            }, 200); // Update every 200ms for smooth animation
        };
        
        // Start encoding progress animation immediately
        startEncodingProgress(91);
        
        // Encode batches and store the WebP data
        const batchWebPs = [];
        
        for (let batchIndex = 0; batchIndex < numBatches; batchIndex++) {
            if (!isExporting) {
                if (progressInterval) clearInterval(progressInterval);
                progressText.textContent = 'Export cancelled';
                return;
            }
            
            const startFrame = batchIndex * batchSize;
            const endFrame = Math.min(startFrame + batchSize, frames.length);
            const batchFrames = frames.slice(startFrame, endFrame);
            
            // Update progress text to show encoding (change from "Capturing" to "Encoding")
            progressText.textContent = `Encoding batch ${batchIndex + 1} of ${numBatches} (frames ${startFrame + 1} to ${endFrame})...`;
            
            // Calculate progress percentage for this batch
            const batchProgress = 90 + ((batchIndex + 1) / numBatches) * 8; // 90% to 98%
            startEncodingProgress(batchProgress);
            
            console.log(`[Batch ${batchIndex + 1}/${numBatches}] Encoding frames ${startFrame + 1} to ${endFrame} (${batchFrames.length} frames)...`);
            
            const batchFramesInput = {
                frameCount: batchFrames.length,
                width: frameWidth,
                height: frameHeight,
                loopCount: 0,
                bgColor: 0x00000000,
                frames: batchFrames.map((frame, idx) => ({
                    duration: Math.round(frame.duration),
                    isKeyframe: idx === 0, // First frame of each batch is keyframe
                    rgba: frame.rgba
                }))
            };
            
            try {
                const batchStartTime = performance.now();
                const batchWebpData = await xmux.encodeFrames(batchFramesInput);
                const batchEndTime = performance.now();
                const batchDuration = ((batchEndTime - batchStartTime) / 1000).toFixed(2);
                
                batchWebPs.push({
                    data: batchWebpData,
                    frameCount: batchFrames.length,
                    startFrame: startFrame
                });
                
                console.log(`[Batch ${batchIndex + 1}/${numBatches}] ✓ Encoded successfully in ${batchDuration}s (${batchFrames.length} frames)`);
            } catch (batchError) {
                if (progressInterval) clearInterval(progressInterval);
                console.error(`[Batch ${batchIndex + 1}/${numBatches}] ✗ Encoding failed:`, batchError);
                throw new Error(`Failed to encode batch ${batchIndex + 1}: ${batchError.message}`);
            }
        }
        
        // Clear progress interval
        if (progressInterval) clearInterval(progressInterval);
        
        // Combine batches into final WebP
        progressText.textContent = `Combining ${numBatches} batches into final animation...`;
        progressBarFill.style.width = '98%';
        
        console.log(`[Combining] Attempting to merge ${numBatches} batches into final WebP...`);
        console.log(`  - Total frames to combine: ${frames.length}`);
        
        let webpData;
        
        // Try to encode all frames at once for final output
        // Since batches encoded successfully, frames are valid
        // But we might still hit memory limits with all frames
        try {
            const finalFramesInput = {
                frameCount: frames.length,
                width: frameWidth,
                height: frameHeight,
                loopCount: 0,
                bgColor: 0x00000000,
                frames: frames.map((frame, idx) => ({
                    duration: Math.round(frame.duration),
                    isKeyframe: idx === 0, // Only first frame is keyframe
                    rgba: frame.rgba
                }))
            };
            
            const finalStartTime = performance.now();
            webpData = await xmux.encodeFrames(finalFramesInput);
            const finalEndTime = performance.now();
            const finalDuration = ((finalEndTime - finalStartTime) / 1000).toFixed(2);
            
            console.log(`[Final Encoding] ✓ Combined all ${frames.length} frames successfully in ${finalDuration}s`);
        } catch (finalError) {
            console.error(`[Final Encoding] ✗ Failed to combine all frames:`, finalError);
            console.log(`[Fallback] Using first batch as output (${batchWebPs[0].frameCount} frames)`);
            
            // Fallback: use the first batch if final encode fails
            // This is not ideal but ensures we get some output
            webpData = batchWebPs[0].data;
            
            progressText.textContent = `Warning: Using first batch only (${batchWebPs[0].frameCount} frames) due to memory limits`;
        }
        
        // Ensure webpData is a Uint8Array or ArrayBuffer
        let webpArray;
        if (webpData instanceof Uint8Array) {
            webpArray = webpData;
        } else if (webpData instanceof ArrayBuffer) {
            webpArray = new Uint8Array(webpData);
        } else if (Array.isArray(webpData)) {
            webpArray = new Uint8Array(webpData);
        } else {
            // Try to convert
            webpArray = new Uint8Array(webpData);
        }
        
        // Create blob from Uint8Array
        const webpBlob = new Blob([webpArray], { type: 'image/webp' });
        
        // Update progress to show encoding complete
        progressText.textContent = 'Finalizing export...';
        progressBarFill.style.width = '99%';
        
        const filename = `animated_webp_${getTimestamp()}.webp`;
        await downloadBlob(webpBlob, filename);
        
        // Save to localStorage for preview
        try {
            const reader = new FileReader();
            reader.onload = () => {
                try {
                    localStorage.setItem('lastExportData', reader.result);
                    localStorage.setItem('lastExportType', 'image/webp');
                    previewBtn.disabled = false;
                } catch (e) {
                    console.log('Could not save preview to localStorage:', e);
                }
            };
            reader.readAsDataURL(webpBlob);
        } catch (e) {
            console.log('Could not save preview:', e);
        }
        
        progressText.textContent = 'Export complete!';
        progressBarFill.style.width = '100%';
        
    } catch (error) {
        console.error('WebP encoding error:', error);
        throw new Error('Failed to encode animated WebP: ' + error.message);
    }
}
