Flameshoter 0.1.3 使用苹果原生材料呈现截图选区，并清理 macOS 界面的遗留自绘样式。

- 整个选区使用 NSGlassEffectView 的 Clear 液态玻璃；未选中区域使用 NSVisualEffectView 的全屏毛玻璃材质。
- 高光、折射、模糊、外观和辅助功能行为交由 AppKit，移除 macOS 选区的 Qt 自绘边框。
- 选区尺寸文字移入原生玻璃内容层，避免边缘折射影响读数；导出仍是原始矩形像素与标注。
- 外部应用选择使用 NSOpenPanel，保存错误使用 NSAlert，置顶截图采用系统窗口阴影。
- 颜色预设采用 SF Symbols；被动帮助提示关闭交互玻璃效果。
- 继续复用 0.1.2 的固定发布证书，CI 检查身份，Homebrew 安装同一验证包。

从 0.1.1 及更早版本迁移到固定签名，需要重新允许一次屏幕录制权限。之后正常升级请勿主动重置权限。若旧授权导致截图失败，使用“设置 → 截图 → 修复屏幕录制授权…”，再按系统提示允许。

应用尚未经过 Apple 公证。首次打开仍可能需要在“系统设置 → 隐私与安全”中选择“仍要打开”。用户无需安装或信任项目证书。

支持 Apple Silicon，最低 macOS 26。包内包含 Qt、中文和英文界面，无需另装 Qt。

Homebrew: `brew install --cask Word2VecT/tap/flameshoter`

完整源代码及第三方许可见仓库。Linux、Windows 与 Intel 版本尚未作为本次发布包验证。
