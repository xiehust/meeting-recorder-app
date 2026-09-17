# 会议记录应用图标

声波素材使用 [Lucide audio-lines](https://github.com/lucide-icons/lucide/blob/main/icons/audio-lines.svg)，2026-09-17 获取，遵循 [ISC 许可](LUCIDE-LICENSE)。随应用打包保留完整许可。青绿色背景、纸张和纪要线条是本项目的组合设计，没有使用会议软件的品牌图标。

原始素材为 `audio-lines.svg`；生成脚本读取其中的声波路径，使用 macOS Core Graphics 绘制图标，没有调用图像生成 API。

在项目根目录运行：

```sh
xcrun swift scripts/make-app-icon.swift
```

输出：

- `Resources/AppIcon.png`：1024 × 1024 透明边缘的主图。
- `Resources/AppIcon-preview.png`：256 × 256 预览。
- `Resources/AppIcon.icns`：16–1024 像素、含 Retina 的 macOS 图标。

`scripts/build-app.sh` 将 ICNS 和许可复制到应用包；`CFBundleIconFile` 指向 `AppIcon`，供 Finder 和 Dock 使用。菜单栏仍使用适配系统明暗外观的原有单色符号。
