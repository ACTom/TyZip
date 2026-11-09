# PeaZip 规模定量画像（用于 TyZip vs PeaZip 差距分析）

- 抓取/统计日期：**2026-10-27**（Asia/Shanghai）。所有 API/网页数据均为该日实测。
- 只读调研：除本文件外未修改任何文件；未 clone PeaZip 仓库（仅下载 `sources` 分支的 codeload tarball 到 `/tmp` 做 LOC 统计，不入工作区）。
- 口径标注：**【官方】**= 官网/仓库文档原文声称；**【实测】**= 本次对 GitHub API / 分支 tarball / 发行资产直接统计；**【未知】**= 未取到，附获取方法。

---

## 1. 一句话结论

PeaZip 11.4.0（2026-10-17 发布）是一个**持续 20 年、178 次公开发布**的跨平台归档管理器：**161,556 行 Pascal 代码（209,790 物理行 / 324 个文件）**，其中主 GUI 单元 `peach.pas` 单文件 **80,938 行**（74,121 代码行，占全部 Pascal 代码 45.9%），**19 个 Lazarus 窗体共 33,763 行 `.lfm`**、**2,076 个菜单项**、**221 个 CLI 开关**；功能由 **9 个外部后端二进制目录**（7-Zip 26.04、FreeArc 0.67、Brotli、Zstd、ZPAQ/Zpaqfranz、PAQ/LPAQ、QUAD/BALZ/BCM、UPX + 自研 Pea 1.34）加 2 个许可受限插件（UNACE/UNRAR）拼装，官方称可打开 **243 种扩展名**、可创建约 **20 个格式族**，**55 个语言文件 / 1,386 条界面字符串**。仓库 8,020 star、95 个 GitHub release（1,773 个资产、19.1 GB、累计 1,625 万次下载）。

对 TyZip 的量级锚点：TyZip 同口径（2026-10-29，commit `d7b8310`，版本 0.3.0）为 **20,164 代码行 / 28,048 物理行 / 49 个文件**（§8），PeaZip 约为其 **8.0× 代码行 / 7.5× 物理行 / 6.6× 文件数**。

---

## 2. 关键数字总表（均 2026-10-27 实测）

| 维度 | 数值 | 口径/来源 |
|---|---|---|
| 最新版本 / 发布日期 | **11.4.0 / 2026-10-17** | 【实测】<https://api.github.com/repos/peazip/PeaZip/releases?per_page=100> |
| 源码内版本表末日 | 11.4.0 / 2026-10-13（包发布日 10-17） | 【实测】`peach.pas` 头部版本表 |
| 首次公开发布 | **PeaZip 1.0 @ 2006-11-03** | 【实测】`peach.pas` 版本表（0.13 行注 "Changed name of the release to PeaZip 1.0"） |
| 项目起点 | Pea-Peach 0.10 @ 2006-09-08 | 【实测】同上（"Initial version named Pea-Peach 0.10"） |
| 公开版本总数 | **178**（1.0 → 11.4.0，含 2.x/3.x beta 与 x.y.a 修订） | 【实测】`peach.pas` 版本表 181 行 − 3 行 Pea-Peach 开发期 |
| GitHub release / tag 数 | **95 / 95**（5.4.0 2014-07-11 → 11.4.0） | 【实测】releases & tags API |
| 发布节奏 | 平均 **8.9 版/年**；版本间隔中位数 **35 天**、均值 41.2 天 | 【实测】178 个版本日期计算 |
| GitHub 仓库 | 创建 2010-11-13，默认分支 `sources`，最后 push 2026-10-21，**size 239,315 KB ≈ 234 MB** | 【实测】`/repos/peazip/PeaZip` |
| 工作树体积 | **≈21.5 MB**（`peazip-sources` 20,447 KB + `PeaZip.ShellEx` 1,018 KB）；分支 tarball 6.5 MB | 【实测】git tree API / codeload |
| 工作树文件数 | **1,107 个 blob / 132 个目录**（根层 9 个文件 + 4 个目录：`.github`、`PeaZip.ShellEx`、`peazip-sources`、`use`） | 【实测】`git/trees/sources?recursive=1`（`truncated:false`） |
| GitHub linguist 语言占比 | Pascal **91.94%**（7,514,889 B）、Inno Setup 5.69%（464,899 B）、Batchfile 1.70%、C++ 0.43%、Shell 0.11%、C 0.08% | 【实测】`/repos/peazip/PeaZip/languages` |
| Pascal 代码量（实测） | **324 个文件 / 209,790 行 / 161,556 代码行**（注释 27,080，空行 21,154；代码占 77.0%） | 【实测】分支 tarball + 自写去注释计数器（§9） |
| 单文件最大 | `dev/peach.pas` **80,938 行 / 74,121 代码行**；占 Pascal 代码 **45.9%** | 【实测】同上 |
| 窗体定义 | **19 个 `.lfm` / 33,763 行**，主窗体 `peach.lfm` 26,649 行 | 【实测】`wc -l dev/*.lfm` |
| 菜单/动作规模 | TMenuItem **2,076**（主窗体 1,947）、TAction 120、TPopupMenu 52、TStringGrid 23、快捷键定义 **203**、Caption 2,285 | 【实测】`grep` 统计 19 个 `.lfm` |
| CLI 开关数 | **221 个** 不同的 `-xxx` 开关字面量 | 【实测】`grep -o "'-[a-z0-9_]*'" peach.pas \| sort -u` |
| 可打开格式数 | **243 种扩展名**【官方 11.4.0 changelog】；官网营销语「over 200 archive formats」 | 见 §5 |
| 可创建格式族 | **≈20 个**（7z、arc/wrc、sfx(7z/arc)、br、bz2、gz、xz、paq/lpaq/zpaq、pea、quad/balz/bcm、rar(需 Rar.exe)、split、tar、upx、wim、zip/zipx、zst） | 见 §5 |
| 语言数 | **55 个语言文件**（含 `default.txt`/`en`/`en-gb` 变体）、**1,386 条**可翻译 key、82,679 行 | 【实测】`res/share/lang/*.txt`；【官方】"over than 50 languages" |
| 外部后端 | `res/bin/` 下 **9 个子目录**（7z/arc/brotli/lpaq/paq/quad/upx/zpaq/zstd）+ unace/unrar 插件；版本见 §5 | 【实测】`res/bin/`、`externalprograms.pas` |
| 发行资产 | 95 个 release 共 **1,773 个资产 / 19.1 GB / 16,254,790 次下载**；最新版 22 个资产 | 【实测】releases API `assets[].download_count/size` |
| 最新版最大包 | `peazip-11.4.0.pack.zip` 65.0 MB；`DARWIN.x86_64.dmg` 25.8 MB；`WIN64.zip` 15.7 MB；`WIN64.exe` 10.9 MB；`src.zip` 6.0 MB | 【实测】同上 |
| 社区规模 | **8,020 star / 422 fork / 84 watcher / 18 open issues**；contributors **44**（API 计数，含 anonymous） | 【实测】repo API + contributors Link header |
| 许可 | **LGPL-3.0**（GitHub 识别 `lgpl-3.0`）；文档 GNU FDL；PEA 格式规范 public domain | 【实测】API license 字段 + <https://peazip.github.io/peazip-free-archiver.html> |

---

## 3. 代码与仓库结构

### 3.1 仓库布局（【实测】git tree API，2026-10-27）

| 路径 | blob 数 | 体积 | 内容 |
|---|---|---|---|
| `peazip-sources/dev/` | 513 | 11,655.6 KB | 全部 Pascal 源码、`.lfm`/`.lrs`、构建脚本（`#*.bat`、`*.sh`）、Inno Setup 脚本、第三方 Pascal 库 |
| `peazip-sources/res/` | 464 | 8,772.9 KB | `bin/`（后端二进制占位）、`share/`（lang 55、themes 21、batch 254、help pdf 1.4 MB、icons 35、presets 16）、`conf/`、`portable/` 标记文件 |
| `PeaZip.ShellEx/` | 111 | 1,018 KB | Windows 11 Explorer 右键菜单扩展（C++/WinRT `IExplorerCommand`）+ MSIX 打包工程 + 31 语言 `.resw` |
| `.github/workflows/` | 9 | 11 KB | CI：`make.yml`（矩阵构建）、`make.pas`（用 Pascal 写的构建编排器，224 行）、`setup.sh`/`setup.ps1` |
| 根文件 | 7 | ~22 KB | `LICENSE`(LGPLv3) `README.md` `README.zh.md` `CHANGELOG.md`(仅 93 B，指向官网) `CONTRIBUTING.md` `SECURITY.md` `.gitmodules` |

`res/bin/` 在源码包里**只有占位文件**（`place 7z binary here.txt` 等），共 9 个子目录：`7z/ arc/ brotli/ lpaq/ paq/ quad/ upx/ zpaq/ zstd/`——第三方二进制因「平台相关」不入库，由打包时填充（`peazip-sources/readme.txt` 第 4 步）；这与「PeaZip 是外部 CLI 前端 + 自研 PEA 引擎」的架构一致。

### 3.2 Pascal 代码量分解（【实测】自写去注释计数器，`.pas/.dpr/.inc/.lpr` 共 324 个文件）

| 分组 | 文件 | 物理行 | 代码行 | 说明 |
|---|---|---|---|---|
| `dev/` 顶层（PeaZip 自有 + 加密库） | 291 | 186,580 | 145,558 | 见下两行拆分 |
| ├ 其中 PeaZip 自有 | 132 | 129,581 | **113,449** | 含 `peach.pas` 74,121 |
| └ 其中 Wolfgang Ehrhardt 加密/哈希库（AES、SHA-3、Blake2、CRC、HMAC、TF 测试框架等） | 159 | 56,999 | **32,109** | 文件头含 "Ehrhardt"，第三方 vendored |
| `dev/dragdropfilesdll.src/` | 21 | 19,151 | 12,649 | Lazarus-CCR 拖放库（Windows DLL） |
| `dev/metadarkstyle/` | 12 | 4,059 | 3,349 | 第三方（zamtmn）Windows 暗色标题栏库 |
| **合计** | **324** | **209,790** | **161,556** | 注释 12.9%，空行 10.1% |

> 口径提示：PeaZip 自有代码 113,449 行中，`peach.pas` 独占 74,121 行，其余 131 个单元共 39,328 行（均 300 行/单元）；`pea.pas`（PEA 格式引擎/CLI）8,061 行。若要对比「TyZip 式单体应用」的等价规模，`peach.pas + pea.pas + list_utils + unitgwrap + pea_utils` ≈ **89,285 代码行**。

### 3.3 最大的 10 个 Pascal 文件（【实测】代码行）

| 文件 | 物理行 | 代码行 | 角色 |
|---|---|---|---|
| `dev/peach.pas` | 80,938 | 74,121 | 主 GUI（文件浏览器 + 归档/解压/选项三屏 + 脚本引擎） |
| `dev/pea.pas` | 9,121 | 8,061 | PEA 格式引擎与 CLI |
| `dev/list_utils.pas` | 3,452 | 2,691 | 归档类型判定/扩展名分派（366 个扩展名字面量） |
| `dev/sp_base.pas` | 3,426 | 2,910 | 加密/工具基础库 |
| `dev/unitgwrap.pas` | 3,115 | 2,637 | Ehrhardt 数学库封装 |
| `dev/dragdropfilesdll.src/DragDropFile.pas` | 3,282 | 2,468 | 拖放库 |
| `dev/metadarkstyle/src/uwin32widgetsetdark.pas` | 2,419 | 2,002 | 暗色样式 |
| `dev/pea_utils.pas` | 2,482 | 1,975 | 路径/参数工具 |
| `dev/t_hmac.pas` | 2,137 | 1,794 | Ehrhardt HMAC 测试 |
| `dev/unitreport.pas` | 1,477 | 1,268 | 任务日志/报告窗体 |

### 3.4 UI 规模（【实测】19 个 `.lfm` 的对象统计）

TMenuItem **2,076**（主窗体 1,947）、TLabel 377、TPanel 169、TCheckBox 140、**TAction 120**、TComboBox 104、TShape 98、TSpeedButton 87、TImage 59、**TPopupMenu 52**、TEdit 50、TBitBtn 39、**TStringGrid 23**、TButton 20、TSpinEdit 19、TActionList 7、TImageList 11；`ShortCut =` 定义 **203** 处（主窗体 138）；`Caption =` 2,285 处。

主程序单元清单（`dev/project_peach.lpr`）：`peach, UnitPW, UnitKF, UnitInput, UnitWeb, UnitAdvf, UnitPM, UnitImgRes, UnitImgCrop, UnitDrop, UnitPaths, UnitSelect, UnitDlg, UnitGwrap, UnitComment, UnitImgViewer` + Windows 专用 `umetadarkstyle, udarkstyleparams, udarkstyleschemes`。

### 3.5 其它代码与资源

| 项目 | 数值 | 来源 |
|---|---|---|
| Inno Setup 安装脚本 | 3 个 `.iss`，**9,649 行**（Win64/Win32/configure） | 实测 `wc -l dev/installer/*.iss` |
| Lazarus 窗体资源 `.lrs` | 19 个 / 14,419 行（生成物） | 实测 |
| ShellEx（C++/WinRT） | 111 文件，C++/头文件 **≈1.1k 行**，31 个语言 `Resources.resw` | 实测 |
| CI 构建编排 | `.github/workflows/make.pas` 224 行 Pascal | 实测 |
| 集成脚本 | `res/share/batch/` **254 个**：Windows 88、freedesktop_integration 81、macOS service menus 36、bat 24、sh 24 | 实测 |
| 主题 | **21 个** `.theme.7z` + 2 个内嵌主题目录；图标 35 个 | 实测 `res/share/themes|icons` |
| 预设 | 压缩预设 15 个 + 自定义槽 1 个（`presets/0..15.txt`） | 实测 |
| 平台条件编译块 | `{$IFDEF MSWINDOWS}` **794**、`DARWIN` 90、`LINUX` 24、`FREEBSD` 17、`NETBSD` 16、`WIN64` 6、`CPUAARCH64` 2 | 实测 `grep -c`（`dev/*.pas`） |

---

## 4. 平台与构建矩阵

### 4.1 官方支持矩阵（【官方】<https://peazip.github.io/> 首页 + 各下载页）

| 平台 | 官方支持状态 | 架构 | 包类型 |
|---|---|---|---|
| Windows | Supported（MS Windows、ReactOS、Wine） | x86_64（WIN64）、x86（WINDOWS） | 安装版 `.exe`（Inno Setup）、便携 `.zip`、**MSIX**（`PeaZip_11.4.0.0_x64…msix`）、Win11 右键菜单扩展 |
| Linux | Supported（x86_64、x86）；aarch64 为 Experimental | x86_64、aarch64、x86 | `.deb`、`.rpm`（GTK2 与 Qt6 各一版）、便携 `.tar.gz`（GTK2 / Qt6 / **GTK3-alpha**）、Flatpak（Flathub，aarch64+x86_64） |
| macOS / Darwin | Supported | aarch64（Apple Silicon）、x86_64 | `.dmg`、`.zip`；需 `xattr -dr com.apple.quarantine` |
| BSD | 随 macOS 通道发布 | x86_64 | 便携 `.tar.gz`（BSD.GTK2） |

- macOS 兼容性：x86_64 版面向 Intel CPU（OSX 至 macOS 10.15 Catalina），aarch64 版面向 Apple Silicon（macOS 11 Big Sur 及更新），两者均为 **Cocoa** widgetset；从源码构建需 Lazarus/FPC 2.2RC 以上（【官方】<https://peazip.github.io/peazip-macos.html>）。
- Linux 桌面集成：Wayland 可用、GNOME/KDE/XFCE 集成脚本见 `res/share/batch/freedesktop_integration`（81 个文件）。
- 界面技术：**FreePascal + Lazarus（LCL）**，多 widgetset 编译（Win32/64、GTK2、GTK3-alpha、Qt5/Qt6）——【官方】<https://peazip.github.io/peazip-sources.html>；11.4.0 用 **Lazarus 4.x** 编译，兼容 3.x/2.x（【官方】changelog）。源码含 ASM 段，但保留纯 Pascal 替代实现以便移植。

### 4.2 最新版发行资产（【实测】11.4.0，22 个资产）

| 资产 | 大小 |
|---|---|
| `peazip-11.4.0.pack.zip`（打包示例） | 65.0 MB |
| `peazip-11.4.0.DARWIN.x86_64.dmg` / `DARWIN.aarch64.dmg` | 25.8 / 25.0 MB |
| `peazip-11.4.0.DARWIN.x86_64.zip` | 22.7 MB |
| `PeaZip_11.4.0.0_x64__….msix` | 19.7 MB |
| `peazip_portable-11.4.0.LINUX.Qt6.x86_64.tar.gz` | 17.2 MB |
| `peazip_portable-11.4.0.LINUX.GTK3-alpha.x86_64.tar.gz` | 17.0 MB |
| `peazip_portable-11.4.0.LINUX.GTK2.x86_64.tar.gz` | 16.7 MB |
| `peazip_portable-11.4.0.WIN64.zip` | 15.7 MB |
| `peazip_11.4.0.LINUX.Qt6-1_amd64.deb` / `GTK2-1_amd64.deb` | 14.3 / 13.8 MB |
| `peazip-11.4.0.LINUX.Qt6-1.x86_64.rpm` / `GTK2-1.x86_64.rpm` | 12.7 / 12.3 MB |
| `peazip_portable-11.4.0.LINUX.GTK2.aarch64.tar.gz` | 12.2 MB |
| `peazip_portable-11.4.0.WINDOWS.zip`（32 位便携） | 11.9 MB |
| `peazip-11.4.0.WIN64.exe` | 10.9 MB |
| `peazip_portable-11.4.0.BSD.GTK2.x86_64.tar.gz` | 10.1 MB |
| `peazip-11.4.0.WINDOWS.exe`（32 位安装版） | 8.3 MB |
| `peazip-11.4.0.src.zip` | 6.0 MB |
| `peazip-11.4.0.about_translations.zip` | 1.6 MB |
| `peazip_help.pdf`（离线手册） | 1.4 MB |
| `SHA256.txt` | — |

历史资产统计（95 个 release 汇总）：`.zip` 436、`.tar.gz` 320、`.deb` 231、`.exe` 191、`.rpm` 171、`.msi` 118、`.dmg` 68、`.msix` 50、`.pdf` 80；合计 1,773 个资产 / **19.1 GB** / 16,254,790 次下载；最新单一 release 下载 78,549 次。

### 4.3 CI 矩阵（【实测】`.github/workflows/make.yml`）

`os: [ubuntu-latest, windows-latest] × arch: [x86_64, aarch64]`，超时 120 分钟，checkout 带 submodules（`use/metadarkstyle`）。
→ **CI 只覆盖 Linux/Windows × 2 架构；macOS 与 BSD 包不在 CI 矩阵内**（由维护者本地构建，属推断，未见 CI 配置）。

---

## 5. 内嵌引擎与格式支持

### 5.1 外部后端清单与版本（【实测】`dev/externalprograms.pas` L56–L140，11.4.0 源码）

| 后端 | Windows | Linux x86_64 | Linux aarch64 | macOS | BSD |
|---|---|---|---|---|---|
| **7-Zip（核心）** | 7z **26.04** + Tino Reichardt sfx/codecs 24.09-v1.5.7-R1 | 7z **26.04** + 7-Zip ZS 25.01-v1.5.7-R4 | 7z 26.04 | 7z **26.04** + cielavenir/p7zip 24.09.1 | 7z **21.07**（明显滞后） |
| **Pea（自研 PEA 格式）** | Pea **1.34**（LGPLv3, G. Tani） | 同 1.34 | 同 | 同 | 同 |
| PAQ 家族 / ZPAQ | PAQ8F/JD/L/O、LPAQ1/5/8、**Zpaqfranz 62.5**（x64）/ Zpaq 7.15（x86） | 同 PAQ/LPAQ + Zpaqfranz **59.8** | 无 | Zpaqfranz **61.2** | 无 |
| FreeArc | **0.67 alpha** | 0.60 | 无 | 无 | 无 |
| Brotli | **1.2.0** | 1.0.7 | 1.1.0 | 1.1.0 | 1.0.9 |
| Zstandard | **1.5.7** | 1.5.7 | 1.5.7 | 1.5.2 | 1.4.8 |
| UPX / Strip | UPX 3.95 / GNU strip | UPX 3.96 | GNU strip | GNU strip | GNU strip |
| QUAD/BALZ/BCM | QUAD 1.12 / BALZ 1.15 / BCM 1.0 | 同 | 无 | 无 | 无 |
| UNACE | UNACEV2.DLL **2.6.0.0**（闭源插件） | UNACE for Linux（插件） | 无 | 无 | 无 |
| UNRAR | UNRAR 5.21（可选插件，默认走 7-Zip unrar 实现） | UNRAR 5.21 beta 2 | 无 | 无 | 无 |

补充（【官方】changelog）：11.0.0=7z 26.00/Pea 1.30、11.1.0=26.01/Pea 1.31、11.2.0=26.02/Pea 1.32、11.3.0=26.03/Pea 1.33、11.4.0=26.04/Pea 1.34。Linux 侧的 `7zalt` 别名指向 cielavenir/p7zip 分支，提供 Brotli、FLZMA2、Lizard、LZ4、LZ5、Zstd 等 7z 扩展算法（非标准 7z 兼容）。
⚠️ 与 TyZip 的对照点：TyZip 用 **7-Zip 26.03** 动态库（= PeaZip 11.3.0 的后端版本）；PeaZip 11.4.0 已升到 26.04。

### 5.2 格式数量：三种口径并存

| 口径 | 数值 | 来源/日期 |
|---|---|---|
| 官网营销语 | "**over 200** archive formats" / "200+ file types" | 【官方】<https://peazip.github.io/> 首页（2026-10-27） |
| 官方精确值（11.4.0） | "**A total of 243 file extensions** can now be opened as archives"（新增 `.ZIM`） | 【官方】<https://peazip.github.io/changelog.html>（2026-10-27） |
| 官网格式清单页枚举 | 93 个逗号条目、括号展开后 **≈118 个扩展名**（示例清单，非全量） | 【实测】<https://peazip.github.io/peazip-free-archiver.html> 文本解析 |
| 源码内的扩展名字面量 | `dev/*.pas` 中 **484** 个不同 `.ext`；`list_utils.pas` 366 个、`peach.pas` 276 个（含图片/视频/源码等"查看器关联"类型，非全是归档） | 【实测】正则统计 `dev/*.pas` |

**可创建（write）格式**（【官方】<https://peazip.github.io/peazip-free-archiver.html> "Full (read/write) support" + <https://peazip.github.io/peazip-64bit.html>）：
`7z`、`arc/wrc`(FreeArc)、`sfx`(7z sfx、arc sfx)、`br`、`bz2`、`gz`、`xz`、`paq/lpaq/zpaq`、`pea`、`quad/balz/bcm`、`rar`（仅当系统装有 Rar.exe）、`split`、`tar`、`upx`、`wim`、`zip/zipx`、`zst` → **约 20 个格式族**。
（注：官网两处清单对 `xz` 是否可创建表述不一致——`free-archiver` 页 "Full support" 未列 xz，`64bit` 页列出 XZ；源码存在 `-add2xz` 开关（`peach.pas` L62521），故实测支持创建 xz。）

**加密能力**（【官方】同上）：7Z=AES256；ZIP=WinZip AES256 AE + 传统 ZipCrypto（可解密 PKZip AES）；ARC=FreeArc AES256/Blowfish/Twofish256/Serpent256；PEA=AES256 **EAX 认证加密**；RAR（经 Rar.exe）=RAR4 AES128 / RAR5 AES256；**两因素认证**（密码 + keyfile，SHA256 后 Base64 前置，自 v2.1 起）。

### 5.3 官方列举的可读格式（【官方】`peazip-free-archiver.html`，代表项）

`7z, apk, br, bz, bz2, bzip2, tbz2, tbz, zst, tzst, gz, gzip, tgz, tpz, tar, zip, zipx, z01, smzip, arj, cab, chm/chi/chq/chw/hxs/hxi/hxr/hxq/hxw, lit, cpio, deb, lzh/lha, rar(含 RAR5,r01,00..), rpm, z, taz, tz, iso, jar/ear/war, pet, pup, pak, pk3/pk4, slp, [Content], xpi, wim, u3p, lzma86, lzma, udf, xar, dmg, hfs, part1, split, swm, kmz, xz, txz, vhd, mslz, apm, mbr, fat, ntfs, exe, dll, sys, msi, msp, ods/ots/odm/oth/oxt/odb/odf/odg/otg/odp/otp/odt/ott, gnm, doc/dot/xls/xlt/ppt/pps/pot/docx/dotx/xlsx/xltx, swf/flv, quad, balz, bcm, zpaq, paq8f/paq8jd/paq8l/paq8o, lpaq1/5/8, ace(闭源插件), arc, wrc, 001, pea, cbz/cbr/cba/cb7/cbt`。
扩展机制：`Open as archive` 可对任意扩展名强制按归档解析；可将 7-Zip Codecs 放入 `res/7z/Codecs` 扩展解析能力（【官方】同上）。

### 5.4 插件（【官方】<https://peazip.github.io/peazip-add-ons.html>）

1. **Additional Formats Plugin v7**（补齐 RPM 等被裁剪的后端二进制）；
2. **UNACE plugin**（UNACEV2.DLL，闭源、许可与 LGPLv3 不兼容）；
3. **UNRAR5 plugin**（可替换 7-Zip 的 unrar 实现）；
4. **sfx modules**（自解压模块）。

---

## 6. 版本历史与迭代节奏

### 6.1 里程碑（【实测】`peach.pas` 头部版本表 181 行）

| 主版本 | 该系列首发日期 | 该系列版本数 | 备注 |
|---|---|---|---|
| 0.x Pea-Peach | 2006-09-08 | 3（0.10–0.12，未公开发布） | 0.13 改名 PeaZip 1.0 |
| **1.0** | **2006-11-03** | **17**（1.0–1.11） | 首个公开版；0.13 行即 1.0 |
| 2.0 | 2008-03-19 | 22（含 2.3a、2.6.beta–2.9.beta） | |
| 3.0 | 2010-02-09（3.0.beta） | 17 | |
| 4.0 | 2011-09-18 | 18 | |
| 5.0.0 | 2013-06-17 | 24 | GitHub release 自 5.4.0（2014-07-11）起 |
| 6.0.0 | 2016-02-21 | 23 | |
| 7.0.0 | 2019-11-25 | 19 | |
| 8.0.0 | 2021-06-09 | 10 | |
| 9.0.0 | 2022-12-15 | 12 | |
| 10.0.0 | 2024-10-19 | 11 | |
| 11.0.0 | 2026-04-05 | 5（至 11.4.0） | 当前系列 |
| **合计** | 2006-11-03 → 2026-10-13 | **178** | 平均 8.9 版/年 |

### 6.2 逐年版数（178 个公开版本）

| 年 | 06 | 07 | 08 | 09 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26(至10月) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 版数 | 2 | 14 | 7 | 13 | 14 | 10 | 10 | 10 | 8 | 10 | 8 | 4 | 3 | 10 | 13 | 9 | 6 | 6 | 8 | 7 | 6 |

- 间隔统计（177 个间隔）：中位 **35 天**、均值 41.2 天、最短 4 天（9.7.0→9.7.1，2024-02-09→02-13）、最长 **174 天**（6.6.0→6.6.1，落在 2017–2018 低谷，全年仅 4/3 版）。
- 最近 12 个间隔：10.3→10.4 46d、10.4→10.5 65d、10.5→10.6 58d、10.6→10.6.1 8d、10.6.1→10.7 62d、10.7→10.8 47d、10.8→10.9 64d、10.9→11.0 61d、11.0→11.1 33d、11.1→11.2 61d、11.2→11.3 78d、11.3→11.4 19d。
- 交叉验证：版本表中 ≥5.4.0 的条目恰好 **95 个**，与 GitHub 的 95 个 release/tag 完全一一对应（无遗漏/多余）；即 1.0–5.3.1 的 **83 个版本**只经由 SourceForge 分发，GitHub release 里没有资产明细。
- 节奏结论：**单作者、约 6 周一个版本、20 年不断**（版本表里作者列始终是 `G.Tani`）。

---

## 7. 国际化、发行与特色能力

### 7.1 国际化（【实测】`res/share/lang/`）

| 指标 | 数值 |
|---|---|
| 语言文件数 | **55** 个 `.txt`（含 `default.txt` 兜底、`en`、`en-gb`；另有 `fr_alt`、`de-uml`、`by-cr`/`by-lt` 等变体） |
| 文件格式 | 纯文本 UTF-8(BOM) + CRLF，`key: value` 行式，**不是** `.po/.mo`；每条含 `=== PeaZip text group ===` 分组与版本号（`en.txt` 头部标注 `11.4`，1,497 行） |
| 可翻译 key 数 | **1,386** 条（`en.txt` 中 `^[A-Za-z0-9_]+:` 计数） |
| 翻译文本总量 | **82,679 行**（55 文件合计，均 ~1,500 行/语言） |
| Windows 右键菜单本地化 | `res/share/lang-wincontext/` **37 个 `.reg`** / 2,720 行 |
| ShellEx（Win11 右键菜单）本地化 | `PeaZip.ShellEx/.../Strings/` **31 个语言** `.resw` |
| 官方说法 | "**over than 50 languages**"（changelog 11.4.0）；旧页写 "localized over than 30 languages"（口径已过时） |
| 翻译社区 | 独立仓库 <https://github.com/peazip/PeaZip-Translations>（gh-pages 站点，2015-07-23 创建，22 star / 10 fork；语言文件随每个 `x.y.z` release 以 `peazip-x.y.z.about_translations.zip`（1.6 MB）发布） |

### 7.2 许可与合规

- 应用：**LGPLv3**（`LICENSE` 7,639 B；GitHub API `license.spdx_id = LGPL-3.0`；官网多页重复强调）。
- 文档：**GNU FDL**（【官方】首页 TOS 段）。
- PEA 格式规范：**public domain**（【官方】`peazip-free-archiver.html` 项目目标段）。
- 第三方许可说明文件 15 个（`res/share/copying/third-parties/`）：7z(LGPL)、7z codecs、arc(GPL)、bcm、brotli(MIT)、lpaq、paq、upx(GPL)、zpaq(GPL)、zpaqfranz、zstd(BSD/GPLv2)；UNACE/UNRAR 因许可限制只能作为**可选插件**分发。

### 7.3 发行形态

- **便携优先**：删空 `res/portable` 标记文件即切换为「安装模式」（配置写用户目录），同一份代码同时产出 Portable 与 Installable（【官方】`peazip-sources/readme.txt`）。
- 安装包：Windows 用 **Inno Setup**（3 个 `.iss`，9,649 行）；另有 **MSIX**（`PeaZip.ShellEx` 的 Windows Application Packaging Project）；Linux `.deb/.rpm`（GTK2 + Qt6 双构建）+ Flatpak；macOS `.dmg`/`.zip`。
- 完整性：不发数字签名，改用 **SHA256.txt** 随 release 发布（官方说明）。
- 文档：离线 `peazip_help.pdf` 1.4 MB 随每个 release 分发 + 在线 FAQ/教程/Wiki。

### 7.4 特色能力（用于「功能面」对标，均【官方】）

| 能力 | 现状 |
|---|---|
| 脚本引擎 | GUI 里定义的任务可从 "Console" 页**导出为 CLI 脚本**（.bat/.ps1/sh），`Tools > Saved task definition scripts`；大量任务开关（源内 `-xxx` 开关 221 个） |
| CLI 前端 | 同一二进制 `peazip` 可带开关无界面执行（`-add2*`、`-ext2*` 等族） |
| SFX | 支持 7z sfx / arc sfx；附 sfx 模块插件 |
| PEA 格式 | 自研"Pack Encrypt Authenticate"，AES256 **EAX 认证加密**、2FA、完整性校验、可对格式做密码学分析（作者自述） |
| 安全 | 强加密（AES/Twofish/Serpent/Blowfish）、加密密码管理器（11.3 起强制主密码）、keyfile 2FA、**secure delete**、hash/checksum 校验、查重 |
| 归档管理 | 转换归档、归档内搜索、书签、**多标签浏览**、缩略图查看器、批量测试、可编辑归档内条目、自定义压缩预设（15+1） |
| 系统集成 | Windows 11 Explorer 右键菜单扩展（C++/WinRT + MSIX）、Windows 7/10 资源管理器集成（`.reg`）、Linux freedesktop/各 DE 集成脚本 81 个、macOS Service Menus 36 个 |
| 主题 | 21 个主题包（`main/blue/line/mac/ten/tux/tuxedo/droid/different` 及其 dark 变体）+ 2 个内嵌主题 |
| 界面字符串 | 1,386 条，55 语言 |

---

## 8. TyZip 对比锚点（同一计数器口径）

计数方法完全一致（同一段 Python 去注释逻辑，`src/`+`backend/`，`.pas/.lpr/.inc/.cpp/.h`）。TyZip 侧仅供量级对照，细节以 `docs/research/tyzip-inventory.md`（task-2）为准。

> TyZip 列为 **2026-10-29 工作树（commit `d7b8310`）**、同一去注释计数器（`src/` + `backend/` 的 `.pas/.lpr/.cpp/.h`）。代码仍在演进，引用时请重跑计数。

| 指标 | PeaZip 11.4.0 | TyZip（2026-10-29，commit d7b8310） | 倍数 |
|---|---|---|---|
| 源文件数 | 324（Pascal；ShellEx 另 111 个打包/本地化文件） | **49** | ~6.6×（按 Pascal/C++ 计） |
| 物理行 | 209,790 | **28,048** | **7.5×** |
| 代码行（去注释） | 161,556 | **20,164** | **8.0×** |
| 注释占比 | 12.9% | 19.6% | — |
| 最大单文件 | `peach.pas` 80,938 行 | `tzip.main.pas` 7,332 行 | 11.0× |
| 窗体定义 | 19 个 `.lfm` / 33,763 行 | **0**（纯代码构建 UI） | — |
| 界面字符串 | 1,386 key / 55 语言 | 1 种语言（zh_CN；311 条 `resourcestring`，两个 `.mo`） | 55× 语言 |
| 压缩后端 | 9 个外部 CLI 后端 + 自研 PEA 格式引擎 | 内嵌 7-Zip **26.03** 动态库 | 架构不同 |
| 可打开格式 | 243 扩展名（官方） | 由 7-Zip API 能力决定（见 task-2） | — |
| CLI 开关 | 221 | 无独立 CLI（见 task-2） | — |

**读法**：PeaZip 的「规模」主要由三块堆起来——① 单文件 7.4 万行的主 GUI/脚本引擎（`peach.pas`）；② 多后端 + 多平台的组合爆炸（9 后端 × 5 平台 × 3 widgetset × 多包格式，平台条件编译块 794/90/24/17/16）；③ 20 年 × 178 个版本的资产与翻译长尾（55 语言 / 1,773 个发行资产 / 254 个系统集成脚本 / 21 个主题）。TyZip 用 7-Zip 动态库 + 单平台（macOS）+ 代码构建 UI，把 ① ② 两块的最贵部分（后端矩阵、多平台打包）外包掉，因此以 ~2.0 万代码行覆盖了 PeaZip 的部分能力面。

---

## 9. 数据来源、统计方法与不确定性

### 9.1 主要来源（全部 2026-10-27 抓取）

- GitHub API：`https://api.github.com/repos/peazip/PeaZip`；`/languages`；`/releases?per_page=100&page=1..2`；`/tags?per_page=100`；`/git/trees/sources?recursive=1`；`/repositories/39554430`（= PeaZip-Translations）
- 源码 tarball（**非 clone**）：`https://codeload.github.com/peazip/PeaZip/tar.gz/refs/heads/sources`（6.5 MB，分支 HEAD，文件时间戳 2026-10-21）
- 官方站：<https://peazip.github.io/>、<https://peazip.github.io/changelog.html>、<https://peazip.github.io/peazip-free-archiver.html>、<https://peazip.github.io/peazip-sources.html>、<https://peazip.github.io/peazip-linux.html>、<https://peazip.github.io/peazip-macos.html>、<https://peazip.github.io/peazip-64bit.html>、<https://peazip.github.io/peazip-add-ons.html>、<https://peazip.github.io/peazip-command-line.html>
- 关键仓库内证据（GitHub blob 链接，`sources` 分支）：
  - 后端版本常量：<https://github.com/peazip/PeaZip/blob/sources/peazip-sources/dev/externalprograms.pas#L56-L140>
  - 版本历史表：<https://github.com/peazip/PeaZip/blob/sources/peazip-sources/dev/peach.pas#L28-L210>
  - 语言文件样例：<https://github.com/peazip/PeaZip/blob/sources/peazip-sources/res/share/lang/en.txt>
  - 构建指南：<https://github.com/peazip/PeaZip/blob/sources/peazip-sources/readme.txt>
  - CI 矩阵：<https://github.com/peazip/PeaZip/blob/sources/.github/workflows/make.yml>

### 9.2 LOC 统计口径（可复现）

1. 取 `sources` 分支 tarball → 解包到 `/tmp`（未入工作区）；
2. 扫描 `.pas/.dpr/.inc/.lpr`，逐字符处理 Pascal 注释（`{ }`、`(* *)`、`//`）与字符串字面量，输出 blank / comment / code 三类；ShellEx 的 C++（`.cpp/.h/.ixx`，1,132 行）用同一逻辑单独统计，**不计入**上述 161,556；
3. 分类：目录 `dev/dragdropfilesdll.src`、`dev/metadarkstyle` 单列；`dev/` 顶层按文件头是否含 "Ehrhardt" 拆出加密/哈希库（159 个单元）；
4. 该口径下 PeaZip 代码行 161,556（注释 27,080 / 空行 21,154），与 GitHub linguist 的 7.51 MB Pascal 字节数（91.94%）方向一致但不可直接换算（linguist 按字节、不含 `.lfm`）。
5. 复现命令示例：
   ```bash
   curl -sL https://codeload.github.com/peazip/PeaZip/tar.gz/refs/heads/sources -o pea.tgz
   tar xzf pea.tgz && wc -l PeaZip-sources/peazip-sources/dev/*.pas | tail -1   # 物理行粗口径
   grep -c 'TMenuItem' PeaZip-sources/peazip-sources/dev/peach.lfm              # UI 规模
   ```

### 9.3 不确定项 / 与官方口径的冲突

| 项 | 状态 | 获取/核实方法 |
|---|---|---|
| 「200+ vs 243」格式数 | 官网首页写 200+，changelog 11.4.0 写精确 243 扩展名；二者不冲突（243 是 11.4.0 的精确值），但官网正文未同步 | 对比 `changelog.html` 与首页；或从 `list_utils.pas` 反推归档类型分派表 |
| 1.0–5.3.1 的发行资产明细 | **未知**：GitHub release 只到 5.4.0，早期 83 个版本无资产清单 | SourceForge `peazip` 项目文件列表 / `changelog` 历史页 |
| SourceForge 累计下载量与当前版本 | **未知**（未抓取） | `https://sourceforge.net/projects/peazip/files/stats/json?start_date=…` 或项目首页计数器 |
| 各发行包内的实际文件数、资源二进制版本落地情况 | **未知**（未下载 .deb/.dmg 解包）；`res/bin` 在源码中仅占位 | 下载 `peazip_11.4.0.LINUX.GTK2-1_amd64.deb` 后 `dpkg -c` / 解包 `PeaZip.app` |
| macOS/BSD 包的构建方式 | CI 矩阵只含 ubuntu/windows × x86_64/aarch64 → macOS/BSD 应为手工构建（推断） | 查 `.github/workflows/` 全量文件（仅 1 个 workflow）或问维护者 |
| contributors 精确人数 | API 返回 44（含 anonymous、按分页数计算） | `contributors?anon=false` 对比 |
| TyZip 侧数据 | 本文 §8 的 `20,164 / 28,048 / 49` 为 2026-10-29（commit `d7b8310`）同一计数器实测，但**权威口径见 task-2 文档** | `docs/research/tyzip-inventory.md` |
| PeaZip 是否仍用 Delphi | **否**：源码/打包全部 Lazarus+FPC，CI 用 lazbuild；Windows 安装器用 Inno Setup（Delphi 风格语法，易混淆） | `peazip-sources/readme.txt` + `make.yml` |
| 后端版本在 BSD 上滞后（7z 21.07） | 源码常量如此，是否为当前实际发布包版本未验证 | 解包 `peazip_portable-11.4.0.BSD.GTK2.x86_64.tar.gz` 执行 `7z --help` |

---

## 10. 结论要点（给差距分析用）

1. **规模量级差距约 8×**（代码行，2026-10-29 时点），且 PeaZip 的代码高度集中：`peach.pas` 一个文件 ≈ TyZip 全部源码的 4.0×，占 PeaZip 自身 Pascal 代码的 65%。
2. PeaZip 的护城河不是某个功能，而是**长尾组合**：178 个版本 × 20 年 × 9 个后端 × 5 平台（Win/Linux/macOS/BSD/Wine）× 4 种 widgetset（Win32/GTK2/GTK3-alpha/Qt6，另有 Qt5 历史版）× 9 类发行文件（exe/msi/msix/zip/deb/rpm/tar.gz/dmg/pdf）+ Flatpak × 55 语言 × 254 个系统集成脚本 × 21 个主题。
3. PeaZip 把压缩算法实现**几乎全部外置**（7-Zip/FreeArc/ZPAQ/Brotli/Zstd/… 都是外部可执行文件，仅自研 PEA 一个格式引擎），TyZip 用 7-Zip 动态库走的是同类「不自研算法」路线——两者可比的其实是 **GUI/文件管理/打包矩阵** 的工程量，而这一块 PeaZip 用 11.3 万行自有 Pascal + 3.4 万行窗体定义完成。
4. 能力边界差异集中区：多后端/多格式创建、归档内编辑、脚本与 CLI、SFX、主题/多语言长尾、全平台打包。TyZip 在这些维度的缺项正是 PeaZip 20 年迭代的主要沉淀（见 task-2）。
