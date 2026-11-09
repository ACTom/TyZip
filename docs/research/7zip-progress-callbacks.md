# 7-Zip 26.03 详细进度回调能力调研（create / convert / extract / open，含 pause）

> **快照：2026-11-09（tag `v0.3.5`），TyZip 0.3.5；引擎 vendor 7-Zip 26.03。**
> 只读调研：除本文件外未改动任何文件，未提交。行号会漂移，定位代码请用函数名。
>
> 一手来源只有两份，下文所有路径都相对它们：
> - `vendor/7zip-26.03/`（下称 **7z**，所有 `CPP/...` 引用都指这里）
> - `backend/tz7z.{h,cpp}`（TyZip 现有 C ABI 桥）
>
> 没有引博客、论坛或二手文档；每条判断后面都跟着 `文件:行`。

---

## 0. 结论（先看这五条）

1. **逐条目（per-item）回调在 create 与 extract 两条路径上都能做到**：索引由引擎作为参数传进来（`GetStream(index,...)` / `SetOperationResult`），7-Zip 自己就是靠这两个点做「文件数 已完成/总计」的。
2. **「当前文件名」引擎不会告诉我们**——回调对象的**所有者**（7-Zip 的 `CArchiveUpdateCallback`、TyZip 的 `CUpdateCallback`）才是名字的来源：create 时名字在 `GetProperty(kpidPath)` 里由**我方**提供，extract 时名字只能 `IInArchive::GetProperty(index,kpidPath)` 预先缓存。TyZip 两条路都已经有名字表，只是没上报。
3. **实时压缩输出字节只有一条来源：`ICompressProgressInfo::SetRatioInfo(inSize,outSize)`**。它不在 `IProgress` 里，必须让我们的回调对象**自己实现这个接口**，7-Zip 会对回调做 QI（`ProgressUtils.cpp:20-22`、`ZipUpdate.cpp:372-375`）。今天 `CUpdateCallback` / `CExtractCallback` 都没实现，所以压缩率、实时输出体积、当前条目压缩量全都拿不到。
4. **打开归档没有通用百分比**。`IArchiveOpenCallback` 只有 `(files,bytes)` 两个计数且**按格式**才有：ZIP 在 CD 扫描里报条目数（`ZipIn.cpp:1879-1881,1926-1931`）、xz/rar 报字节（`XzHandler.cpp:434,561`；`RarHandler.cpp:1135,1220`）、**7z 一次都不调**（`CPP/7zip/Archive/7z/7zIn.cpp` 里没有 `SetTotal`/`SetCompleted`/`Callback`）。7-Zip 自己的 GUI 干脆把这两个参数注释掉只用来取消（`UpdateCallbackGUI.cpp:196-209`）。
5. **pause 不在 ABI 里，background 也不是引擎能力**。7-Zip 的 GUI 就是在自己的回调里阻塞：`CheckStop()` 死循环 + `Sleep(100)`（`ProgressDialog2.cpp:91-112`）；「后台」只是把进程降到 IDLE 优先级并藏窗口（`ProgressDialog2.cpp:1150-1156`）。TyZip 照抄这个办法即可，不需要引擎配合。

---

## 1. 接口地图（权威声明）

| 接口 | 声明位置 | 继承 | 关键方法 | 何时被调 |
|---|---|---|---|---|
| `IProgress` | `CPP/7zip/IProgress.h:12-14` | — | `SetTotal(UInt64)`, `SetCompleted(const UInt64*)` | 见 §3.2/§5 |
| `ICompressProgressInfo` | `CPP/7zip/ICoder.h:14-16` | — | `SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize)` | 编/解码时由 coder 反复调 |
| `IArchiveOpenCallback` | `CPP/7zip/IArchive.h:177-181` | **`IUnknown`**（`:17-18,181`） | `SetTotal(const UInt64 *files, const UInt64 *bytes)`, `SetCompleted(files, bytes)` | 仅部分 handler 在头解析时 |
| `IArchiveExtractCallback` | `CPP/7zip/IArchive.h:234-239` | **`IProgress`** | `GetStream(index,outStream,askMode)`, `PrepareOperation`, `SetOperationResult(opRes)` | 每一条目 |
| `IArchiveUpdateCallback` | `CPP/7zip/IArchive.h:445-451` | **`IProgress`** | `GetUpdateItemInfo(index,...)`, `GetProperty(index,propID,...)`, `GetStream(index,inStream)`, `SetOperationResult` | 每一条目 |
| `IArchiveUpdateCallback2` | `CPP/7zip/IArchive.h:454-458` | `IArchiveUpdateCallback` | `GetVolumeSize`, `GetVolumeStream` | 分卷时 |
| `IArchiveUpdateCallbackFile` | `CPP/7zip/IArchive.h:486-490` | `IUnknown` | `GetStream2(index,inStream,notifyOp)`, `ReportOperation(indexType,index,notifyOp)` | 每一条目 + 操作类型 |
| `IArchiveExtractCallbackMessage2` | `CPP/7zip/IArchive.h:258-260` | `IUnknown` | `ReportExtractResult(indexType,index,opRes)` | 出错条目 |
| `IInArchive` | `CPP/7zip/IArchive.h:316-328` | `IUnknown` | `GetNumberOfItems`, `GetProperty(index,propID,...)`, `Extract(indices,numItems,testMode,cb)` | 打开/枚举/提取 |

`IArchiveUpdateCallbackFile::ReportOperation` 的操作码在 `IArchive.h:460-477`（`kAdd,kUpdate,kAnalyze,kReplicate,kRepack,kSkip,kDelete,kHeader,kHashRead,kInFileChanged`）。**注意 `index` 可能是块索引而不是条目索引**：`NEventIndexType::kBlockIndex`（`7zUpdate.cpp:2377`）vs `kInArcIndex`（`7zUpdate.cpp:2389`），两者必须分开处理。

关键约束（决定实现方式）：`IArchive.h:186-192` 明确写着 `IProgress` / `ICompressProgressInfo` **可能**被 7-Zip 从别的线程同时调用，而 `GetStream`/`PrepareOperation`/`SetOperationResult` **不会**并发。`IInArchive` 本身不允许跨线程并发调用（`IArchive.h:305-307`）。

---

## 2. 操作 × 可用数据（总表）

图例：✅ 引擎直接给 ｜ ⚠️ 有条件（格式/形态相关）｜ ❌ 拿不到

| 数据项 | create（新建） | convert（extract+create，TyZip 现路径） | extract | open：头解析 | open：条目枚举 |
|---|---|---|---|---|---|
| 当前条目索引 | ✅ `GetStream(index)` / `GetProperty(index)` | ✅（两段各自有） | ✅ `GetStream(index)`（`7zExtract.cpp:89`） | ❌ | ✅ Pascal 自己数 |
| 条目总数 | ✅ 我方输入表长度 | ✅ | ✅ 我方 `count` | ⚠️ ZIP 有（条目数），7z 无 | ✅ `GetNumberOfItems` |
| 当前条目名 | ✅ 我方 `CCreateItem.ArcPath`/旧名 | ✅ | ✅ `_names[index]`（已缓存） | ❌ | ✅ `kpidPath` |
| 已处理输入字节 | ✅ `SetCompleted` | ✅ | ⚠️ 语义见 §5 | ❌ | — |
| 总字节 | ✅ `SetTotal`（仅未知尺寸时不调） | ✅ | ✅ `SetTotal` | ⚠️ 仅 xz/rar 等 | — |
| 实时压缩输出字节 | ⚠️ 需 `ICompressProgressInfo` | ⚠️ 同左（create 段） | ⚠️ 需 `ICompressProgressInfo`，solid 下是块级 | ❌ | ❌ |
| 单条目压缩后大小 | ❌（编码中未知） | ❌ | ✅ `kpidPackSize`（静态值） | — | ✅ `kpidPackSize` |
| 单条目完成事件 | ✅ `SetOperationResult` | ✅ | ✅ `SetOperationResult` | — | — |
| 百分比 | ✅ | ✅（分母分两段） | ✅ | ⚠️ 仅部分格式 | ✅ |
| 速度 / 剩余时间 | ❌ 引擎无字段，UI 自算 | 同左 | 同左 | ❌ | ❌ |

---

## 3. create（新建归档）

### 3.1 逐条目索引从哪来

- `IArchiveUpdateCallback::GetProperty(index, propID, ...)`（`IArchive.h:447`）：`kpidPath`（`CPP/7zip/PropID.h:13`）、`kpidSize`（`:17`）、`kpidIsDir`（`:16`）都由**我们**回答——引擎不会把名字回传给我们，它只是问。
- `IArchiveUpdateCallback::GetStream(index, inStream)`（`IArchive.h:448`）：新数据（`NewData=1`）的条目每次被读之前调一次；`7zFolderInStream` 在读完一个文件后立刻 `SetOperationResult`（`7zFolderInStream.cpp:124-137`），ZIP 在自己的循环里逐条 `SetOperationResult`（`ZipUpdate.cpp:700,753,1344,1352`）。
- 新数据 vs 旧数据：`GetUpdateItemInfo(index,newData,newProps,indexInArchive)`（`IArchive.h:446`，语义注释 `:416-425`）。`indexInArchive = -1` 表示「归档里没有这一项」。
- 想要「这个条目现在在 新增 / 更新 / 复制 / 重压」：实现 `IArchiveUpdateCallbackFile`，拿 `ReportOperation`/`GetStream2` 的 `notifyOp`。7z 在 `7zUpdate.cpp:1906-1907` 对回调做 QI，ZIP 在 `ZipUpdate.cpp:927-928`；复制型旧数据的例子见 `ZipUpdate.cpp:449-455`（`kReplicate` + `kInArcIndex`）。

**结论：create 的「当前文件名」完全由我方解析**——`CCreateItem` 里同时有 `DiskPath`/`ArcPath`/`OldIndex`（`tz7z.cpp:1394-1412`），`modify` 更是把所有旧条目先读成 `outItems`（`tz7z.cpp:3092-3113`），因此 `outItems[index].ArcPath` 就是 index 对应的名字，新旧都对。

### 3.2 SetTotal / SetCompleted 计什么

- `SetTotal(size)` = **所有 `NewData` 条目的未压缩尺寸之和**（`7zUpdate.cpp:2071-2084` 的 `complexity`）。只要有一个条目尺寸未知，**整个 `SetTotal` 被跳过**（`:2083-2084`）→ 调用方会永远看不到 total。
- `SetCompleted(value)` = **已处理的输入（未压缩）字节**，因为 7z 用 `lps->Init(updateCallback, true)`（`7zUpdate.cpp:2090-2091`，`inSizeIsMain=true`），`CLocalProgress` 在 `inSizeIsMain` 时取 `InSize`（`ProgressUtils.cpp:39-49`）。ZIP 同样：`CMtProgressMixer2::Create(updateCallback, true)`（`ZipUpdate.cpp:1234-1237`）+ `SetRatioInfo` 里按 `InSizes` 汇总（`ZipUpdate.cpp:393-408`）。
- 即：**不是文件数，也不是压缩输出字节**。文件数只能靠 `GetStream`/`SetOperationResult` 自己数（7-Zip GUI 就是这么做的：`UpdateCallbackGUI.cpp:139-142` 的 `NumFiles++` / `Set_NumFilesCur`）。

### 3.3 实时压缩输出字节（关键）

只有 `SetRatioInfo(inSize, outSize)` 一条路：

- 取用方式是 **QI**：`CLocalProgress::Init` 里 `_progress.QueryInterface(IID_ICompressProgressInfo, &_ratioProgress)`（`ProgressUtils.cpp:20-22`）；ZIP 的混合器同样（`ZipUpdate.cpp:372-375`）。**回调对象不实现这个接口，就永远收不到压缩量。**
- 7z：`7zUpdate.cpp:2581` 把 `lps` 当 `compressProgress` 交给 `encoder.Encode1`；`7zEncode.cpp:437,466-467` 决定用 MT 包装还是直接传给混合器；`7zEncode.cpp:103-120` 的 `CMtEncMultiProgress` 用「真实写出字节」回调 `SetRatioInfo(inSize,&outSize2)`；LZMA 走 SDK 的进度回调，`CWrappers.cpp:63-68` 直接 `SetRatioInfo(inSize,outSize)`。
- ZIP：单线程路径同样 `lps->Init(updateCallback, true)`（`ZipUpdate.cpp:657`），每个条目开头记 `lps->InSize/OutSize` 并 `lps->SetCur()`（`:667-669`）；多线程路径每个文件压完报一次（`ZipUpdate.cpp:303-305`）再经 `CMtProgressMixer2` 叠加（`:355-412`）。
- `in` = 已吃的未压缩字节（与 `SetCompleted` 同口径），`out` = 已产出的压缩字节（**累计**）。归档完成前**没有最终压缩大小**，只有这个累计值。

替代方案（不建议）：轮询 `COutputFile` 的临时文件大小——分卷（`tz7z_create_options.volume_size`）会把它拆成 `.001/.002…`，且缓冲/落盘时机不由我们控制。

### 3.4 单条目压缩后大小

编码期间**拿不到**：per-entry packed size 是 folder 写完之后才确定的（`7zUpdate.cpp:2652-2653` 在编码结束后才 `lps->OutSize += newDatabase.PackSizes[...]`），solid 时是整块共享。只有打开/提取时 `kpidPackSize`（`PropID.h:18`）才有静态值。

---

## 4. convert（转换：extract + create）

TyZip 现在的 `TzConvertArchive` **不是** `tz7z_modify`，而是「先 `TzExtract` 全部到临时目录，再 `TzCreateArchive`」（`src/tzip.engine.pas:255-360`，两次引擎调用共用一个 `AProgress`）。因此：

- 逐条目数据来自 §5（extract 段）与 §3（create 段）两次调用，**没有统一的 total**：进度条会从「解压字节」跳成「新建输入字节」，中间还要加上目录扫描。
- 名字两段都有：extract 段有 `_names`（`tz7z.cpp:1024-1030`），create 段有 `DiskList/ArcList`（`tzip.engine.pas:315-330`）→ 只要 sink 带 `op`/`phase` 字段就能区分。
- 真正走「引擎内 extract+create」的是 `tz7z_modify`（`IOutArchive::UpdateItems`，`tz7z.cpp:3153-3156`）：旧数据若被整块复制或重压，会触发 `kReplicate`/`kRepack` 的 `ReportOperation`（`7zUpdate.cpp:2377-2389`、`ZipUpdate.cpp:449-455`），这是唯一能区分「复制/重压/新增」的信号。`SetTotal` 的分母只统计 `ui.NewData` 的条目（`7zUpdate.cpp:2071-2084`），被整块复制的旧数据**不计入** → 百分比分母小于归档总解压尺寸。

---

## 5. extract（提取 / 测试）

- 逐条目索引：`IArchiveExtractCallback::GetStream(index, outStream, askMode)`（`IArchive.h:234-239`）。7z 传的是归档内索引 `_fileIndex`（`7zExtract.cpp:89`），条目结束时 `SetOperationResult`（`:112,122`）；通用参考实现见 `ArchiveExtractCallback.cpp:1698`（`GetStream`）、`:1734`（`_index = index`）、`:2825`（`SetOperationResult`）。
- 名字：只能 `IInArchive::GetProperty(index, kpidPath)`（`IArchive.h:320`）。**必须在 `Extract()` 之前缓存**：gz/bz2 这类单流 handler 在提取回调里取 `kpidPath` 会返回空，TyZip 已经踩过并修好（`tz7z.cpp:984-989,1024-1030`）。
- `IProgress::SetTotal/SetCompleted` 计什么（**两套口径**）：
  - 7z：`SetTotal(importantTotalUnpacked)`（`7zExtract.cpp:272`），`lps->Init(extractCallback, false)`（`:274-275`）→ `inSizeIsMain=false` → `SetCompleted` 拿到的是**已产出的解压字节**（`ProgressUtils.cpp:39-49`）。
  - 单流格式例外：handler 自己把 `SetTotal` 设成**压缩**大小，`SetCompleted` 报已消耗压缩字节——gz（`GzHandler.cpp:682`）、bz2（`Bz2Handler.cpp:182`）、xz（`XzHandler.cpp:1036-1039`）。`IArchive.h:214-223` 的注释就是这个口径（xz/gz/bz2/lzma/z/ppmd 用 packSize，其它用 unpackSize；没调过 `SetTotal` 时用 packSize）。
- 实时压缩位置：需要 `ICompressProgressInfo`——7z 用 `lps` 对我们的回调做 QI（`7zExtract.cpp:275` + `ProgressUtils.cpp:14-27`），解码器每次 `SetRatioInfo(&packedConsumed, &unpackedProduced)`（`LzmaDecoder.cpp:213`、`DeflateDecoder.cpp:413`）。**solid 7z 里这个 `in` 是块级**：`7zExtract.cpp:306-308` 只在每个 solid 块边界 `lps->InSize += curPacked`，块内进度由解码器推进 → 不能当「本条目已消耗压缩字节」用。
- 单条目压缩大小：`kpidPackSize` 随时可查（`tz7z.cpp:1902` 已经填进 `tz7z_entry_info.packed_size`）。

---

## 6. open（头解析 vs 条目枚举）

`IArchiveOpenCallback` 只有 `SetTotal/SetCompleted(files, bytes)` 两个方法，且**基类是 `IUnknown` 而不是 `IProgress`**（`IArchive.h:17-18,177-181`）——没有百分比语义，只有「文件数 / 字节数」两个可选计数。

实测调用情况（同一份 vendor 源码）：

| 格式 | 头解析期进度 | 证据 |
|---|---|---|
| ZIP | ✅ 每 0x1000 个 CD 条目报一次 `SetTotal(&NumEntries)` / `SetCompleted(&numFiles,&cdBytes)` | `ZipIn.cpp:1879-1881,1926-1931` |
| xz | ✅ 字节 | `XzHandler.cpp:434,561` |
| RAR / RAR5 | ✅ 字节 | `RarHandler.cpp:1135,1220`；`Rar5Handler.cpp:2313,2551` |
| ISO / WIM / Squashfs / Ext / Z / Base64 / Ihex / VMDK | ✅ 各自报字节或文件数 | `IsoIn.cpp:403`、`WimIn.cpp:1694`、`SquashfsHandler.cpp:1511`、`ExtHandler.cpp:823` |
| **7z** | ❌ **一次都不调** | `CPP/7zip/Archive/7z/7zIn.cpp` 里没有 `SetTotal`/`SetCompleted`/`Callback` 引用 |

7-Zip 自己的两套 UI 也印证这个「按格式、常常没有」：GUI 的 `Open_SetTotal/Open_SetCompleted` 把数字参数直接注释掉，只 `return CheckStop()`（`UpdateCallbackGUI.cpp:196-209`）；控制台则真的用它打百分比，文件数优先、否则字节（`OpenCallbackConsole.cpp:20-70`）。

因此「打开」必须分成两段看：

1. **头解析（`IInArchive::Open`）**：7z 无任何进度（`tz7z.cpp:1694` 调用返回前只能干等）；ZIP 有「条目数」进度；xz/rar 有字节进度。TyZip 的 `COpenCallback` 现在把两个 `Set*` 直接 `return S_OK`（`tz7z.cpp:938-939`），**即使 ZIP 报了条目数也被丢掉**。
2. **条目枚举（`GetNumberOfItems` + 逐条 `GetProperty`）**：这是 TyZip 现在的「打开进度」来源，纯 Pascal 侧循环，每 128 条 tick 一次（`tzip.engine.pas:796-838`，注释在 `:830-834` 解释了为什么不是逐条）。`IInArchive` 不能多线程并发读（`IArchive.h:305-307`），所以这段只能串行。

---

## 7. pause / background

**ABI 里没有 pause。** 整棵 `CPP/` 树里 `pause` 只出现在 `CPP/7zip/UI/FileManager/ProgressDialog*`（7-Zip 自己的 Windows GUI/文件管理器）。

7-Zip 的实现就是「在回调里阻塞」：

- 状态位 `_paused` + 互斥量：`ProgressDialog2.h:32-45` 的 `CProgressSync`（`_stopped`/`_paused`），`Get_Paused`/`Set_Paused` 在 `:68-72`。
- `CheckStop()`：死循环，`_stopped → E_ABORT`，`_paused → Sleep(kPauseSleepTime=100)`（`ProgressDialog2.cpp:91-112`，宏 `CHECK_STOP` 在 `:91`，`kPauseSleepTime` 在 `:49`）。
- 老对话框 `CProgressSync::ProcessStopAndPause()`：完全一样的 `Sleep(100)` 循环（`ProgressDialog.cpp:22-31`）。
- 暂停按钮只翻转标志（`ProgressDialog2.cpp:1130-1141`）；**没有**任何引擎调用。
- 注入点在 callback 里：`CheckBreak()` 就是 `CheckStop()`（`UpdateCallbackGUI.cpp:82-85`），被 `GetUpdateItemInfo`（`UpdateCallback.cpp:148`）和 `GetStream`/`GetStream2`（`UpdateCallback.cpp:596,623`）调用。

**background** 同样不是引擎能力：`OnPriorityButton` 只是把进程设成 `IDLE_PRIORITY_CLASS` 并把按钮文案换掉（`ProgressDialog2.cpp:1150-1156`），工作线程照跑。

对 TyZip 的含义：

- **pause**：在 `tz7z_progress_fn`（或新 sink）里阻塞即可——引擎线程被卡在回调里，数据流自然停住。这就是 7-Zip 的做法，不需要新 ABI。
- **background**：TyZip 已经有 `TZJob = class(TThread)`（`src/tzip.jobs.pas:193`）在后台跑，UI 侧只是个状态；要「更像后台」可以降线程/进程优先级，同样不涉 ABI。
- **粒度**：只在回调发生的瞬间生效。solid 压缩时 LZMA 大约每 N 字节回调一次（`CWrappers.cpp:63-68`）；提取时取决于解码器 `SetCompleted` 频率（`7zExtract.cpp:306-308` 每块一次 + 解码器内部）。最坏情况是一个大块解压/压缩期间没有回调点。
- **线程安全**：`SetRatioInfo`/`SetCompleted` 可能来自编码器内部线程（`IArchive.h:186-192`；ZIP 的 `CMtProgressMixer2` 就是给多线程用的，`ZipUpdate.cpp:355-412`）→ 暂停标志要原子/加锁，回调里**不能碰 LCL**（与 `tz7z.h:10-14` 的「一个 handle 不许跨线程」不冲突：这是同一个 handle 的内部线程回调）。

---

## 8. TyZip 现状（逐点对照）

| 能力 | 现状 | 位置 |
|---|---|---|
| 回调签名 | `int (*)(void *user, uint64_t completed, uint64_t total)`，只有两个数 | `tz7z.h:143-144` |
| create 进度 | `SetTotal`/`SetCompleted` → `(completed,total)`；没有条目信息 | `tz7z.cpp:1443-1462` |
| extract 进度 | 同上，并且兼作取消/前缀截断检查 | `tz7z.cpp:1095-1122`；取消点 `:1139-1143` |
| 条目索引 | `GetStream(index)` 里有，但只用于落盘/取属性，不上报 | `tz7z.cpp:1124,1524` |
| 当前条目名 | extract 侧已经算出 `utf8Name`（`tz7z.cpp:1152`），create 侧有 `ArcPath`（`:1485-1489`），**都没上报** | 同上 |
| 压缩率 / 实时输出字节 | 无：两个回调都没实现 `ICompressProgressInfo`（`Z7_COM_UNKNOWN_IMP_2` @ `tz7z.cpp:1020`，`_3` @ `:1429`） | 未实现 |
| 操作类型（新增/复制/重压） | 无：没实现 `IArchiveUpdateCallbackFile` | 未实现 |
| open 进度 | `COpenCallback::SetTotal/SetCompleted` 直接 `return S_OK`，丢弃 ZIP/xz 的计数 | `tz7z.cpp:924-948` |
| 「打开进度」实际来源 | Pascal 侧枚举（每 128 条 tick，`jpkItems`） | `tzip.engine.pas:796-838`；`tzip.jobs.pas:581` |
| ABI 校验 | 结构严格 `sizeof + version` 相等；加字段会拒旧调用方 | `tz7z.cpp:234-250`；`tz7z.h:52-58` |

---

## 9. 最小桥接扩展提案（ABI v4）

目标：**新老共存**，`tz7z_progress_fn` 一字不改，现有 Pascal 绑定（`src/tzip.api.bind.pas:78`）继续可用。

### 9.1 ABI 形状

```c
/* tz7z.h —— 新增，不动 tz7z_progress_fn */
#define TZ7Z_ABI_VERSION 4u          /* 3 -> 4；旧 loader 会被 tz7z_abi_version() 挡住 */

/* 操作阶段，用于 convert 的两段（extract 段 / create 段）与 open 段 */
#define TZ7Z_PH_OPEN     0
#define TZ7Z_PH_EXTRACT  1
#define TZ7Z_PH_CREATE   2
#define TZ7Z_PH_TEST     3

/* 条目事件 */
#define TZ7Z_EV_TICK     0   /* 只有字节，没有条目变化 */
#define TZ7Z_EV_ITEM     1   /* 进入某个条目（bytes_* 是进入时的快照） */
#define TZ7Z_EV_ITEM_DONE 2  /* 某个条目完成 */

typedef struct tz7z_progress_info
{
  uint32_t    struct_size;    /* caller sets sizeof */
  uint32_t    abi_version;    /* caller sets TZ7Z_ABI_VERSION */
  uint32_t    phase;          /* TZ7Z_PH_* */
  uint32_t    event;          /* TZ7Z_EV_* */
  uint32_t    item_index;     /* (uint32_t)-1 = 未知 */
  uint32_t    item_count;     /* 0 = 未知 */
  uint32_t    index_is_arc;   /* 1 = item_index 是归档内索引；0 = 客户端索引 */
  int32_t     packed_known;   /* packed_done 是否有效 */
  uint64_t    bytes_done;     /* 输入/解压字节（与 SetCompleted 同口径） */
  uint64_t    bytes_total;    /* 0 = 未知（引擎没给 SetTotal） */
  uint64_t    packed_done;    /* 累计压缩输出字节（TZ7Z_PH_CREATE）或已消耗压缩字节（PH_EXTRACT） */
  const char *item_name;      /* UTF-8，仅回调期间有效，可为 NULL */
} tz7z_progress_info;

/* 返回 1 = 继续，0 = 取消（与 tz7z_progress_fn 语义一致）；可在里面阻塞实现 pause。 */
typedef int (*tz7z_progress_ex_fn)(void *user, const tz7z_progress_info *info);

typedef struct tz7z_progress_sink
{
  uint32_t struct_size;       /* caller sets sizeof(tz7z_progress_sink) */
  uint32_t abi_version;
  tz7z_progress_ex_fn fn;     /* NULL = 不订阅 */
  void *user;
} tz7z_progress_sink;

/* 新入口：老函数原样保留，内部用 NULL sink 调 *_ex 实现，避免两份逻辑 */
int tz7z_open_ex(const char *path, const char *password,
                 const tz7z_progress_sink *sink,
                 tz7z_archive **out_archive, char *err, int err_capacity);
int tz7z_extract_ex(tz7z_archive *a, const uint32_t *indices, uint32_t count,
                    const char *out_dir, const char *password,
                    tz7z_progress_fn progress, void *user,          /* 旧回调仍然会收到 */
                    const tz7z_progress_sink *sink,
                    char *err, int err_capacity);
int tz7z_test_ex(...);        /* 同上 */
int tz7z_create_ex(const char *archive_path, const tz7z_create_options *options,
                   const tz7z_input *inputs, uint32_t count,
                   tz7z_progress_fn progress, void *user,
                   const tz7z_progress_sink *sink,
                   char *err, int err_capacity);
int tz7z_modify_ex(...);      /* 同上 */
```

约定：

- sink 里 `fn == NULL` 时 `*_ex` 与旧函数完全等价（便于 TyZip 分阶段上线）。
- 旧 `tz7z_progress_fn` 继续在每次 tick 时被调用（`completed/total` 语义不变），所以现有 percent 逻辑不动。
- 校验沿用现有风格：`CheckAbi(struct_size, abi_version, sizeof, ...)`（`tz7z.cpp:234-250`）。**不往旧结构里加字段**——`tz7z_create_options` 这类结构一旦长大，`sizeof` 严格比较会拒掉所有旧调用方。

### 9.2 C++ 侧改动（最小集）

1. `CUpdateCallback`（`tz7z.cpp:1414-1429`）：`Z7_COM_UNKNOWN_IMP_3` → `_5`，加 `ICompressProgressInfo` 与 `IArchiveUpdateCallbackFile`（宏存在：`CPP/Common/MyCom.h:429,438`；写法照抄 `UpdateCallback.h:87,99,103-104`），并 `Z7_IFACE_COM7_IMP(...)`。`IArchiveUpdateCallbackFile` 才能拿到 `notifyOp`（新增/更新/复制/重压）。
2. `CExtractCallback`（`tz7z.cpp:968-1020`）：`Z7_COM_UNKNOWN_IMP_2` → `_3`，加 `ICompressProgressInfo`。
3. `COpenCallback`（`tz7z.cpp:924-948`）：持有 sink，在 `SetTotal/SetCompleted` 里发 `phase=OPEN`（`files`/`bytes` 可能为 NULL → 对应字段留「未知」）。
4. 上报点（都在回调内部，天然串行，只有 `SetRatioInfo`/`SetCompleted` 需加锁）：
   - `GetStream(index)` → `EV_ITEM`，`item_name` 用 `_items[index].ArcPath`（create）或 `_names[index]`（extract，`tz7z.cpp:1145-1152` 已有）。
   - `SetOperationResult` → `EV_ITEM_DONE`（create 的 7z 路径在 `7zFolderInStream.cpp:137`，ZIP 在 `ZipUpdate.cpp:700,753`；extract 在 `7zExtract.cpp:112-122`）。
   - `SetTotal` / `SetCompleted` → `EV_TICK` + `bytes_total`/`bytes_done`。
   - `SetRatioInfo(in,out)` → `EV_TICK` + `packed_done`（create: `out`；extract: `in`）+ `packed_known=1`。
   - `GetProperty(kpidPath)` 时也可以顺手记下 index→名字缓存（extract 已这么做）。

### 9.3 线程与调用上下文（必须写进注释）

- `GetStream`/`GetProperty`/`SetOperationResult`/`PrepareOperation` 不会并发（`IArchive.h:186-190`）→ 条目事件可以直接发。
- `SetCompleted` / `SetRatioInfo` **可能**来自编码器内部线程，甚至与上面几个回调并发（`IArchive.h:186-192`）→ sink 调用必须串行化（一把 mutex，或只发无锁快照）。
- sink 是 C ABI 回调，**不得**在内部做 LCL/UI 操作；TyZip 现有 `TZJobSink.Tick` 只是存数字（`src/tzip.jobs.pas:166-175`），沿用这个约束。
- `tz7z.h:10-14` 的「同一 handle 不得两个线程同时用」不变；这里说的是引擎自己的内部线程。

### 9.4 明确不能提供（写死，免得反复试）

1. **归档最终压缩大小**：完成前不存在；只有 `packed_done` 累计值。
2. **create 期间单条目的压缩后大小**（尤其 solid）：per-entry pack size 在 folder 写完后才确定（`7zUpdate.cpp:2652-2653`）。
3. **solid 7z 提取时「本条目已消耗压缩字节」**：引擎只给块级（`7zExtract.cpp:306-308`）。
4. **7z 头解析百分比**：引擎不调 open 回调（§6）。
5. **精确速度 / 剩余时间**：引擎无字段，必须由 Pascal 侧按时间序列算（7-Zip GUI 也是自己算：`ProgressDialog2.cpp` 的 `UpdateStatInfo`/`_elapsedTime`）。
6. **任意时刻暂停**：只能停在回调边界（§7）。

---

## 10. 7-Zip GUI 字段 × 可行性

字段取自 7-Zip 自己的进度对话框（状态量 `ProgressDialog2.h:39-44`，格式化在 `ProgressDialog2.cpp` 的 `UpdateStatInfo` 与 `Set_Ratio`）。

| 7-Zip GUI 字段 | 现在可行 | 需桥接改动 | 不可行 | 依据 |
|---|---|---|---|---|
| 已完成 / 总字节 | ✅ | | | `tz7z_progress_fn` 已给；create=`输入字节`，extract=`解压字节`（§3.2/§5） |
| 百分比 | ✅ | | | `TzProgressPercent`（`src/tzip.progress.pas:28`） |
| 速度 / 已用 / 剩余时间 | ✅（UI 自算） | | | 引擎无字段，GUI 亦自算（`ProgressDialog2.cpp: UpdateStatInfo`） |
| 文件数 已完成 / 总计 | | ✅ | | 条目事件来自 `GetStream`+`SetOperationResult`（§3.1/§5） |
| 当前文件名 | | ✅ | | create 用 `ArcPath`，extract 用 `_names[index]`（已缓存） |
| 压缩率（in/out） | | ✅ | | 只在 `SetRatioInfo`（需实现 `ICompressProgressInfo`） |
| 实时输出体积 | | ✅ | | 同 `SetRatioInfo` 的 `out`；**累计值**，非最终值 |
| 打开：条目数百分比（ZIP） | | ✅ | | `ZipIn.cpp:1879-1881`，现在被 `tz7z.cpp:938-939` 丢弃 |
| 打开：百分比（7z） | | | ❌ | `7zIn.cpp` 无回调 |
| 打开：字节百分比（xz/rar） | | ✅ | | `XzHandler.cpp:434,561`；`RarHandler.cpp:1135,1220` |
| 最终压缩后总大小 | | | ❌ | 归档完成前未知 |
| 单条目压缩后大小（create 中） | | | ❌（solid）/ ⚠️（非 solid 也只能事后） | `7zUpdate.cpp:2652-2653` |
| 错误计数 / 消息 | ✅ | | | `tz7z` 的返回码 + `err` 缓冲 |
| 「后台」状态 | ✅（UI + 线程优先级） | | | 非 ABI（`ProgressDialog2.cpp:1150-1156` 是同一思路） |
| 「暂停」 | | ✅（在 sink 里阻塞，无需新 ABI） | | `ProgressDialog2.cpp:91-112` |

---

## 11. 证据索引（按文件）

**接口声明**

- `CPP/7zip/IProgress.h:12-14` — `SetTotal` / `SetCompleted`
- `CPP/7zip/ICoder.h:14-16` — `ICompressProgressInfo::SetRatioInfo`
- `CPP/7zip/IArchive.h:17-18,177-181` — `IArchiveOpenCallback`（`IUnknown` 基类，files/bytes）
- `CPP/7zip/IArchive.h:186-192` — 回调并发约束
- `CPP/7zip/IArchive.h:214-223` — extract 的 `SetCompleted` 口径（packSize vs unpackSize）
- `CPP/7zip/IArchive.h:234-239` — `IArchiveExtractCallback`
- `CPP/7zip/IArchive.h:258-260` — `IArchiveExtractCallbackMessage2`
- `CPP/7zip/IArchive.h:305-307` — `IInArchive` 不可多线程
- `CPP/7zip/IArchive.h:316-328` — `IInArchive`
- `CPP/7zip/IArchive.h:416-425,445-451` — `IArchiveUpdateCallback` + `GetUpdateItemInfo` 语义
- `CPP/7zip/IArchive.h:454-458,460-477,486-490` — `IArchiveUpdateCallback2`、`NUpdateNotifyOp`、`IArchiveUpdateCallbackFile`
- `CPP/7zip/PropID.h:13,16,17,18` — `kpidPath/kpidIsDir/kpidSize/kpidPackSize`
- `CPP/Common/MyCom.h:429,438` — `Z7_COM_UNKNOWN_IMP_4/5`

**create / update**

- `CPP/7zip/UI/Common/UpdateCallback.h:33-50,87,99,103-104` — 7-Zip 自己怎么实现 `ICompressProgressInfo`
- `CPP/7zip/UI/Common/UpdateCallback.cpp:103-122,148,588-596,623` — 转发与 `CheckBreak`
- `CPP/7zip/Common/ProgressUtils.h:8-33` / `.cpp:14-27,39-49` — `CLocalProgress`（`inSizeIsMain` 决定 `SetCompleted` 口径）
- `CPP/7zip/Archive/7z/7zUpdate.cpp:1906-1907,2071-2091,2377-2389,2581,2652-2653` — QI、`SetTotal`、`ReportOperation`、编码进度
- `CPP/7zip/Archive/7z/7zEncode.cpp:103-120,437,466-467` — 真实输出字节进 `SetRatioInfo`
- `CPP/7zip/Common/CWrappers.cpp:63-68` — LZMA SDK 进度 → `SetRatioInfo`
- `CPP/7zip/Archive/7z/7zFolderInStream.cpp:124-137` — 7z 逐条目 `SetOperationResult`
- `CPP/7zip/Archive/Zip/ZipUpdate.cpp:303-305,355-412,449-455,657,667-669,700,753,927-928,1234-1237,1344,1352`

**extract**

- `CPP/7zip/Archive/7z/7zExtract.cpp:89,112,122,272,274-275,306-308`
- `CPP/7zip/UI/Common/ArchiveExtractCallback.cpp:377-378,397-405,430-445,451-455,1698,1734,2825`
- `CPP/7zip/Compress/LzmaDecoder.cpp:213`、`CPP/7zip/Compress/DeflateDecoder.cpp:413` — 解码器 `SetRatioInfo`
- `CPP/7zip/Archive/GzHandler.cpp:682`、`Bz2Handler.cpp:182`、`XzHandler.cpp:1036-1039` — 单流格式的 packSize 口径

**open**

- `CPP/7zip/Archive/Zip/ZipIn.cpp:1879-1881,1926-1931`
- `CPP/7zip/Archive/XzHandler.cpp:434,561`；`RarHandler.cpp:1135,1220`；`Rar5Handler.cpp:2313,2551`；`IsoIn.cpp:403`；`WimIn.cpp:1694`
- `CPP/7zip/UI/GUI/UpdateCallbackGUI.cpp:196-209`；`CPP/7zip/UI/Console/OpenCallbackConsole.cpp:20-70`

**pause / background**

- `CPP/7zip/UI/FileManager/ProgressDialog2.cpp:49,91-112,1130-1141,1150-1156`
- `CPP/7zip/UI/FileManager/ProgressDialog2.h:32-45,39-44,68-72`
- `CPP/7zip/UI/FileManager/ProgressDialog.cpp:22-31`
- `CPP/7zip/UI/GUI/UpdateCallbackGUI.cpp:82-85,139-142`

**TyZip 侧**

- `backend/tz7z.h:10-14,52-58,143-144`
- `backend/tz7z.cpp:234-250,924-948,968-1020,1024-1030,1095-1122,1124-1152,1325,1394-1412,1414-1429,1443-1462,1464-1489,1524,1694,1707-1711,3153-3156`
- `src/tzip.api.bind.pas:78`（`TZ7ZProgressFn`）
- `src/tzip.engine.pas:255-360`（convert = extract+create）、`:796-838`（枚举进度）
- `src/tzip.jobs.pas:166-175,196,581`
