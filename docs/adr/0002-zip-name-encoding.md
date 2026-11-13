# 0002 — ZIP 文件名编码：打 7-Zip 补丁、默认按界面语言、编辑保持原编码

- Status: accepted (2026-11-13)
- Owners: 归档打开 / 编辑（工单 27）

## 背景

ZIP 只为条目名提供两个选项：带 UTF-8 标志（0x0800）的 UTF-8 字节，或不带标志的「本地代码页」字节。Windows 上的压缩工具习惯写 GBK，macOS/Linux 上的工具默认写 UTF-8；双方读到对方的包都可能乱码。几类具体问题：

1. 打开 Windows/GBK 生成的 zip，中文名在 TyZip 里是乱码。
2. 上游 7-Zip 的 POSIX 构建没有代码页表：`MultiByteToUnicodeString2` 在没有 Windows 代码页支持时把字节逐位当成 Latin-1，`UnicodeStringToMultiByte2` 遇到表示不了的字符写 `_`。Windows 版 7-Zip 能正确解 GBK，是因为它带代码页支持。
3. POSIX 构建还缺 Windows 版有的一条启发式：Unix host 写的名字没有 UTF-8 标志、但字节是合法 UTF-8 时按 UTF-8 读。mac 工具写出的包因此也会被按旧代码页解错。
4. 编辑旧代码页的包时，把名字统一改写成 UTF-8 会让 Windows 用户再次乱码；用默认代码页重写又可能把原本 UTF-8 的包写坏。

约束：TyZip 不启动 `7z` 命令行，7-Zip 只经 `backend/tz7z.cpp` 的 C ABI 调用；模型层不依赖 LCL；`vendor/` 是上游原样拷贝，不就地长期修改；三份二进制都要 minos 11.0。

## 决策

### 1. 用构建期补丁 + libiconv 修 7-Zip，而不是在应用层重写名字

`scripts/patches/7zip-26.03/0001-zip-name-codepage.patch` 打在 `vendor/7zip-26.03` 的副本上（`scripts/build_7zip.sh` 复制到 `lib/build/7zip-26.03-src` 再 `patch`），`7z.so` 链接 `-liconv`：

- `Common/StringConvert.cpp`：在 `MultiByteToUnicodeString2` / `UnicodeStringToMultiByte2` 里用 iconv 实现带代码页的多字节转换（CP936 / CP950 / CP932 / CP949 / GB18030 / CP1252 / ISO-8859-1 等）。
- `Archive/Zip/ZipItem.cpp`：补上 POSIX 缺的 Unix-host UTF-8 启发式；并记录每条名字是否走了旧代码页（见第 4 点）。
- `Archive/Zip/ZipHandlerOut.cpp`：写入时代码页表示不了的名字单条回退 UTF-8 并置标志，而不是写 `_`。
- `PropID.h` / `Common/PropId.cpp` / `Archive/Zip/ZipHandler.cpp`：新增 `kpidTzipNameWasLegacy`，把上面的记录暴露给桥接。

不选应用层方案（自己解 ZIP 目录、自己重编名字）的理由：7-Zip 的目录读取、加密、内嵌包和 CRC 校验都在一起，应用层重解一遍等于复制一个 ZIP 解析器，且会和 7-Zip 对同一名字有两种解释。

### 2. ABI 增加两个入口

- **v5 `tz7z_set_name_codepage(archive, cp)`**：只对 ZIP 生效；`cp=0` 保持历史行为；带 UTF-8 标志的名字永远不受影响；非 ZIP 返回 `TZ7Z_E_FORMAT`，调用方忽略。
- **v6 `tz7z_entry_name_is_legacy(archive, index)`**：告诉应用「这条名字是不是按旧代码页/Info-ZIP Unicode 扩展字段读出来的」。
- **v7 `tz7z_entry_name_uses_codepage(archive, index)`**：收窄版——只有「名字文本真的由代码页决定」才为 1；UTF-8 标志名、Info-ZIP Unicode 扩展名、ASCII 名都是 0。查看菜单用它决定是否置灰（切换不会改变显示时禁用）。

结构体布局不变，旧调用方二进制兼容；Pascal 侧 `tzip.api.bind` 的整体符号校验要求 ABI 版本等于 6。

### 3. 默认编码是「按界面语言自动」

设置里的 `[Archive] NameEncoding` 默认 `auto`，由 `TzResolveNameCodepage` 按当前界面语言解析：简体中文 → GB18030，繁体中文 → Big5，日文 → CP932，韩文 → CP949，其余 → CP1252。理由：

- 绝大多数乱码来自「同语言环境、不同系统」：中文用户打开 Windows 的 GBK 包。默认值跟着界面语言走，用户不用先知道「代码页」这个词。
- 固定 GB18030 对繁体/日文/韩文和西文用户是错的；固定 UTF-8 等于不修。
- 显式值仍可在设置里选；单包可用查看 →「名称编码」临时覆盖（只在本次会话、当前包有效，不落盘；v1 不做跨会话持久化）。

### 4. 编辑保持原编码；探测靠补丁的逐条标志

编辑（添加/删除/改名/注释）前，先探测这个包实际用的编码：`TzArchiveNameEncoding` 调 ABI v6 的 `tz7z_entry_name_is_legacy`。有一条名字是旧代码页读出来的 → 用原代码页写；全部是 UTF-8/ASCII → 显式按 UTF-8 写（`cp=65001` + `cu`）。

为什么不用「用两种代码页各解一遍再比较」：我们自己的旧代码页包会带 Info-ZIP Unicode 扩展字段，两种代码页都会优先从扩展字段解出正确 Unicode，比较结果恒相同；只看字节又看不到。让 7-Zip 在解码时记录「是否用了旧代码页/扩展字段」，是唯一可靠的信号，代价是一个 PROPID 和 ABI v6。

`tz7z_modify` 在读旧条目名之前用 `options->codepage` 设置同一个代码页——这个 handle 是桥接内部打开的，应用层拿不到，所以必须由桥接改。

### 5. 混合编码的包按旧代码页写，单条回退 UTF-8

一个包里同时有 UTF-8 标志名和 GBK 名时，按旧代码页重写：GBK 名字节不变；表示不了的名字（emoji 等）由第 1 点的写入回退变成 UTF-8 单条。这样最坏情况只影响「本来就是 UTF-8、且恰好在旧代码页里可表示」的那条名字，而不会把整包 GBK 字节转掉。文档里明确这是取舍，不是无损承诺。

## 影响

- 新增 `tzip.nameenc`（编码表、id、auto 解析），`TAppSettings.NameEncoding` + INI 读写；`TZJob.NameCodepage` / `TArchiveContext.NameCodepage` / `TTzArchive.NameCodepage` 三层透传；设置对话框、查看菜单、i18n 文案。
- 构建链：`build_7zip.sh` 负责复制/打补丁/链接 iconv；`build_backend.sh` 从打过补丁的源码取头文件，并要求先跑 `build_7zip.sh`。vendor 树保持 `git status` 干净。
- 测试：`tests/api_encoding.pas` 用 python 写原始 ZIP 字节，覆盖带/不带标志、Unix host、加密、非 ZIP、写入代码页、更新保持、混合包、不可表示名字回退；ABI 相关单测钉住版本 6 与新增符号。
- 已知非目标：不探测「每条名字各自是什么编码」（ZIP 没有这种元数据）；不会自动重命名已乱码的条目；单包覆盖不跨会话保存；编码探测在更新开始前同步扫一遍条目名（大包会在界面线程多花一点时间），v1 不把它搬进修改作业。
