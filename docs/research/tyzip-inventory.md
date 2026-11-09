# TyZip 代码级能力清单（盘点快照，用于 PeaZip 差距对比）

> **盘点快照（2026-10-29，commit `d7b8310`，打包版本 0.3.0），不是实时状态。**
> 票 25–27 的最终结构之后重新盘点：§1（架构/规模/ABI）、§8（测试）、预览前缀/批量状态机/arm64 与「新增/已删除单元」已按当前代码重测；更早章节的行号/数字仍来自 2026-10-27 原始盘点，会继续漂移。定位代码请用单元/函数名；判断现状以 `src/`、`backend/`、`tests/` 与 `README.md` 为准。

盘点对象：本仓库。**快照 commit `d7b8310`（快照时 `git describe` = `v0.2.0-12-gd7b8310`；`packaging/version.txt` = 0.3.0，最终 tag 由发布流程补）**：`src/` 46 个文件 24,617 行，`backend/` 3 个文件 3,431 行，`tests/` 55 个程序 14,608 行。

## 0. 口径、快照与证据

- **只读盘点**：不改源码/测试/构建产物；本次为 0.3.0 发布收口盘点，结构数字直接读源码与 `git show d7b8310:<path>`。
- **快照**：以 commit `d7b8310` 的树为准（票 13/16 结构拆分、票 20 预览 pane、票 21 API 四合一、票 23 搜索任务化、票 25 批量状态机、票 26 前缀预览、票 27 arm64 交叉构建已落地；ABI v3）。行号会继续漂移，**定位请用单元/函数名**。
- 统计口径：`wc -l`、`grep -c '^  rs' src/tzip.i18n.pas`、`git ls-tree -r d7b8310`；数字是代码行数（物理行）。
- 行号即“截至该快照”；「没有」的依据分三类：①菜单/对话框/工具栏清单里不存在；②全仓库 `grep` 无对应实现；③README「已知限制」声明 + 代码验证。
- 一次只读实测：`python3 ctypes` `dlopen("lib/7z.so")` 调 `GetNumberOfFormats`/`GetHandlerProperty2`，枚举本项目引擎实际注册的格式（不写文件）→ 见 §3.2。

---

## 1. 架构与规模

### 1.1 文件与行数（2026-10-29 快照，commit d7b8310）

| 层 | 文件（行数） | 合计 |
|---|---|---:|
| 入口 | `TyZip.lpr` (34) | 1 文件 / 34 |
| UI/窗口 | `tzip.main.pas` (7332)、`tzip.dialogs.pas` (1578)、`tzip.i18n.lcl.pas` (56)、`tzip.preview.pane.pas` (940)、`tzip.ui.arclist.pas` (138)、`tzip.ui.dialogkit.pas` (125)、`tzip.ui.fslist.pas` (228)、`tzip.ui.icons.pas` (546)、`tzip.ui.menu.pas` (332)、`tzip.ui.sidebartree.pas` (290) | 10 / 11,565 |
| 预览 | `tzip.preview.pas` (841)、`tzip.preview.syntax.pas` (1527)、`tzip.preview.session.pas` (226)、`tzip.preview.workers.pas` (300) | 4 / 2,894 |
| 控制器/状态（无 LCL） | `tzip.navstate.pas` (268)、`tzip.navpaths.pas` (74)、`tzip.iconstore.pas` (323)、`tzip.iconkeys.pas` (82)、`tzip.jobcontrol.pas` (198)、`tzip.jobqueue.pas` (162)、`tzip.commands.pas` (190)、`tzip.appcache.pas` (149)、`tzip.createopts.pas` (462)、`tzip.batch.pas` (337) | 10 / 2,245 |
| 引擎/模型 | `tzip.engine.pas` (1725)、`tzip.api.pas` (604)、`tzip.api.bind.pas` (316)、`tzip.api.errors.pas` (113)、`tzip.api.formats.pas` (92)、`tzip.jobs.pas` (1290)、`tzip.formats.pas` (340)、`tzip.arcpath.pas` (98)、`tzip.extract.pas` (322)、`tzip.search.pas` (247)、`tzip.rename.pas` (125)、`tzip.editwrite.pas` (125)、`tzip.presets.pas` (270)、`tzip.imageinfo.pas` (57) | 14 / 5,724 |
| 平台/i18n/设置 | `tzip.platform.pas` (338)、`tzip.platform_macos.pas` (553)、`tzip.i18n.pas` (488)、`tzip.settings.pas` (195)、`tzip.services_macos.pas` (193)、`tzip.passwords.pas` (194)、`tzip.passwordstore.pas` (194) | 7 / 2,155 |

合计：`src/` 46 文件 24,617 行；`backend/` 3 文件 3,431 行（`tz7z.cpp` 3,194、`tz7z.h` 237、`StdAfx.h` 0）；`tests/` 55 个程序 14,608 行。最大单文件是 `tzip.main.pas`（7,332 行），其次是 `tzip.engine.pas`（1,725）、`tzip.dialogs.pas`（1,578）与 `tzip.jobs.pas`（1,290）。

**新增单元（票 20/21/25）**：`tzip.api.bind`（ABI 记录/符号绑定）、`tzip.api.errors`（错误码分类/文案）、`tzip.api.formats`（格式表 JSON）从 `tzip.api.pas` 拆出；`tzip.preview.pane` 承接预览控件层；`tzip.batch` 承接批量解压状态机（逐包 list → resolve conflicts → extract，取消即停）。`tzip.jobs` 的 `TZJobKind` 增加 `jkSearch` 与 `TZJobSearchPayload`（票 23）。

**已删除单元（票 13/16）**：`tzip.queue.pas`（生产代码未使用的批量调度）与 `tzip.ui.dialogs.progress.pas`（遮罩层已取代）已删除。等待队列、批量汇总与密码重试现在在 `tzip.jobcontrol.pas` + `tzip.jobqueue.pas`；进度 UI 在 `tzip.main` 的遮罩卡片。

### 1.2 依赖与分层

- 图形：Lazarus/LCL（Cocoa）+ TyControls（UI 控件）+ SynEdit（预览）+ BGRABitmap（图像）。
- **分层（ADR 0001）**：UI → 控制器 → 引擎 → 桥接。UI = `tzip.main` / `tzip.dialogs` / `tzip.preview.pane` / `tzip.ui.*`；控制器（无 LCL）= `tzip.navstate`、`tzip.navpaths`、`tzip.iconstore`、`tzip.iconkeys`、`tzip.jobcontrol`、`tzip.jobqueue`、`tzip.commands`、`tzip.batch`、`tzip.preview.session`、`tzip.preview.workers`；引擎/模型 = `tzip.engine`、`tzip.api` 门面、`tzip.api.bind`/`tzip.api.errors`/`tzip.api.formats`、`tzip.formats`、`tzip.arcpath`、`tzip.extract`、`tzip.search`、`tzip.rename`、`tzip.editwrite`、`tzip.jobs`；桥接 = `tzip.api.bind` → `backend/tz7z.h`。
- 引擎：运行时 `dlopen` 桥接库（`libtz7z.dylib`）+ 官方 `7z.so`；候选路径含可执行文件旁、`.app/Contents/Frameworks`、源码树、`TYZIP_LIB`。
- **不调用 `7z`/`7zz` CLI**：`backend/tz7z.cpp` 直接用 `IInArchive`/`IOutArchive`/`ISetProperties` 等 COM 接口；`src/` 中唯一的 `TProcess` 是 `/usr/bin/open`（`tzip.platform_macos`）。
- 后台：耗时操作走 `TZJob` 线程，主线程定时器轮询；等待队列、批量 tally 与密码重试在 `TJobController`/`TJobQueue`。每个 `TZJobKind` 把输入放在自己的 payload record（`TZJobSearchPayload` 等），`TZJobExecutor` 读取 payload；`TZJob` 上的扁平字段只是兼容访问器。**同一时刻只允许一个压缩包作业**。

### 1.3 7-Zip C ABI 暴露面（`backend/tz7z.h`，ABI v3）

头文件导出 **18 个函数**；FPC 侧 `tzip.api.bind` 绑定其中 **17 个**（`tzip.api.pas` 只是转发门面；写注释走 `tz7z_modify` 的 `comment`/`has_comment` 字段，不单独绑定 `tz7z_set_comment`）。

| 类别 | 函数 |
|---|---|
| 版本/格式 | `tz7z_abi_version`、`tz7z_format_json` |
| 打开/关闭 | `tz7z_open`、`tz7z_close`、`tz7z_entry_count`、`tz7z_format_name`、`tz7z_has_encrypted`、`tz7z_can_update` |
| 条目 | `tz7z_entry_name`、`tz7z_entry_info_get` |
| 注释 | `tz7z_comment`、`tz7z_set_comment`（写入只支持 zip） |
| 解压/测试 | `tz7z_extract`、`tz7z_test`、`tz7z_extract_one`、`tz7z_extract_one_prefix`（ABI v3，解到 max_bytes 即停） |
| 创建/修改 | `tz7z_create`、`tz7z_modify` |
| 回调 | `tz7z_progress_fn`（返回 0 = 取消） |
| 错误码 | `TZ7Z_E_*` 共 11 个（-1..-11） |
| 结构体 | `tz7z_entry_info`、`tz7z_input`、`tz7z_create_options`，均以 `struct_size` + `abi_version` 开头 |

**ABI v3 变化**：新增 `tz7z_extract_one_prefix`（有界前缀解压，供文本/未知类型预览只解 2 MB）；结构体布局与 v2 一致。**ABI v2 变化**：删除 `tz7z_set_password`（无调用者；密码只经 `tz7z_open`/`tz7z_extract`/`tz7z_test`/`tz7z_modify` 的参数传递）。加载器必须先比较 `tz7z_abi_version()`，结构体版本不符会被库以 `TZ7Z_E_ARG` 拒绝，而不是写坏调用方的内存。

**没有**的桥接能力：哈希、属性写入、恢复记录、SFX、按条目的属性编辑。**注释与转换已有**：注释通过 `tz7z_comment` 读、通过 `tz7z_modify` 的 `comment` 字段写（只支持 zip；7z 可读）；转换由 UI 用「解出 + 重新创建」实现（`TzConvertArchive`），不需要新增桥接函数。`tz7z_open` 仍无 codepage 参数——读取旧代码页 ZIP 名称不可配置，只有创建时有 `codepage` 字段。

### 1.4 数据流

`TyZip.lpr` → `TMainForm`（`tzip.main.pas`）→ 控制器（`tzip.commands`、`tzip.jobcontrol`、`tzip.jobqueue`、`tzip.batch`、`tzip.navstate`、`tzip.iconstore`、`tzip.preview.*`）→ `TZJob`（`tzip.jobs.pas`，按 kind 取 payload）→ `TArchiveContext`/`TzListEntries`/`TzListArchiveByPath`（`tzip.engine.pas`）→ `TZ7Z*`/`Tz*`（`tzip.api.pas` 门面 + `tzip.api.bind` 的 ABI 结构/符号）→ `tz7z_*`（`backend/tz7z.cpp`）→ `7z.so`。UI 不直接调用 7-Zip。

---

## 2. 界面动作清单

### 2.1 主菜单

**macOS**：主菜单栏只有 File / Edit / Go / View；About / Settings… / Language 由 LCL Cocoa 的**应用菜单**承载（`tzip.ui.menu.pas` 的 `BuildAppMenu` 设置 `CocoaConfigMenu.appMenu`，原生子菜单由 `TAppMenuHook.Created` 挂接）。**Windows/Linux 构建**才会创建 Tools（Settings、Language）+ Help（About）菜单（同函数 `{$ELSE}` 分支）。

| 菜单 | 动作 | 处理函数 | 快捷键（快照行号） |
|---|---|---|---|
| File | New Archive… | `MenuNewClick` | ⌘N（:2876） |
| File | Open Archive… | `MenuOpenClick` | ⌘O（:2877） |
| File | Close Archive | `MenuCloseArchiveClick` | 无（:2878） |
| File | Extract… | `MenuExtractClick` | 无（:2880） |
| File | Test Archive | `MenuTestClick` | 无（:2881） |
| File | Archive Information | `MenuInfoClick` | 无（:2882） |
| File | Convert to Another Format… | `MenuConvertClick` | 无 |
| File | Extract All Selected | `MenuExtractAllClick` | 无 |
| File | Exit | `MenuExitClick` | ⌘Q（:2884） |
| Edit | Select All | `MenuSelectAllClick` | ⌘A（:2889） |
| Edit | Delete | `MenuDeleteClick` | Delete（:2890） |
| Edit | Add Files… | `AddClick` | 无（:2891） |
| Edit | Add Folder… | `MenuAddFolderClick` | 无（:2892） |
| Edit | Find in Archive… | `SearchClick` | ⌘F |
| Edit | Clear Search | `ClearSearchClick` | 无 |
| Go | Back | `MenuBackClick` | ⌘←（:2897） |
| Go | Forward | `MenuForwardClick` | ⌘→（:2898） |
| Go | Enclosing Folder | `MenuUpClick` | ⌘↑（:2899） |
| Go | Refresh | `MenuRefreshClick` | **无快捷键**（:2900） |
| View | Show Hidden Files（AutoCheck） | `MenuShowHiddenClick` | 无（:2905-2907） |
| View | Sidebar（AutoCheck，默认关） | `MenuSidebarClick` | 无（:2909-2911） |
| View | Preview Pane（AutoCheck，默认开） | `MenuPreviewClick` | 无（:2912-2914） |
| View | Theme ▸ | `BuildThemeMenus` | 无（:2917-2919） |
| View | Appearance ▸（系统/浅色/深色） | `BuildThemeMenus` | 无（:2920-2923） |
| 应用菜单（仅 macOS） | About TyZip / Settings…（Cmd+,）/ Language ▸ | `MenuAboutClick` / `MenuSettingsClick` / `MenuLanguageClick` | Cmd+, 由 widgetset 绑定（:2969-2990） |
| Tools（仅非 macOS） | Settings… / Language ▸ | 同上 | 无（:2992-2995） |
| Help（仅非 macOS） | About TyZip | `MenuAboutClick` | 无（:2996-2998） |

### 2.2 工具栏与导航栏（`main.pas:BuildUi`，快照行号）

| 区域 | 控件/动作 | 行号 |
|---|---|---|
| 工具栏（图标在上、文字在下） | New / Open / ─ / Extract / Test / ─ / Add / Delete / Info / Convert | :1899-1930 |
| 导航栏 | Back / Forward / Up | :1822 起 |
| 导航栏 | 可编辑面包屑（双击切换文本框） | :1855 起、`:BreadcrumbDblClick`（:4367） |
| 导航栏 | 名称过滤框（固定右侧） | `FFilterEdit`（:1840 附近）、`FilterChange`（:6125） |
| 导航栏 | 预览窗格显示/隐藏按钮 | `CreatePathButton(FPreviewToggleBtn…)`（:1855）、`ApplyPreviewVisibility`（:7077） |
| 状态栏 | 条目数/选中数/大小/状态 | `FStatus`（:1931）、`UpdateStatus`（:6066） |
| 预览底栏 | 编码下拉、Wrap、Syntax、1:1、±、Fit | `FPreviewBar`（:2069） |

### 2.3 右键菜单（`BuildFsPopup` / `FsPopupPopup` / `ArcPopupPopup`）

> 现状（2026-10-28）：两个列表都有右键菜单。旧快照里「压缩包条目列表没有右键菜单」已失效——`BuildFsPopup` 会创建 `FArcPopup`，在 `BuildArchivePane` 里挂到 `FArcList`，由 `ArcPopupPopup` 填充。

**文件列表**（`FsPopupPopup`）：

| 项 | 条件 |
|---|---|
| Open / Open With ▸ / Show in Finder / Copy Path | 有选中 |
| Open as Archive | 选中项是文件 |
| Extract Here | 选中项是已识别的压缩包 |
| Create Archive / Add to <name>.7z | 单选（多选时标题变为“Add N Selected…”） |
| Create Each / Add Selected… | 多选 |
| Convert | 单选且是压缩包 |
| 批量解压（到目录/原地/各自文件夹）、Test All | 选区里至少一个压缩包 |
| Refresh | 没有选中项时只显示这一项 |

**压缩包条目列表**（`ArcPopupPopup`）：

| 项 | 条件 |
|---|---|
| Extract / Extract Here / Open | 有选中（Extract Here 仅文件条目） |
| Archive Comment… | 有选中 |
| Rename | 选中文件条目（文件夹不支持） |
| Copy Path | 有选中 |
| Test | 总是 |
| Delete | 有选中且当前归档可更新 |

空白处右键只显示 Extract 与 Test。

### 2.4 实际快捷键

菜单快捷键在 `tzip.ui.menu.pas` 的 `BuildAppMenu` 中集中定义：⌘N、⌘O、⌘Q、⌘A、Delete、⌘F、⌘←、⌘→、⌘↑；Refresh 没有快捷键。键处理（`FormKeyDown` / `ArcKeyDown`）另有 Return 打开、Esc 退出压缩包、Backspace 在压缩包列表返回上级。macOS 上 Settings 的 ⌘, 由 Cocoa 应用菜单提供。

README 的「界面与快捷键」已按当前菜单重写：删除了不存在的 ⌘[ / ⌘] / ⌘R，补上 ⌘F、⌘Q、Esc 与 Settings 的 ⌘,。

### 2.5 README 未写的动作/选项

- Edit → Add Folder…（:2892）与工具栏 Add（只加文件）。
- 拖入文件到**已打开的压缩包窗口** = 添加，带确认与 replace/skip 冲突选择（`AddDroppedFiles`）。
- 文件列表 F2 就地重命名（TyControls 提供，见 §4.3）——README 未提。
- 新建压缩包高级页：字典大小、match finder、P-word（PPMd 字长）、passes、额外参数（`dialogs.pas:770-832`），以及 ZIP 名称编码（:714-721）、归档后删除源文件（:676）。
- 右键 Open as Archive / Extract Here（README 有提，但主菜单没有对应项）。
- 外部打开多个文件时每文件开一个新进程（`TzOpenInNewInstance`，`platform_macos.pas:245-283`）。
- macOS 应用菜单集成（About/Settings/Language 的 HIG 位置与 Cmd+,）——README 现已写成「设置 → 语言 或 macOS 应用菜单 → Language」。

---

## 3. 压缩包能力

### 3.1 操作矩阵（全部经 `tz7z_*`）

| 操作 | 有/无 | 实现与依据 |
|---|---|---|
| 打开（自动识别格式） | 有 | `TzOpenContext`（`engine.pas:794-935`）；按扩展名优先、再逐个 handler 尝试（`tz7z.cpp:1177-1266`） |
| 列举/虚拟目录 | 有 | `TzListEntries`（`engine.pas:594-762`）；目录树由条目路径推导（`main.pas:PopulateArchiveTree` :4592）；文件夹行合计大小/压缩后大小 |
| 测试（整包/选中） | 有 | `DoTest`（:6615）；`tz7z_test` → 7-Zip `Extract(..., testMode)`（`tz7z.cpp:1500-1506,1414-1468`） |
| 解压全部 | 有 | `DoExtract(False)`（:6577）；未选中时取全部 |
| 解压选中（目录自动展开） | 有 | `TzSelectedIndices`（`engine.pas:948-992`） |
| 解出单个条目（预览/双击打开） | 有 | `tz7z_extract_one`；后台线程 `TPreviewLoaderThread` 在 `tzip.preview.workers` |
| Extract Here（文件列表右键） | 有 | `ExtractArchiveHere`（:3237） |
| 创建压缩包 | 有 | `NewClick`（:6453）→ `TNewArchiveDialog`（`dialogs.pas:609-850`）→ `DoCreateArchive`（:6511）→ `TzCreateArchive`（`engine.pas:1190-1246`） |
| 添加文件 | 有 | `DoAddFiles`（:6790）→ `tz7z_modify` |
| 添加文件夹 | 有 | `DoAddFolder`（:6834） |
| 删除条目 | 有 | `DoDeleteEntries`（:6871），默认需确认（`Settings.ConfirmDelete`） |
| 修改已有条目 | 有 | 独立路径：编辑回写、条目重命名、压缩包注释；普通替换仍可用“添加同名路径”。拖放冲突时可选 Replace/Skip（`AddDroppedFiles`），Add Files 对话框仍无冲突提示 |
| 查看压缩包信息 | 有 | `TArchiveInfoForm`（`dialogs.pas:1337-1445`）：名称/来源/格式/条目数/解压后大小/压缩后大小/压缩比/是否加密/是否可更新/是否嵌套/打开位置/嵌套链 |
| 关闭压缩包 | 有 | File→Close（:2878），返回 `OpenedFromFs` |
| 压缩包内重命名 | 有 | 条目列表右键 Rename → `DoRenameEntry`（`tzip.rename.pas` 校验重名/非法名）→ `jkRename`；只支持文件条目，文件夹拒绝 |
| 压缩包内移动/复制条目 | **无** | 没有移动/复制命令 |
| 从压缩包内条目创建新压缩包 | **无** | 明确拒绝：`rsErrArchiveOnlyInFiles`（`main.pas:NewClick`，字符串 `i18n.pas:253`） |
| 增量更新（只写变更） | **无** | `tz7z_modify` 总是读旧条目 + 写**同级临时文件**再 `rename`（`tz7z.cpp:1978-2095`），整包重写 |

### 3.2 格式支持（代码事实 + 引擎实测）

UI **不硬编码**可读格式列表：`TzLoadFormats` 运行时从 `tz7z_format_json` 取得；文件类型识别来自 `tzip.formats.pas` 的单一扩展名表（读/创建/是否包装由每行声明）。

**实测本项目 `lib/7z.so`：注册 handler 60 个，其中可写（`update=true`）7 个**（`dlopen` + `GetNumberOfFormats`/`GetHandlerProperty2`）：

| 类别 | 格式（handler 名） |
|---|---|
| 可创建（7） | `7z`、`zip`、`tar`、`gzip`、`bzip2`、`xz`、`wim` |
| 只读归档/容器（节选，均实测存在） | `rar`/`Rar5`、`cab`、`iso`、`udf`、`dmg`、`chm`/`Hxs`、`nsis`、`cpio`、`ar`（含 deb/udeb/lib）、`rpm`、`cramfs`、`squashfs`、`ext2/3/4`、`fat`、`hfs/hfsx`、`ntfs`、`apfs`、`apm`、`gpt`/`mbr`、`vhd/vhdx/vdi/vmdk/qcow`、`macho`/`pe`/`coff`/`te`/`elf`、`swf`、`xar`、`arj`、`lzh/lha`、`base64`、`ihex`、`sparse`、`split`、`flv`、`mub`、`lp`、`uefi` |
| 只读压缩流 | `gzip`、`bzip2`、`xz`、`zstd`、`lzma`/`lzma86`、`Z`、`Ppmd`、`MsLZ` |
| 引擎**没有**（因此打不开/建不了） | `pea`/`pei`、`zpaq`、`arc`（ARC，不是 Unix ar）、`lz4`、`brotli`、`freearc`、`ace`（7-Zip 26.03 Format7zF 未含这些 handler）；RAR 可读不可写 |

创建对话框只列出 `update=true` 的格式，按偏好排序 `7z, zip, tar, gzip, bzip2, xz, wim`，其余可写格式追加在后（`dialogs.pas:534-538,642-651`）；注释写明“7-Zip 只能创建这七种”（:511-513）。

应用层识别为“压缩包”的扩展名（单一表 `tzip.formats.pas`）：7z zip rar tar gz tgz bz2 tbz2 xz txz lzma zst cab iso dmg arj lzh lha cpio rpm deb apk jar war ear whl xpi msi doc xls ppt img wim 001 002 z lz，以及 ZIP 容器文档 docx/docm/dotx/dotm/xlsx/xlsm/xltx/xltm/pptx/pptm/potx/potm/ppsx/ppsm/odt/ods/odp/odg/epub。Office/ODF 默认双击交给系统关联程序，右键 Open as Archive 才进容器（`tzip.formats.pas` 的 `TzIsDocumentName`；`tzip.main` 的 `IsArchiveForDefaultOpen`）。

`Info.plist` 注册文档类型：归档类 31 个扩展名 + ZIP 文档类 22 个扩展名（`packaging/Info.plist:9-89`）。

### 3.3 创建参数（对话框 → API → 7-Zip 属性）

| 参数 | UI 取值 | 适用格式 | 后端属性 | 依据 |
|---|---|---|---|---|
| 格式 | 上述 7 个可写格式 | — | handler 名 | `dialogs.pas:642-651` |
| 级别 | Store/Fastest/Fast/Normal/Maximum/Ultra → 0/1/3/5/7/9 | 7z/zip/wim/gzip/bzip2/xz（tar 无） | `x` | `dialogs.pas:678-684,1083`；`tz7z.cpp:1565-1571` |
| 方法 | 7z: LZMA2/LZMA/PPMd/BZip2/Deflate/Copy；zip: Deflate/Deflate64/BZip2/LZMA/PPMd/Copy；wim: LZX/XPRESS/Copy | 有 method 的格式 | `m` | `dialogs.pas:993-1018`；`tz7z.cpp:1572-1579` |
| 固实块 | 勾选框（默认开） | 仅 7z | `s` | `dialogs.pas:578,693-695,963`；`tz7z.cpp:1583-1589` |
| 线程 | 0–64，0=自动 | 有级别的格式 | `mt` | `dialogs.pas:770-778`；`tz7z.cpp:1580-1582` |
| 密码 | 密码 + 确认 + 显示 | 7z/zip | 密码回调 | `dialogs.pas:730-747` |
| 7z 加密文件名 | 勾选框 | 仅 7z | `he=true` | `dialogs.pas:748-750,963`；`tz7z.cpp:1590-1596` |
| ZIP AES-256 | 勾选框（有密码才显示） | 仅 zip | `em=AES256` | `dialogs.pas:751-753`；`tz7z.cpp:1597-1604` |
| 分卷大小 | Single/100 MB/700 MB/1 GB/4 GB/16 GB/50 GB | 仅 7z/zip | `CMultiOutStream` 写 `.001`… | `dialogs.pas:700-706,1084`；`tz7z.cpp:1849-1875` |
| ZIP 名称编码 | Auto(UTF-8)/UTF-8/GBK/GB18030/Shift-JIS/Latin-1 | 仅 zip | `cp` + `cl`/`cu` | `dialogs.pas:714-721,1086`；`tz7z.cpp:1669-1701` |
| 字典大小 | 1 MB–1 GB，11 档 | LZMA/LZMA2/PPMd | `d` | `dialogs.pas:540-558,785-788`；`tz7z.cpp:1607-1625` |
| Match finder | bt4/bt3/bt2/hc4 | LZMA/LZMA2 | `mf` | `dialogs.pas:793-797`；`tz7z.cpp:1637-1643` |
| PPMd 字长 | 16/32/64/128/256 | PPMd | `o` | `dialogs.pas:802-807`；`tz7z.cpp:1626-1632` |
| Passes | 1–256，默认 32 | BZip2/Deflate | `pass` | `dialogs.pas:819,1133`；`tz7z.cpp:1644-1660` |
| 额外参数 | 原始 `name=value:...` | 全部 | 逐对 `SetProperties`；保留键被过滤；失败会剔除后重试 | `dialogs.pas:825-832`；`tz7z.cpp:1703-1748` |
| 归档后删除源文件 | 勾选框 | 全部 | 调用方 `TzDeleteSources`（引擎不删） | `dialogs.pas:676,1108`；`engine.pas:1139-1188` |
| RAM 估算提示 | 只读标签，超物理内存变红 | LZMA 字典 | 仅提示 | `dialogs.pas:1049-1075`；`platform_macos.pas:384-397` |

补充：
- tar 会清空压缩相关参数，避免 handler 以 `E_INVALIDARG` 拒绝整个任务（`engine.pas:1091-1109`；测试 `tests/api_formats.pas:412-418`）。
- 单流格式（gzip/bzip2/xz）对目录/多文件自动改为 `.tar.gz/.tar.bz2/.tar.xz`：先打 tar，再压成单流（`engine.pas:1081-1089,1190-1246`；UI 后缀 `dialogs.pas:874-917`）。`.tar.zst/.tar.lzma` 可读可解，但**不能创建**（zstd/lzma 不可写）。
- `FormatCaps` 对未知可写格式一律按“单流、只有级别”处理（`dialogs.pas:596-601`）。

### 3.4 加密与密码

| 能力 | 有/无/部分 | 依据 |
|---|---|---|
| 7z 加密文件内容 | 有 | 密码经 `ICryptoGetTextPassword`（`tz7z.cpp:930-947,1119-1133`） |
| 7z 加密文件名 | 有 | `he=true`（`tz7z.cpp:1590-1596`）；无密码打开返回 `E_PASSWORD`（:1256-1259），`api.pas:545-551` 归类为密码错误 |
| ZIP AES-256 | 有 | `em=AES256`；不上勾走 ZipCrypto（`tz7z.cpp:1597-1604`） |
| ZIP ZipCrypto | 有（默认） | 同上 |
| 打开加密包时提示密码 | 有 | `CompleteJob` 收到 `TZ7Z_E_PASSWORD`（:5865）→ `RestartJobWithPassword`（:5821；`dialogs.pas:312-326`） |
| 错误密码重试 | 有 | `RestartJobWithPassword` 克隆 job 以新密码重跑；`TZJob.Clone`（`jobs.pas`） |
| 解压/测试时用密码 | 有 | `DoExtract` 传 `Pw`；`DoTest` 传 `FCtx.Password` |
| 密码持久化/密码管理器 | **部分** | `tzip.passwordstore.pas` 用 `/usr/bin/security` 把密码存进 macOS Keychain（`TzPasswordStore`，打开/解压/转换时 `RememberedPassword` 取回）；不是 PeaZip 那种多包管理器，Keychain 失败时静默降级为仅内存密码 |
| 按条目不同密码 | **无** | 单一密码作用于整个作业（`tz7z_extract/test` 只有一个 password 参数） |
| 加密算法选择（AES-128/256 等） | **无** | 7z 用引擎默认；UI 无算法选项 |

### 3.5 分卷

| 能力 | 状态 | 依据 |
|---|---|---|
| 创建分卷 | 有（7z/zip） | `tz7z.cpp:1849-1875`：`CMultiOutStream`，文件名 `.001/.002…` |
| 打开分卷 | 有，**仅当路径以 `.001` 结尾** | `OpenInputVolumes`（`tz7z.cpp:1135-1176`）；UI 创建后自动打开 `.001`（`main.pas:6003`） |
| 直接更新已分卷压缩包 | **有保护（已修）** | 现状（2026-10-28）：`CheckArchiveWritable` 用 `TzIsSplitArchivePart` 拒绝更新并提示 `rsErrSplitArchiveReadOnly`；`rsErrSplitUpdate` 已不再引用。只读打开仍支持 `.001` |
| 分卷大小选项完整性 | **已修** | 现状（2026-10-28）：`Vol[0..6]` 与 7 个选项一一对应，并加了 `Assert(FVolume.Items.Count = Length(Vol))`；ZIP 代码页 `Cp[]` 同样对齐 |

### 3.6 双层格式、嵌套下钻与只读限制

| 能力 | 状态 | 依据 |
|---|---|---|
| `.tar.gz/.tgz/.tar.bz2/.tar.xz/.tar.zst/...` 自动解出内层 tar 并打开 | 有，最多 8 层 | 解包循环 `while IsWrapper`（`engine.pas:854-923`），深度上限 :877-887；容器后缀推导 :394-413 |
| 纯压缩流单条目命名 | 有 | 单条目无名时用去掉压缩扩展名的内层名（`engine.pas:226-277,492-493`） |
| 只对“纯压缩流”继续下钻 | 有 | `TzIsPureCompression`（:785-792）、停止条件 :888-902 |
| 内层压缩包双击继续下钻 | 有 | `ArcItemActivate`（:5252）：解出到临时目录再打开为嵌套上下文 |
| 嵌套/双层内部只读 | 有 | `TArchiveContext.CanUpdate`（`engine.pas:508-511`）；`CheckArchiveWritable`（:6636）报 `rsErrNestedReadOnly` |
| 临时文件清理 | 有 | `TemporarySource` 析构删除（`engine.pas:458-464`）；退出删临时根（`main.pas:TzDeleteTempRoot` :5020） |
| Office/ODF 文档默认按文档打开 | 有 | `TzIsDocumentName`（`tzip.formats.pas`）、`IsArchiveForDefaultOpen`（`tzip.main`） |

### 3.7 解压行为与其他限制

- 解压对话框已有：目标目录、快捷目的地（桌面/下载/文档等）、智能子文件夹（以包名建子目录）、冲突策略（覆盖/跳过/重命名）、解压后删除源包、密码（仅加密包显示）、完成后打开目录（`src/tzip.extract.pas` + `dialogs.pas` 的 `TExtractDialogForm`）。旧快照的「没有覆盖策略/智能子文件夹/快捷目的地」已失效。
- 解压由 `SafeJoin` 防目录穿越（`tz7z.cpp:241-283`），并恢复 Unix mode 与 mtime（:846-930）；同名文件按对话框的冲突策略处理（默认重命名，可选覆盖/跳过）。
- ZIP 旧代码页名称：**写入**可选 GBK/GB18030/Shift-JIS/Latin-1（`dialogs.pas:714-721`、`tz7z.cpp:1669-1701`），**读取**无 codepage 参数（`tz7z.h:103-105`），只能依赖引擎自动判断。
- RAR：只能读/测试/解压（实测 `Rar`/`Rar5` update=false）；不能创建或更新（README「已知限制」）。
- 压缩包注释（现状 2026-10-28）：归档级注释可由 `tz7z_comment` 读取、由 `tz7z_set_comment` 写入（写入通过重写 ZIP EOCD 实现，只支持 zip；7z 可读）；UI 有 `ShowCommentDialog` 与 `ShowArchiveComment`/`SaveArchiveComment`，可写格式可编辑保存，嵌套/只读格式只读。条目级 comment 仍只读进模型、不在列表显示。
- 修复/恢复记录：无（桥接无相关属性设置）。

---

## 4. 文件管理与浏览

### 4.1 已有能力

| 能力 | 实现与依据 |
|---|---|
| 文件系统列表 | TyControls `TTyShellListView`（子类 `TZipShellListView`，`main.pas:143-185`）；默认 4 列 Name/Size/Type/Modified（TyControls `source/tyControls.ShellListView.pas:496-512`） |
| 表头排序（升/降） | TyControls 内建（`source/tyControls.ListView.pas:3894-3908`）；文件夹优先 `FoldersFirst`（`main.pas:2238` 附近） |
| 固定首行 `..` | 两个列表都插合成父行（`main.pas:ApplyListing` :4823、`TZipShellListView` 方法组） |
| 名称过滤（当前文件夹） | `FilterChange`/`RefreshFilter`（:6125/:6149 附近）；不递归、无内容搜索、无正则 |
| 面包屑 | FS：`UpdateBreadcrumbFs`（:4308）；压缩包：文件系统路径 + 包名 + 包内目录（`UpdateBreadcrumbArchive` :4937） |
| 可编辑地址栏 | 双击面包屑（`BreadcrumbDblClick` :4367）；`NavigatePathText`（:4427）支持绝对路径、`~`、相对路径、压缩包路径、包内目录（如 `.../file.zip/docs/`） |
| 后退/前进/上级 | 状态栈 `PushBack`/`ApplyState`（:5343/:5393）；刷新 :5479 |
| 侧边栏 | 文件树（自绘，避免启动扫描 `/Volumes`，`main.pas:201-235,1937-1967`）；压缩包模式切换为虚拟目录树（:1969-1988,4592）；无收藏/书签/“位置”列表 |
| 预览——文本 | SynEdit 只读、行号、可选中、语法高亮（`tzip.preview`/`tzip.preview.syntax`）、Wrap、编码切换；分类与限制在 `tzip.preview.session`（显示上限 2 MB，超出标注截断；归档文本/未知类型用 `tz7z_extract_one_prefix` 只解前缀，不再按大小拒绝） |
| 预览——图片 | BGRABitmap；扩展名分类/缩放算术在 `tzip.preview.session`，像素预算在 `tzip.imageinfo`，后台解码在 `tzip.preview.workers` 的 `TImageLoadThread`；压缩上限 32 MB |
| 预览——压缩包条目 | 后台解出到临时文件再预览；加密条目拒绝预览（`PreviewArchiveItem` :4252） |
| 系统图标 | PNG 缓存与平台解析在 `tzip.ui.icons`（`TIconCache`/`TIconLoaderThread`/`IconCachedPx`），槽位/队列/过期规则在 `tzip.iconstore`+`tzip.iconkeys`；`tzip.platform_macos.pas` 提供 `TzMacSystemIcon`；`@none` 处理无扩展名 |
| 主题 | TyControls 内置 17 套（`default` + `system` + 15 个 skin，TyControls `tyControls.BuiltinThemeData.pas:5999`），另有 系统/浅色/深色；即时切换并持久化（`ApplyTheme` :7103 / `ApplyMode` :7114） |
| 设置持久化 | 主题、模式、语言、显示隐藏、文件夹优先、删除确认、解压目录、解压后打开、侧边栏/预览显示与宽度、默认格式（`SaveSettings` :7124 / `LoadSettings` :7154；ini 在 `~/.config/TyZip/TyZip.ini`，`i18n.pas:319-322`） |
| 状态栏/动作禁用 | 条目数/选中数/大小/格式/加密标记（`UpdateStatus` :6066 / `UpdateActions` :6094）；作业运行时写操作按钮临时禁用 |
| 键盘导航 | Return 打开、Esc 退出压缩包、Backspace 上一级、Delete 删除条目（`FormKeyDown` :6210、`ArcKeyDown` :5306） |

### 4.2 明确没有的文件管理动作

依据：主菜单（§2.1）、两个列表的右键菜单（§2.3）与全仓库 grep。旧快照里「压缩包条目列表无右键菜单」已失效。

| 动作 | 结论 | 依据 |
|---|---|---|
| 新建文件夹 | 无 | 无菜单项/右键项；`grep -rn "CreateDir\|NewFolder"` = 0（只有 `ForceDirectories` 用于解压目标/临时目录） |
| 重命名（文件系统） | **部分**（仅 F2） | TyControls `TTyCustomShellListView.CommitEdit` → `RenameFileUTF8`（`TyControls/source/tyControls.ShellListView.pas:842-866`）；F2 由 TyControls ListView 处理（`source/tyControls.ListView.pas:4201-4209`）；应用 `FFsList.ReadOnly := False`（`main.pas` FsList 属性块）→ 可在磁盘上重命名。**无菜单/右键/快捷键说明**，README 未写 |
| 重命名（压缩包内） | **有（文件条目）** | 右键 Rename → `DoRenameEntry` → `jkRename`；文件夹条目拒绝 |
| 删除文件（磁盘） | 无 | Delete 键只在压缩包模式生效（`FormKeyDown`）；TyControls 列表无删除实现 |
| 复制/移动/粘贴（磁盘文件） | 无 | `Clipboard` 只用于 Copy Path（`FsPopupCopyPathClick`）；无 MoveFile/CopyFile 文件操作（唯一 `CopyFile` 在 `i18n.pas:339`，用于迁移旧配置） |
| 批量重命名 | 无 | 无对话框/菜单；grep 无实现 |
| 搜索（文件名/内容） | **部分** | `SearchClick` → `ShowSearchDialog`；`TzSearchListing` 跨目录按名称扫描；内容匹配函数在 `tzip.search.pas`，engine 列表尚未接线（票 08） |
| 标签/书签/收藏 | 无 | grep `tag/bookmark` 无相关实现（`Tag` 仅菜单项编号） |
| 队列/批量任务 | **有** | 文件列表多选后的批量解压走 `tzip.batch` 状态机（逐包 list→resolve→extract，skip/rename/overwrite 逐包生效、取消即停），批量测试走 `TJobController`/`TJobQueue`；同一时刻仍只有一个 7-Zip 作业 |
| 拖出（拖到 Finder/桌面） | 无 | 只注册 `OnDropFiles`（`main.pas` 构造函数），无拖出源 |
| 多窗口/标签页 | 无 | 单主窗体；外部多文件打开时每文件起独立进程（`platform_macos.pas:245-283`） |
| 属性/权限编辑 | 无 | Attributes 列只读（`ArcCellText` + `TzArcAttrText` :5086 附近） |
| 在压缩包内复制/移动条目 | 无 | 只有重命名，没有复制/移动命令 |

### 4.3 重命名的细节

- 文件系统列表：`TZipShellListView.CommitEdit` 把行号偏移 1 后交给 TyControls；TyControls 在 F2 时 `BeginEdit` 并在提交时调用 `RenameFileUTF8`，只允许叶子名（拒绝 `/`、`\`）。磁盘生效并刷新；没有菜单/右键入口，README 未单独说明。
- 压缩包条目列表：右键 Rename 是独立实现（`DoRenameEntry` + `tzip.rename.pas` 校验 + `jkRename`），只支持文件条目；文件夹会提示不支持。

---

## 5. 工具类功能逐项判定

| 功能 | 判定 | 依据 |
|---|---|---|
| 哈希/校验和计算（MD5/SHA 等） | **无** | `src/`、`backend/` grep `SHA/MD5/hash` 无实现；条目 CRC 仅从 7-Zip 读出并显示（`tz7z.cpp:1393`；`ArcCellText` 的 CRC 列） |
| 完整性测试 | **有** | §3.1；结果弹窗 `rsInfoTestDoneFmt` |
| 安全删除/擦除 | **无** | grep `secure/Shred/wipe` = 0 |
| 拆分/合并文件（非分卷） | **无** | 仅压缩包分卷（`tz7z.cpp:1849-1875`、`OpenInputVolumes` :1135） |
| 压缩包转换（convert/repack） | **有** | `TzConvertArchive`（`engine.pas`）+ File → Convert / 文件列表右键 Convert（`MenuConvertClick`/`BeginConvertFor`） |
| 批量任务/队列 | **有** | 多选后的 `BatchExtract`/`BatchTest` + `tzip.batch` 状态机 + `TJobController`/`TJobQueue`（§4.2） |
| 包内条目重命名 | **有** | 右键 Rename（§4.3） |
| 编辑回写 | **有** | 双击条目用外部程序编辑，回来提示写回（`tzip.editwrite.pas` + `CheckEditWriteBack`） |
| 压缩预设 | **有** | `tzip.presets.pas`；新建对话框顶部套用/保存 |
| CLI/命令行接口 | **部分** | 只有 `ParamStr(1)` 作为“打开路径”（`AfterConstruction` :869、`OpenStartupPath` :6352）；无 `--help`/`--extract`/`--create` 等参数解析 |
| 基准测试（benchmark） | **无** | grep `benchmark` = 0；README「已知限制」列未实现 |
| SFX 自解压创建 | **无** | grep `SFX` = 0；README「已知限制」列未实现 |
| 压缩包注释（读/写） | **有（zip 可写，7z 可读）** | `tz7z_comment`/`tz7z_set_comment`；UI 对话框 `ShowCommentDialog`；条目级 comment 仍不进列表 |
| 修复/恢复记录 | **无** | 无 7-Zip recovery record 属性设置；无 repair UI |
| 重复文件查找 | **无** | grep `duplicate` 只出现在排序/CJK 测试注释 |
| 密码管理器/密码库 | **部分** | macOS Keychain（`tzip.passwordstore.pas`）；单密码记忆，不是多包管理器 |
| 十六进制/二进制查看器 | **无** | 预览只做文本/图片（`ShowPreviewFile` :3387） |
| 条目属性/权限编辑 | **无** | §4.2 |
| 压缩包信息检视 | **有** | `TArchiveInfoForm`（`dialogs.pas:1337-1445`） |
| 文件预览（文本/图片） | **有** | §4.1 |
| 拖放添加 | **有** | `AddDroppedFiles`（:6706） |
| Finder“显示/打开方式”等价动作 | **有** | `Show in Finder`/`Open With`（§2.3） |
| 系统通知 | **无** | grep `NSUserNotification`/`Notification` = 0 |
| AppleScript / Automator / 服务菜单 | **部分** | Finder Services 已实现 6 项（`tzip.services_macos.pas` + `Info.plist` 的 `NSServices`）；AppleScript 脚本接口与 URL Scheme 仍无 |
| Finder 扩展 / Quick Look 插件 | **无** | 只有文档类型注册；无扩展 target |
| 压缩包内搜索 | **部分** | 跨目录名称搜索 + 子串/通配/正则；内容匹配函数已存在，engine 列表尚未接线（票 08） |

---

## 6. 平台集成（macOS）与移植状态

### 6.1 macOS

| 项 | 状态 | 依据 |
|---|---|---|
| 文档类型注册 | 有，2 个 `CFBundleDocumentTypes`（31 + 22 个扩展名，role=Viewer，rank=Alternate） | `packaging/Info.plist:9-89` |
| bundle 标识/版本/最低系统 | `app.tyzip.TyZip` / `1.0.0` / macOS 11.0 / HiDPI | `Info.plist:90-114` |
| **macOS 应用菜单** | 有：About、Settings…、Language 原生子菜单；`CocoaConfigMenu.appMenu` + `TAppMenuHook.Created`（LCL Cocoa 集成） | `tzip.ui.menu.pas` 的 `BuildAppMenu` |
| 从 Finder 双击/Open With 打开 | 有 | LCL `Application.OnDropFiles`（`main.pas` 构造函数）→ `OpenFilesFromSystem`（:6265） |
| 拖入窗口 | 有 | `AllowDropFiles` + `OnDropFiles`；拖到压缩包窗口=添加，拖到文件视图=打开/导航（`FormDropFiles` :6409） |
| Open With（LaunchServices 列表 + Other…） | 有（仅文件列表右键） | `platform_macos.pas:85-165,168-190,192-240` |
| 显示所在文件夹 | 有（打开父目录，不是选中文件） | `FsPopupRevealClick`（:3216） |
| 多文件外部打开各自新实例 | 有（`open -n`） | `platform_macos.pas:245-283`；`OpenFilesFromSystem` |
| 系统图标/应用图标 | 有（NSWorkspace + 探针文件 + 后台线程 + 磁盘缓存 64 px） | `tzip.ui.icons`（`TIconCache`/`IconCachedPx`）+ `tzip.iconstore`/`tzip.iconkeys`；`tzip.platform_macos.pas` 的 `TzMacSystemIcon` |
| 物理内存探测（新建对话框 RAM 提示） | 有（`sysctlbyname hw.memsize`） | `platform_macos.pas:384-397` |
| 根卷显示名 | 有（NSFileManager displayName） | `platform_macos.pas:399-412` |
| 系统通知 | **无** | grep 0 |
| Finder Services | 有（6 项：Add to Archive…、Extract…、Extract Here、Extract to Folder、Add to <name>.7z、Add Each to a Separate Archive） | `tzip.services_macos.pas`；`packaging/Info.plist` 的 `NSServices`（每个 `NSMessage` 必须与单元方法名一致） |
| AppleScript / URL Scheme | **无** | `Info.plist` 无 `CFBundleURLTypes`；grep `AppleScript` 0 |
| Finder 右键菜单集成 | **无**（README「已知限制」已说明） | 无 Finder Sync 扩展；右键菜单是应用内自绘 |
| 公证（notarization） | **无**（ad-hoc 签名） | `scripts/package_app.sh` 的 codesign 段；README |
| 架构 | 当前构建 x86_64；苹果芯片需自行重建 | README「依赖」；`package_app.sh` 按 `fpc -iTP`/`-iTO` 推导目录，可用 `TYZIP_TARGET` 覆盖 |

### 6.2 Windows/Linux 移植状态（代码事实）

| 项 | 状态 | 依据 |
|---|---|---|
| 动态库名分支 | 有：`tz7z.dll` / `libtz7z.dylib` / `libtz7z.so` | `api.pas:314-325` |
| 平台门面回退 | 有：非 macOS 用 `TzFallbackIcon`、`OpenDocument`、返回 0/空 | `platform.pas:103-226`；`platform_macos.pas:423-470`（非 Darwin stub） |
| 平台名/根卷名分支 | 有 | `platform.pas:128-143,202-214` |
| 非 macOS 菜单 | 有：Tools（Settings/Language）+ Help（About）分支 | `main.pas:2991-2998` |
| **Linux 目标可编译性** | **不成立** | `platform.pas:120-125` 在 `LINUX` 下调用 `TzMacPhysicalMemory`，但该函数只在 `platform_macos.pas` 声明/实现，且非 Darwin stub 列表（`platform_macos.pas:423-470`）**没有它** → Linux 编译缺符号 |
| macOS 专属单元隔离 | `tzip.platform_macos.pas` 只在 `DARWIN` 下被引用 | `platform.pas:62-64`；`platform_macos.pas:5` |
| 构建/打包脚本 | 仅 macOS（`clang++ -dynamiclib`、`install_name_tool`、`codesign`） | `scripts/build_backend.sh`、`scripts/package_app.sh` |
| 安装包/打包描述 | 只有 macOS `Info.plist` | `packaging/` 仅 `Info.plist` |
| README 定位 | 明确“当前交付仅针对 macOS” | README:136-139 |

---

## 7. 国际化

| 项 | 事实 | 依据 |
|---|---|---|
| 字符串源 | `resourcestring` 311 条，默认英文（2026-10-29 统计；票 12 删除了未使用项，票 22/23/25 新增/调整了文案） | `grep -c '^  rs' src/tzip.i18n.pas` |
| 语言包 | 仅 **1** 种语言：`zh_CN`，两个 `.mo`（`tzip.zh_CN.mo` + `lclstrconsts.zh_CN.mo`）；`tzip.zh_CN.po` 306 条可翻译 `msgid`（另 1 条头部） | `ls languages`；`grep -c '^msgid' languages/source/tzip.zh_CN.po` = 307 |
| 机制 | LCLTranslator `SetDefaultLang(Lang, dir, 'tzip')`，读取 `tzip.<lang>.mo`；目录探测 6 层（含 `Contents/Resources/languages`） | `i18n.pas:384-415` |
| 默认语言 | **跟随系统**：无 ini 时 `LanguageSystem` → `SetDefaultLang('')`；`TYZIP_LANG` 可开发时覆盖 | `i18n.pas:359-382`；`TyZip.lpr:28-31` |
| README 声明 | 「首次启动跟随系统语言」 | README 已与代码一致（`TzConfiguredLanguage` 无 ini 时返回 `LanguageSystem`） |
| 切换方式 | macOS：应用菜单 Language ▸；设置对话框也可改；**重启生效**（只弹提示，热切换不重译菜单） | `i18n.pas:207`；`MenuLanguageClick`（:7244）；`RetranslateUi`（:7262）只处理标题/过滤框/状态栏 |
| README 的菜单位置 | 「设置 → 语言 或 macOS 应用菜单 → Language」 | README 已同步（Tools 只在非 macOS 构建） |
| 语言列表 | 硬编码 3 项（System default/English/简体中文），不扫描 `languages/`；新增语言包需改代码 | `i18n.pas:417-428`；`main.pas:2956-2964` |
| 可翻译覆盖 | UI 文本基本都走 `rs*`（含新建/设置/解压/信息对话框）；**未覆盖**：TyControls 内建字符串（文件列表列头 Name/Size/Type/Modified、内置主题名）、`api.pas:255-273` 与 backend 的错误文本、引擎格式名/方法名、预览编码标签（`preview.pas:189-204`）、`English`/`简体中文` 字面量、About 文本中的英文短语 | 见各文件 |
| 打包 | `package_app.sh` 只复制 `*.mo` 到 `Contents/Resources/languages`；并复制 `THIRD_PARTY_NOTICES.md` 与 `licenses/` | `scripts/package_app.sh` |

---

## 8. 测试覆盖

现状（2026-10-29，commit `d7b8310`）：测试入口是 `tests/run_all.sh`（构建应用 + 两个套件）；发布门禁是 `scripts/ci.sh`（版本/plist/shell 静态检查 + run_all + x86_64 `file`/`otool` minos 11.0 + arm64 交叉构建/bundle 校验 + 按版本打包；`SKIP_ARM64=1` 可跳过交叉构建，`REQUIRE_ARM64_APP=1` 把缺 arm64 app 视为失败）。`tests/run_engine_tests.sh` **自动发现** `tests/unit_*.pas` 与 `tests/api_*.pas`，排除 `api_test`（手工诊断工具）与预览专属的 `unit_preview`，当前 **51 个程序**；`tests/run_preview_tests.sh` 固定跑 `preview_syntax_check`、`editor_integration`、`unit_preview` **3 个程序**。每个程序退出码必须为 0，并打印 `== engine: N passed, M failed` / `== preview: ...`。共 55 个 `.pas`（含 `api_test`）。

| 范围 | 程序 | 覆盖内容 |
|---|---|---|
| 引擎/API（16） | `api_backend_abi`、`api_backend_p0`、`api_backend_p1`、`api_backend_prefix`、`api_comment`、`api_content`、`api_convert`、`api_encoding`、`api_formats`、`api_model_listbypath`、`api_model_prefix`、`api_model_search`、`api_model_searchjob`、`api_options`、`api_rename`、`api_roundtrip` | ABI v3 结构/版本与前缀解压、后端 P0/P1 回归、注释读写、内容搜索、搜索任务（jkSearch/TzSearchArchive）、转换、ZIP 代码页、格式与复合 `.tar.*`、list-by-path、选项/加密/分卷、改名、往返 |
| 模型层（13） | `unit_model_api`、`unit_model_cancel`、`unit_model_encrypted`、`unit_model_engine`、`unit_model_errors`、`unit_model_executor`、`unit_model_formats`、`unit_model_jobmatrix`、`unit_model_jobs`、`unit_model_listing`、`unit_model_open`、`unit_model_passwordstore`、`unit_model_payload` | JSON/错误分类、取消/进度、加密负路径、分卷只读、`TZJob` executor 与 9 种 job、单一格式表、虚拟目录列举、`TzOpenContext`、Keychain 参数不泄漏、payload/Clone |
| 主窗体控制器（12） | `unit_main_about`、`unit_main_arcpath`、`unit_main_batch`、`unit_main_commands`、`unit_main_iconkeys`、`unit_main_iconstore`、`unit_main_imageinfo`、`unit_main_jobcontrol`、`unit_main_jobqueue`、`unit_main_navstate`、`unit_main_paths`、`unit_main_preview_session` | About 文本/版本、条目名/行号混用回归、批量状态机（逐包 list→resolve→extract、取消即停、计数）、命令构造、图标 key/槽位/队列、像素预算、等待队列/批量 tally/密码重试、导航栈与面包屑、`~` 展开、预览分类/缩放 |
| 纯逻辑/对话框/设置（10） | `unit_appcache`、`unit_dialogs_opts`、`unit_editwrite`、`unit_extract`、`unit_passwords`、`unit_presets`、`unit_pure`、`unit_rename`、`unit_search`、`unit_settings` | `.app` 缓存范围、对话框选项映射、回写阈值、解压冲突策略、密码记忆、预设、路径/大小/错误文本、改名校验、搜索规则、设置 INI |
| 预览（3） | `preview_syntax_check`、`editor_integration`、`unit_preview` | 语言表、分词、跨行状态、主题着色、无界面 `TSynEdit` 挂载、编码检测、2 MB 显示/前缀常量 |
| 手工工具（1） | `api_test` | 列可写格式、打开参数路径、列条目、测试；**不在任何脚本中** |

**未覆盖**：GUI 窗口交互（预览 2 MB 前缀、批量逐包冲突、搜索任务、arm64 包运行冒烟见 `docs/qa-smoke.md`；arm64 只能在 Apple Silicon 上冒烟）、AppKit 服务安装本身、Windows/Linux 目标。`tzip.queue` 及其测试已随死单元清理删除；批量状态机现在测在 `unit_main_batch`，等待队列在 `unit_main_jobcontrol`/`unit_main_jobqueue`。README 的测试章节说明 `tests/run_all.sh`（测试入口）与 `scripts/ci.sh`（发布门禁）的分工。

---

## 9. 缺失/受限项汇总

### 9.1 完全缺失（TyZip 功能面为 0）

> 现状（2026-10-28）：转换、批量/队列、注释编辑、搜索、条目重命名、编辑回写、压缩预设与 Finder Services 已实现，不再列在这里。

| # | 能力 | 关键依据 |
|---|---|---|
| 1 | 哈希/校验和计算 | 无 UI、无桥接（§5） |
| 2 | 安全删除/擦除 | grep 0 |
| 3 | 文件拆分/合并（非压缩包分卷） | 无 |
| 4 | 完整 CLI（create/extract/test 参数） | 只支持打开首个路径参数 |
| 5 | 基准测试 | grep 0；README 已列未实现 |
| 6 | SFX 创建 | grep 0；README 已列未实现 |
| 7 | 修复/恢复记录 | 无 |
| 8 | 重复文件查找 | 无 |
| 9 | 磁盘文件 新建文件夹/删除/复制/移动/批量重命名 | 无菜单/右键/实现 |
| 10 | 压缩包内条目 移动/复制 | 只有重命名 |
| 11 | 标签、书签、收藏夹 | 无 |
| 12 | 十六进制/二进制查看器 | 无 |
| 13 | 多窗口/标签页 | 无（进程级多实例） |
| 14 | 拖出到 Finder | 无 |
| 15 | 系统通知、AppleScript、URL Scheme、Finder 扩展、Quick Look | 无；Finder Services 已有，见 §6.1 |
| 16 | Windows/Linux 可交付构建 | 只有 macOS 脚本；Linux 编译问题见 §6.2 |
| 17 | 创建 RAR / PEA / ZPAQ / ARC / LZ4 / Brotli / FreeArc / ACE | 引擎无对应可写 handler；RAR 连读都只读 |

### 9.2 部分实现/受限

| # | 能力 | 限制 | 依据 |
|---|---|---|---|
| 1 | 更新已分卷压缩包 | **已修**：现在明确拒绝更新并提示只读 | §3.5；`CheckArchiveWritable` + `TzIsSplitArchivePart` |
| 2 | 分卷大小选项 | **已修**：`Vol[0..6]` 与 7 个选项对齐并有 Assert | §3.5 |
| 3 | ZIP 名称编码（读） | 只有写侧可选 codepage；读侧无参数 | `tz7z.h` |
| 4 | ZIP 名称编码（写） | **已修**：`Cp[]` 已与下拉项对齐 | §3.5 |
| 5 | 嵌套/双层包 | 只读；关闭/退出时删临时副本 | `engine.pas` 的 `TzOpenContext`；`CheckArchiveWritable` |
| 6 | RAR | 只能读/测/解 | 实测 update=false |
| 7 | `.tar.zst/.tar.lzma` | 能读能解，不能创建 | zstd/lzma update=false |
| 8 | 压缩包注释 | zip 可读写；7z 可读不可写；其他格式为空 | §3.7 |
| 9 | 条目注释 | 读入模型但列表不显示、不可编辑 | `TArchiveEntry.Comment`；`rsColComment` 未用 |
| 10 | 添加同名文件 | Add Files 无冲突提示；拖放才有 replace/skip | `DoAddFiles` vs `AddDroppedFiles` |
| 11 | 提取选项 | 覆盖/跳过/重命名、智能子文件夹、快捷目的地、解压后删源均已实现 | `tzip.extract.pas` + `TExtractDialogForm` |
| 12 | 密码 | macOS Keychain 记忆（单密码，非多包管理器） | §3.4 |
| 13 | 命令行 | 只能“打开一个路径” | `OpenStartupPath` |
| 14 | 预览 | 文本显示上限 2 MB（不再按文件大小拒绝；归档文本/未知类型只解前缀），图片 32 MB + 像素预算；无 PDF/Office 渲染 | `tzip.preview.session`/`tzip.preview.workers`/`tzip.imageinfo` |
| 15 | 状态/动作 | 作业期间写操作禁用；无取消后回滚（已写文件保留） | `UpdateActions` |
| 16 | 文件重命名 | 只有 F2 隐藏能力 | §4.3 |
| 17 | 批量/队列 | 批量解压逐包 list→resolve→extract，skip/rename/overwrite 逐包生效、取消即停；同一时刻仍只有一个 7-Zip 作业 | `tzip.batch`；§4.2 |

### 9.3 文档与实现不一致 / 代码缺陷

> 盘点后已修、不再列为缺陷：README 的默认语言、快捷键、图标缓存尺寸、语言菜单位置、测试章节；分卷更新拦截；分卷大小与 ZIP 代码页映射。下面只留仍成立项。

| # | 问题 | 依据 |
|---|---|---|
| 1 | Linux 目标缺少 `TzMacPhysicalMemory` 定义，当前无法编译 | `platform.pas` 的 `TzPhysicalMemory` LINUX 分支；`platform_macos.pas` 非 Darwin stub 列表 |
| 2 | 条目级注释读取后不显示（`rsColComment` 未使用） | §3.7；`src/tzip.i18n.pas` |
| 3 | 未使用的 resourcestring 仍有残留（如 `rsErrSplitUpdate`） | grep 无引用；死代码清理票处理 |

> 说明：行号一律以 2026-10-27 快照为准，定位请用函数名。

---

## 10. 供 PeaZip 差距分析的关键结论（TyZip 侧）

1. **规模**：2026-10-29（commit `d7b8310`，版本 0.3.0）`src/` 46 个文件 24,617 行，`backend/` 3 个文件 3,431 行，`tests/` 55 个程序 14,608 行；单主窗体 `tzip.main.pas` 7,332 行（定位用单元名）；单平台 macOS（x86_64 本机测试，arm64 交叉构建）。
2. **引擎边界**：官方 7-Zip 26.03（Format7zF）→ 实测 **60 个可读 handler、7 个可写格式**（7z/zip/tar/gzip/bzip2/xz/wim）；RAR 只读；PEA/ZPAQ/ARC/LZ4/Brotli/FreeArc/ACE 完全不支持。
3. **核心压缩操作齐全**：打开/列举/测试/解压（全部/选中/单条）/创建/添加文件/添加文件夹/删除条目/信息/关闭；分卷创建与 `.001` 读取；加密（7z 加密头、zip AES-256/ZipCrypto）与密码重试；更新已分卷包会被拒绝。
4. **双层/嵌套**：`.tar.gz` 等自动解包（≤8 层），内层只读；Office/ODF 作为 ZIP 可浏览但默认按文档打开。
5. **已补齐的工作流（2026-10-29）**：转换、名称/内容搜索（后台任务、可取消、尊重当前过滤）、批量解压（逐包 list→resolve→extract、冲突策略逐包生效）/批量测试、解压策略（冲突/智能子文件夹/快捷目的地/删源）、2 MB 文本前缀预览、归档注释、条目重命名、编辑回写、压缩预设、Finder Services。**仍缺**：哈希、安全删除、拆分/合并、完整 CLI、benchmark、SFX、修复/恢复记录、重复查找、完整密码管理器。
6. **文件管理很薄**：浏览/排序/过滤/面包屑/地址栏/预览/图标/主题/语言/设置齐全；但无新建文件夹、无磁盘删除、无复制/移动、无批量重命名、无文件系统搜索/标签/书签/队列；唯一隐藏动作是文件列表 F2 重命名（TyControls 自带，README 未单独说明）。
7. **压缩包内文件管理**：解压/测试/添加/删除/重命名/注释/编辑回写都有；没有移动/复制条目，不能从包内条目创建新包；条目列表现在有右键菜单。
8. **界面文档缺口**：README 现覆盖右键菜单、Services、搜索/转换/批量/注释/回写/预设与快捷键；仍不展开 F2 重命名、拖放添加与高级压缩参数（字典/match finder/passes/额外参数）。
9. **文档错误**：本轮已修 README 的默认语言、快捷键、图标缓存尺寸、语言菜单位置、分卷更新说明、测试命令与目录说明；研究类文档只更新与现状矛盾的锚点。
10. **平台**：仅 macOS（Info.plist + 31/22 个文档扩展名、拖放、Open With、Show in Finder、多实例 `open -n`、Cocoa 应用菜单/About/Settings/Language、6 个 Finder Services）；无通知/AppleScript/URL Scheme/Finder 扩展/Quick Look；无公证；Windows/Linux 未交付且 Linux 目标有编译问题。
11. **i18n**：311 条 resourcestring、1 种语言（zh_CN，tzip + lclstrconsts 两个 .mo）、默认跟随系统、切换需重启、TyControls 内建字符串与引擎错误文本不在翻译范围。
12. **测试**：无界面套件由 `tests/run_all.sh` 统一入口（发布门禁 `scripts/ci.sh`，含 arm64 交叉构建校验）；engine 自动发现 51 个程序，preview 固定 3 个，覆盖引擎/API、模型层、主窗体控制器、纯逻辑与预览高亮；GUI 与 arm64 运行冒烟仍靠手动验证（清单见 `docs/qa-smoke.md`）。
