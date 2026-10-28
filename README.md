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

- 区域截图、多显示器和延时截图。
- 截图内标注：画笔、直线、箭头、形状、文字、序号与遮挡。
- 复制、保存、置顶和 macOS 系统分享。
- 保存和复制前自动无损优化 PNG，支持无损 WebP 保存，可在设置中关闭压缩优化。
- 简体中文、英文及可自定义的快捷键。
- Apple 原生 Liquid Glass 界面。

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

## 快捷键

以下为默认快捷键，可在设置中修改。

| 快捷键 | 操作 |
| --- | --- |
| ⌘⇧X | 全局区域截图 |
| P / D / A | 画笔 / 直线 / 箭头 |
| R / C / M | 矩形 / 椭圆 / 荧光笔 |
| T / N / B | 文字 / 序号 / 遮挡 |
| ⌘C / ⌘S / ⌘⇧S | 复制 / 保存 / 分享 |
| ⌘Z / ⌘⇧Z | 撤销 / 重做 |
| ⌘P | 置顶截图 |
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
