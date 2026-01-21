/**
 * PNG Frames Export Module
 * Exports video frames as PNG images in a ZIP file
 */

async function exportPNGFrames(video, videoCanvas, applyChromaKey, redrawFrame, seekAndWait, downloadBlob, getTimestamp, progressBarFill, progressText, previewBtn, isExporting) {
    const JSZip = window.JSZip;
    if (!JSZip) {
        throw new Error('JSZip library not loaded');
    }

    const zip = new JSZip();
    const duration = video.duration;
    const fpsSelect = document.getElementById('exportFps');
    const fps = fpsSelect ? parseInt(fpsSelect.value) || 30 : 30;
    const totalFrames = Math.floor(duration * fps);
    
    // Create a dedicated export canvas
    const exportCanvas = document.createElement('canvas');
    const exportCtx = exportCanvas.getContext('2d', { willReadFrequently: true });
    
    const canvasWidth = video.videoWidth;
    const canvasHeight = video.videoHeight;
    
    if (canvasWidth === 0 || canvasHeight === 0) {
        throw new Error('Video dimensions not available');
    }
    
    // Set export canvas dimensions
    exportCanvas.width = canvasWidth;
    exportCanvas.height = canvasHeight;
    
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
    
    for (let i = 0; i < totalFrames; i++) {
        if (!isExporting) break;
        
        // Seek to frame time
        const frameTime = i / fps;
        await seekAndWait(video, frameTime);
        
        // Wait for video to be ready to draw
        while (video.readyState < 2) {
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        
        // Wait a bit more to ensure frame is fully decoded
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        
        // Capture directly from video with chroma key applied to exportCanvas
        exportCtx.clearRect(0, 0, exportCanvas.width, exportCanvas.height);
        exportCtx.drawImage(video, 0, 0, exportCanvas.width, exportCanvas.height);
        
        // Apply chroma key to the export canvas
        const frameImageData = exportCtx.getImageData(0, 0, exportCanvas.width, exportCanvas.height);
        const processedData = applyChromaKey(frameImageData);
        exportCtx.putImageData(processedData, 0, 0);
        
        // Get PNG data (PNG is lossless, no quality parameter needed)
        const dataUrl = exportCanvas.toDataURL('image/png');
        const base64Data = dataUrl.split(',')[1];
        
        // Validate frame is not empty (empty frames are ~3KB)
        const minFrameSize = 5000; // 5KB minimum (empty frames are ~3KB)
        const frameSize = (base64Data.length * 3) / 4; // Approximate binary size from base64
        
        if (frameSize < minFrameSize && i < 3) {
            console.warn(`Frame ${i} appears to be empty (${(frameSize / 1024).toFixed(1)} KB). Check chroma key settings.`);
        }
        
        // Validate frame has content by checking pixel data
        const validationData = processedData.data;
        let visiblePixelCount = 0;
        for (let j = 0; j < validationData.length; j += 4) {
            if (validationData[j + 3] >= 128) {
                visiblePixelCount++;
            }
        }
        const visiblePercentage = (visiblePixelCount / (validationData.length / 4)) * 100;
        
        if (visiblePercentage < 1 && i < 3) {
            console.warn(`Frame ${i} has only ${visiblePercentage.toFixed(2)}% visible pixels. Frame may appear empty.`);
        }
        
        // Add to zip with padded frame number
        const frameName = `frame_${String(i).padStart(5, '0')}.png`;
        zip.file(frameName, base64Data, { base64: true });
        
        // Update progress
        const progress = Math.round(((i + 1) / totalFrames) * 100);
        progressBarFill.style.width = progress + '%';
        progressText.textContent = `Exporting frames... ${progress}% (${i + 1}/${totalFrames})`;
        
        // Allow UI to update
        await new Promise(resolve => setTimeout(resolve, 10));
    }
    
    // Generate and download ZIP
    progressText.textContent = 'Creating ZIP file...';
    const zipBlob = await zip.generateAsync({ type: 'blob' });
    const zipFilename = `frames_export_png_${getTimestamp()}.zip`;
    
    // Download using cross-browser compatible method
    await downloadBlob(zipBlob, zipFilename);
    
    // Save first frame to localStorage for preview
    await seekAndWait(video, 0);
    while (video.readyState < 2) {
        await new Promise(resolve => setTimeout(resolve, 10));
    }
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    exportCtx.clearRect(0, 0, exportCanvas.width, exportCanvas.height);
    exportCtx.drawImage(video, 0, 0, exportCanvas.width, exportCanvas.height);
    const previewImageData = exportCtx.getImageData(0, 0, exportCanvas.width, exportCanvas.height);
    const previewProcessed = applyChromaKey(previewImageData);
    exportCtx.putImageData(previewProcessed, 0, 0);
    const previewDataUrl = exportCanvas.toDataURL('image/png');
    try {
        localStorage.setItem('lastExportData', previewDataUrl);
        localStorage.setItem('lastExportType', 'image/png');
        previewBtn.disabled = false;
    } catch (e) {
        console.log('Could not save preview to localStorage:', e);
    }
    
    progressText.textContent = 'Export complete!';
}
