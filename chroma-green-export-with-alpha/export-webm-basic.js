/**
 * WebM Basic Export Module
 * Exports video as WebM using MediaRecorder API
 */

async function exportWebMBasic(video, videoCanvas, seekAndWait, downloadBlob, getTimestamp, progressBarFill, progressText, previewBtn, isExporting) {
    const duration = video.duration;
    const fpsSelect = document.getElementById('exportFps');
    const fps = fpsSelect ? parseInt(fpsSelect.value) || 30 : 30;
    
    // Store dimensions
    const canvasWidth = video.videoWidth;
    const canvasHeight = video.videoHeight;
    
    if (canvasWidth === 0 || canvasHeight === 0) {
        throw new Error('Video dimensions not available');
    }
    
    // Use the visible videoCanvas for recording (it's already rendering the chroma-keyed video)
    const stream = videoCanvas.captureStream(fps);
    
    // Setup MediaRecorder with VP9 codec for transparency support
    const chunks = [];
    const mediaRecorder = new MediaRecorder(stream, {
        mimeType: 'video/webm;codecs=vp9',
        videoBitsPerSecond: 8000000,
    });
    
    mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) {
            chunks.push(e.data);
        }
    };
    
    // Reset video to start
    video.pause();
    await seekAndWait(video, 0);
    
    // Start recording with chunks every 100ms
    mediaRecorder.start(100);
    
    // Play video in real-time while recording
    video.play();
    
    // Wait for video to finish playing, updating progress
    await new Promise((resolve) => {
        const checkProgress = setInterval(() => {
            if (!isExporting) {
                clearInterval(checkProgress);
                video.pause();
                mediaRecorder.stop();
                resolve();
                return;
            }
            
            const progress = Math.round((video.currentTime / duration) * 100);
            progressBarFill.style.width = progress + '%';
            progressText.textContent = `Recording... ${progress}%`;
            
            if (video.ended || video.currentTime >= duration - 0.1) {
                clearInterval(checkProgress);
                resolve();
            }
        }, 100);
        
        video.onended = () => {
            clearInterval(checkProgress);
            resolve();
        };
    });
    
    // Stop video and recording
    video.pause();
    progressText.textContent = 'Finalizing video...';
    
    const blob = await new Promise((resolve) => {
        mediaRecorder.onstop = () => {
            resolve(new Blob(chunks, { type: 'video/webm' }));
        };
        mediaRecorder.stop();
    });
    
    const filename = `video_export_${getTimestamp()}.webm`;
    
    // Download the video (cross-browser compatible)
    await downloadBlob(blob, filename);
    
    // Save to localStorage for preview (try video first, fall back to frame)
    try {
        const reader = new FileReader();
        reader.onload = () => {
            try {
                localStorage.setItem('lastExportData', reader.result);
                localStorage.setItem('lastExportType', 'video/webm');
                previewBtn.disabled = false;
            } catch (e) {
                // Video too large, save first frame instead
                console.log('Video too large for localStorage, saving frame instead');
                saveFirstFrameForPreview();
            }
        };
        reader.readAsDataURL(blob);
    } catch (e) {
        saveFirstFrameForPreview();
    }
    
    async function saveFirstFrameForPreview() {
        await seekAndWait(video, 0);
        const previewCanvas = document.createElement('canvas');
        previewCanvas.width = canvasWidth;
        previewCanvas.height = canvasHeight;
        const previewCtx = previewCanvas.getContext('2d');
        previewCtx.drawImage(videoCanvas, 0, 0);
        const previewDataUrl = previewCanvas.toDataURL('image/webp', 0.9);
        try {
            localStorage.setItem('lastExportData', previewDataUrl);
            localStorage.setItem('lastExportType', 'image/webp');
            previewBtn.disabled = false;
        } catch (e) {
            console.log('Could not save preview to localStorage:', e);
        }
    }
    
    progressText.textContent = 'Export complete!';
}
