.pragma library

// 网页搜索引擎表
//
// 从 Clavis 的 Common/functions/SpotlightSearch.js 提取常用子集（原版有 15 个）。
// 想换引擎改 ParallaxConfig.launcherSearchEngine 即可。

var engines = [
    { "id": "google", "label": "Google", "url": "https://www.google.com/search?q=" },
    { "id": "bing", "label": "Bing", "url": "https://www.bing.com/search?q=" },
    { "id": "baidu", "label": "百度", "url": "https://www.baidu.com/s?wd=" },
    { "id": "duckduckgo", "label": "DuckDuckGo", "url": "https://duckduckgo.com/?q=" },
    { "id": "sogou", "label": "搜狗", "url": "https://www.sogou.com/web?query=" },
    { "id": "brave", "label": "Brave", "url": "https://search.brave.com/search?q=" },
    { "id": "startpage", "label": "Startpage", "url": "https://www.startpage.com/sp/search?query=" },
    { "id": "ecosia", "label": "Ecosia", "url": "https://www.ecosia.org/search?q=" }
];

function engineById(id) {
    const target = String(id || "");
    for (let i = 0; i < engines.length; i++) {
        if (engines[i].id === target)
            return engines[i];
    }
    return engines[0]; // 兜底 google
}

// 拼出搜索 URL（query 需转义，否则含 & # 等字符会破坏 URL）
function searchUrl(engineId, query) {
    return engineById(engineId).url + encodeURIComponent(String(query || ""));
}

// 判断输入是否像一个域名/URL（用于决定显示"打开"而非"搜索"）。
// 规则保守些：不含空格，且要么带协议前缀，要么形如 example.com[/path]
function looksLikeUrl(text) {
    const value = String(text || "").trim();
    if (value === "" || /\s/.test(value))
        return false;
    if (/^(https?|ftp|file):\/\//i.test(value))
        return true;
    return /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?([/?#].*)?$/i.test(value);
}

// 补全协议头
function normalizeUrl(text) {
    const value = String(text || "").trim();
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value))
        return value;
    return "http://" + value;
}
