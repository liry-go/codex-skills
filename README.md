# Codex Skills

可独立安装的 Codex 技能，供个人和团队在不同项目中复用。

## 技能

| 技能 | 用途 |
| --- | --- |
| [git-devsync](skills/git-devsync/SKILL.md) | 将功能分支尚未同步的提交增量 cherry-pick 到 `_devsync` 分支，处理冲突并验证后合入本地 `dev`，再返回原功能分支。 |
| [figma-hardware-preview](skills/figma-hardware-preview/SKILL.md) | 在 USB 连接的 Android 样机上预览指定 Figma Frame，可按设计范式加按钮按压反馈。 |

## 在 Codex 中安装

把下面这段话发送给 Codex：

```text
使用 $skill-installer 安装这个 GitHub 仓库中的 git-devsync 技能：
https://github.com/liry-go/codex-skills/tree/main/skills/git-devsync
```

安装对象是 `skills/git-devsync` 整个目录，包括 `SKILL.md`、`scripts/devsync.sh` 和 `agents/openai.yaml`。

安装后，在下一轮对话中使用技能。如果技能没有出现，重启 Codex。安装器会选择本机的技能目录，不需要手动替换用户名或安装路径。已有同名技能时，安装器会停止；请先检查并备份本地定制，再决定替换。

Codex 也支持把整个技能目录放到用户级 `~/.agents/skills/` 下。安装位置和发现机制见 [OpenAI 官方技能文档](https://learn.chatgpt.com/docs/build-skills)。

## 使用 git-devsync

在需要同步的项目中打开 Codex，先查看待同步提交：

```text
使用 $git-devsync 检查当前功能分支还有哪些提交尚未同步到 dev，先只执行 status。
```

确定要同步时：

```text
使用 $git-devsync 将当前功能分支的待同步提交同步到最新 dev；处理冲突并运行相关检查，通过后合入本地 dev，再返回当前功能分支。不要 push。
```

`status` 会 fetch 远端 `dev` 以刷新比较基准，但不会切换分支或执行 cherry-pick。完整流程见 [技能说明](skills/git-devsync/SKILL.md)。

### 运行条件

- 本地具备 Bash 和 Git（支持 `git switch`）。Windows 可在具备 Bash 和 Git 的环境中运行，例如 WSL。
- 对目标 Git 仓库及其远端有访问权限。
- 默认远端为 `origin`，集成分支为 `dev`；可通过 `--remote`、`--dev` 和 `--source-base` 指定不同配置。
- 同步和合回前工作区需要干净。遇到冲突时保留现场，解决并验证后继续。
- 技能不会自动 push；远端推送需要单独提出。

## 使用 figma-hardware-preview

在 Codex 中发送以下安装请求。

```text
使用 $skill-installer 安装 https://github.com/liry-go/codex-skills/tree/main/skills/figma-hardware-preview
```

样机首次安装 [Android 预览器 APK](https://github.com/liry-go/codex-skills/releases/tag/figma-hardware-preview-v1.0.0)。后续提供 Figma Frame 链接或本地 PNG 即可通过 USB 更新画面。默认静态展示，按需应用用户指定的按钮范式。Figma 工具必须限制在只读白名单内。详见 [安装和使用](skills/figma-hardware-preview/references/setup.md)。

预览器源码在 [android/figma-hardware-preview](android/figma-hardware-preview)。构建需要 JDK 17+、Android SDK 35 和 Build Tools 35.0.0。在该目录执行 `./gradlew :app:assembleRelease :app:lintRelease`。发布时用 Android SDK 的 `zipalign` 与 `apksigner` 对齐并签名 APK。升级沿用原发布签名。

## 更新技能

通过安装器安装的副本不会随着本仓库更新而自动更新。需要新版本时，可让 Codex 对比仓库版本与本机版本，保留本地定制后更新。

## 目录结构

```text
skills/
└── git-devsync/
    ├── SKILL.md
    ├── agents/openai.yaml
    └── scripts/devsync.sh
```

`figma-hardware-preview` 的 Skill 目录包含 `scripts/preview.py`、只读 MCP 配置与使用说明。Android 预览器独立发布。
