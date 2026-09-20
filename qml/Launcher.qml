import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Clavis.Keyboard
import "ParallaxConfig.js" as Config
import "SearchEngines.js" as SearchEngines

// 启动器 —— 搜索并启动桌面应用
//
// 两种视图样式：
//   grid —— 图标墙（默认，参数参考 Clavis 的 SpotlightAppGrid）
//   list —— 紧凑列表
// 运行时按 Ctrl+G 切换；默认样式由 ParallaxConfig.launcherViewStyle 决定。
//
// 触发：IPC `launcher toggle`
//   QS_CONFIG_PATH=<此目录>/shell.qml qs ipc call launcher toggle
PanelWindow {
    id: root

    property bool opened: false
    property string query: ""
    property int selectedIndex: 0
    property string viewStyle: Config.launcherViewStyle

    // ------------------------------------------------------ 壁纸选择
    // 目录与 ~/.local/bin/set-wallpaper 的 WALLPAPER_DIR 是同一处约定
    readonly property string wallpaperDir: (Quickshell.env("HOME") || "") + "/Pictures/wallpapers"
    property var wallpaperPaths: []
    property var wallpaperScanBuffer: []

    // 每次打开启动器时重扫，这样新放进目录的图立刻可见（find 一个目录很快）
    function scanWallpapers() {
        if (wallpaperScanner.running)
            return;
        root.wallpaperScanBuffer = [];
        wallpaperScanner.running = true;
    }

    // ------------------------------------------------------ 主题配色
    // 由 matugen 随壁纸生成（见 ~/.config/matugen/templates/launcher-colors.json）。
    // 读不到时所有取色函数都会回落到硬编码兜底值，因此文件缺失也能正常显示。
    property var themeColors: ({})
    readonly property string colorsPath: (Quickshell.env("HOME") || "") + "/.cache/niri-quickshell/colors.json"

    FileView {
        id: colorsFile

        path: root.colorsPath
        watchChanges: true
        // 换壁纸 → matugen 重写 json → 这里自动重载，界面当场变色
        onFileChanged: reload()
        onLoaded: root.parseColors()
        onLoadFailed: root.themeColors = ({})
        Component.onCompleted: reload()
    }

    function parseColors() {
        try {
            const text = colorsFile.text();
            root.themeColors = text ? JSON.parse(text) : ({});
        } catch (e) {
            root.themeColors = ({});
        }
    }

    // 取色：缺失或格式不对时用兜底值
    function c(name, fallback) {
        const v = root.themeColors[name];
        return (v && String(v).length > 0) ? String(v) : fallback;
    }

    // 取色并附加透明度
    function ca(name, alpha, fallback) {
        const hex = String(root.themeColors[name] || "");
        if (/^#[0-9a-fA-F]{6}$/.test(hex)) {
            return Qt.rgba(parseInt(hex.substr(1, 2), 16) / 255, parseInt(hex.substr(3, 2), 16) / 255,
                           parseInt(hex.substr(5, 2), 16) / 255, alpha);
        }
        return fallback;
    }

    // 明暗系数：>1 提亮、<1 压暗、=1 原色。
    // 之所以包一层：Qt.lighter 的系数只能 >1，想压暗得换用 Qt.darker(1/factor)。
    // 分成两个分支写，配置里的系数才能保持「越大越亮」这一个直观语义。
    //
    // saturationFactor（可选）：饱和度缩放。1 = 不变、<1 更灰、>1 更艳。
    // 提亮本身就会冲淡色相，这一项是给「还是嫌蓝太正」时单独补的微调。
    function tone(color, factor, saturationFactor) {
        var c = color;
        if (factor > 1)
            c = Qt.lighter(c, factor);
        else if (factor < 1)
            c = Qt.darker(c, 1 / factor);
        if (saturationFactor !== undefined && saturationFactor !== 1)
            c = Qt.hsla(c.hslHue, Math.max(0, Math.min(1, c.hslSaturation * saturationFactor)),
                        c.hslLightness, c.a);
        return c;
    }

    // Ctrl 键是否按住 —— 由 Clavis.Keyboard 的 ShortcutRecorder 查询。
    // 用途：按住时在每个结果项上显示它的启动命令（纯信息展示，不改行为）。
    property bool controlHeld: false

    ShortcutRecorder {
        id: modifierSnapshot

        target: searchField
        // 只做修饰键快照，不订阅设备也不拦截事件
        enabled: false
    }

    function syncControlHeld() {
        if (!root.opened) {
            root.controlHeld = false;
            return;
        }
        root.controlHeld = (modifierSnapshot.currentModifiers() & Qt.ControlModifier) !== 0;
    }

    // ------------------------------------------------------------ 窗口
    visible: opened
    color: "transparent"

    WlrLayershell.namespace: "niri-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // 关键：不设 Exclusive 就收不到键盘输入
    WlrLayershell.keyboardFocus: opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.exclusionMode: ExclusionMode.Ignore

    // 屏幕尺寸从 screen 属性取 —— 不能再用 root.width/height，
    // 因为下面会把窗口尺寸绑定到面板尺寸，用 root.width 会形成循环依赖。
    readonly property real screenW: root.screen ? root.screen.width : 1920
    readonly property real screenH: root.screen ? root.screen.height : 1200

    // 面板尺寸随视图样式变化
    readonly property real panelWidth: root.viewStyle === "grid" ? Math.min(Config.launcherGridWidth,
                                                                             root.screenW - 80) : Math.min(
                                                                                                     Config.launcherListWidth,
                                                                                                     root.screenW - 80)
    readonly property real panelHeight: Math.min(Config.launcherMaxHeight, root.screenH - 220)

    // 窗口只覆盖面板本身的大小与位置。
    // 这样 niri 的 background-effect 模糊就只作用于面板区域，
    // 而不会像全屏 surface 那样把整张壁纸都糊掉。
    implicitWidth: root.panelWidth
    implicitHeight: root.panelHeight

    // PanelWindow 的 anchors 只支持 top/bottom/left/right 四个 bool，
    // 没有 horizontalCenter，所以水平居中用 margins.left 算。
    anchors.top: true
    anchors.left: true
    margins.top: Math.round((root.screenH - root.panelHeight) * Config.launcherVerticalRatio)
    margins.left: Math.round((root.screenW - root.panelWidth) / 2)

    // 切换样式时回到第一项，避免索引越界或落点突兀
    onViewStyleChanged: root.selectedIndex = 0

    // -------------------------------------------------------- 应用列表
    readonly property var allApps: {
        const out = [];
        const src = DesktopEntries.applications.values || [];
        for (const app of src) {
            if (!app || app.noDisplay === true || app.hidden === true)
                continue;
            const id = String(app.id || "");
            const cmd = app.command || [];
            if (!id || !cmd || cmd.length === 0)
                continue;
            const displayName = String(app.name || id);

            // 辅助搜索文本：desktop id + 通用名 + 注释 + 关键词 + 可执行文件名。
            // 刻意不含显示名 —— 显示名走单独的模糊匹配路径（见 results 里的打分），
            // 两条路径匹配方式不同，混在一起会互相干扰。
            // id 是关键：微信的 Name[zh_CN] 是「微信」，但 id 是 wechat，
            // 只比对本地化名就搜不到 wechat —— 108 个可见应用里有 60 个是这种
            // 中英文名不一致的情况（google-chrome 和 firefox 的 Name[zh_CN] 甚至
            // 被上游打包成「新建窗口」，只能靠 id 搜到）。
            const parts = [id];
            if (app.genericName)
                parts.push(String(app.genericName));
            if (app.comment)
                parts.push(String(app.comment));
            const kws = app.keywords || [];
            for (let i = 0; i < kws.length; i += 1)
                parts.push(String(kws[i]));
            // /usr/bin/wechat → wechat；只取末段，
            // 否则 /usr/bin 这类通用路径会把「bin」变成命中所有应用的查询词
            if (cmd.length > 0)
                parts.push(String(cmd[0]).split("/").pop());

            out.push({
                "kind": "app",
                "id": id,
                "name": displayName,
                // 预存小写名：模糊匹配时对 323 个应用逐个 toLowerCase() 太浪费
                "nameLower": displayName.toLowerCase(),
                // 同上，一并预存小写：搜索时每次按键都要对全部应用算一遍
                "searchText": parts.filter(s => s).join(" ").toLowerCase(),
                "icon": String(app.icon || ""),
                // 预解析图标路径：Quickshell.iconPath() 会查图标主题的文件系统，
                // 放在 delegate 里每次重绘都调用是主要卡顿来源
                "iconUrl": root.iconUrl(app.icon),
                "command": cmd,
                "workingDirectory": String(app.workingDirectory || "")
            });
        }
        out.sort((a, b) => String(a.name).localeCompare(String(b.name)));
        return out;
    }

    // 简单模糊匹配：查询字符需按顺序出现，连续命中给更高分
    function fuzzyScore(query, target) {
        let qi = 0;
        let score = 0;
        let lastHit = -2;
        for (let ti = 0; ti < target.length && qi < query.length; ti++) {
            if (target[ti] === query[qi]) {
                score += (lastHit === ti - 1) ? 4 : 1;
                if (ti === 0)
                    score += 3; // 首字母命中加权
                lastHit = ti;
                qi++;
            }
        }
        return qi === query.length ? score : -1;
    }

    // ------------------------------------------------------------ 壁纸模式
    // 输入约定的关键词（见 ParallaxConfig.launcherWallpaperKeywords，需完全匹配）
    // 时，整个结果列表换成 ~/Pictures/wallpapers 下的壁纸缩略图。
    readonly property bool wallpaperMode: {
        const q = String(root.query).trim().toLowerCase();
        if (q === "")
            return false;
        const keys = Config.launcherWallpaperKeywords;
        for (let i = 0; i < keys.length; i += 1) {
            if (String(keys[i]).toLowerCase() === q)
                return true;
        }
        return false;
    }

    // 壁纸只有缩略图、没有文字，列表视图的一行装不下，故强制走网格。
    // 用派生属性而非改写 viewStyle，这样退出壁纸模式后用户原来的选择还在。
    readonly property string effectiveViewStyle: root.wallpaperMode ? "grid" : root.viewStyle

    // 当前选中项（可能是应用，也可能是末尾的"打开网址/搜索"条目）
    readonly property var selectedItem: (root.selectedIndex >= 0
                                         && root.selectedIndex < root.results.length)
                                        ? root.results[root.selectedIndex] : null

    readonly property var results: {
        const raw = String(query).trim();

        // ---- 壁纸模式：整个列表换成壁纸缩略图 ----
        if (root.wallpaperMode) {
            return root.wallpaperPaths.map(path => ({
                "kind": "wallpaper",
                "path": path,
                "url": "file://" + path
            }));
        }

        // ---- 应用匹配 ----
        const q = raw.toLowerCase();
        let apps = [];
        if (q === "") {
            apps = allApps.slice(0, 200);
        } else {
            const scored = [];
            for (const app of allApps) {
                // 两条匹配路径，方式不同，不能混用：
                // 1) 显示名 —— 子序列模糊匹配（"wx" 也能命中「微信」），
                //    再加固定加成，保证显示名命中永远排在辅助字段命中之前。
                // 2) 辅助字段（id/关键词/注释等）—— 只做「子串精确匹配」。
                //    这里绝对不能用模糊匹配：keywords 是多语言词条大杂烩
                //    （KDE 应用动辄几百字符，塞了几十种语言），子序列匹配会
                //    在无关应用里把任意查询词凑出来 —— 实测搜 firefox 时
                //    捞出 18 个假阳性（KWrite、GParted、表情符号选择工具…）。
                const sName = root.fuzzyScore(q, app.nameLower);
                let s = -1;
                if (sName > 0)
                    s = sName + 12;          // 名字命中：≥13
                else if (app.searchText.indexOf(q) !== -1)
                    s = 8;                   // 辅助字段命中：固定 8，排在所有名字命中之后
                if (s > 0)
                    scored.push({
                        "app": app,
                        "score": s
                    });
            }
            scored.sort((a, b) => b.score - a.score);
            apps = scored.slice(0, 200).map(x => x.app);
        }

        if (q === "")
            return apps;

        // ---- 末尾追加"打开网址 / 网页搜索" ----
        const extras = [];
        if (Config.launcherEnableUrlOpen && SearchEngines.looksLikeUrl(raw)) {
            extras.push({
                "kind": "url",
                "name": raw,
                "detail": "在浏览器中打开",
                "target": SearchEngines.normalizeUrl(raw),
                "icon": ""
            });
        }
        extras.push({
            "kind": "search",
            "name": raw,
            "detail": "用 " + SearchEngines.engineById(Config.launcherSearchEngine).label + " 搜索",
            "target": SearchEngines.searchUrl(Config.launcherSearchEngine, raw),
            "icon": ""
        });

        return apps.concat(extras);
    }

    // ------------------------------------------------------------ 动作
    function open() {
        // 必须显式清空输入框本身。
        // query 是从 TextInput.text 单向同步过来的（在 onTextChanged 里），
        // 只把 query 置空不会影响输入框里残留的上次内容。
        searchField.text = "";
        root.query = "";
        root.selectedIndex = 0;
        root.viewStyle = Config.launcherViewStyle;
        root.opened = true;
        // 重扫壁纸目录，新放进来的图立刻可见
        root.scanWallpapers();
        searchField.forceActiveFocus();
    }

    function close() {
        root.opened = false;
    }

    function toggle() {
        root.opened ? root.close() : root.open();
    }

    function toggleViewStyle() {
        root.viewStyle = (root.viewStyle === "grid") ? "list" : "grid";
    }

    // 网格列数，用于上下移动时跨越整行
    readonly property int gridColumns: Math.max(1, Math.floor(appGrid.width / appGrid.cellWidth))

    function moveSelection(dir) {
        const n = root.results.length;
        if (n === 0)
            return;

        let idx = root.selectedIndex;
        if (root.viewStyle === "grid") {
            if (dir === "left")
                idx -= 1;
            else if (dir === "right")
                idx += 1;
            else if (dir === "up")
                idx -= root.gridColumns;
            else if (dir === "down")
                idx += root.gridColumns;
        } else {
            if (dir === "up")
                idx -= 1;
            else if (dir === "down")
                idx += 1;
        }

        root.selectedIndex = Math.max(0, Math.min(n - 1, idx));

        if (root.viewStyle === "grid")
            appGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain);
        else
            resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }

    function launchCurrent() {
        const list = root.results;
        if (root.selectedIndex < 0 || root.selectedIndex >= list.length)
            return;
        root.launch(list[root.selectedIndex]);
    }

    function launch(item) {
        if (!item)
            return;

        // 壁纸条目：交给 set-wallpaper 处理（切图 + 同步 matugen 配色）。
        // 走脚本而不是内联 IPC，是为了复用同一份逻辑（含就绪等待与配色生成）。
        if (item.kind === "wallpaper") {
            if (item.path)
                Quickshell.execDetached([(Quickshell.env("HOME") || "") + "/.local/bin/set-wallpaper",
                                         item.path]);
            root.close();
            return;
        }

        // 特殊条目：打开网址 / 网页搜索
        if (item.kind === "url" || item.kind === "search") {
            if (item.target)
                Quickshell.execDetached(["xdg-open", item.target]);
            root.close();
            return;
        }

        // 应用条目
        if (!item.command || item.command.length === 0)
            return;
        // 与 Clavis 的 ApplicationService 一致：先进入 scope 再执行，
        // 避免应用的子进程继承 shell 服务的 cgroup
        const argv = ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--slice=app.slice",
                      "--expand-environment=no"];
        if (item.workingDirectory)
            argv.push("--working-directory=" + item.workingDirectory);
        Quickshell.execDetached(argv.concat(["--"]).concat(Array.from(item.command)));
        root.close();
    }

    function iconUrl(name) {
        const value = String(name || "");
        if (value.startsWith("file://") || value.startsWith("image://"))
            return value;
        if (value.startsWith("/"))
            return "file://" + value;
        const resolved = Quickshell.iconPath(value || "application-x-executable",
                                             "application-x-executable");
        return resolved && resolved !== "" ? resolved : "";
    }

    // ---------------------------------------------------------------- IPC
    IpcHandler {
        target: "launcher"

        function toggle(): void {
            root.toggle();
        }
        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
        // 供外部切换 list/grid
        function toggleView(): void {
            root.toggleViewStyle();
        }
    }

    // 注意：窗口现在只覆盖面板区域，所以没有「点击面板外关闭」了 ——
    // 这是为了让 niri 的模糊只作用于面板而不糊掉整张壁纸。
    // 关闭请用 Esc，或再按一次 Mod+Space。

    // ------------------------------------------------------------ 面板
    Rectangle {
        id: panel

        // 窗口尺寸已等于面板尺寸，这里直接铺满
        anchors.fill: parent
        radius: 14
        // 半透明面板。色源 / 不透明度 / 明暗系数都在 ParallaxConfig 里可调。
        // 色源默认取 primaryContainer（随壁纸变）；用 surface* 族会得到一块不随壁纸的
        // 中性灰，贴在彩色壁纸上会显脏 —— 详见 ParallaxConfig 里的说明。
        color: root.tone(root.ca(Config.launcherPanelSurface, Config.launcherPanelOpacity,
                                 Qt.rgba(0.17, 0.27, 0.47, Config.launcherPanelOpacity)),
                         Config.launcherPanelBrightness, Config.launcherPanelSaturation)
        border.width: 1
        // 描边跟底色同色系（primary），避免用 outline 的灰在蓝底上围出一圈脏边
        border.color: root.ca("primary", 0.3, Qt.rgba(1, 1, 1, 0.14))

        // 刻意不给 width 加动画：动画期间宽度每帧变化，会让 GridView 的
        // cellWidth 每帧重算、delegate 持续重排，切换样式时明显掉帧。
        // 直接瞬变反而更跟手。

        // 吞掉点击，避免穿透到遮罩导致误关闭
        MouseArea {
            anchors.fill: parent
        }

        Column {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            // ---- 搜索框 ----
            Rectangle {
                width: parent.width
                height: 46
                radius: 10
                color: root.tone(root.ca(Config.launcherInputSurface, Config.launcherInputOpacity,
                                         Qt.rgba(1, 1, 1, 0.06)),
                                 Config.launcherInputBrightness, Config.launcherInputSaturation)
                border.width: searchField.activeFocus ? 1 : 0
                border.color: root.ca("primary", 0.6, Qt.rgba(0.61, 0.8, 0.98, 0.6))

                TextInput {
                    id: searchField

                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 76
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.c("onSurface", "#cdd6f4")
                    font.pixelSize: 17
                    selectByMouse: true
                    clip: true

                    onTextChanged: {
                        root.query = text;
                        root.selectedIndex = 0;
                    }

                    Keys.onEscapePressed: root.close()
                    Keys.onDownPressed: root.moveSelection("down")
                    Keys.onUpPressed: root.moveSelection("up")
                    Keys.onLeftPressed: root.moveSelection("left")
                    Keys.onRightPressed: root.moveSelection("right")
                    Keys.onReturnPressed: root.launchCurrent()
                    Keys.onEnterPressed: root.launchCurrent()

                    Keys.onPressed: event => {
                        // Ctrl+G 切换视图样式
                        if (event.key === Qt.Key_G && (event.modifiers & Qt.ControlModifier)) {
                            root.toggleViewStyle();
                            event.accepted = true;
                            return;
                        }
                        root.syncControlHeld();
                    }
                    Keys.onReleased: root.syncControlHeld()

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: searchField.text === ""
                        text: "搜索应用…"
                        color: root.ca("onSurfaceVariant", 0.55, Qt.rgba(1, 1, 1, 0.35))
                        font.pixelSize: 17
                    }
                }

                // 样式提示（右对齐）
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.viewStyle === "grid" ? "图标墙" : "列表") + "  ^G"
                    color: root.ca("onSurfaceVariant", 0.5, Qt.rgba(1, 1, 1, 0.3))
                    font.pixelSize: 12
                }
            }

            // ---- 结果区 ----
            Item {
                width: parent.width
                height: parent.height - 56 - 22

                // ============ 列表视图 ============
                ListView {
                    id: resultList

                    anchors.fill: parent
                    visible: root.effectiveViewStyle === "list"
                    clip: true
                    model: root.results
                    currentIndex: root.selectedIndex
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: row

                        required property var modelData
                        required property int index

                        width: resultList.width
                        height: 44
                        radius: 8
                        color: index === root.selectedIndex ? root.ca("primary",
                                                                      Config.launcherSelectedOpacity,
                                                                      Qt.rgba(0.61, 0.8, 0.98,
                                                                              Config.launcherSelectedOpacity)) : "transparent"

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 12

                            // 应用显示图标
                            Image {
                                id: rowIcon

                                anchors.verticalCenter: parent.verticalCenter
                                width: 24
                                height: 24
                                // 加载失败时让位给下面的首字母占位
                                visible: row.modelData.kind === "app" && rowIcon.status !== Image.Error
                                source: row.modelData.kind === "app" ? row.modelData.iconUrl : ""
                                sourceSize: Qt.size(48, 48)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                            }

                            // 图标缺失时的占位：应用名首字母
                            // （比如 Typora 的 .desktop 指向不存在的绝对路径）
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 24
                                height: 24
                                visible: row.modelData.kind === "app" && rowIcon.status === Image.Error
                                text: String(row.modelData.name || "?").charAt(0).toUpperCase()
                                color: index === root.selectedIndex ? root.c("onPrimaryContainer",
                                                                              "#ffffff") : root.ca(
                                                                                  "onSurfaceVariant", 0.75,
                                                                                  Qt.rgba(1, 1, 1, 0.6))
                                font.pixelSize: 13
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }

                            // 非应用条目用符号占位
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 24
                                visible: row.modelData.kind !== "app"
                                text: row.modelData.kind === "url" ? "🌐" : "🔍"
                                font.pixelSize: 17
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 48
                                text: row.modelData.kind === "app" ? row.modelData.name : (row.modelData.detail
                                                                                          + "：" + row.modelData.name)
                                color: index === root.selectedIndex ? root.c("onPrimaryContainer",
                                                                              "#ffffff") : root.c("onSurface",
                                                                                                  "#cdd6f4")
                                font.pixelSize: 15
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            // 鼠标完全不影响选中状态，也不做悬停视觉反馈 ——
                            // 划过列表不该带走键盘的选中位置。
                            // 单击选中，双击启动。
                            onClicked: root.selectedIndex = row.index
                            onDoubleClicked: {
                                root.selectedIndex = row.index;
                                root.launch(row.modelData);
                            }
                        }
                    }
                }

                // ============ 网格视图（图标墙）============
                GridView {
                    id: appGrid

                    anchors.fill: parent
                    visible: root.effectiveViewStyle === "grid"
                    clip: true
                    model: root.results
                    currentIndex: root.selectedIndex
                    // 壁纸格子更大：只显示图不显示名字，大一点才好挑
                    cellWidth: root.wallpaperMode ? Math.min(width, Config.launcherWallpaperCellWidth)
                                                  : Math.min(width, Config.launcherCellWidth)
                    cellHeight: root.wallpaperMode ? Config.launcherWallpaperCellHeight : Config.launcherCellHeight
                    boundsBehavior: Flickable.StopAtBounds
                    keyNavigationEnabled: false

                    delegate: Item {
                        id: tile

                        required property var modelData
                        required property int index

                        readonly property bool selected: tile.index === root.selectedIndex

                        width: appGrid.cellWidth
                        height: appGrid.cellHeight

                        Rectangle {
                            id: tileSurface

                            anchors.fill: parent
                            anchors.margins: Config.launcherCellGap / 2
                            radius: 12
                            // 只有选中态有背景，鼠标划过不做任何视觉变化
                            color: tile.selected ? root.ca("primary", Config.launcherSelectedOpacity,
                                                           Qt.rgba(0.61, 0.8, 0.98,
                                                                   Config.launcherSelectedOpacity)) : "transparent"
                            scale: tileMouse.pressed ? 0.94 : 1

                            // 只保留缩放动画；颜色直接切换 —— 颜色动画要为每个
                            // delegate 常驻一个 ColorAnimation，收益不值这个开销
                            Behavior on scale {
                                NumberAnimation {
                                    duration: 150
                                    easing.type: Easing.OutCubic
                                }
                            }

                            // ---- 壁纸缩略图（壁纸模式专用，不显示任何文字）----
                            Image {
                                id: wallpaperThumb

                                anchors.fill: parent
                                anchors.margins: 10
                                visible: tile.modelData.kind === "wallpaper"
                                source: tile.modelData.kind === "wallpaper" ? tile.modelData.url : ""
                                // 必须限制解码尺寸：壁纸原图动辄 4096×1708 / 数 MB，
                                // 按原尺寸解码既慢又占内存（整屏十几张就上百 MB）。
                                sourceSize: Qt.size(Config.launcherWallpaperCellWidth * 2,
                                                    Config.launcherWallpaperCellHeight * 2)
                                // 与图标一样走同步加载。壁纸走 file:// 不经过那个有
                                // 线程安全问题的 IconImageProvider，本可以异步，但保持
                                // 一致更稳妥 —— 异步加载的坑见下面 appIcon 的注释。
                                asynchronous: false
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                clip: true
                                scale: tile.selected ? 1.04 : 1

                                Behavior on scale {
                                    NumberAnimation {
                                        duration: 180
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            // 选中描边。缩略图盖住了 tileSurface 的底色，选中态单独画。
                            Rectangle {
                                anchors.fill: wallpaperThumb
                                visible: tile.modelData.kind === "wallpaper" && tile.selected
                                color: "transparent"
                                border.width: 2
                                border.color: root.ca("primary", 0.9, Qt.rgba(0.61, 0.8, 0.98, 0.9))
                                radius: 4
                            }

                            Image {
                                id: appIcon

                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.top
                                anchors.topMargin: 12
                                width: Config.launcherIconSize
                                height: width
                                // 加载失败时让位给下面的首字母占位
                                visible: tile.modelData.kind === "app" && appIcon.status !== Image.Error
                                source: tile.modelData.kind === "app" ? tile.modelData.iconUrl : ""
                                sourceSize: Qt.size(Config.launcherIconSize * 2, Config.launcherIconSize * 2)
                                // 必须同步加载。quickshell 的 IconImageProvider::requestPixmap
                                // 内部调用 QIcon::fromTheme() 与 icon.pixmap()，而 QIconLoader /
                                // QSvgIconEngine 都不是线程安全的（Qt 要求该函数可重入）。
                                // 异步加载会让它在线程池中并发执行，竞争 QIconLoader 的全局状态，
                                // 导致堆越界 —— 实测表现为启动即 "free(): chunks in smallbin
                                // corrupted" 后 SEGV，整个 Quickshell 进程（含壁纸层）一起挂掉。
                                asynchronous: false
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                scale: tile.selected ? 1.18 : 1

                                Behavior on scale {
                                    NumberAnimation {
                                        duration: 180
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            // 图标缺失时的占位：应用名首字母
                            // （比如 Typora 的 .desktop 指向失效的绝对路径）
                            Text {
                                anchors.top: parent.top
                                anchors.topMargin: 12
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: Config.launcherIconSize
                                height: Config.launcherIconSize
                                visible: tile.modelData.kind === "app" && appIcon.status === Image.Error
                                text: String(tile.modelData.name || "?").charAt(0).toUpperCase()
                                font.pixelSize: Math.round(Config.launcherIconSize * 0.42)
                                font.bold: true
                                color: root.ca("onSurfaceVariant", 0.75, Qt.rgba(1, 1, 1, 0.55))
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                scale: tile.selected ? 1.18 : 1

                                Behavior on scale {
                                    NumberAnimation {
                                        duration: 180
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            // 特殊条目（搜索 / 网址）用符号占位，高度与图标一致以保持对齐
                            Text {
                                anchors.top: parent.top
                                anchors.topMargin: 12
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: Config.launcherIconSize
                                height: Config.launcherIconSize
                                visible: tile.modelData.kind === "url" || tile.modelData.kind === "search"
                                text: tile.modelData.kind === "url" ? "🌐" : "🔍"
                                font.pixelSize: Math.round(Config.launcherIconSize * 0.7)
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                scale: tile.selected ? 1.18 : 1

                                Behavior on scale {
                                    NumberAnimation {
                                        duration: 180
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            Text {
                                anchors.top: appIcon.bottom
                                anchors.topMargin: 10
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                height: 40
                                // 壁纸只显示缩略图，不显示文件名
                                visible: tile.modelData.kind !== "wallpaper"
                                text: tile.modelData.name
                                font.pixelSize: Config.launcherLabelFontSize
                                color: tile.selected ? root.c("onPrimaryContainer", "#ffffff") : root.c("onSurface",
                                                                                                         "#cdd6f4")
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignTop
                                maximumLineCount: 2
                                wrapMode: Text.Wrap
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: tileMouse

                            anchors.fill: tileSurface
                            cursorShape: Qt.PointingHandCursor
                            // 鼠标完全不影响选中状态，也不做悬停视觉反馈 ——
                            // 划过图标墙不该带走键盘的选中位置。
                            // 单击选中，双击启动。
                            onClicked: root.selectedIndex = tile.index
                            onDoubleClicked: {
                                root.selectedIndex = tile.index;
                                root.launch(tile.modelData);
                            }
                        }
                    }
                }

                // ---- 空状态 ----
                Text {
                    anchors.centerIn: parent
                    visible: root.results.length === 0
                    color: root.ca("onSurfaceVariant", 0.6, Qt.rgba(1, 1, 1, 0.4))
                    font.pixelSize: 14
                    text: root.wallpaperMode ? "未在 ~/Pictures/wallpapers 找到图片（支持 jpg/png/webp）"
                                             : root.allApps.length === 0 ? "未读取到任何应用" : "无匹配结果"
                }
            }

            // ---- 底部状态栏 ----
            Item {
                width: parent.width
                height: 12

                // 按住 Ctrl：显示当前选中项的启动命令 / 目标地址
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.controlHeld
                    clip: true
                    elide: Text.ElideMiddle
                    color: root.ca("primary", 0.9, Qt.rgba(0.61, 0.8, 0.98, 0.8))
                    font.pixelSize: 11
                    text: {
                        const item = root.selectedItem;
                        if (!item)
                            return "";
                        if (item.kind === "url" || item.kind === "search")
                            return item.target || "";
                        return (item.command || []).join(" ");
                    }
                }

                // 默认：快捷键提示
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !root.controlHeld
                    text: root.wallpaperMode
                          ? "↑↓←→ 选择 · Enter/双击 应用壁纸 · Esc 关闭" : "↑↓←→ 选择 · Enter/双击 启动 · ^G 切换样式 · 按住 ^ 看命令 · Esc 关闭"
                    color: root.ca("onSurfaceVariant", 0.45, Qt.rgba(1, 1, 1, 0.28))
                    font.pixelSize: 11
                }
            }
        }
    }

    // ------------------------------------------------------------ 壁纸扫描
    // 与 Clavis 的 WallpaperService.scan() 同法：find 列目录，SplitParser 逐行收，
    // 退出时排序去重。只读不写。
    Process {
        id: wallpaperScanner

        command: ["find", root.wallpaperDir, "-type", "f", "(", "-iname", "*.jpg", "-o", "-iname",
            "*.jpeg", "-o", "-iname", "*.png", "-o", "-iname", "*.webp", ")", "-print"]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const path = line.trim();
                if (path !== "")
                    root.wallpaperScanBuffer.push(path);
            }
        }

        onExited: {
            // 排序 + 去重：顺序稳定，免得每次打开启动器缩略图都在跳位置
            const sorted = root.wallpaperScanBuffer.slice().sort();
            const unique = [];
            for (let i = 0; i < sorted.length; i += 1) {
                if (i === 0 || sorted[i] !== sorted[i - 1])
                    unique.push(sorted[i]);
            }
            root.wallpaperPaths = unique;
            root.wallpaperScanBuffer = [];
        }
    }
}
