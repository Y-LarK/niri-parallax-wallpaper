import QtQuick

// 壁纸转场层
//
// 双 viewport 交替工作：换图时先把新图加载到后台 viewport，等它解码完成，
// 再用 ShaderEffect 按 progress 0→1 把前后两个 viewport 混合，动画结束后
// 交换前后台角色。整个过程不阻塞、不闪白。
//
// 相比 Clavis 原版（528 行）的裁剪：
//   - 去掉全景（panorama）、预览源（previewSource）、纯色源支持
//   - 去掉从未被使用的 currentViewportGeometry / currentViewportX / imagePixelWidth 等属性
//   - shader 路径从 Paths.assetsDir 改为 Qt.resolvedUrl，指向同级的 shaders/
Item {
    id: root

    property string sourcePath: ""
    property int imageFillMode: Image.PreserveAspectCrop
    property real shaderFillMode: 2
    // random 表示每次从 includedTransitions 里随机挑一种
    property string transitionType: "random"
    property var includedTransitions: ["fade", "wipe", "disc", "stripes", "iris bloom", "pixelate",
        "portal"]
    property int transitionDurationMs: 1000
    property string transitionEasingMode: "customBezier"
    property var transitionBezierCurve: [0.43, 1.19, 1.0, 0.4, 1.0, 1.0]
    property bool transitionsEnabled: true
    // 传给 viewport 以决定图片解码方式，见 WallpaperImageViewport 里的说明。
    // 由上层传屏幕尺寸对应的值，不要用本组件自身的 width/height（那是画布尺寸）。
    property bool panoramaEnabled: false

    property int textureWidth: Math.min(Math.max(1, Math.round(width)), 8192)
    property int textureHeight: Math.min(Math.max(1, Math.round(height)), 8192)

    // ---------------------------------------------------------------- 状态
    property int currentViewportIndex: 0
    readonly property Item currentViewport: currentViewportIndex === 0 ? viewportA : viewportB
    readonly property Item nextViewport: currentViewportIndex === 0 ? viewportB : viewportA
    readonly property string currentSource: currentViewport ? currentViewport.sourcePath : ""
    readonly property string nextSource: nextViewport ? nextViewport.sourcePath : ""

    property string activeTransition: "none"
    property real transitionProgress: 0
    property bool effectActive: false
    property string pendingSource: ""
    property bool nextIsImmediate: false

    // 各转场的随机化参数
    property vector4d fillColor: Qt.vector4d(0, 0, 0, 1)
    property real edgeSmoothness: 0.1
    property real wipeDirection: 0
    property real discCenterX: 0.5
    property real discCenterY: 0.5
    property real stripesCount: 16
    property real stripesAngle: 0

    property int activeTransitionDurationMs: 1000
    property int activeTransitionEasingType: Easing.BezierSpline
    property var activeTransitionBezierCurve: [0.43, 1.19, 1.0, 0.4, 1.0, 1.0]
    property string lastError: ""

    readonly property bool ready: root.sourcePath === "" || root.currentSource === root.sourcePath

    // 解码后的图片像素尺寸，供上层计算全景几何。
    // 优先取就绪的 nextViewport（换图瞬间就能拿到新图尺寸，避免几何跳变）。
    readonly property real imagePixelWidth: {
        if (root.nextViewport.ready && root.nextSource !== "")
            return root.nextViewport.imagePixelWidth;
        return root.currentViewport.imagePixelWidth;
    }
    readonly property real imagePixelHeight: {
        if (root.nextViewport.ready && root.nextSource !== "")
            return root.nextViewport.imagePixelHeight;
        return root.currentViewport.imagePixelHeight;
    }

    signal loadFailed(string source, string message)

    // ---------------------------------------------------------------- 逻辑
    function chooseTransition() {
        let transition = root.transitionType;
        if (transition !== "random")
            return transition;

        const included = root.includedTransitions;
        if (!included || included.length === 0)
            return "fade";
        return included[Math.floor(Math.random() * included.length)];
    }

    function easingType(mode) {
        switch (mode) {
        case "linear":
            return Easing.Linear;
        case "quad":
            return Easing.InOutQuad;
        case "cubic":
            return Easing.InOutCubic;
        case "quart":
            return Easing.InOutQuart;
        case "quint":
            return Easing.InOutQuint;
        case "sine":
            return Easing.InOutSine;
        case "expo":
            return Easing.InOutExpo;
        case "circ":
            return Easing.InOutCirc;
        case "customBezier":
        default:
            return Easing.BezierSpline;
        }
    }

    // 不做动画，直接把 viewport 落到目标图
    function setImmediate(path) {
        transitionAnimation.stop();
        const requested = path || "";
        if (requested !== "" && requested === root.nextSource && root.nextViewport.ready) {
            root.currentViewportIndex = root.currentViewportIndex === 0 ? 1 : 0;
            root.nextViewport.sourcePath = "";
        } else {
            root.currentViewport.sourcePath = requested;
            root.nextViewport.sourcePath = "";
        }
        root.pendingSource = "";
        root.activeTransition = "none";
        root.transitionProgress = 0;
        root.effectActive = false;
        root.nextIsImmediate = false;
    }

    // 每种转场的随机化：方向 / 中心点 / 条纹数，避免每次看起来一模一样
    function prepareTransition(type) {
        switch (type) {
        case "wipe":
            root.wipeDirection = Math.random() * 4;
            break;
        case "disc":
        case "pixelate":
        case "portal":
            root.discCenterX = Math.random();
            root.discCenterY = Math.random();
            break;
        case "stripes":
            root.stripesCount = Math.round(Math.random() * 20 + 4);
            root.stripesAngle = Math.random() * 360;
            break;
        }
    }

    function startTransition() {
        if (!root.transitionsEnabled) {
            root.setImmediate(root.nextSource);
            return;
        }
        root.activeTransitionDurationMs = root.transitionDurationMs;
        root.activeTransitionEasingType = root.easingType(root.transitionEasingMode);
        root.activeTransitionBezierCurve = root.transitionEasingMode === "customBezier"
                ? root.transitionBezierCurve : [0, 0, 1, 1, 1, 1];
        root.effectActive = true;
        // 延迟一帧再启动：让 ShaderEffectSource 先抓到两个 viewport 的纹理
        transitionDelayTimer.restart();
    }

    function acceptPreparedImage() {
        if (root.nextSource === "" || !root.nextViewport.ready)
            return;
        root.lastError = "";
        if (root.nextIsImmediate) {
            root.setImmediate(root.nextSource);
            return;
        }
        root.startTransition();
    }

    function requestWallpaper(path, immediate) {
        const requested = path || "";
        root.lastError = "";
        if (requested === "") {
            root.setImmediate("");
            return;
        }

        if (requested === root.currentSource && !root.nextSource)
            return;

        // 首次加载没有上一帧可保留，直接落位，省掉一次多余解码
        if (root.currentSource === "") {
            root.setImmediate(requested);
            return;
        }

        // 正在播动画时把请求排队，播完再处理
        if (transitionAnimation.running || root.effectActive) {
            root.pendingSource = requested;
            return;
        }

        root.nextIsImmediate = immediate || !root.transitionsEnabled || root.transitionType === "none"
                || root.transitionDurationMs <= 0;
        root.activeTransition = root.nextIsImmediate ? "none" : root.chooseTransition();
        if (root.activeTransition === "none")
            root.nextIsImmediate = true;
        else
            root.prepareTransition(root.activeTransition);
        root.transitionProgress = 0;
        root.nextViewport.sourcePath = requested;
        if (root.nextViewport.ready)
            root.acceptPreparedImage();
    }

    function handleViewportReady(viewport) {
        if (viewport !== root.nextViewport || root.nextSource === "" || transitionAnimation.running
                || root.effectActive)
            return;
        root.acceptPreparedImage();
    }

    function handleViewportFailure(viewport, source, message) {
        root.lastError = message;
        if (viewport === root.nextViewport) {
            root.nextViewport.sourcePath = "";
            root.nextIsImmediate = false;
        }
        root.loadFailed(source, message);
    }

    onSourcePathChanged: requestWallpaper(sourcePath, false)
    Component.onCompleted: requestWallpaper(sourcePath, true)

    // ---------------------------------------------------------------- 渲染
    WallpaperImageViewport {
        id: viewportA

        anchors.fill: parent
        sourcePath: ""
        imageFillMode: root.imageFillMode
        panoramaEnabled: root.panoramaEnabled
        textureWidth: root.textureWidth
        textureHeight: root.textureHeight
        visible: root.currentViewport === viewportA || (root.effectActive && root.nextViewport === viewportA)

        onReadyChanged: root.handleViewportReady(viewportA)
        onLoadFailed: (source, message) => root.handleViewportFailure(viewportA, source, message)
    }

    WallpaperImageViewport {
        id: viewportB

        anchors.fill: parent
        sourcePath: ""
        imageFillMode: root.imageFillMode
        panoramaEnabled: root.panoramaEnabled
        textureWidth: root.textureWidth
        textureHeight: root.textureHeight
        visible: root.currentViewport === viewportB || (root.effectActive && root.nextViewport === viewportB)

        onReadyChanged: root.handleViewportReady(viewportB)
        onLoadFailed: (source, message) => root.handleViewportFailure(viewportB, source, message)
    }

    ShaderEffectSource {
        id: srcCurrent

        sourceItem: root.effectActive ? root.currentViewport : null
        hideSource: root.effectActive
        live: root.effectActive
        mipmap: false
        recursive: false
        textureSize: Qt.size(root.textureWidth, root.textureHeight)
    }

    ShaderEffectSource {
        id: srcNext

        sourceItem: root.effectActive ? root.nextViewport : null
        hideSource: root.effectActive
        live: root.effectActive
        mipmap: false
        recursive: false
        textureSize: Qt.size(root.textureWidth, root.textureHeight)
    }

    Loader {
        id: effectLoader

        anchors.fill: parent
        active: root.effectActive
        sourceComponent: transitionComponent(root.activeTransition)

        function transitionComponent(type) {
            switch (type) {
            case "wipe":
                return wipeComp;
            case "disc":
                return discComp;
            case "stripes":
                return stripesComp;
            case "iris bloom":
                return irisComp;
            case "pixelate":
                return pixelateComp;
            case "portal":
                return portalComp;
            case "fade":
            default:
                return fadeComp;
            }
        }
    }

    // ------------------------------------------------------- 7 种转场效果
    Component {
        id: fadeComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            fragmentShader: Qt.resolvedUrl("shaders/wp_fade.frag.qsb")
        }
    }

    Component {
        id: wipeComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real smoothness: root.edgeSmoothness
            property real direction: root.wipeDirection
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            fragmentShader: Qt.resolvedUrl("shaders/wp_wipe.frag.qsb")
        }
    }

    Component {
        id: discComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real smoothness: root.edgeSmoothness
            property real aspectRatio: root.width / Math.max(1, root.height)
            property real centerX: root.discCenterX
            property real centerY: root.discCenterY
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            fragmentShader: Qt.resolvedUrl("shaders/wp_disc.frag.qsb")
        }
    }

    Component {
        id: stripesComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real smoothness: root.edgeSmoothness
            property real aspectRatio: root.width / Math.max(1, root.height)
            property real stripeCount: root.stripesCount
            property real angle: root.stripesAngle
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            fragmentShader: Qt.resolvedUrl("shaders/wp_stripes.frag.qsb")
        }
    }

    Component {
        id: irisComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real smoothness: root.edgeSmoothness
            property real centerX: 0.5
            property real centerY: 0.5
            property real aspectRatio: root.width / Math.max(1, root.height)
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            fragmentShader: Qt.resolvedUrl("shaders/wp_iris_bloom.frag.qsb")
        }
    }

    Component {
        id: pixelateComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real smoothness: root.edgeSmoothness
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            property real centerX: root.discCenterX
            property real centerY: root.discCenterY
            property real aspectRatio: root.width / Math.max(1, root.height)
            fragmentShader: Qt.resolvedUrl("shaders/wp_pixelate.frag.qsb")
        }
    }

    Component {
        id: portalComp

        ShaderEffect {
            anchors.fill: parent
            property variant source1: srcCurrent
            property variant source2: srcNext
            property real progress: root.transitionProgress
            property real smoothness: root.edgeSmoothness
            property real aspectRatio: root.width / Math.max(1, root.height)
            property real centerX: root.discCenterX
            property real centerY: root.discCenterY
            property real fillMode: root.shaderFillMode
            property vector4d fillColor: root.fillColor
            property real imageWidth1: root.width
            property real imageHeight1: root.height
            property real imageWidth2: root.width
            property real imageHeight2: root.height
            property real screenWidth: root.width
            property real screenHeight: root.height
            fragmentShader: Qt.resolvedUrl("shaders/wp_portal.frag.qsb")
        }
    }

    // ---------------------------------------------------------- 动画驱动
    Timer {
        id: transitionDelayTimer

        interval: 16
        repeat: false
        onTriggered: transitionAnimation.restart()
    }

    NumberAnimation {
        id: transitionAnimation

        target: root
        property: "transitionProgress"
        from: 0
        to: 1
        duration: root.activeTransitionDurationMs
        easing.type: root.activeTransitionEasingType
        easing.bezierCurve: root.activeTransitionBezierCurve

        onFinished: {
            // 交换前后台角色，释放旧图
            root.currentViewportIndex = root.currentViewportIndex === 0 ? 1 : 0;
            root.nextViewport.sourcePath = "";
            root.transitionProgress = 0;
            root.effectActive = false;

            // 动画期间被排队的请求现在处理
            if (root.pendingSource !== "") {
                const pending = root.pendingSource;
                root.pendingSource = "";
                Qt.callLater(() => root.requestWallpaper(pending, false));
            }
        }
    }
}
