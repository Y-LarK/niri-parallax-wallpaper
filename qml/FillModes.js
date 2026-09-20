.pragma library

// 壁纸填充模式映射
//
// 数值取自 Qt 的 Image.fillMode 枚举（.js 中无法 import QtQuick，故写数值）：
//   0=Stretch  1=PreserveAspectFit  2=PreserveAspectCrop
//   3=Tile     4=TileVertically     5=TileHorizontally     6=Pad
//
// 这套数值同时用作 ShaderEffect 的 fillMode uniform —— Clavis 原版里
// qtFillMode() 与 shaderFillMode() 返回的其实是同一组数，故此处合并为一个函数。

function fillModeValue(modeName) {
    switch (modeName) {
    case "Stretch":
        return 0;
    case "Fit":
    case "PreserveAspectFit":
        return 1;
    case "Fill":
    case "PreserveAspectCrop":
    case "panorama":
        return 2;
    default:
        return 2; // 兜底 PreserveAspectCrop
    }
}

// 配置合法性校验
function isValid(modeName) {
    return modeName === "Fill" || modeName === "Fit" || modeName === "Stretch"
        || modeName === "panorama";
}

// 各模式的中文说明，供注释或调试输出用
function describe(modeName) {
    switch (modeName) {
    case "Fill":
        return "铺满屏幕并裁切多余部分";
    case "Fit":
        return "完整显示整张图，可能留黑边";
    case "Stretch":
        return "拉伸变形以铺满屏幕";
    case "panorama":
        return "宽图按原比例展开，可随列焦点大幅横向平移";
    default:
        return "未知模式";
    }
}
