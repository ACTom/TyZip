# 架构

TyZip 是一个单一 macOS 应用（Lazarus / Free Pascal + LCL Cocoa，控件库 TyControls 3.99），压缩能力来自 7-Zip 26.03 动态库，经 `backend/tz7z.cpp` 的 C ABI 使用，不经过 7-Zip 命令行。代码按 **UI → 控制器 → 引擎 → API → 桥接** 单向分层：窗口只装配控件并转发事件，控制器持有可测试的状态与规则，引擎负责归档语义，API 只做桥接门面。控制器、引擎与 API 合称模型层，**不得依赖 LCL**，也不得引用 `tzip.main` / `tzip.dialogs` / `tzip.ui.*`；这条边界就是本文件里“模型层边界”那条线（ADR 0001）。

## 分层总览

```text
+------------------------------------------------------------------+
|  UI            tzip.main   tzip.dialogs   tzip.preview.pane      |
|                tzip.ui.*     (LCL + TyControls, main thread)     |
+------------------------------------------------------------------+
                                 |   events, callbacks
---------------------------------+----------------------------------
模型层边界：以下各层不引用 LCL
+--------------------------------v---------------------------------+
|  controllers   (no LCL)                                          |
|                navstate   navpaths   iconstore   iconkeys        |
|                jobcontrol   jobqueue   commands   batch          |
|                preview.session   preview.workers                 |
+------------------------------------------------------------------+
                                 |
+--------------------------------v---------------------------------+
|  engine        (no LCL)                                          |
|                engine   formats   arcpath   extract              |
|                search   rename   editwrite   jobs                |
+------------------------------------------------------------------+
                                 |
+--------------------------------v---------------------------------+
|  API           (no LCL)                                          |
|                tzip.api      facade, TTzArchive, Tz* calls       |
|                api.bind      ABI records and symbol binding      |
|                api.errors    11 codes -> TZErrorClass            |
|                api.formats   format table parsed from JSON       |
+------------------------------------------------------------------+
                                 |   C ABI v7: UTF-8, POD, struct_size
+--------------------------------v---------------------------------+
|  bridge        backend/tz7z.cpp  ->  libtz7z.dylib               |
+------------------------------------------------------------------+
                                 |   @loader_path/7z.so
                                 v
                                 7-Zip 26.03   lib/7z.so
```

数据流：`TyZip.lpr` → `TMainForm`（`tzip.main`）→ 控制器 → `TZJob`（`tzip.jobs`）→ `TArchiveContext` / `TzListArchive` / `TzListEntries` / `TzOpenContext`（`tzip.engine`）→ `Tz*`（`tzip.api` + `api.bind`）→ `tz7z_*`（`backend/tz7z.cpp`）→ `7z.so`。UI 从不直接调用 7-Zip。

## 单元职责表

| 单元 | 层 | 职责 |
|---|---|---|
| `TyZip.lpr` | 入口 | 设 UTF-8 代码页、装语言包、创建 `TMainForm`、`Application.Run`。 |
| `tzip.main.pas` | UI | `TMainForm`：控件装配、事件接线、每窗状态、遮罩卡片、作业完成分派表、图标定时器。 |
| `tzip.dialogs.pas` | UI | 全部模态对话框（密码、文本、注释、搜索、解压、新建、设置、压缩包信息）与 `TZipDialog` 基类。 |
| `tzip.preview.pane.pas` | UI | 预览窗格控件：只读 SynEdit 查看器、编码/Wrap/Syntax 底栏、图像缩放拖动。 |
| `tzip.ui.fslist.pas`、`tzip.ui.arclist.pas` | UI | 文件列表（`TTyShellListView` 子类）与压缩包 13 列列表的数据源/回调适配。 |
| `tzip.ui.sidebartree.pas`、`tzip.ui.arctree.pas`、`tzip.ui.scrollguard.pas` | UI | 文件系统侧边栏树；归档树选中事件绑定（单选树只发 `OnChange`）；Cocoa 表单滚动守卫。 |
| `tzip.ui.menu.pas`、`tzip.ui.dialogkit.pas` | UI | 主菜单 / macOS 应用菜单构造；对话框控件与布局小工具。 |
| `tzip.ui.icons.pas` | UI | 图标磁盘缓存 `TIconCache`、PNG 编解码、应用图标预取 `TAppIconPrefetcher`。 |
| `tzip.preview.pas`、`tzip.preview.syntax.pas` | UI（预览） | 预览纯逻辑：编码检测/解码、主题配色、缩放数学；SynEdit 高亮器与语言表。 |
| `tzip.navstate.pas`、`tzip.navpaths.pas` | 控制器 | `TNavHistory` 返回/前进栈与面包屑构造；路径栏 `~` 展开与快捷键焦点判定。 |
| `tzip.iconstore.pas`、`tzip.iconkeys.pas` | 控制器 | 后缀/应用键 → 图像槽表与待办队列；缓存键、过期与 `TzIconWorkAllowed` 门控策略。 |
| `tzip.jobcontrol.pas`、`tzip.jobqueue.pas` | 控制器 | 等待作业 FIFO、批量计数与汇总、密码重试克隆。 |
| `tzip.commands.pas` | 控制器 | 归档命令的 `TZJob` 与 `TCreateSettings` 构造（modify / rename / extract / test / batch）。 |
| `tzip.batch.pas` | 控制器 | 批量解压状态机：逐包 list → 落点/冲突处理 → extract，取消即停；落点模式普通 / 同名文件夹 / 智能。 |
| `tzip.createopts.pas`、`tzip.presets.pas`、`tzip.appcache.pas` | 控制器 | 可写格式能力表与压缩选项清单；压缩预设 INI；哪些 `.app` 可缓存及 `app_*` 键。 |
| `tzip.preview.session.pas`、`tzip.preview.workers.pas` | 控制器 | 预览字节/像素预算与缩放常量；后台解出一个条目、后台解码图像（带 generation）。 |
| `tzip.engine.pas` | 引擎 | `TArchiveContext`、条目快照、`TzOpenContext`（含 wrapper 解包）、列表/搜索/输入集。 |
| `tzip.jobs.pas` | 引擎 | `TZJob` 线程、每种 kind 的 payload record、`TZJobExecutor` 接缝、进度与取消。 |
| `tzip.api.pas` | API（门面） | 门面：`TTzArchive`、`TzOpenArchive` / `TzExtract` / `TzCreate` 等与 `TCreateSettings`。 |
| `tzip.api.bind.pas`、`tzip.api.errors.pas`、`tzip.api.formats.pas` | API | ABI 记录与符号绑定；11 个错误码的分类与文案；格式表 JSON 解析。 |
| `tzip.formats.pas`、`tzip.arcpath.pas` | 引擎 | 后缀表（可写 / 双层 / 纯压缩 / 文档）与归档内路径规范化、选中行取名。 |
| `tzip.extract.pas`、`tzip.search.pas` | 引擎 | 解压选项、目标目录与冲突策略、唯一路径、智能布局（摊平/直出/包名文件夹、垃圾过滤）、暂存树提交；名称/内容搜索的匹配与预算。 |
| `tzip.rename.pas`、`tzip.editwrite.pas` | 引擎 | 条目改名校验与目标路径；外部编辑后的回写判定。 |
| `tzip.platform.pas`、`tzip.platform_macos.pas`、`tzip.services_macos.pas` | 平台 | 跨平台门面；平台系统调用集中在 macOS 实现（另有几个 UI 单元带 Cocoa 分支）；Finder Services 提供者。 |
| `tzip.settings.pas` | 横切 | `TAppSettings`、面板宽度钳制、INI 读写、最近打开列表。 |
| `tzip.nameenc.pas` | 横切 | ZIP 名称编码表（id、代码页、「auto」按界面语言解析）。 |
| `tzip.i18n.pas`、`tzip.i18n.lcl.pas` | 横切 | `rs*` 文案资源与语言配置；用 LCLTranslator 安装 `.mo`。 |
| `tzip.passwords.pas`、`tzip.passwordstore.pas` | 横切 | 密码存储抽象与内存实现；`/usr/bin/security` 钥匙串实现（超时 10 s）。 |
| `tzip.icns.pas`、`tzip.imageinfo.pas`、`tzip.timing.pas` | 横切 | `.icns` 内挑最合适的 PNG；预览图像像素预算；`TYZIP_TIMING` 启动打点。 |

## 导航与状态模型

`TArchiveContext`（`tzip.engine`）是一个已打开的归档：持有 `TTzArchive` 句柄、`Entries` 快照、`DisplayName`、`Password`、`Parent`（嵌套包链）、`OpenedFromFs` 与 `TemporarySource`。它不依赖 LCL，句柄只属于该上下文，同一时刻只被一个作业使用。

导航位置是 `TNavState`：`Kind`（`nkFiles` / `nkArchive`）、`FsPath`、`Ctx`、`Inner`。`TNavHistory` 用两个数组保存返回/前进栈；`PushBack` 记录离开前的位置并丢弃前进分支，`Back` / `Forward` 把当前状态存到另一栈。面包屑由 `FsBreadcrumbs`（卷根 + 每段路径）与 `ArchiveBreadcrumbs`（打开前的文件系统路径 + 包链 + 包内路径）生成，`TCrumb.Kind`（`ckFs` / `ckArchive` / `ckInner`）说明点击的含义，不靠字符串猜。

两种模式共用一套状态机。`tzip.main` 里的每窗状态包括 `FMode`、`FFsPath`、`FCtx`、`FInnerPath`、`FFilter`、`FListing`、`FSearchQuery` / `FSearchOptions`、`FSortCol` / `FSortDesc`、`FHistory`、`FEditSession`、`FSettings`；控制器只持有可推导的派生状态（图标槽表、队列、批量计数）。

包内导航只改 `FInnerPath`，列表随之重建：`SetArchiveContext` 设好路径后调 `RefreshArchiveListing`，小包同步走 `TzListArchive(FCtx, FInnerPath, ...)`，大包走 `jkList` 的条目快照。左侧归档树只在换上下文时重建（`FArcTreeCtx` 相同就跳过），同一包内移动只由 `SyncArchiveTreeSelection` 改选中。嵌套包通过 `Parent` 链接；`.tar.gz` 之类 wrapper 由 `TzOpenContext` 解出内层临时文件（`TemporarySource = True`），只读打开。回到文件系统时复用已有目录列表，不重新枚举。

## 后台作业与线程模型

`TZJobKind` 共 10 种：`jkOpen`、`jkList`、`jkExtract`、`jkTest`、`jkExtractOne`、`jkCreate`、`jkModify`、`jkRename`、`jkConvert`、`jkSearch`。每种 kind 的输入放在自己的 payload record（如 `TZJobSearchPayload`、`TZJobListPayload`），`TZJob` 上的扁平字段只是兼容访问器。执行侧是 `TZJobExecutor`：`OpenJob` / `ListJob` / `ExtractJob` / … 一个虚方法对一种 kind，默认实例调用真实的 engine + api，测试注入假执行器断言“作业向引擎要了什么”。

`TZJob` 是挂起创建的 `TThread`（`FreeOnTerminate = False`），`Execute` 只按 kind 分派给 executor。进度经 `TZ7ZProgressSink`：桥把 user 指针透传给 cdecl 跳板，作业用自己的 `TZJobSink` 接收 `Tick`，因此多个作业不会共用全局进度对象。

主线程不等待线程结束：`FJobTimer`（60 ms）轮询 `Snapshot`（进度、明细）与 `TakeResult`（结果码、错误文本），拿到结果后 `CompleteJob` 按 `TZJobPurpose` 查表调用对应的 `TJobHandler`（`RegisterJobHandlers` / `JobHandlerFor`）。同一时刻只跑一个 `TZJob`；第二个请求进 `TJobController` 的等待队列，由 `StartNextQueued` 依次取出。批量汇总（`BeginBatch` / `NoteResult` / `SummaryText`）与密码重试（`CloneForRetry` 用 `TZJob.Clone` 复制输入）也在 `TJobController`。

取消是协作式的：`RequestCancel` 只置标志，`TZJobSink.Tick` 返回 `False`，桥的进度回调返回 0，7-Zip 中止并返回 `TZ7Z_E_CANCEL`；不 `Terminate` 线程，避免在库调用中途拆栈。

列表阈值在 `tzip.main`：`SyncListingEntries = 20000`。条目数不超过它就同步 `TzListArchive`（几十毫秒，避免异步闪烁），超过则改为 `jkList` 后台列举；搜索始终在后台。所有归档操作都在工作线程，遮罩卡片延迟 `OverlayRevealMs = 140` 才出现，作业期间写类按钮在 `RefreshActions` 里禁用——这就是界面不被阻塞的原因。

## 7-Zip 桥接（ABI v7）

`backend/tz7z.h` 导出打开/关闭、条目、注释、解压/测试、创建/修改、格式表、ABI 版本，以及 ABI v4 引入的 `*_ex` 入口（`tz7z_open_ex` / `tz7z_extract_ex` / `tz7z_test_ex` / `tz7z_create_ex` / `tz7z_modify_ex`）。FPC 侧 `tzip.api.bind` 绑定它们；写注释走 `tz7z_modify` 的 `comment` / `has_comment` 字段，不单独绑定 `tz7z_set_comment`。旧入口保留，内部以 NULL sink 调用 `*_ex`，所以旧调用方字节不变。跨 ABI 的结构体（`tz7z_entry_info`、`tz7z_input`、`tz7z_create_options`）都以 `struct_size` + `abi_version` 开头，库校验后不符返回 `TZ7Z_E_ARG`，不会写坏调用方内存。

### ZIP 文件名编码（ABI v5 / v6）

ZIP 的非 ASCII 条目名有两种存法：带 UTF-8 标志（0x0800）的 UTF-8 字节，或不带标志的本地代码页字节（Windows 工具通常写 GBK）。POSIX 版 7-Zip 没有代码页表，历史行为是把不带标志的名字逐字节读成 Latin-1，于是中文名全是乱码。`scripts/patches/7zip-26.03/0001-zip-name-codepage.patch` 做了三件事：

1. `Common/StringConvert.cpp` 接 libiconv（CP936 / CP950 / CP932 / CP949 / GB18030 / CP1252 / ISO-8859-1），让带代码页的多字节转换真的可用；`7z.so` 链接 `-liconv`。
2. `Archive/Zip/ZipItem.cpp` 补上 Windows 版才有、POSIX 版缺失的启发式：Unix host 写的名字没有标志但字节是合法 UTF-8 时按 UTF-8 读。
3. `Archive/Zip/ZipHandlerOut.cpp`：写入时代码页表示不了的名字单条回退 UTF-8 并置 0x0800，不再写成 `_`。

vendor 树保持原样：`scripts/build_7zip.sh` 把 `vendor/7zip-26.03` 复制到 `lib/build/7zip-26.03-src` 再打补丁；`build_backend.sh` 从这个打过补丁的副本取头文件，桥接读到的 PROPID 与库一致。

- **ABI v5 `tz7z_set_name_codepage(archive, cp)`**：只对 ZIP 生效，打开后、读条目名之前调用；`cp=0` 保持历史行为；带 UTF-8 标志的名字永远不受影响；非 ZIP 返回 `TZ7Z_E_FORMAT`（调用方忽略）。
- **应用侧**：`tzip.nameenc` 定义可选编码（auto / UTF-8 / GB18030 / GBK / Big5 / Shift-JIS / EUC-KR / Windows-1252）与「auto 按界面语言解析」（简体中文 → GB18030，繁体 → Big5，日 → CP932，韩 → CP949，其余 CP1252）；`tzip.settings` 把 id 存进 `[Archive] NameEncoding`；`tzip.main.StartJobNow` 把解析结果写进 `TZJob.NameCodepage`，经 `tzip.jobs` / `tzip.engine` / `tzip.api` 透传到桥接。
- **创建**：`TCreateSettings.Codepage` 交给 7-Zip 的 `cp` 属性（`ForceUtf8` 对应 `cu`），对话框里选的名称编码随包写入。
- **更新保持原编码**：改包前 `TzArchiveNameEncoding` 用 **ABI v6 `tz7z_entry_name_is_legacy`** 问补丁：有没有条目名是按旧代码页（或 Info-ZIP Unicode 扩展字段）读出来的。只看两次解码结果不可靠——扩展字段会让两种代码页都解出正确 Unicode。有则 `Codepage=原代码页、ForceUtf8=False`，否则 `Codepage=65001、ForceUtf8=True`；`tz7z_modify` 在读旧条目名之前用同一个代码页（`options->codepage`），因此 GBK 包改完仍是原来的 GBK 字节。混合包按旧代码页写，单条表示不了的名字走上面的 UTF-8 回退。
- **界面**：设置里「ZIP 文件名编码」是默认值；查看 → 「名称编码」只对当前顶层 ZIP 生效，选一次就带该代码页重开当前包，不落盘。打开作业会用 **ABI v7 `tz7z_entry_name_uses_codepage`** 缓存「是否有名字真的受代码页影响」；如果全都带 UTF-8 标志、或带 Info-ZIP Unicode 名扩展（这类名字任何代码页都解对），菜单置灰。

ABI v4 引入的详细进度通过 `tz7z_progress_sink` 传递（`struct_size` + `abi_version` + `fn` + `user`）：`tz7z_progress_info` 带 `phase`（open/extract/create/test）、`event`（tick/item/item_done）、条目索引/总数/名字、以及已知时的累计压缩字节。`*_ex` 在没有 sink 时与旧函数完全等价；旧 `tz7z_progress_fn` 仍按原语义收到 `(completed,total)` tick。`SetCompleted` / `SetRatioInfo` 可能来自编码器内部线程，桥接用一把锁串行化 sink 调用；sink 不允许碰 LCL。设计依据与逐条证据见 `docs/research/7zip-progress-callbacks.md`。

加载在 `tzip.api.bind.TzLoadLibrary`：按候选路径依次 `LoadLibrary`（macOS 上是 `dlopen`，符号取 `GetProcedureAddress` / `dlsym`）。候选包括可执行文件同目录、`lib/`、`../Frameworks`、`../lib`、`../Resources`、`../../lib`、`../../Frameworks`、`$TYZIP_LIB` 和裸文件名 `libtz7z.dylib`。每个候选先查 `tz7z_format_json` 与 `tz7z_abi_version`，版本必须等于 `TZ7Z_ABI_VERSION = 7`；随后绑定全部符号（含 `*_ex`、`tz7z_set_name_codepage`、`tz7z_entry_name_is_legacy`、`tz7z_entry_name_uses_codepage`），缺一个就整体卸载并试下一个候选。

`libtz7z.dylib` 不自己去猜 7z 的位置：`scripts/build_backend.sh` 用 `install_name_tool` 把依赖改写成 `@loader_path/7z.so`，所以打包时两者必须放在同一目录（app 内是 `Contents/Frameworks`）。

错误分类在 `tzip.api.errors`：成功是 `TZ7Z_OK = 0`，失败是 `TZ7Z_E_ARG` … `TZ7Z_E_UNSUPPORTED` 共 11 个负码；`TzErrorClassOf` 映射到 `TZErrorClass`，`TzErrorClassText` / `TzErrorText` 给文案，调用方按类决定“重试密码 / 报告损坏 / 提示格式不支持”。

格式表（含每个格式能否更新）也来自库而不是硬编码：`tz7z_format_json` 两段式调用（先问长度再取内容），`TzParseFormatsJSON` 解析 `name` / `ext` / `addext` / `update` 得到 `TFormatInfo`，供新建压缩包对话框和格式判断使用；本地硬编码的只有 `tzip.formats` 里那张用于识别与图标的后缀表。

全程没有 7z CLI：`src/` 里没有任何地方启动 `7z` / `7zz`；仅有的外部进程是 `/usr/bin/open`（Finder 显示、新实例打开）与 `/usr/bin/security`（钥匙串）。

## 平台与性能约束

平台系统调用集中在 `tzip.platform_macos.pas`（NSWorkspace 图标、LaunchServices「打开方式」、版本、内存、空闲时间），由 `tzip.platform.pas` 做门面；带 Cocoa 分支的还有 `tzip.services_macos.pas`（Finder Services）、`tzip.main` 与 `tzip.ui.menu.pas`（应用菜单）、`tzip.ui.scrollguard.pas`（表单滚动）。

- **NSWorkspace / IconServices 只能在主线程调用。** 在后台线程调用会产生 “Thread was created from extern … risk data corruption”，单次查询可阻塞 1–3 秒。后缀图标由 `tzip.main` 的 `FIconTimer` 每 tick 解一个（`IconTimerTick` 先过门控）；应用图标扫描 `TAppIconPrefetcher` 也不是线程，由 `AppIconTimerTick` 每次放行后最多推进 6 个 bundle，已写好的缓存文件则随时装配。
- 任何每 tick 的图标查询都必须过 `TzIconWorkAllowed`（`tzip.iconkeys`）：启动后 `IconWorkStartDelayMs = 2500` 内不做；前台需空闲 `IconWorkIdleSecondsActive = 8.0` 秒；应用不在前台时只受启动延迟限制。
- `.app` 图标优先走文件快速路径：`tzip.platform.TzBundleIconPng` 直接读 `Contents/Resources/<CFBundleIconFile>.icns`，用 `tzip.icns.TzIcnsBestPng` 挑最接近的 PNG，全程纯文件 I/O；只有旧式 RLE `.icns` 或 `Assets.car` 才回退到门控下的平台查询。
- 图标缓存规则：键一律小写（`IconKeyName`、`AppIconCacheKey`），`app_*` 是 bundle 图标而非后缀图标；缓存边长 `IconCachedPx = 32`（16 逻辑像素 × Retina）；后缀缓存首帧前恢复，`app_*` 在首帧之后用一次 `Names.AddStrings` 批量恢复（逐条 `Add` 会触发整表 refill）；`RestoreIconCache` 跳过 `app_*`；版本升级只用 `PurgeAppGlyphs` 清 `app_*`，不 purge base 字形（重建 4 个 ≈ 4 次 NSWorkspace）。缓存目录是 `<config>/iconcache`，不可写时退到 `GetTempDir/TyZip-iconcache`。
- 三份二进制必须 minos 11.0：`TyZip`（`-WM11.0`）、`libtz7z.dylib`（`-mmacosx-version-min=11.0`）、`7z.so`（`MACOSX_DEPLOYMENT_TARGET=11.0`）；`scripts/ci.sh` 的 `check_minos` 逐个校验。

## 扩展点

- **新作业种类**：在 `tzip.jobs` 增加 `TZJobKind` 值、payload record、`ClearPayloads` 分支与访问器，在 `TZJobExecutor` 加一个虚方法并在默认执行器里实现；再到 `tzip.main` 的 `TZJobPurpose` 与 `RegisterJobHandlers` 注册完成处理。
- **新 UI 面板**：新建 `tzip.ui.*` 单元（TyControls 控件），在 `tzip.main` 的 `BuildUi` 里装配，把可测的状态与规则放进控制器单元，窗口只留接线。
- **新归档命令**：命令构造放 `tzip.commands`（返回填好的 `TZJob`），确认/提示放 `tzip.dialogs`，完成动作放 `tzip.main` 的 handler 表；不要绕开 `TZJob` 直接调引擎。
- **新平台后端**：实现 `tzip.platform` 暴露的函数集（图标、版本、内存、空闲时间、Open With 等）并新增对应 `{$IFDEF}` 单元；`tzip.platform_macos` 是 macOS 系统调用的唯一入口，`tzip.main` / `tzip.ui.menu` / `tzip.services_macos` 里只放菜单与服务的薄适配。Linux 分支目前仍是占位（沿用 macOS 实现），无法编译；当前交付仅 macOS。
- **测试布局**：`tests/run_all.sh` 构建应用后跑两套。`tests/run_engine_tests.sh` 自动发现 `unit_*.pas` 与 `api_*.pas`（引擎/API/控制器/作业矩阵）；`tests/run_preview_tests.sh` 跑 `preview_syntax_check`、`editor_integration`、`unit_preview` 与 `tree_selection_events`。GUI 行为按 `docs/qa-smoke.md` 手工验收。

## 相关文档

- [构建与工具链](BUILDING.md)
- [用户指南](USER-GUIDE.md)
- [手工验收清单](qa-smoke.md)
- [架构决定记录](adr/0001-split-the-main-form.md)
- [代码盘点快照（2026-10-29，可能滞后）](research/tyzip-inventory.md)
