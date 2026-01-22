# Chroma Key Green Screen Export

Web-based tool for removing green screen (or any color) backgrounds from videos with real-time preview and multiple export formats.

## How It Works

1. **Load a video** - Click the upload area or folder icon to select a video file
2. **Adjust filters** - Use sliders to fine-tune color detection, saturation, and edge smoothing
3. **Export** - Choose format (WebP frames, PNG frames, WebM, GIF, or Animated WebP) and FPS
4. **Preview** - Test exported files with transparency on a colored background

The tool uses HTML5 Canvas to process each frame in real-time, converting RGB to HSV color space for accurate color matching and applying spill suppression to clean edges.

## Tools & Packages

### Browser Libraries (CDN)
- **[JSZip](https://stuk.github.io/jszip/) v3.10.1** - ZIP file creation for frame exports
- **[gif.js](https://jnordberg.github.io/gif.js/) v0.2.0** - Animated GIF encoding
- **[@ffmpeg/ffmpeg](https://ffmpegwasm.netlify.app/) v0.12.15** - FFmpeg WebAssembly (for advanced exports)
- **[@ffmpeg/util](https://github.com/ffmpegwasm/ffmpeg.wasm) v0.12.1** - FFmpeg utilities
- **[@ffmpeg/core](https://github.com/ffmpegwasm/ffmpeg.wasm) v0.12.6** - FFmpeg core WASM
- **[webpxmux](https://www.npmjs.com/package/webpxmux) v0.0.2** - Animated WebP encoding

### Command-Line Tools (for shell scripts)
- **[FFmpeg](https://ffmpeg.org/)** - Video processing and encoding
- **[ffprobe](https://ffmpeg.org/ffprobe.html)** - Media file analysis (part of FFmpeg)
- **[webpmux](https://developers.google.com/speed/webp/docs/webpmux)** - WebP animation tool (part of [libwebp](https://developers.google.com/speed/webp))

## Features

- Real-time chroma key preview
- Multiple color detection modes (green, magenta, cyan, custom, region selection)
- Export formats: WebP frames, PNG frames, WebM, GIF, Animated WebP
- Adjustable settings: color threshold, saturation, edge smoothing
- Video persistence: remembers last loaded video path

## Browser Support

Modern browsers with HTML5 Canvas support. WebM export requires VP9 codec support (Chrome, Firefox, Edge).
