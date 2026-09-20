import QtQuick

// 壁纸渲染单元：把一张图按指定填充模式铺满自身，并暴露解码后的像素尺寸。
//
// 转场层用两个实例交替承载「前一张」和「后一张」，ShaderEffect 再把两者混合。
// 相比 Clavis 原版，此处去掉了调色板源（ZenPaletteRenderer）与纯色源支持，
// 只保留图片路径这一种输入。
Item {
    id: root

    property string sourcePath: ""
    property int imageFillMode: Image.PreserveAspectCrop
    // 全景模式。取「配置选没选 panorama」这样的纯配置值，**不要**传依赖
    // imagePixelWidth 的派生量 —— 那会绕回下面的 sourceSize 形成闭环。
    property bool panoramaEnabled: false
    // 解码尺寸上限，用于限制显存占用
    property int textureWidth: Math.min(Math.max(1, Math.round(width)), 8192)
    property int textureHeight: Math.min(Math.max(1, Math.round(height)), 8192)

    // 记录"上一次成功解码"的路径与尺寸。
    // 之所以记路径而不只看 status：Image 换源瞬间 status 会短暂回到 Loading，
    // 只看 status 会让上层误以为已经 ready。
    property string lastReadySourcePath: ""
    property real lastReadyImageWidth: 0
    property real lastReadyImageHeight: 0

    // 注意：这里刻意不用属性绑定。
    // ready 被上层 WallpaperTransitionSurface 的 onReadyChanged 消费，而上层在该回调里
    // 会改写 nextViewport.sourcePath。若 ready 是绑定，就形成
    // 「ready 变 → 改 sourcePath → ready 变」的循环，QML 会持续报 Binding loop。
    // 改为显式更新：只在这三个明确时机重算。
    property bool ready: false

    function updateReady() {
        const next = root.sourcePath === "" || (image.status === Image.Ready
                                                && root.lastReadySourcePath === root.sourcePath);
        if (root.ready !== next)
            root.ready = next;
    }

    readonly property int imageStatus: image.status
    readonly property real imagePixelWidth: Math.max(1, root.lastReadyImageWidth)
    readonly property real imagePixelHeight: Math.max(1, root.lastReadyImageHeight)

    signal loadFailed(string source, string message)

    // 换源后 ready 需要立即回到 false（新图尚未解码）
    onSourcePathChanged: root.updateReady()
    Component.onCompleted: root.updateReady()

    clip: true

    function imageUrl(path) {
        return path && path !== "" ? "file://" + path : "";
    }

    function rememberReadyImageSize() {
        if (image.status !== Image.Ready)
            return;
        // sourceSize 可能已缩放，优先用原始尺寸，退化时用 implicitWidth
        const sourceWidth = Number(image.sourceSize.width);
        const sourceHeight = Number(image.sourceSize.height);
        const imageWidth = sourceWidth > 0 ? sourceWidth : Number(image.implicitWidth);
        const imageHeight = sourceHeight > 0 ? sourceHeight : Number(image.implicitHeight);
        if (isFinite(imageWidth) && imageWidth > 0 && isFinite(imageHeight) && imageHeight > 0) {
            root.lastReadySourcePath = root.sourcePath;
            root.lastReadyImageWidth = imageWidth;
            root.lastReadyImageHeight = imageHeight;
        }
    }

    Image {
        id: image

        anchors.fill: parent
        source: root.imageUrl(root.sourcePath)
        fillMode: root.imageFillMode
        asynchronous: true
        cache: true
        retainWhileLoading: true
        smooth: true
        // 全景时宽度传 0：0 意为「不限制宽度」，图片按原始比例解码，
        // rememberReadyImageSize() 里 sourceWidth > 0 判断落空，于是回退到
        // implicitWidth/Height，拿到的是图片真实比例。
        // 若这里照样传具体的 textureWidth，读回来的就是画布尺寸本身，上层会把它
        // 当成图片比例去反推画布宽度 —— 闭环，比例全错（图片被裁、位移只剩零头）。
        // 取自 Clavis 原版 Modules/Wallpaper/WallpaperImageViewport.qml 的做法。
        sourceSize: root.panoramaEnabled ? Qt.size(0, root.textureHeight)
                                         : Qt.size(root.textureWidth, root.textureHeight)

        onStatusChanged: {
            if (status === Image.Ready) {
                root.rememberReadyImageSize();
            } else if (status === Image.Error && root.sourcePath !== "") {
                root.loadFailed(root.sourcePath, "Failed to decode image");
            }
            // 状态变化后统一重算 ready（rememberReadyImageSize 可能刚更新了尺寸）
            root.updateReady();
        }
    }
}
