<p align="center"><img src="packaging/macos/Flameshoter-Default.png" width="160" alt="Flameshoter"></p>

# Flameshoter

基于 [Flameshot](https://github.com/flameshot-org/flameshot) 的 macOS 菜单栏截图与标注工具，支持简体中文、英文和 Apple 原生 Liquid Glass。

[English](README.en.md) · [下载](https://github.com/Word2VecT/flameshoter/releases)

## 安装

需要 Apple Silicon 和 macOS 26 或更新版本。

```sh
brew install --cask Word2VecT/tap/flameshoter
brew upgrade --cask flameshoter
```

首次打开若被系统拦截，请在“系统设置 → 隐私与安全”中允许打开。首次截图时按提示授予屏幕录制权限。

## 使用

- 启动后驻留菜单栏，点击火焰图标或按 **⌘⇧X** 开始截图。
- 拖选区域后直接标注，按 **空格** 调整颜色、线宽和文字等参数。
- **⌘C** 复制，**⌘S** 保存，**⌘⇧S** 打开系统分享面板，**Esc** 取消。
- 在菜单栏的“设置”中调整语言、工具和快捷键。

运行 `flameshoter --help` 查看命令行用法。

## 许可证

[GPL-3.0-or-later](LICENSE) · [第三方声明](THIRD_PARTY.md) · [构建说明](docs/BUILDING.md)
