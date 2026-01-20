/**
 * GIF Export Module
 * Exports video as animated GIF with transparency
 */

async function exportGIF(video, videoCanvas, applyChromaKey, redrawFrame, seekAndWait, downloadBlob, getTimestamp, progressBarFill, progressText, previewBtn, isExporting, isPlaying, drawFrame) {
    const duration = video.duration;
    const fpsSelect = document.getElementById('exportFps');
    const fps = fpsSelect ? parseInt(fpsSelect.value) || 30 : 30;
    const totalFrames = Math.floor(duration * fps);
    const frameDelay = 1000 / fps; // Delay between frames in ms
    
    // Store dimensions
    const canvasWidth = video.videoWidth;
    const canvasHeight = video.videoHeight;
    
    if (canvasWidth === 0 || canvasHeight === 0) {
        throw new Error('Video dimensions not available');
    }
    
    // Create export canvas - will be resized to match videoCanvas
    const exportCanvas = document.createElement('canvas');
    const exportCtx = exportCanvas.getContext('2d', { willReadFrequently: true });
    
    // Create GIF encoder with inline worker
    // Fetch and create blob URL for worker to avoid CORS issues
    let workerBlob;
    try {
        const workerResponse = await fetch('https://cdnjs.cloudflare.com/ajax/libs/gif.js/0.2.0/gif.worker.js');
        const workerText = await workerResponse.text();
        workerBlob = URL.createObjectURL(new Blob([workerText], { type: 'application/javascript' }));
    } catch (e) {
        console.error('Failed to load GIF worker:', e);
        throw new Error('Failed to initialize GIF encoder');
    }
    
    // Reset video to start
    video.pause();
    await seekAndWait(video, 0);
    
    // Ensure videoCanvas has correct dimensions by redrawing first frame
    redrawFrame();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    
    // Get actual dimensions from videoCanvas
    const actualWidth = videoCanvas.width;
    const actualHeight = videoCanvas.height;
    
    if (actualWidth === 0 || actualHeight === 0) {
        throw new Error('Canvas dimensions not available after frame render');
    }
    
    // Set export canvas dimensions
    exportCanvas.width = actualWidth;
    exportCanvas.height = actualHeight;
    
    const gif = new GIF({
        workers: 2,
        quality: 10,
        width: actualWidth,
        height: actualHeight,
        workerScript: workerBlob,
        transparent: 0xFF00FF, // Magenta as transparent color (less likely to conflict)
        background: '#FF00FF'
    });
    
    // Play video and capture frames as it renders (similar to WebM export)
    let frameIndex = 0;
    let lastCaptureTime = 0;
    const frameInterval = 1000 / fps; // Time between frames in ms
    
    // Start playing the video - ensure animation loop is running
    video.currentTime = 0;
    await seekAndWait(video, 0);
    
    // Ensure the animation loop is running to update videoCanvas
    if (!isPlaying) {
        isPlaying = true;
        drawFrame(); // Start the animation loop
    }
    
    video.play();
    
    // Capture frames as video plays
    await new Promise((resolve) => {
        const captureFrame = () => {
            if (!isExporting || video.ended || video.currentTime >= duration - 0.1) {
                video.pause();
                resolve();
                return;
            }
            
            const currentTime = video.currentTime * 1000; // Convert to ms
            
            // Capture frame at the desired FPS interval
            if (currentTime - lastCaptureTime >= frameInterval) {
                lastCaptureTime = currentTime;
                
                // videoCanvas should already be updated by the drawFrame animation loop
                // Wait for next frame to ensure canvas is updated
                requestAnimationFrame(() => {
                    requestAnimationFrame(() => {
                        // Ensure exportCanvas matches videoCanvas dimensions
                        if (exportCanvas.width !== videoCanvas.width || exportCanvas.height !== videoCanvas.height) {
                            exportCanvas.width = videoCanvas.width;
                            exportCanvas.height = videoCanvas.height;
                        }
                        
                        // Copy from videoCanvas (which has the chroma-keyed frame) to exportCanvas
                        exportCtx.clearRect(0, 0, exportCanvas.width, exportCanvas.height);
                        exportCtx.drawImage(videoCanvas, 0, 0);
                        
                        // For GIF: replace transparent pixels with the key color (GIF only supports 1-bit transparency)
                        const imageData = exportCtx.getImageData(0, 0, exportCanvas.width, exportCanvas.height);
                        const data = imageData.data;
                        
                        // Count visible pixels and validate content
                        let visiblePixelCount = 0;
                        let totalPixels = data.length / 4;
                        
                        for (let j = 0; j < data.length; j += 4) {
                            if (data[j + 3] >= 128) {
                                visiblePixelCount++;
                            } else {
                                // Set transparent pixels to magenta (transparent key color for GIF)
                                data[j] = 255;     // R
                                data[j + 1] = 0;   // G
                                data[j + 2] = 255; // B
                                data[j + 3] = 255; // A (opaque for GIF, but will be made transparent by GIF encoder)
                            }
                        }
                        
                        // Log first few frames for debugging
                        const visiblePercentage = (visiblePixelCount / totalPixels) * 100;
                        if (frameIndex < 3) {
                            console.log(`Frame ${frameIndex}: ${visiblePercentage.toFixed(2)}% visible pixels`);
                        }
                        
                        exportCtx.putImageData(imageData, 0, 0);
                        
                        // Add frame to GIF - gif.js copies the canvas data
                        gif.addFrame(exportCanvas, { delay: frameDelay, copy: true });
                        
                        frameIndex++;
                        
                        // Update progress
                        const progress = Math.round((video.currentTime / duration) * 100);
                        progressBarFill.style.width = progress + '%';
                        progressText.textContent = `Capturing frames... ${progress}% (${frameIndex}/${totalFrames})`;
                    });
                });
            }
            
            // Continue capturing
            requestAnimationFrame(captureFrame);
        };
        
        // Start capturing
        captureFrame();
        
        // Also handle video end event
        video.onended = () => {
            video.pause();
            resolve();
        };
    });
    
    if (!isExporting) {
        progressText.textContent = 'Export cancelled';
        URL.revokeObjectURL(workerBlob);
        return;
    }
    
    // Render GIF
    progressText.textContent = 'Encoding GIF...';
    
    await new Promise((resolve, reject) => {
        gif.on('finished', async (blob) => {
            // Clean up worker blob URL
            URL.revokeObjectURL(workerBlob);
            
            // Validate the exported GIF
            const minSize = 300 * 1024; // 300KB in bytes
            const fileSizeKB = blob.size / 1024;
            
            // Check if file is suspiciously small (likely empty)
            if (blob.size < minSize) {
                console.warn(`GIF file size (${blob.size} bytes) is smaller than expected minimum (${minSize} bytes). The export may be empty or corrupted.`);
                alert(`Warning: The exported GIF file size (${fileSizeKB.toFixed(1)} KB) is smaller than expected. The file may be empty or corrupted.`);
            } else {
                // Even if file size is large, validate by checking if it's likely empty
                // Large empty GIFs can still have significant file size due to encoding overhead
                console.log(`GIF export completed: ${fileSizeKB.toFixed(1)} KB, ${totalFrames} frames`);
            }
            
            const filename = `animation_export_${getTimestamp()}.gif`;
            await downloadBlob(blob, filename);
            
            // Save preview
            const reader = new FileReader();
            reader.onload = () => {
                try {
                    localStorage.setItem('lastExportData', reader.result);
                    localStorage.setItem('lastExportType', 'image/gif');
                    previewBtn.disabled = false;
                } catch (e) {
                    console.log('Could not save preview to localStorage:', e);
                }
            };
            reader.readAsDataURL(blob);
            
            progressText.textContent = 'Export complete!';
            resolve();
        });
        
        gif.on('progress', (p) => {
            const progress = Math.round(p * 100);
            progressBarFill.style.width = progress + '%';
            progressText.textContent = `Encoding GIF... ${progress}%`;
        });
        
        gif.render();
    });
}
