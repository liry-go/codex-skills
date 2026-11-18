# 安装与使用

## 首次安装

1. 向 Codex 发送下面这段话。安装后开启新对话，调用 `$figma-hardware-preview`。

   ```text
   使用 $skill-installer 安装 https://github.com/liry-go/codex-skills/tree/main/skills/figma-hardware-preview
   ```

   如果本机没有 Python，请 Codex 用 Git 或 GitHub ZIP 下载整个 `skills/figma-hardware-preview` 目录，复制到本机 Codex 的 `skills` 目录（默认 `~/.codex/skills/`）。然后开启新对话。

2. 样机需要 Android 10 或以上。用 USB 数据线连接，并在样机上开启和授权 USB 调试。
3. 首次使用时，启动脚本会复用已有的 Python 3.10+ 和 adb。缺少时，脚本下载并校验便携版工具，存入当前用户缓存目录。首次部署到一台样机时，脚本还会从 GitHub Release 自动下载、校验并安装预览器。首次下载需要电脑能访问 GitHub 和 Google 的 Android SDK 下载站。
4. 需要从 Figma 直接读取时，可按 [只读配置示例](figma-readonly.toml) 设置 Codex MCP，并用自己的账号授权访问目标文件。启用的连接器如果要求文件会话，将 `create_session` 加到该连接器已有的工具白名单中。已有独立 MCP 配置时，可用 `codex mcp get figma --json` 核对 `enabled_tools`。配置生效后，确认当前对话实际暴露的 Figma 工具均在 [Skill 的只读白名单](../SKILL.md#figma-只读边界) 内。只提供本地导出图时可跳过这一步。

## 更新已有 Skill

已安装的副本需要手动更新。把下面的请求发给 Codex，让它先备份旧目录到 Skill 搜索路径之外，再安装 GitHub `main` 上的版本。完成后开启新对话。

```text
请更新已安装的 figma-hardware-preview。先把旧版目录备份到 Codex 的 skills 目录之外，再用 $skill-installer 安装 https://github.com/liry-go/codex-skills/tree/main/skills/figma-hardware-preview。安装失败时恢复旧版。
```

用 Figma 链接取图时，按首次安装的第 4 步核对生效的白名单。对要求文件会话的连接器，只给原白名单增加 `create_session`，然后重新加载 MCP。会话只用于读取用户指定的画板或素材。

## 静态快显

适用于已安装 Figma Hardware Preview 预览器的 USB 样机。新样机先走一次常规预览，让 Skill 安装预览器。在 Codex 里发送以下请求，并附上 Figma Frame 链接或本地 PNG。

```text
用 $figma-hardware-preview 静态快显这个画板，收到显示回执即可。
```

Figma 链接按 Skill 的只读边界取得对应 Frame 的 PNG。本地 PNG 可直接传给快显命令。从 Skill 目录运行：

```sh
sh scripts/preview.sh quick --screen /path/to/frame.png
```

Windows 下用 `powershell -NoProfile -File .\scripts\preview.ps1` 替换 `sh scripts/preview.sh`。若连接多台 USB 样机，加 `--serial <序列号>`。需要取一张实机截图时，加 `--capture /path/to/device-screen.png`，也可以事后单独运行 `capture`。快显收到预览器的成功回执便结束，只有传入 `--capture` 才会继续取图。

## 常规预览

在 Codex 中提供 Frame 链接或本地 PNG，并说明是否需要按钮反馈。

```text
使用 $figma-hardware-preview 把这个 Figma Frame 显示到 USB 样机上。
右侧操作区的按钮参考我提供的按压规范，保留各自原有样式。
```

以下命令从已安装的 Skill 目录运行。

```sh
sh scripts/preview.sh pack --screen /path/to/frame.png --out /path/to/preview.zip
sh scripts/preview.sh deploy --bundle /path/to/preview.zip
sh scripts/preview.sh capture --out /path/to/device-screen.png
```

Windows 下用 `powershell -NoProfile -File .\scripts\preview.ps1` 替换 `sh scripts/preview.sh`，后面的子命令和参数相同。连接多台样机时，脚本会列出可选序列号，指定 `--serial <序列号>` 后再部署。

自动准备 adb 覆盖 macOS、Windows 和 x86-64 Linux。Linux ARM 可复用系统自带的 adb。电脑系统的 USB 驱动或设备权限需满足 ADB 连接条件。

更新成功后预览器自动显示新图，退出后重新打开也会恢复最近一次成功加载的画面。已有本地 APK 时，也可通过启动脚本的 `install --apk /path/to/figma-hardware-preview.apk` 手动安装。

按钮版本在 `pack` 时加上 `--buttons /path/to/buttons.json`。素材、预览包和实机截图应放在用户授权的本地工作目录。
