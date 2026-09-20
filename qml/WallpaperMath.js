function clamp01(value) {
    return Math.max(0, Math.min(1, Number(value) || 0));
}

function supportsParallaxCanvas(preserveAspectCrop, source,
                                 sourceIsColor) {
    return !!preserveAspectCrop
        && String(source || "") !== ""
        && !sourceIsColor;
}

// 图片宽高比与屏幕相差在 tolerance 以内 → 认为它是「为这块屏准备的」，
// 直接铺满即可，不必再靠平移去找画面。
// 图片尚未解码时 imagePixelWidth/Height 是 1（见 WallpaperImageViewport 的
// Math.max(1, ...) 兜底），这里要求两侧都 > 1 才算「已就绪」，
// 免得拿占位值把任意图片都判成 1:1 而误判。
function aspectMatchesScreen(screenWidth, screenHeight,
                             imageWidth, imageHeight, tolerance) {
    const safeScreenWidth = Math.max(1, Number(screenWidth) || 1);
    const safeScreenHeight = Math.max(1, Number(screenHeight) || 1);
    const safeImageWidth = Number(imageWidth) || 0;
    const safeImageHeight = Number(imageHeight) || 0;
    if (safeImageWidth <= 1 || safeImageHeight <= 1)
        return false;

    const screenAspect = safeScreenWidth / safeScreenHeight;
    const imageAspect = safeImageWidth / safeImageHeight;
    const safeTolerance = Math.max(0, Number(tolerance) || 0);
    return Math.abs(imageAspect - screenAspect) / screenAspect <= safeTolerance;
}

function parallaxCanvasGeometry(screenWidth, screenHeight,
                                preferredScale, active, verticalActive) {
    const safeScreenWidth = Math.max(1, Number(screenWidth) || 1);
    const safeScreenHeight = Math.max(1, Number(screenHeight) || 1);
    const safePreferredScale = active
        ? Math.max(1, Number(preferredScale) || 1) : 1;
    // 纵向视差关闭时不放大纵向：画布高度等于屏幕高度，图片上下完整显示。
    // 若仍然放大，就只是白裁掉边缘却换不来任何位移。省略该参数时维持旧行为。
    const vertical = verticalActive === undefined ? true : !!verticalActive;
    const verticalScale = (active && vertical) ? safePreferredScale : 1;
    const scaledWidth = safeScreenWidth * safePreferredScale;
    const scaledHeight = safeScreenHeight * verticalScale;

    return {
        scale: safePreferredScale,
        scaledWidth: scaledWidth,
        scaledHeight: scaledHeight,
        overflowX: Math.max(0, scaledWidth - safeScreenWidth),
        overflowY: Math.max(0, scaledHeight - safeScreenHeight)
    };
}

function panoramaGeometry(screenWidth, screenHeight,
                          imageWidth, imageHeight, enabled) {
    const safeScreenWidth = Math.max(1, Number(screenWidth) || 1);
    const safeScreenHeight = Math.max(1, Number(screenHeight) || 1);
    const safeImageWidth = Math.max(0, Number(imageWidth) || 0);
    const safeImageHeight = Math.max(0, Number(imageHeight) || 0);
    const screenAspect = safeScreenWidth / safeScreenHeight;
    const imageAspect = safeImageHeight > 0
        ? safeImageWidth / safeImageHeight : 0;
    const active = !!enabled
        && safeImageWidth > 0
        && safeImageHeight > 0
        && imageAspect > screenAspect;

    if (!active) {
        return {
            active: false,
            scale: 1,
            canvasWidth: safeScreenWidth,
            canvasHeight: safeScreenHeight,
            overflowX: 0,
            overflowY: 0
        };
    }

    const scale = safeScreenHeight / safeImageHeight;
    const canvasWidth = safeImageWidth * scale;
    return {
        active: true,
        scale: scale,
        canvasWidth: canvasWidth,
        canvasHeight: safeScreenHeight,
        overflowX: Math.max(0, canvasWidth - safeScreenWidth),
        overflowY: 0
    };
}

function tiledColumnProgress(columnCount, fullSpan) {
    const columns = Math.max(0, Math.round(Number(columnCount) || 0));
    const span = Math.max(2, Math.round(Number(fullSpan) || 6));
    if (columns === 0)
        return 0.5;
    if (columns === 1)
        return 0;
    return clamp01((columns - 1) / (span - 1));
}

function isHorizontalTiledWindow(window) {
    return !!window
        && !window.isFloating
        && Number(window.layoutColumn) > 0;
}

function horizontalColumns(windows) {
    const seen = {};
    const columns = [];
    if (!windows)
        return columns;

    for (let index = 0; index < windows.length; index += 1) {
        const window = windows[index];
        if (!isHorizontalTiledWindow(window))
            continue;
        const column = Math.round(Number(window.layoutColumn));
        const key = String(column);
        if (seen[key])
            continue;
        seen[key] = true;
        columns.push(column);
    }
    columns.sort((left, right) => left - right);
    return columns;
}

function rememberFocusedHorizontalColumn(memory, focusedWindow) {
    const current = memory || {};
    if (!isHorizontalTiledWindow(focusedWindow))
        return current;

    const workspaceKey = String(focusedWindow.workspaceId || "");
    if (workspaceKey === "")
        return current;
    const column = Math.round(Number(focusedWindow.layoutColumn));
    if (Number(current[workspaceKey]) === column)
        return current;

    const next = {};
    for (let key in current)
        next[key] = current[key];
    next[workspaceKey] = column;
    return next;
}

function nearestHorizontalColumn(columns, preferredColumn) {
    if (!columns || columns.length === 0)
        return 0;

    const preferred = Number(preferredColumn);
    if (!isFinite(preferred) || preferred <= 0)
        return columns[0];

    let nearest = columns[0];
    let distance = Math.abs(nearest - preferred);
    for (let index = 1; index < columns.length; index += 1) {
        const candidateDistance =
            Math.abs(columns[index] - preferred);
        if (candidateDistance < distance) {
            nearest = columns[index];
            distance = candidateDistance;
        }
    }
    return nearest;
}

// 位移跨度自适应实际列数：第一列对齐图片最左端，最后一列对齐最右端，
// 于是无论当前工作区开了几列，切到最后一列都能把整张图走完。
// 原先此处拿固定的 fullSpan 当分母，列数少于它时永远走不满 —— 例如配 6 列
// 而实际只开 3 列，最多只能移到 40%，图片右半边永远看不到。
//
// minSpan 是跨度下限：跨度取 max(实际列数, minSpan)。列太少时步长会很大
// （2 列即为「最左一步跨到最右」），下限把它压小，代价是列数不足时走不满全程。
// 传 2（或不传）等于不设下限。
function focusedColumnProgress(columns, focusedColumn, minSpan) {
    // 没有窗口、或只有一列时，焦点必定落在最左那列 —— 对齐图片最左端。
    // 不取 0.5 居中：单列是最普通的状态，此时显示图片中段会让人以为壁纸
    // 被裁歪了；对齐左端才符合「壁纸从开头看起」的直觉。
    if (!columns || columns.length <= 1)
        return 0;

    const resolved = nearestHorizontalColumn(
        columns, focusedColumn);
    const rankIndex = columns.indexOf(resolved);
    const floor = Math.max(2, Math.round(Number(minSpan) || 2));
    const span = Math.max(columns.length, floor);
    return clamp01(Math.max(0, rankIndex) / (span - 1));
}

function workspaceProgress(workspaces) {
    if (!workspaces || workspaces.length <= 1)
        return 0.5;
    let activePosition = 0;
    for (let index = 0; index < workspaces.length; index += 1) {
        if (workspaces[index].isActive) {
            activePosition = index;
            break;
        }
    }
    return clamp01(activePosition / (workspaces.length - 1));
}

function horizontalProgress(baseProgress, leftOpen, rightOpen,
                            sidebarStep) {
    let result = Number(baseProgress);
    if (!isFinite(result))
        result = 0.5;
    const step = Math.max(0, Number(sidebarStep) || 0);
    if (leftOpen)
        result -= step;
    if (rightOpen)
        result += step;
    return clamp01(result);
}

function wallpaperPosition(overflow, progress) {
    const safeOverflow = Math.max(0, Number(overflow) || 0);
    return -safeOverflow * clamp01(progress);
}

function wallpaperToScreen(offsetX, offsetY, wallpaperX, wallpaperY) {
    return {
        x: Number(offsetX) + Number(wallpaperX),
        y: Number(offsetY) + Number(wallpaperY)
    };
}

function screenToWallpaper(offsetX, offsetY, screenX, screenY) {
    return {
        x: Number(screenX) - Number(offsetX),
        y: Number(screenY) - Number(offsetY)
    };
}

function wallpaperToNormalized(canvasWidth, canvasHeight, wallpaperX,
                               wallpaperY) {
    return {
        xNorm: clamp01(Number(wallpaperX)
            / Math.max(1, Number(canvasWidth) || 1)),
        yNorm: clamp01(Number(wallpaperY)
            / Math.max(1, Number(canvasHeight) || 1))
    };
}

function normalizedToWallpaper(canvasWidth, canvasHeight, xNorm, yNorm) {
    return {
        x: clamp01(xNorm) * Math.max(1, Number(canvasWidth) || 1),
        y: clamp01(yNorm) * Math.max(1, Number(canvasHeight) || 1)
    };
}
