# GitHub Pages Setup Instructions

## Quick Setup Steps

1. **Push your code to GitHub**
   ```bash
   git add .
   git commit -m "Initial commit"
   git push origin main
   ```

2. **Configure GitHub Pages**:
   - Go to your repository on GitHub
   - Click **Settings** (top menu)
   - Scroll down to **Pages** (left sidebar)
   - Under **Source**, select:
     - **Branch**: `main` (or `master`)
     - **Folder**: `/ (root)`
   - Click **Save**

3. **Custom Domain** (you already have CNAME file):
   - In the same **Pages** settings section
   - Under **Custom domain**, you should see `frogfx.tools`
   - Check **Enforce HTTPS** (recommended)
   - GitHub will automatically detect your `CNAME` file

4. **Wait for deployment**:
   - GitHub Pages typically takes 1-2 minutes to build
   - You'll see a green checkmark when it's ready
   - Your site will be live at `https://frogfx.tools`

## Accessing Your Tools

- **Landing page**: `https://frogfx.tools/` (shows the root index.html)
- **Chroma Key tool**: `https://frogfx.tools/chroma-green-export-with-alpha/`

## Notes

- The `CNAME` file must be in the root directory (already done)
- DNS records should point to GitHub Pages IPs (you mentioned you've configured this)
- After pushing, changes may take a few minutes to appear
- You can check deployment status in the **Actions** tab

## Optional: Root index.html

The root `index.html` I created serves as a landing page. If you don't want it:
- Delete `index.html` from the root
- Users visiting the root will get a 404
- Direct links to tools (like `/chroma-green-export-with-alpha/`) will still work
