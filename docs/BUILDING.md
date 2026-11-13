# 从源码构建

这份文档写给要改 TyZip 代码、跑测试或出发布包的人：从一台干净的 Mac 出发，把 7-Zip、C 桥接库、Lazarus 应用和 `.app` 一步步构建出来。本地发布门禁是 `scripts/ci.sh`，它跑测试、静态检查和打包，通过时最后一行打印 `CI OK (TyZip <version>, macOS 11.0+; ...)`。

## 环境依赖

TyZip 是 macOS 归档管理器（Lazarus / Free Pascal + LCL Cocoa），压缩引擎是仓库自带的 7-Zip 26.03，经 `backend/tz7z.cpp` 的 C ABI 桥梁调用，不调用 `7z` 命令行。

| 依赖 | 说明 |
|---|---|
| macOS 11+ | 部署目标 11.0；三份二进制（应用、`libtz7z.dylib`、`7z.so`）都必须以 minos 11.0 构建 |
| fpcupdeluxe（FPC 3.2.3 / Lazarus 4.8） | 唯一工具链来源；系统 FPC（`/usr/local`、brew）不参与构建 |
| TyControls 3.99 | 已安装进 Lazarus 包路径，工程引用 `tycontrols` 包；源码在 `~/Projects/TyControls`，本仓库不含其源码 |
| Xcode Command Line Tools | `clang++`、`install_name_tool`、`codesign`（打包脚本另用 `strip`、`ditto`） |
| `vendor/7zip-26.03/` | 仓库内已有的官方 7-Zip 源码 |

脚本默认的 fpcupdeluxe 布局（都可用环境变量覆盖）：

```bash
FPC="$HOME/fpcupdeluxe/fpc/bin/x86_64-darwin/fpc.sh"   # 带 -n @fpc.cfg，忽略系统配置
LAZARUS="$HOME/fpcupdeluxe/lazarus"
LAZBUILD="$HOME/fpcupdeluxe/lazarus/lazbuild"
PCP="$HOME/fpcupdeluxe/config_lazarus"                 # IDE 与测试构建的 Lazarus 配置
```

## 快速开始（全新克隆，x86_64 本机）

```bash
# 1) 7-Zip 本体：只需构建一次，产物之后一直复用
./scripts/build_7zip.sh
# 2) C 桥接库（同时准备好官方库）
./scripts/build_backend.sh
# 3) 应用（Default 构建模式，即测试/调试构建）
./scripts/build_app.sh
# 4) 组装测试用 .app
./scripts/package_app.sh
open bin/TyZip.app
```

各步骤产物（`lib/`、`bin/` 都不在版本库里，`_o/` 也只是编译产物）：

| 脚本 | 产物 |
|---|---|
| `build_7zip.sh` | `lib/7z.so`（x86_64）或 `lib/aarch64-darwin/7z.so`（arm64）：官方 `vendor/` 副本 + `scripts/patches/` 补丁后构建，链接系统 `libiconv`；`MACOSX_DEPLOYMENT_TARGET=11.0`（同名环境变量可覆盖） |
| `build_backend.sh` | `lib/libtz7z.dylib`（id `@rpath/libtz7z.dylib`，依赖 `@loader_path/7z.so`）；x86_64 直接用 `lib/7z.so`，arm64 用 `lib/aarch64-darwin/7z.so` |
| `build_app.sh` | `lib/x86_64-darwin/TyZip`，同目录是它的单元 |
| `package_app.sh` | `bin/TyZip.app`：`Contents/{MacOS,Frameworks,Resources}`，含图标、`Info.plist`、语言包、`LICENSE`、`THIRD_PARTY_NOTICES.md`、`licenses/`；默认 ad-hoc 签名 |

## 7-Zip 补丁与 libiconv

`vendor/7zip-26.03` 是官方源码，**保持原样、不提交本地修改**。TyZip 需要的 ZIP 名称旧代码页支持以补丁形式放在 `scripts/patches/7zip-26.03/`：

- `build_7zip.sh` 每次把 `vendor/7zip-26.03` 复制到 `lib/build/7zip-26.03-src/`，用 `patch -p3` 应用补丁，再以 `O=<私有对象目录>` 构建。补丁应用失败会让构建失败，不会悄悄产出旧库。
- 补丁让 POSIX 构建用系统 iconv 做 GBK/GB18030/Big5/CP932/CP949/CP1252/Latin-1 的读写转换，并补上“Unix 宿主、无 UTF-8 标志的名字先按 UTF-8 试”的启发式；`7z.so` 因此链接 `/usr/lib/libiconv.2.dylib`（系统库，不改变 minos）。
- 升级 7-Zip：替换 `vendor/7zip-26.03` → 重新生成并应用补丁 → `tests/run_all.sh`。补丁只碰 `Common/StringConvert.cpp`、`Common/PropId.cpp`、`7zip/PropID.h`、`Archive/Zip/ZipItem.cpp`、`Archive/Zip/ZipItem.h`、`Archive/Zip/ZipHandler.cpp`、`Archive/Zip/ZipHandlerOut.cpp`。
- 检查：`otool -L lib/7z.so | grep libiconv`。桥接库编译时把 `lib/build/7zip-26.03-src/CPP` 放在包含路径最前（`build_backend.sh`），这样它读到的 PROPID 与打过补丁的库一致。


版本号只有一个来源：`packaging/version.txt`；`package_app.sh` 打包时把它写进 `Info.plist` 的 `CFBundleShortVersionString`/`CFBundleVersion`，`packaging/Info.plist` 本身只是模板。

## 构建模式与输出目录

`TyZip.lpi` 有两个构建模式，输出路径也写在 `.lpi` 里（脚本只做镜像）：

| | Default（测试/调试） | Release（发布） |
|---|---|---|
| 编译参数（`TyZip.lpi`） | `-O1`、`-gw2` Dwarf 调试信息、`-WM11.0` | `-O3`、无调试信息、`-WM11.0` |
| Lazarus 配置（`--pcp`） | `$HOME/fpcupdeluxe/config_lazarus` | `$HOME/fpcupdeluxe/config_lazarus_release` |
| 可执行文件 | `lib/<cpu>-<os>/TyZip`（本机 `lib/x86_64-darwin/TyZip`） | `dist/<cpu>-<os>/TyZip`（未 strip，带符号） |
| 打包产物 | `bin/TyZip.app`（测试包） | `dist/TyZip.app`、`dist/TyZip-arm64.app`、`dist/TyZip-<version>-<arch>.zip` |
| 谁在用 | IDE、`build_app.sh`、`tests/run_all.sh`、`scripts/ci.sh` | `scripts/release.sh` |

三个目录按用途分开，互不覆盖：`lib/` 是编译产物（测试直接从 `lib/` 取 `libtz7z.dylib` 和 `7z.so`），`bin/` 是测试用 `.app`，`dist/` 是发布可执行文件、发布 `.app` 和对外 zip。`lib/`、`bin/`、`dist/` 都在 `.gitignore` 里，所以全新克隆时它们并不存在，由脚本按需创建。

## 发布构建（Release → dist/）

发布构建使用自己的一套 Lazarus 配置目录，IDE 与测试继续用 `config_lazarus`，两边互不写入。这是一次性准备（`release.sh` 发现缺失时也会自动跑一次）：

```bash
./scripts/setup_release_pcp.sh            # 生成 $HOME/fpcupdeluxe/config_lazarus_release
FORCE=1 ./scripts/setup_release_pcp.sh    # 从 config_lazarus 重建
```

为什么要这份副本：构建需要的两样东西猜不出来，必须从现有配置里继承——`environmentoptions.xml` 里的 `CompilerFilename`（fpcupdeluxe 的 `fpc.sh`）和 `packagefiles.xml` 里的包列表（`tycontrols` 在 Lazarus 目录外，空配置找不到它）。**编译参数不在这份配置里**，而在 `TyZip.lpi` 的 `Release` 构建模式：构建模式只带与编译器默认不同的值、不继承项目级 `CompilerOptions`，所以 `src;backend`、输出目录和 `-WM11.0` 都在模式里重复了一遍。改发布参数 = 改 `.lpi`，不是改 PCP。

```bash
./scripts/release.sh                               # 本机 x86_64 + arm64 交叉，各自打 zip
SKIP_ARM64=1 ./scripts/release.sh                  # 只出本机架构（缺 ppca64 时用这个）
TYZIP_TARGET=aarch64-darwin ./scripts/release.sh   # 只出 arm64
```

产物：

```text
dist/x86_64-darwin/TyZip             发布可执行文件（同目录是它的单元）
dist/aarch64-darwin/TyZip            arm64 交叉构建
dist/TyZip.app                       x86_64 发布包（ad-hoc 签名）
dist/TyZip-arm64.app                 arm64 发布包（ad-hoc 签名）
dist/TyZip-<version>-<arch>.zip      对外分发的 zip，版本号来自 packaging/version.txt
```

`release.sh` 不是只跑 lazbuild：缺少库时先补建该架构的 7-Zip/bridge；每个 bundle 都要通过 `file` 的架构校验、`otool -l` 读到 `LC_BUILD_VERSION` 的 `minos` 必须正好是 `11.0`、`Info.plist` 里的版本必须等于 `packaging/version.txt`、`Contents/Resources/LICENSE` 必须存在，最后 `codesign --verify --deep --strict` 必须通过，才用 `ditto -c -k --noextattr --norsrc` 打 zip——构建产物都带 `com.apple.provenance` 扩展属性，ditto 默认会把它们写成 zip 里的 `._*` AppleDouble 条目；打完还会断言 zip 里没有 `._*` / `__MACOSX`。在 Intel 主机上默认追加 arm64；在 arm64 主机上只出本机架构（脚本此时不追加 x86_64）。

去符号只在打包这一步做：`STRIP=1`（`release.sh` 自动传）让 `package_app.sh` 在签名前 strip bundle 里的可执行文件，`dist/<target>/TyZip` 本身仍带符号。原因是 FPC 的 `-Xs` 在 Darwin 上并不去符号，而符号表占了可执行文件三分之一以上。C 桥接库和 `7z.so` 本来就以 `-O2`、无调试信息构建，两个模式共用。

## arm64 交叉构建（Intel 主机）

需要 fpcupdeluxe 的 aarch64-darwin 交叉编译器及其 RTL 单元：

- `$HOME/fpcupdeluxe/fpc/bin/x86_64-darwin/ppca64`
- 同一前缀下的 aarch64-darwin RTL/单元（`fpc.cfg` 已带路径）

应用侧通过 `scripts/ppca64.sh` 调用它：该包装只负责选 `ppca64` 和 `fpc.cfg`，`--cpu=aarch64 --os=darwin` 由 `build_app.sh` 传给 lazbuild（首次会按需交叉构建 LCL、SynEdit、BGRABitmap、TyControls 等包）。手工步骤：

```bash
# 1) 7-Zip arm64：输出 lib/aarch64-darwin/7z.so，不碰 x86 的 _o/7z.so
TYZIP_TARGET=aarch64-darwin ./scripts/build_7zip.sh
# 2) bridge arm64：lib/aarch64-darwin/libtz7z.dylib，依赖 @loader_path/7z.so
TYZIP_TARGET=aarch64-darwin ./scripts/build_backend.sh
# 3) 应用本体 + Lazarus 包的交叉构建
TYZIP_TARGET=aarch64-darwin ./scripts/build_app.sh
# 4) 打包到独立路径，避免覆盖 Intel 的 bin/TyZip.app
TYZIP_TARGET=aarch64-darwin APP_BUNDLE="$PWD/bin/TyZip-arm64.app" ./scripts/package_app.sh
# 5) 静态校验：三份产物都必须是 arm64、minos 11.0
for f in lib/aarch64-darwin/TyZip lib/aarch64-darwin/libtz7z.dylib lib/aarch64-darwin/7z.so; do
  file "$f"
  otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}'
done
```

**arm64 产物不能在 Intel 主机上运行**，本机只能做到构建与静态校验；运行冒烟必须在 Apple Silicon 上做（见 `docs/qa-smoke.md`）。`release.sh` 会先检查 `ppca64`，缺失时在开始任何构建之前直接报错并提示安装方式或 `SKIP_ARM64=1`。

## 测试

```bash
tests/run_all.sh                    # 构建应用 + 两个无界面套件
SKIP_APP_BUILD=1 tests/run_all.sh   # 已有应用构建时只跑套件
```

`tests/run_all.sh` 默认先用 lazbuild（`--pcp` + `--lazarusdir`，Default 模式）构建应用，再依次跑两个套件。应用构建写共享的 `lib/`，所以用 `.tyzip-build.lock` 串行；套件各自用 `$TMPDIR` 下的私有输出目录，可以并行。

- `tests/run_engine_tests.sh`：**自动发现** `tests/unit_*.pas` 与 `tests/api_*.pas`，排除 `api_test`（手工诊断工具，接受路径参数）和 `unit_preview`（归预览套件）。当前应为 `== engine: 52 passed, 0 failed`（数字随测试文件增加，以脚本输出为准）。编译只用 `src` + LazUtils，不建窗体。
- `tests/run_preview_tests.sh`：显式 `PROGS` 列表——`preview_syntax_check`、`editor_integration`、`unit_preview`、`tree_selection_events`，当前应为 `== preview: 4 passed, 0 failed`。它链接 LCL/SynEdit/TyControls，但不开窗口（无界面 `TSynEdit`、真实 `TTyTreeView`）。

只有每个程序都构建成功且退出码为 0 才算通过；`run_all.sh` 两个套件都过后打印 `ALL GREEN`，否则打印 `FAILURES` 并以非 0 退出。工具链默认取 fpcupdeluxe，可用 `FPCUP=` 或分别用 `FPC=... LAZARUS_DIR=... LAZARUS_PCP=... BGRA_LIB=... TYCONTROLS_LIB=...` 覆盖；测试程序要求 `lib/libtz7z.dylib` 与 `lib/7z.so` 已存在（`testenv.sh` 会把它们复制到测试输出目录）。**测试必须保持无界面**：不弹窗、不依赖执行顺序、不依赖残留构建产物。

发布门禁：

```bash
scripts/ci.sh                      # 测试 + 静态检查 + 本机打包（默认还会交叉构建 arm64，2–3 分钟）
SKIP_TESTS=1 scripts/ci.sh         # 只跑快速静态检查
SKIP_ARM64=1 scripts/ci.sh         # 跳过 arm64 交叉构建
REQUIRE_ARM64_APP=1 scripts/ci.sh  # lib/aarch64-darwin/TyZip 缺失即失败
```

`ci.sh` 检查：`packaging/version.txt` 非空；`plutil -lint packaging/Info.plist` 且 `LSMinimumSystemVersion` 为 `11.0`；所有 `scripts/*.sh` 与 `tests/*.sh` 过 `bash -n`；跑 `tests/run_all.sh`；用 `file`/`otool` 校验 `lib/7z.so`、`lib/libtz7z.dylib`、`lib/x86_64-darwin/TyZip` 的架构与 minos；交叉构建 arm64 的 7-Zip/bridge 并校验架构、minos 和 `@loader_path/7z.so`；`lib/aarch64-darwin/TyZip` 存在时组装 `bin/TyZip-arm64.app` 并校验（`REQUIRE_ARM64_APP=1` 把缺失视为失败）；最后按版本号打包 `bin/TyZip.app`（`CODESIGN=0`）并核对版本与 `LICENSE`。注意 `ci.sh` 固定检查 x86_64 与 `lib/` 路径，面向 Intel 主机的本机门禁。

**`ci` 只构建测试模式**，`bin/` 里的是 debug 包；发布产物（`dist/`）一律由 `scripts/release.sh` 生成。

## 语言包

`.po` 源文件直接放在 `languages/` 下，编译出的 `.mo` 与它们同目录：

```text
languages/tzip.zh_CN.po          UI 文案（tzip.i18n 的 rs*）
languages/tzip.zh_CN.mo
languages/lclstrconsts.zh_CN.po  LCL 自带字符串
languages/lclstrconsts.zh_CN.mo
```

改完 `.po` 后重新编译（需要 gettext 的 `msgfmt`）：

```bash
msgfmt -o languages/tzip.zh_CN.mo languages/tzip.zh_CN.po
msgfmt -o languages/lclstrconsts.zh_CN.mo languages/lclstrconsts.zh_CN.po
```

`package_app.sh` 只复制 `languages/*.mo` 到 `Contents/Resources/languages`（没有 `.mo` 时只警告，打出来的是纯英文包）。开发时用 `TYZIP_LANG=zh_CN` 覆盖语言，例如：

```bash
TYZIP_LANG=zh_CN ./lib/x86_64-darwin/TyZip
```

开发构建从可执行文件所在目录向上最多 6 级查找 `languages/`，所以 `lib/<target>/TyZip` 能找到仓库根的 `languages/`；`.app` 里则是 `Contents/Resources/languages`。

## 常见构建问题

- **`lazbuild not found`**：`build_app.sh` 找不到 `$FPCUP/lazarus/lazbuild`；装好 fpcupdeluxe 或用 `FPCUP=/path/to/fpcupdeluxe`，只跑套件时用 `SKIP_APP_BUILD=1`。
- **TyControls units not found**：预览套件从 `packagefiles.xml` 推导目录，推不出来时用 `TYCONTROLS_LIB=~/Projects/TyControls/lib/<cpu>-<os>` 指定。
- **missing ppca64**：`release.sh` 构建前就会失败；用 fpcupdeluxe 装 aarch64-darwin 交叉编译器，或 `SKIP_ARM64=1 scripts/release.sh`。
- **`Build the backend for ... first`**：先跑对应 `TYZIP_TARGET` 的 `build_7zip.sh` + `build_backend.sh`，`lib/` 里要有 `libtz7z.dylib` 和 `7z.so`。
- **开发运行时换库**：`TYZIP_LIB="$PWD/lib/libtz7z.dylib" ./lib/x86_64-darwin/TyZip`（bridge 仍从自己目录 `dlopen` `7z.so`，两个文件放一起）。
- **启动计时**：`TYZIP_TIMING=1 ./lib/x86_64-darwin/TyZip /Applications 2>/tmp/timing.log`，每行 `[timing] <阶段> <ms>`；不设变量时零开销。
- **`7z.so` 的 minos**：stock makefile 会把当前 SDK 版本写进 `LC_BUILD_VERSION`（曾导致库实际要求 macOS 15）；`build_7zip.sh` 用 `MACOSX_DEPLOYMENT_TARGET=11.0` 统一修好，仍不对就用上面的 `otool -l` 循环复查三份二进制。
