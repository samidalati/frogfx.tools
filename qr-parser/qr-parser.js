(function () {
    'use strict';

    var MAX_DIMENSION = 2048;

    var dropZone = document.getElementById('dropZone');
    var fileInput = document.getElementById('fileInput');
    var previewWrap = document.getElementById('previewWrap');
    var qrInfoList = document.getElementById('qrInfoList');
    var statusEl = document.getElementById('status');
    var output = document.getElementById('output');
    var btnReset = document.getElementById('btnReset');
    var btnCopy = document.getElementById('btnCopy');
    var btnOpen = document.getElementById('btnOpen');

    var objectUrl = null;

    function revokePreviewUrl() {
        if (objectUrl) {
            URL.revokeObjectURL(objectUrl);
            objectUrl = null;
        }
    }

    function setStatus(message, kind) {
        statusEl.textContent = message || '';
        statusEl.className = 'status' + (kind ? ' ' + kind : '');
    }

    function syncResetButton() {
        var hasContent = previewWrap.children.length > 0 || output.value.length > 0;
        btnReset.disabled = !hasContent;
    }

    function clearDetails() {
        setDetailsRows([
            ['Tip', 'Load an image to see version, encoding, and dimensions.']
        ]);
    }

    function setDetailsRows(rows) {
        var frag = document.createDocumentFragment();
        for (var i = 0; i < rows.length; i++) {
            var dt = document.createElement('dt');
            dt.textContent = rows[i][0];
            var dd = document.createElement('dd');
            dd.textContent = rows[i][1];
            frag.appendChild(dt);
            frag.appendChild(dd);
        }
        qrInfoList.innerHTML = '';
        qrInfoList.appendChild(frag);
    }

    function moduleCountFromVersion(version) {
        if (!version || version < 1) {
            return null;
        }
        return 21 + 4 * (version - 1);
    }

    function scalePoint(p, natW, natH, decW, decH) {
        return { x: p.x * natW / decW, y: p.y * natH / decH };
    }

    function distPoint(p, q) {
        return Math.hypot(p.x - q.x, p.y - q.y);
    }

    function qrSymbolSidesPx(loc, natW, natH, decW, decH) {
        var tl = scalePoint(loc.topLeftCorner, natW, natH, decW, decH);
        var tr = scalePoint(loc.topRightCorner, natW, natH, decW, decH);
        var bl = scalePoint(loc.bottomLeftCorner, natW, natH, decW, decH);
        return {
            topEdgePx: distPoint(tl, tr),
            leftEdgePx: distPoint(tl, bl)
        };
    }

    function formatEncodingModes(chunks) {
        if (!chunks || !chunks.length) {
            return '—';
        }
        var labels = {
            numeric: 'Numeric',
            alphanumeric: 'Alphanumeric',
            byte: 'Byte',
            kanji: 'Kanji',
            eci: 'ECI'
        };
        var seen = [];
        for (var i = 0; i < chunks.length; i++) {
            var t = chunks[i].type;
            if (seen.indexOf(t) === -1) {
                seen.push(t);
            }
        }
        return seen.map(function (t) {
            return labels[t] || String(t);
        }).join(', ');
    }

    function eciAssignmentHint(chunks) {
        if (!chunks) {
            return '';
        }
        for (var i = 0; i < chunks.length; i++) {
            var ch = chunks[i];
            if (ch.type === 'eci' && ch.assignmentNumber !== undefined) {
                return ' — ECI assignment ' + ch.assignmentNumber;
            }
        }
        return '';
    }

    function clarityLabel(modulePx) {
        if (modulePx >= 4) {
            return 'Good';
        }
        if (modulePx >= 2) {
            return 'Moderate';
        }
        return 'Low — larger or sharper image helps';
    }

    function rowsForDecodedQr(code, natW, natH, decW, decH) {
        var modules = moduleCountFromVersion(code.version);
        var sides = qrSymbolSidesPx(code.location, natW, natH, decW, decH);
        var versionStr = String(code.version);
        var moduleLine = '—';
        if (modules) {
            versionStr += ' (' + modules + '×' + modules + ' modules)';
            var modulePx = (sides.topEdgePx / modules + sides.leftEdgePx / modules) / 2;
            moduleLine =
                (modulePx >= 1 ? modulePx.toFixed(1) : modulePx.toFixed(2)) +
                ' px — clarity: ' +
                clarityLabel(modulePx);
        }
        var payload =
            code.binaryData && code.binaryData.length
                ? code.binaryData.length + ' bytes'
                : '—';
        return [
            ['Image dimensions', natW + ' × ' + natH + ' px'],
            ['QR version', versionStr],
            ['Encoding modes', formatEncodingModes(code.chunks) + eciAssignmentHint(code.chunks)],
            ['Payload', payload],
            [
                'QR in image (approx.)',
                Math.round(sides.topEdgePx) + ' × ' + Math.round(sides.leftEdgePx) + ' px'
            ],
            ['Module size (approx.)', moduleLine],
            ['Error correction', 'ECC level (L/M/Q/H) is not provided by jsQR.']
        ];
    }

    function resetAll() {
        revokePreviewUrl();
        previewWrap.innerHTML = '';
        output.value = '';
        setStatus('', '');
        btnCopy.disabled = true;
        btnOpen.disabled = true;
        fileInput.value = '';
        clearDetails();
        syncResetButton();
    }

    function getOpenableUrl(text) {
        var trimmed = (text || '').trim();
        if (!trimmed) {
            return null;
        }
        try {
            var u = new URL(trimmed);
            if (u.protocol === 'http:' || u.protocol === 'https:') {
                return u.href;
            }
        } catch (ignore) {}
        return null;
    }

    function decodeWithCanvas(img) {
        var w = img.naturalWidth;
        var h = img.naturalHeight;
        if (!w || !h) {
            return { code: null, decW: 0, decH: 0 };
        }

        function tryDecode(cw, ch) {
            var canvas = document.createElement('canvas');
            canvas.width = cw;
            canvas.height = ch;
            var ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, cw, ch);
            var imageData = ctx.getImageData(0, 0, cw, ch);
            var code = jsQR(imageData.data, imageData.width, imageData.height, {
                inversionAttempts: 'attemptBoth'
            });
            return { code: code, decW: cw, decH: ch };
        }

        var scale = 1;
        if (w > MAX_DIMENSION || h > MAX_DIMENSION) {
            scale = Math.min(MAX_DIMENSION / w, MAX_DIMENSION / h);
        }
        var cw = Math.max(1, Math.round(w * scale));
        var ch = Math.max(1, Math.round(h * scale));
        var attempt = tryDecode(cw, ch);
        if (attempt.code) {
            return { code: attempt.code, decW: attempt.decW, decH: attempt.decH };
        }
        if (scale < 1) {
            attempt = tryDecode(w, h);
            if (attempt.code) {
                return { code: attempt.code, decW: attempt.decW, decH: attempt.decH };
            }
        }
        return { code: null, decW: attempt.decW, decH: attempt.decH };
    }

    function applyDecoded(pkg, natW, natH) {
        var code = pkg && pkg.code;
        if (code && code.data) {
            output.value = code.data;
            setStatus('QR code found.', 'success');
            btnCopy.disabled = false;
            btnOpen.disabled = getOpenableUrl(code.data) === null;
            setDetailsRows(rowsForDecodedQr(code, natW, natH, pkg.decW, pkg.decH));
        } else {
            output.value = '';
            setStatus('No QR code found in this image.', 'error');
            btnCopy.disabled = true;
            btnOpen.disabled = true;
            setDetailsRows([['Image dimensions', natW + ' × ' + natH + ' px']]);
        }
        syncResetButton();
    }

    function loadImageFromBlob(blob) {
        if (!blob || !blob.type || blob.type.indexOf('image/') !== 0) {
            setStatus('Please provide an image file.', 'error');
            clearDetails();
            syncResetButton();
            return;
        }
        revokePreviewUrl();
        objectUrl = URL.createObjectURL(blob);

        var img = new Image();
        img.onload = function () {
            var natW = img.naturalWidth;
            var natH = img.naturalHeight;
            previewWrap.innerHTML = '';
            previewWrap.appendChild(img);
            try {
                var pkg = decodeWithCanvas(img);
                applyDecoded(pkg, natW, natH);
            } catch (err) {
                setStatus('Could not read this image.', 'error');
                output.value = '';
                btnCopy.disabled = true;
                btnOpen.disabled = true;
                setDetailsRows([['Image dimensions', natW + ' × ' + natH + ' px']]);
                syncResetButton();
            }
        };
        img.onerror = function () {
            setStatus('Could not load this image.', 'error');
            previewWrap.innerHTML = '';
            output.value = '';
            btnCopy.disabled = true;
            btnOpen.disabled = true;
            revokePreviewUrl();
            clearDetails();
            syncResetButton();
        };
        img.alt = 'Uploaded image preview';
        img.src = objectUrl;
    }

    function onFileList(files) {
        if (!files || !files.length) {
            return;
        }
        loadImageFromBlob(files[0]);
    }

    btnReset.addEventListener('click', function () {
        resetAll();
    });

    dropZone.addEventListener('click', function () {
        fileInput.click();
    });

    dropZone.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            fileInput.click();
        }
    });

    fileInput.addEventListener('change', function () {
        onFileList(fileInput.files);
        fileInput.value = '';
    });

    ['dragenter', 'dragover'].forEach(function (ev) {
        dropZone.addEventListener(ev, function (e) {
            e.preventDefault();
            e.stopPropagation();
            dropZone.classList.add('dragover');
        });
    });

    ['dragleave', 'drop'].forEach(function (ev) {
        dropZone.addEventListener(ev, function (e) {
            e.preventDefault();
            e.stopPropagation();
            dropZone.classList.remove('dragover');
        });
    });

    dropZone.addEventListener('drop', function (e) {
        var dt = e.dataTransfer;
        if (dt && dt.files && dt.files.length) {
            onFileList(dt.files);
        }
    });

    window.addEventListener('paste', function (e) {
        var cb = e.clipboardData;
        if (!cb) {
            return;
        }
        var items = cb.items;
        if (items) {
            for (var i = 0; i < items.length; i++) {
                var item = items[i];
                if (item.kind === 'file' && item.type.indexOf('image/') === 0) {
                    var f = item.getAsFile();
                    if (f) {
                        e.preventDefault();
                        loadImageFromBlob(f);
                        return;
                    }
                }
            }
        }
        var files = cb.files;
        if (files && files.length) {
            e.preventDefault();
            onFileList(files);
        }
    });

    btnCopy.addEventListener('click', function () {
        var text = output.value;
        if (!text) {
            return;
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(function () {
                setStatus('Copied to clipboard.', 'success');
            }).catch(function () {
                fallbackCopy(text);
            });
        } else {
            fallbackCopy(text);
        }
    });

    function fallbackCopy(text) {
        output.readOnly = false;
        output.select();
        output.setSelectionRange(0, text.length);
        var ok = false;
        try {
            ok = document.execCommand('copy');
        } catch (ignore) {}
        output.readOnly = true;
        if (ok) {
            setStatus('Copied to clipboard.', 'success');
        } else {
            setStatus('Copy failed—select the text and copy manually.', 'error');
        }
    }

    btnOpen.addEventListener('click', function () {
        var url = getOpenableUrl(output.value);
        if (!url) {
            return;
        }
        window.open(url, '_blank', 'noopener,noreferrer');
    });

    clearDetails();
})();
