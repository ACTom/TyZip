## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/` in this repo. That directory is **local-only** (gitignored, never published); see `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default label strings (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Layout is single-context: one `GLOSSARY.md` at the repo root, with architecture decisions in `docs/adr/`. See `docs/agents/domain.md`.

---

# TyZip

macOS 归档管理器（打开、浏览、创建、解压、预览、搜索压缩包）。Lazarus / Free Pascal + LCL Cocoa，界面用 TyControls；压缩引擎是仓库自带的 7-Zip 26.03，经 `backend/tz7z.cpp` 的 C ABI 桥梁调用。目标是 macOS 11+ 的 x86_64 与 arm64，GPL-3.0。

## 常用命令

```bash
tests/run_all.sh     # 构建应用 + engine/preview 两套测试；退出码 0 即通过
scripts/ci.sh        # 发布门禁：测试 + plist/shell 检查 + minos 11.0 + 打包 bin/TyZip.app；最后一行 CI OK
scripts/release.sh   # Release 构建 → dist/TyZip-<ver>-<arch>.zip；缺 arm64 交叉编译器时加 SKIP_ARM64=1
```

工具链只用 fpcupdeluxe（FPC 3.2.3 / Lazarus 4.8）；系统 FPC 和 brew 不参与构建。构建模式、发布配置、arm64 交叉、语言包与排错见 `docs/BUILDING.md`。

发布 GitHub Release 走 API：打 `v<version>` tag，建 release 正文取 `CHANGELOG.md` 对应版本段，再上传 `dist/TyZip-<ver>-<arch>.zip`。PAT 放在本机 `~/.config/tz/gh-token`（权限 600，只在本机、不进仓库，用户明确要求长期复用）。

## 按分支查文档

- 构建 / 测试 / 发布 / arm64 → `docs/BUILDING.md`
- 分层、单元职责、作业线程模型、7-Zip ABI → `docs/ARCHITECTURE.md`
- **改图标、平台、窗口、服务之前** → `docs/ARCHITECTURE.md` 的「平台与性能约束」
- 用户可见行为、安装、FAQ → `docs/USER-GUIDE.md`、`docs/FAQ.md`
- 架构决定 → `docs/adr/`；上游 TyControls 问题 → `docs/tycontrols-issues.md`
- 发版前手工验收 → `docs/qa-smoke.md`
- 研究快照 → `docs/research/`（可能滞后，以代码为准）
- 内部工单与交接 → `.scratch/`（只在本地，不入库）

## 硬约束

- 引擎、API、模型层（`tzip.engine`、`tzip.jobs`、`tzip.extract`、`tzip.search`、`tzip.api*`）不依赖 LCL；LCL 只出现在 UI 与 `tzip.main` 一侧。
- 7-Zip 只经由 `backend/tz7z.cpp` 的 C ABI 调用，`src/` 不启动 `7z` 命令行。
- UI 文案全部走 `tzip.i18n` 的 `rs*`；新增或修改文案时同步改 `languages/tzip.zh_CN.po` 并重建 `.mo`。
- 版本号唯一来源是 `packaging/version.txt`：`package_app.sh` 注入 Info.plist，About 读 bundle，tag 用 `v<version>`。
- 三份二进制（`TyZip`、`libtz7z.dylib`、`7z.so`）都按 minos 11.0 构建，`scripts/ci.sh` 的 `check_minos` 校验。
- NSWorkspace / IconServices 只在主线程调用；每 tick 的图标查询先过 `TzIconWorkAllowed` 门控。
- TyControls 事件语义按实现确认：`TTyTreeView` 单选树移动选中只发 `OnChange`；归档树绑定集中在 `tzip.ui.arctree`。

## 行为与提交

- 行为保持优先：文档与代码冲突时按现有行为改文档，只有行为本身是 bug 才改代码；为修 bug 的 LCL 绕行必须带注释和回归测试，腐蚀性补丁清理掉。
- 每个修复配一个先红后绿的回归测试；测试不依赖执行顺序、外部 GUI 或残留构建产物。
- 提交信息用英文祈使句，一个工单一个提交；只 `git add` 自己的文件，不 `commit -a`、不 amend。
- 文档用中文，代码标识符与提交信息用英文；与用户沟通用中文。
- 远端 `origin` = `git@github.com:ACTom/TyZip.git`，主分支 `main`；push 只在用户明确要求时做。
