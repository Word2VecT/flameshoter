<p align="center"><img src="packaging/macos/Flameshoter-Default.png" width="160" alt="Flameshoter"></p>

# Flameshoter

源自 [Flameshot](https://github.com/flameshot-org/flameshot) 的 macOS 截图与标注工具。**0.2.0 起完全使用 Swift / AppKit，已移除 Qt 及所有第三方运行库。** 支持简体中文、英文和 Apple 原生 Liquid Glass。

[English](README.en.md) · [下载](https://github.com/Word2VecT/flameshoter/releases) · [Homebrew tap](https://github.com/Word2VecT/homebrew-tap)

## 安装

需要 **Apple Silicon、macOS 26 或更新版本**。

```sh
brew install --cask Word2VecT/tap/flameshoter
brew upgrade --cask flameshoter
```

首次截图请允许屏幕录制权限。官方发布包沿用 0.1.2 的固定自签证书与 Bundle ID，使升级前后保持相同应用身份。应用尚未通过 Apple 公证；首次启动若被 Gatekeeper 阻止，可在“系统设置 → 隐私与安全”中使用系统提供的“仍要打开”。tap 不会移除隔离属性或关闭系统检查。

从早期临时签名迁移到固定签名需要重新授权一次。若权限开关已开启但仍失败，可在“设置 → 截图”选择“修复屏幕录制授权…”，重启后重新申请。这个操作会清除本应用的旧录屏条目；正常升级无需使用它。

## 使用

- 默认全局截图快捷键：**⌘⇧X**；也可以使用菜单栏中的火焰图标。
- 拖选区域后，使用画笔、直线、箭头、矩形、椭圆、荧光笔、遮挡、文字、序号和颜色反转。
- 按空格、右键或点击“工具设置”打开原生面板，调整颜色、尺寸、文字格式及标注图层。
- **⌘C** 复制，**⌘S** 保存，**⌘Z / ⌘⇧Z** 撤销 / 重做，**Esc** 取消。
- 支持置顶截图、缩放、透明度和使用其他应用打开。
- 关闭所有普通窗口后自动隐藏 Dock 图标，保留菜单栏；最小化窗口会保留 Dock 图标。
- “试用标注工具”提供无需录屏权限的示例画布。

```sh
flameshoter gui
flameshoter gui -d 2000
flameshoter full -p ~/Pictures
flameshoter screen -n 0 --raw > capture.png
flameshoter gui --region 640x360+120+80 --accept-on-select -p ~/Pictures
flameshoter launcher
flameshoter config
```

`full` 合并所有显示器，`screen -n` 选择单个显示器。`--help` 查看其他参数。

## 设置与迁移

提供 **通用、截图、工具栏、颜色、保存、标注、快捷键** 七个原生设置页。语言可选择简体中文、English 或跟随系统；系统对话框语言在重启后应用。全局快捷键修改立即生效。

首次启动 0.2.0 会导入现有 Flameshoter INI 配置。也可手动导入 Flameshot `.ini` 或原生 JSON，并导出或恢复默认值。新设置保存在 `~/Library/Application Support/Flameshoter/settings.json`，旧文件保留。

导出使用 Apple ImageIO，格式菜单仅显示系统支持编码的格式；当前提供 PNG、JPEG、TIFF、BMP。传统马赛克可在设置中开启；默认遮挡使用选区周围颜色替换内部，避免直接缩小原始敏感内容。

## 原生设计与图标

选区整体使用 Apple `NSGlassEffectView` 的 Clear 材质，截图内容作为前景保持清晰，边缘显示系统玻璃效果。选区外采用 `NSVisualEffectView` 的 FullScreenUI 毛玻璃。工具栏使用 `NSGlassEffectContainerView` 组织原生玻璃组；设置、菜单、颜色面板、保存面板、文本编辑、置顶窗口和撤销管理均采用 AppKit。没有自制玻璃着色器或仿制模糊效果。材质只影响预览，导出保留原始矩形像素与标注。

图标保留 Flameshot 的三片火焰轮廓，使用 **Apple Icon Composer** 制作。发布时由 `actool` 将 [`Flameshoter.icon`](packaging/macos/Flameshoter.icon) 编译为系统图标资源，适配浅色、深色及单色外观。

截图通过 ScreenCaptureKit 完成，标注逻辑由本项目的 Swift / Core Graphics 实现。Apple 没有提供完整截图标注编辑器的公共组件；使用原生材质不代表 Apple 认证。

[构建与发布](docs/BUILDING.md) · [设计实现](docs/DESIGN.md) · [版本说明](docs/RELEASE_NOTES.md)

## 许可证与来源

GPL-3.0-or-later。最初基于 Flameshot 提交 `da34dcb1b296bd2e3bc589767abbe788084215ae`，保留原作者与贡献者署名。Flameshoter 是独立衍生项目；旧 C++ / Qt 实现在 Git 历史中保留，当前源码只支持 macOS。

[许可证](LICENSE) · [来源与组件说明](THIRD_PARTY.md)
