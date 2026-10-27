<p align="center"><img src="packaging/macos/Flameshoter-Default.png" width="160" alt="Flameshoter"></p>

# Flameshoter

基于 [Flameshot](https://github.com/flameshot-org/flameshot) 的 macOS 截图与标注工具。保留截图和标注核心，使用 **AppKit 原生 Liquid Glass** 重做 macOS 控件层，支持简体中文和英文。

[English](README.en.md) · [下载](https://github.com/Word2VecT/flameshoter/releases) · [Homebrew tap](https://github.com/Word2VecT/homebrew-tap)

## 安装

首版发布包支持 **Apple Silicon、macOS 26 及以上**。

```sh
brew install --cask Word2VecT/tap/flameshoter
```

首次截图时，请按系统提示允许 Flameshoter 的屏幕录制权限。自 0.1.2 起，官方发布包统一使用固定自签证书，使不同版本保持同一签名身份。应用尚未经过 Apple 公证；如果 Gatekeeper 阻止首次打开，请在“系统设置 → 隐私与安全”中使用系统提供的“仍要打开”。应用不会移除隔离属性或关闭系统安全检查。

升级：`brew upgrade --cask flameshoter`。

从旧版 ad hoc 临时签名迁移到固定签名，需要重新授权一次。若系统已开启权限但仍无法截图，在“设置 → 截图”选择“修复屏幕录制授权…”，重启后点击“截取区域”重新申请。若系统列表中没有此应用，请点击 **+** 添加 `/Applications/Flameshoter.app` 并允许，然后从应用中“重新启动”。此操作只重建 Flameshoter 的录屏授权；正常升级无需主动重置权限。

## 使用

- 启动窗口中的“试用标注工具”可打开示例画布。
- 默认全局截图快捷键：**⌘⇧X**。
- 拖动选择区域；浮动玻璃工具栏提供画笔、箭头、矩形、椭圆、荧光笔、马赛克、文字和序号。
- 更多菜单保留其他截图工具；支持撤销、重做、复制、保存和置顶截图。
- 按空格或点击“工具设置”调整颜色、尺寸、文字格式及标注图层。
- **⌘C** 复制，**⌘S** 保存，**Esc** 取消。

```sh
flameshoter gui
flameshoter gui -d 2000
flameshoter full -p ~/Pictures
flameshoter launcher
flameshoter config
```

## 完整设置

默认选区跟随系统强调色，图标使用中性玻璃底板，并自动适配浅色与深色外观。

原生设置提供七个页面：**通用、截图、工具栏、颜色、保存、标注、快捷键**。包括登录启动、后台行为、通知、放大镜、原生全屏、选区几何信息、撤销历史、工具可见性、颜色预设、文件命名、保存与剪贴板行为、工具参数和完整快捷键录制。支持导入/导出原版 Flameshot `.ini` 配置，以及恢复默认值。

在“设置 → 通用 → 语言”选择“简体中文”“English”或跟随系统。更改界面语言和全局快捷键后重启应用。

## 原生设计与图标

截图内容仍由 Flameshot 核心绘制。浮动操作层使用 `NSGlassEffectView` 和 `NSGlassEffectContainerView`；设置、菜单、颜色选择器及弹出面板使用原生 AppKit 控件。材料、对比度、强调色和动态效果由系统处理。

应用图标保留原版三片火焰轮廓与配色，使用 **Apple Icon Composer** 制作独立图层。源文件为 [`Flameshoter.icon`](packaging/macos/Flameshoter.icon)，发布时由 Xcode 的 `actool` 编译到 `Assets.car`，支持系统外观变体。PNG 仅用于文档和兼容预览。

## 构建与发布

详见 [构建与发布说明](docs/BUILDING.md) 和 [设计实现说明](docs/DESIGN.md)。公开发布包使用官方 Qt 6.12.0，并检查最低系统版本、动态库依赖、语言包和签名。

Linux 和 Windows 的上游源码保留在仓库中；首版只发布、验证 macOS Apple Silicon 版本。

## 许可证与来源

GPL-3.0-or-later。基于 Flameshot 上游提交 `da34dcb1b296bd2e3bc589767abbe788084215ae`，保留原作者及贡献者署名。Flameshoter 是独立衍生项目。

[许可证](LICENSE) · [第三方组件](THIRD_PARTY.md) · [上游 README](docs/UPSTREAM_README.md)
