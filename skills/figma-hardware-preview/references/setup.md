# 安装与使用

## 首次安装

1. 向 Codex 发送下面这段话。安装后开启新对话，调用 `$figma-hardware-preview`。

   ```text
   使用 $skill-installer 安装 https://github.com/liry-go/codex-skills/tree/main/skills/figma-hardware-preview
   ```

2. 本机准备 Python 3.10+ 和 Android Platform Tools（`adb`）。样机需要 Android 10 或以上，使用 USB 数据线连接，并在样机上开启和授权 USB 调试。
3. 首次部署到一台样机时，Skill 会从 GitHub Release 下载固定版本的预览器，校验 SHA-256 后通过 ADB 安装。此步骤需要电脑能访问 GitHub。之后直接通过 USB 更新画面。
4. 需要从 Figma 直接读取时，将 [只读设置](figma-readonly.toml) 合并到当前使用的 Codex MCP 配置，按自己的账号授权访问目标文件，重新打开对话。用 `codex mcp get figma --json` 核对 `enabled_tools`，并确认当前对话实际暴露的 Figma 工具也在白名单内。当前对话如有额外的 Figma 连接器，应停用它或使用只配置了该白名单的环境。只提供本地导出图时可跳过这一步。

## 每次预览

在 Codex 中提供 Frame 链接或本地 PNG，并说明是否需要按钮反馈。

```text
使用 $figma-hardware-preview 把这个 Figma Frame 显示到 USB 样机上。
右侧操作区的按钮参考我提供的按压规范，保留各自原有样式。
```

以下命令从已安装的 Skill 目录运行。连接多台样机时，先用 `adb devices -l` 确认目标，并向每条设备命令传入 `--serial <序列号>`。

```sh
python3 scripts/preview.py pack --screen /path/to/frame.png --out /path/to/preview.zip
python3 scripts/preview.py deploy --bundle /path/to/preview.zip
python3 scripts/preview.py capture --out /path/to/device-screen.png
```

更新成功后预览器自动显示新图，退出后重新打开也会恢复最近一次成功加载的画面。已有本地 APK 时，也可通过 `python3 scripts/preview.py install --apk /path/to/figma-hardware-preview.apk` 手动安装。

按钮版本在 `pack` 时加上 `--buttons /path/to/buttons.json`。素材、预览包和实机截图应放在用户授权的本地工作目录。
