<div align="center">
  <img src="packaging/macos/Flameshoter-Default.png" width="128" alt="Flameshoter">
  <h1>Flameshoter</h1>
  <p>简单易用的 macOS 截图与标注工具。</p>
  <p>
    <a href="https://github.com/Word2VecT/flameshoter/actions/workflows/macos.yml"><img src="https://img.shields.io/github/actions/workflow/status/Word2VecT/flameshoter/macos.yml?branch=master&amp;label=macOS" alt="macOS build"></a>
    <a href="https://github.com/Word2VecT/flameshoter/releases"><img src="https://img.shields.io/github/v/release/Word2VecT/flameshoter" alt="Latest release"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/Word2VecT/flameshoter" alt="License"></a>
  </p>
  <p><a href="README.en.md">English</a></p>
</div>

## 目录

- [功能](#功能)
- [使用](#使用)
- [快捷键](#快捷键)
- [安装](#安装)
- [编译](#编译)
- [许可证](#许可证)
- [参与贡献](#参与贡献)

## 功能

- 区域截图、多显示器、延时截图和自动窗口选区；授权辅助功能后可识别界面元素。
- 截图时刷新屏幕画面并保留选区与标注；可选择在截图中包含鼠标指针。
- 按显示器保存并切换截图区域历史。
- 在相同显示器和缩放比例下恢复截图历史，并重新编辑标注。历史保留遮挡前的选区原图，可在设置中关闭记录或清除。
- 纵向或横向长截图，支持预览、裁剪、复制、保存和置顶。
- 区域录屏，支持帧率、延迟、声音、暂停、预览和修剪，可保存为 MP4、GIF 或 WebP 动图；可叠加鼠标点击、键盘快捷键提示和摄像头画中画。
- 截图内标注：画笔、直线、折线、箭头、形状、聚光灯、放大镜、文字、平铺水印、序号与遮挡。
- 在本机识别邮箱、电话号码、网址 / IP、凭据标签和人脸并自动打码；结果可调整或撤销，分享前请核对。
- 复制、保存、置顶和 macOS 系统分享。
- 将剪贴板中的图片、GIF 和 WebP 动图、文字、颜色或文件置顶；支持旋转、水平翻转、锁定和重新标注，重启后可恢复贴图和已关闭的历史记录。
- 在截图和置顶图片中离线识别文字、二维码与条码，直接选择图片中的文字。
- 使用 macOS 本地翻译截图或置顶图片，可编辑原文、译文并生成译图；首次使用某些语言时需下载系统语言包。
- 在本机识别截图或置顶图片中的表格，修改单元格、排序和调整行列，并保存为 CSV 或 Excel；Excel 保留识别出的合并单元格。
- 在本机识别文档文字，校对后导出 Word、RTF、TXT 或 Markdown；当前导出可编辑文本段落，复杂版式与公式还原尚未支持。
- 取色并复制 HEX、RGB、HSV 等颜色值；支持 PNG、无损 WebP、PDF 和 AVIF 等格式，PNG 可自动无损优化。
- 保存时对照原图与导出预览，查看像素尺寸和文件大小，调整 JPEG / AVIF 质量。
- 简体中文、英文及可自定义的快捷键。
- Apple 原生 Liquid Glass 界面。

与 PixPin 的功能对照、离线实现范围和剩余缺口见 [功能对照](docs/PIXPIN_PARITY.md)。

## 使用

启动 Flameshoter 后，应用常驻菜单栏。点击火焰图标或按 **⌘⇧X** 开始截图，拖选区域后即可标注。

也可以通过命令行操作：

```sh
flameshoter gui                    # 区域截图
flameshoter gui -d 2000            # 延时 2 秒截图
flameshoter full -p ~/Pictures     # 全屏截图并保存
flameshoter config                 # 打开设置
```

菜单栏的“设置”可调整语言、工具和快捷键。更多命令行参数见 `flameshoter --help`。

折线逐点点击，双击或按回车完成；按退格删除最后一个顶点，Esc 放弃当前折线。聚光灯、放大镜和水印的参数在“工具设置”中调整。贴图右键菜单可旋转、翻转或重新标注；标注窗口按回车生成新贴图，取消返回原图。

录屏选项默认关闭摄像头和键盘提示；开启后才请求摄像头或输入监控权限。键盘提示只显示快捷键和导航按键，跳过普通文字及安全输入。

## 快捷键

以下为默认快捷键，可在设置中修改。

| 快捷键 | 操作 |
| --- | --- |
| ⌘⇧X | 全局区域截图 |
| P / D / A | 画笔 / 直线 / 箭头 |
| R / C / M | 矩形 / 椭圆 / 荧光笔 |
| T / N / B | 文字 / 序号 / 遮挡 |
| V / O / E / W | 折线 / 聚光灯 / 放大镜 / 水印 |
| ⇧B | 自动打码 |
| ⌘C / ⌘S / ⌘⇧S | 复制 / 保存 / 分享 |
| ⌘Z / ⌘⇧Z | 撤销 / 重做 |
| ⌘P | 置顶截图 |
| ⌃⇧2 / ⌃⇧3 | 置顶剪贴板 / 恢复上次关闭的贴图 |
| ⇧C / Q | 文字识别 / 二维码与条码识别 |
| ⌥Q | 翻译截图或置顶图片 |
| ⇧Q | 识别截图或置顶图片中的表格 |
| ⌥D | 识别截图或置顶图片中的文档 |
| L / 空格（贴图中） | 锁定贴图 / 重新标注 |
| L | 长截图 |
| G | 录制屏幕 |
| F5 | 按住查看屏幕，松开后刷新截图 |
| [ / ] | 上一个 / 下一个截图区域 |
| , / . | 上一张 / 下一张截图历史 |
| ⌥C | 复制鼠标下方的颜色；按住 ⌥ 并按 ⇧ 切换格式 |
| 空格 / 鼠标右键 | 工具设置 |
| Esc | 取消截图 |

## 安装

需要 **Apple Silicon 和 macOS 26 或更新版本**。

### Homebrew

```sh
brew install --cask Word2VecT/tap/flameshoter
brew upgrade --cask flameshoter
```

### 直接下载

从 [Releases](https://github.com/Word2VecT/flameshoter/releases) 下载并放入“应用程序”文件夹。

首次截图时按提示授予屏幕录制权限。如果 macOS 拦截首次启动，请在“系统设置 → 隐私与安全”中允许打开。

## 编译

使用 Xcode 27 或更新版本：

```sh
git clone https://github.com/Word2VecT/flameshoter.git
cd flameshoter
./scripts/build-macos.sh --package
```

测试、开发和打包步骤见 [构建说明](docs/BUILDING.md)。

## 许可证

- 代码采用 [GPL-3.0-or-later](LICENSE)。
- 图标基于 Flameshot 的原始作品，采用 [Free Art License 1.3](licenses/FlameshotLogo-FAL-1.3.txt)。
- 详细来源与许可见 [第三方声明](THIRD_PARTY.md)。

## 参与贡献

欢迎通过 [Issues](https://github.com/Word2VecT/flameshoter/issues) 报告问题或提出建议，也欢迎提交 Pull Request。

感谢 [Flameshot](https://github.com/flameshot-org/flameshot) 的原作者与贡献者。
