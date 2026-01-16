# Chroma Key Green Screen Export with Alpha Channel

A web-based tool for removing green screen backgrounds from videos and images, with support for exporting transparent backgrounds in multiple formats.

## Features

- **Real-time Preview**: See the chroma key effect applied in real-time as you adjust settings
- **Multiple Detection Modes**:
  - **Default Green Screen Detection**: Automatically detects and removes green backgrounds
  - **Custom Color Selection**: Pick any color from the video to remove (supports green, blue, red, or any custom color)
- **Adjustable Settings**:
  - Color threshold/sensitivity
  - Saturation threshold
  - Edge softness/smoothing
- **Multiple Export Formats**:
  - **Frame-by-Frame (WebP)**: Export as a ZIP file containing individual WebP frames with transparency
  - **Animated Video (WebM)**: Export as WebM video with VP9 codec supporting alpha transparency
  - **Animated GIF**: Export as GIF with transparency support
- **Video Controls**:
  - Play/pause
  - Seek bar with time display
  - Mute/unmute
  - Repeat/loop
- **Preview Page**: Test exported files with transparency on a colored background

## How to Use

1. **Load a Video**: Click the folder icon to select a video file (or the tool will try to load `input.mov` if present)
2. **Choose Detection Mode**:
   - **Default**: Automatically detects green screens
   - **Custom**: Click "Pick Color" and then click on the video to select the color to remove
3. **Adjust Settings**: Use the sliders to fine-tune the chroma key effect:
   - **Color Threshold**: How sensitive the color detection is
   - **Saturation Threshold**: Minimum color intensity required (filters out gray pixels)
   - **Smoothness**: Edge smoothing for better blending
4. **Export**: Click the export button and choose:
   - **FPS**: Frames per second (10, 15, 24, 30, or 60)
   - **Format**: WebP frames, WebM video, or GIF
5. **Preview**: Use the preview button to view your exported file with transparency

## Technical Details

- Uses HTML5 Canvas for real-time chroma key processing
- Supports HSV (Hue, Saturation, Value) color space for better color matching
- Includes spill suppression to reduce color contamination on edges
- WebM export uses MediaRecorder API with VP9 codec for alpha channel support
- GIF export uses gif.js library with 1-bit transparency support

## Browser Compatibility

- Modern browsers with HTML5 Canvas and MediaRecorder support
- Chrome, Firefox, Edge, Safari (latest versions)
- WebM export requires VP9 codec support
- GIF export works in all modern browsers

## File Structure

- `index.html`: Main application with video player and chroma key controls
- `preview.html`: Preview page for testing exported files with transparency
- `input.mov`: Sample video file (optional)

## Notes

- For best results, use videos with consistent lighting and a solid color background
- Green screen backgrounds work best, but the tool supports any solid color
- Higher FPS exports result in larger file sizes but smoother animations
- WebM format provides the best quality with full alpha channel support
- GIF format has 1-bit transparency (fully opaque or fully transparent pixels)
