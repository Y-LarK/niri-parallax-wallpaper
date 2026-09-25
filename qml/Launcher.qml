import QtQuick
import QtQuick.Effects
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
// 运行时按 Ctrl+G 切换，切换结果在**本次壳层运行期间**保持（关闭再打开不重置）；
// 初始样式由 ParallaxConfig.launcherViewStyle 决定 —— 详见 open() 里的说明。
//
// 触发：IPC `launcher toggle`
//   QS_CONFIG_PATH=<此目录>/shell.qml qs ipc call launcher toggle
PanelWindow {
    id: root

    property bool opened: false
    property string query: ""
    property int selectedIndex: 0
    // 初值只在**壳层启动时**生效；其后由 Ctrl+G 切换并保持，关闭启动器不再重置
    // （见 open() 里的说明，2026-09-22 改）。
    property string viewStyle: Config.launcherViewStyle

    // -------------------------------------------------------- 开关动画状态
    // opened 是**逻辑**状态（IPC 语义、输入框焦点归属）；reveal 是**视觉**展开度 0~1。
    //
    // 窗口可见性与键盘焦点都取自这两者的组合，**刻意不设第三个 closing 标志**。
    // 之前用 `opened || closing` 的写法必然要「先置 opened=false、再置 closing=true」，
    // 两次赋值之间绑定会求值到瞬时 false：surface 先 unmap 再 map、键盘焦点先放再抓，
    // 观感上就是关闭时闪两下。2026-09-20 实测确认，关闭一次 visible 变了
    // true → false → true → false 共三次。改用 reveal 判断就全程单调了。
    // 展开度 0~1，由下面那条 NumberAnimation 单向驱动。
    // 刻意不用 Behavior —— Behavior 会被**任何**对 reveal 的赋值触发，
    // 而这里需要在「退场途中重新打开」时精确控制重启，只有显式 restart 才可控。
    property real reveal: 0

    // 动画派生量，面板与它的投影共用一份，免得两处各写一遍公式后渐渐走样。
    // reveal=0 → 起始态（缩放 Config.launcherAnimScale、上移 Config.launcherAnimOffsetY），
    // reveal=1 → 归位（缩放 1、偏移 0）。
    readonly property real animScale: Config.launcherAnimScale + (1 - Config.launcherAnimScale) * root.reveal
    readonly property real animOffsetY: Config.launcherAnimOffsetY * (1 - root.reveal)


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
    // 面板包边颜色。必须是**派生属性**而非直接在 border.color 里调 ca()：
    // ca() 依赖 themeColors，而后者由 FileView 异步加载；写成派生属性，
    // themeColors 变化时边框会自动重新求值（直接内联调用会停在初始化时的兜底值）。
    //
    // 色源用 primary 而非 outline —— outline 是 Material You 的中性灰角色，
    // 不承载壁纸色相（实测三次换壁纸：#8e9099 → #928f99 → #8b9198，几乎不动），
    // 而 primary 同期是 #a8c8ff → #c8bfff → #96ccf8，明显跟壁纸走。
    readonly property color borderColor: root.ca("primary", Config.launcherBorderOpacity,
                                                 Qt.rgba(0.61, 0.8, 0.98, Config.launcherBorderOpacity))

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
    // 可见性与键盘焦点同源：opened 为真，或退场动画还没走完（reveal > 0）。
    // reveal 归零时 visible 自动变 false，不需要额外的收尾逻辑。
    // 这样每次开关这两项都只翻转一次，不会出现中间态（见上面状态属性的说明）。
    visible: root.opened || root.reveal > 0
    color: "transparent"

    WlrLayershell.namespace: "niri-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // 关键：不设 Exclusive 就收不到键盘输入。
    // 退场动画期间继续独占：那时面板仍然可见，此时放开焦点会让键盘输入漏给
    // 底下的窗口，观感上是「还没关完就已经穿透了」。
    WlrLayershell.keyboardFocus: (root.opened || root.reveal > 0) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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

    // 窗口尺寸 = 面板 + 四周的阴影边距。
    //
    // 为什么非要留边距：layer-shell 的 surface 边界就是窗口矩形，绘制到边界外的
    // 内容一律不可见。而 RectangularShadow 的 offset/blur 会让阴影溢出面板边界 ——
    // offset 向下 8px 时，下方两角的圆角被裁成直线、上方两角却正常（2026-09-25 实测）。
    // 留出边距后阴影才有完整的绘制空间，四角圆角才正确。
    // 代价：niri 的 background-effect 作用于**整个 surface**，于是面板外会多出一圈
    // 被模糊的区域，宽度即此边距。想彻底消除那一圈，只能关掉阴影。
    readonly property real shadowMargin: Config.launcherShadowEnabled ? Math.ceil(
                                                                             Config.launcherShadowBlur + Math.abs(
                                                                                 Config.launcherShadowOffsetY)) : 0

    implicitWidth: root.panelWidth + root.shadowMargin * 2
    implicitHeight: root.panelHeight + root.shadowMargin * 2

    // PanelWindow 的 anchors 只支持 top/bottom/left/right 四个 bool，
    // 没有 horizontalCenter，所以水平居中用 margins.left 算。
    // 减去 shadowMargin 是为了让**面板**（而不是窗口）仍落在原来算出的位置上 ——
    // 否则加了边距后面板会整体偏移，视觉位置和改动前对不上。
    anchors.top: true
    anchors.left: true
    margins.top: Math.round((root.screenH - root.panelHeight) * Config.launcherVerticalRatio) - root.shadowMargin
    margins.left: Math.round((root.screenW - root.panelWidth) / 2) - root.shadowMargin

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
        // 这里**刻意不重置 viewStyle** —— 2026-09-22 起用户要求记住 Ctrl+G 的切换结果，
        // 关闭再打开应保持上次的选择（在此之前是每次打开都强制回到配置里的默认样式）。
        // 不重置并不会丢失默认值：viewStyle 的 property 初值仍是
        // Config.launcherViewStyle，所以壳层重启后自然回到配置的默认样式。
        root.opened = true;
        // 不设 from：NumberAnimation 以「当前 reveal 值」为起点，
        // 于是退场途中重新打开能从当前位置平滑接上，而不是跳回 0 重来一遍。
        revealAnim.to = 1;
        revealAnim.restart();
        // 重扫壁纸目录，新放进来的图立刻可见
        root.scanWallpapers();
        searchField.forceActiveFocus();
    }

    // 播退场动画。窗口不必在这里隐藏 —— reveal 归零时 visible 自己会变 false。
    // 重复调用是安全的（退场途中 opened 已是 false 就直接返回），否则连按 Esc
    // 会反复重启动画，看起来像卡住不动。
    function close() {
        if (!root.opened)
            return;
        root.opened = false;
        revealAnim.to = 0;
        revealAnim.restart();
    }

    function toggle() {
        // 判据用 opened 而非可见性：退场动画进行中 opened 已经是 false，
        // 此时该做的是「重新打开」，而不是再触发一次 close。
        root.opened ? root.close() : root.open();
    }

    // 开关动画的唯一定时源。时长与曲线都跟随 opened：
    //   入场 OutCubic —— 快进慢停，入场曲线的通用做法；
    //   退场 InCubic —— 慢起快走，让面板不透明度撑到最后再快速归零。
    // 退场之所以要「慢起」，是因为 niri 侧那块模糊矩形不跟随面板 alpha ——
    // 面板越早变透明，那层毛玻璃暴露得越久（详见 ParallaxConfig 里退场时长的说明）。
    //
    // 读值时机没问题：open()/close() 都是先置 opened、后 restart()，
    // 动画重启时读到的必然是对应方向的那一组参数。
    // 不需要 onFinished 收尾：隐藏窗口这件事完全由 reveal 的值驱动。
    NumberAnimation {
        id: revealAnim

        target: root
        property: "reveal"
        duration: root.opened ? Config.launcherAnimDurationMs : Config.launcherCloseDurationMs
        easing.type: root.opened ? Easing.OutCubic : Easing.InCubic
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
    // 投影。RectangularShadow 是 Qt 6.9+ 的 QtQuick.Effects 类型，按自身几何绘制
    // 阴影、不需要 source（这点与 MultiEffect 不同，不强制额外分层，开销小得多）。
    // 必须声明在 panel **之前** —— QML 同级项按声明顺序决定 z 序，放后面会盖住面板。
    // 这里填满 parent 而不是 anchors.fill: panel：panel 同样是填满 parent 的，
    // 几何等价，但免掉了对后面声明项的依赖。
    // 三个动画绑定必须与 panel 保持一致，否则退场时会看到一圈孤立的阴影留在原地。
    RectangularShadow {
        // 内缩 shadowMargin，与 panel 的几何保持一致 ——
        // 窗口比面板大一圈，正是为了给这里的 blur/offset 留绘制空间
        anchors.fill: parent
        anchors.margins: root.shadowMargin
        radius: Config.launcherPanelRadius
        blur: Config.launcherShadowBlur
        color: Qt.rgba(0, 0, 0, Config.launcherShadowOpacity)
        offset: Qt.vector2d(0, Config.launcherShadowOffsetY)
        visible: Config.launcherShadowEnabled
        opacity: root.reveal
        scale: root.animScale
        transform: Translate {
            y: root.animOffsetY
        }
    }

    Rectangle {
        id: panel

        // 窗口比面板四周各大 shadowMargin（那是给阴影留的绘制空间），这里内缩回来。
        // 于是 panel 的实际尺寸仍等于 panelWidth/panelHeight，内部布局不受影响。
        anchors.fill: parent
        anchors.margins: root.shadowMargin
        radius: Config.launcherPanelRadius

        // 开关动画。**窗口尺寸不变**，只动这三个 —— 窗口自身 resize 会让 GridView
        // 每帧重算 cellWidth 并重排全部 delegate（同下面紧跟着的那段说明）。
        opacity: root.reveal
        scale: root.animScale
        // 用 transform 而非改 anchors：anchors 是布局、动它要重算几何，
        // transform 是纯绘制变换，动画期间不触发布局。
        transform: Translate {
            y: root.animOffsetY
        }
        // 半透明面板。色源 / 不透明度 / 明暗系数都在 ParallaxConfig 里可调。
        // 色源默认取 primaryContainer（随壁纸变）；用 surface* 族会得到一块不随壁纸的
        // 中性灰，贴在彩色壁纸上会显脏 —— 详见 ParallaxConfig 里的说明。
        color: root.tone(root.ca(Config.launcherPanelSurface, Config.launcherPanelOpacity,
                                 Qt.rgba(0.17, 0.27, 0.47, Config.launcherPanelOpacity)),
                         Config.launcherPanelBrightness, Config.launcherPanelSaturation)
        border.width: Config.launcherBorderWidth
        // 包边色源见上面 borderColor 的说明（用 primary，随壁纸色相变化）
        border.color: root.borderColor

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
                radius: Config.launcherInputRadius
                color: root.tone(root.ca(Config.launcherInputSurface, Config.launcherInputOpacity,
                                         Qt.rgba(1, 1, 1, 0.06)),
                                 Config.launcherInputBrightness, Config.launcherInputSaturation)
                border.width: searchField.activeFocus ? 1 : 0
                border.color: root.ca("primary", 0.6, Qt.rgba(0.61, 0.8, 0.98, 0.6))

                // 放大镜。手绘而非取图标主题 —— 主题里的 edit-find 是给浅色背景画的
                // 深色图标，贴在这块深色面板上几乎看不见；手绘还能让颜色跟着 matugen
                // 的 onSurfaceVariant 走，随壁纸换色。
                Item {
                    id: searchIcon

                    anchors.left: parent.left
                    anchors.leftMargin: 15
                    anchors.verticalCenter: parent.verticalCenter
                    width: 13
                    height: 13
                    opacity: 0.55

                    // 镜片：圆环，外径 11
                    Rectangle {
                        width: 11
                        height: 11
                        radius: width / 2
                        color: "transparent"
                        border.width: 1.6
                        border.color: root.c("onSurfaceVariant", "#c4c6cf")
                    }

                    // 手柄：自圆环右下沿 45° 伸出。
                    // transformOrigin 取 Left 即绕「左边缘中点」旋转，所以 y 要减去
                    // 半个高度，把旋转轴落到 (x, y + h/2) = (8.5, 8.5) 这个起点上。
                    Rectangle {
                        x: 8.5
                        y: 7.7
                        width: 4.5
                        height: 1.6
                        color: root.c("onSurfaceVariant", "#c4c6cf")
                        rotation: 45
                        transformOrigin: Item.Left
                    }
                }

                TextInput {
                    id: searchField

                    anchors.fill: parent
                    // 左侧让开放大镜，右侧让开「清空按钮 + 样式提示」
                    anchors.leftMargin: 40
                    anchors.rightMargin: 112
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
                    id: styleHint

                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: (root.viewStyle === "grid" ? "图标墙" : "列表") + "  ^G"
                    color: root.ca("onSurfaceVariant", 0.5, Qt.rgba(1, 1, 1, 0.3))
                    font.pixelSize: 12
                }

                // 清空输入。只在有内容时出现，贴在样式提示左侧 ——
                // 所以声明在 styleHint 之后，靠它定位（避免对后面声明项的前向引用）。
                // 这里给悬停反馈是有意的：项目里「鼠标划过不做视觉变化」那条原则针对的是
                // 结果列表项（划过不该把键盘的选中位置带走），独立按钮不受它约束。
                Item {
                    id: clearButton

                    anchors.right: styleHint.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    visible: searchField.text !== ""

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: root.ca("onSurfaceVariant", clearMouse.containsMouse ? 0.24 : 0.12,
                                       Qt.rgba(1, 1, 1, clearMouse.containsMouse ? 0.2 : 0.1))

                        Behavior on color {
                            ColorAnimation {
                                duration: 120
                            }
                        }
                    }

                    // × 用两根交叉短棒画，同样是不依赖字体里有没有 × 字形
                    Rectangle {
                        anchors.centerIn: parent
                        width: 8
                        height: 1.5
                        radius: height / 2
                        color: root.c("onSurface", "#cdd6f4")
                        rotation: 45
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: 8
                        height: 1.5
                        radius: height / 2
                        color: root.c("onSurface", "#cdd6f4")
                        rotation: -45
                    }

                    MouseArea {
                        id: clearMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // 只清输入框本身即可：query / selectedIndex 由 searchField 的
                        // onTextChanged 单向同步过去，重复赋值反而多一条路径。
                        onClicked: {
                            searchField.text = "";
                            searchField.forceActiveFocus();
                        }
                    }
                }
            }

            // ---- 结果区 ----
            // 高度公式里的两个常数与上方搜索框、下方状态栏配平：
            //   56 = 搜索框 46 + Column spacing 10
            //   30 = 状态栏 20 + Column spacing 10
            // 改任一高度都要同步改这里，否则会溢出面板或留出空档。
            Item {
                width: parent.width
                height: parent.height - 56 - 30

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

                        readonly property bool selected: row.index === root.selectedIndex

                        width: resultList.width
                        height: 44
                        radius: Config.launcherRowRadius
                        color: row.selected ? root.ca("primary", Config.launcherSelectedOpacity,
                                                      Qt.rgba(0.61, 0.8, 0.98,
                                                              Config.launcherSelectedOpacity)) : "transparent"

                        // 选中项左侧的强调条。网格视图靠图标放大表示选中，列表这边原先
                        // 只有背景色变化，两处动效语言不成对，补上这一条。
                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 3
                            width: Config.launcherAccentBarWidth
                            height: parent.height - 18
                            radius: width / 2
                            color: root.ca("primary", 0.95, Qt.rgba(0.61, 0.8, 0.98, 0.95))
                            visible: row.selected && Config.launcherAccentBarWidth > 0
                        }

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
                            radius: Config.launcherCellRadius
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
            // 高度 20 是给键帽留的（原先一整行纯文字只要 12）。
            // 这个值与上面结果区的 height 公式配平，见那里的说明。
            Item {
                width: parent.width
                height: 20

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

                // 默认：快捷键提示。改成「键帽 + 说明」交替排布，比一整行纯文字好扫读。
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !root.controlHeld
                    spacing: 14

                    Row {
                        spacing: 5

                        KbdKey {
                            label: "↑↓←→"
                        }

                        HintLabel {
                            text: "选择"
                        }
                    }

                    Row {
                        spacing: 5

                        KbdKey {
                            label: "Enter"
                        }

                        HintLabel {
                            text: root.wallpaperMode ? "应用壁纸" : "启动"
                        }
                    }

                    // 下面两组只在应用模式出现 —— 壁纸模式下它们没有意义。
                    // Row 会自动跳过 visible 为 false 的子项，不留空隙。
                    Row {
                        spacing: 5
                        visible: !root.wallpaperMode

                        KbdKey {
                            label: "^G"
                        }

                        HintLabel {
                            text: "切换样式"
                        }
                    }

                    Row {
                        spacing: 5
                        visible: !root.wallpaperMode

                        KbdKey {
                            label: "^"
                        }

                        HintLabel {
                            text: "按住看命令"
                        }
                    }

                    Row {
                        spacing: 5

                        KbdKey {
                            label: "Esc"
                        }

                        HintLabel {
                            text: "关闭"
                        }
                    }
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

    // ---------------------------------------------------- 底部提示的内联组件
    // 用 inline component 而不是各建一个文件：这两者只服务于底部那一行提示，
    // 拆成文件要多付一次跨文件跳转的成本，不值。
    component KbdKey: Rectangle {
        property string label: ""

        // 宽度跟着文字走 —— 「↑↓←→」这类中文键名比「Esc」宽得多，写死宽度必然对不齐
        width: keyText.implicitWidth + 12
        height: 18
        radius: 5
        color: root.ca("onSurfaceVariant", 0.13, Qt.rgba(1, 1, 1, 0.09))
        border.width: 1
        border.color: root.ca("onSurfaceVariant", 0.18, Qt.rgba(1, 1, 1, 0.1))

        Text {
            id: keyText

            anchors.centerIn: parent
            text: parent.label
            color: root.ca("onSurfaceVariant", 0.85, Qt.rgba(1, 1, 1, 0.72))
            font.pixelSize: 10
        }
    }

    component HintLabel: Text {
        // 固定 18 与键帽同高，Row 里顶部对齐即视觉居中。
        // 不能在 Row 的子项上用 anchors.verticalCenter —— Positioner 与 anchors 冲突。
        height: 18
        verticalAlignment: Text.AlignVCenter
        color: root.ca("onSurfaceVariant", 0.5, Qt.rgba(1, 1, 1, 0.34))
        font.pixelSize: 11
    }
}
