# Third-party notices

## TyZip (this project)

TyZip's own source — `src/`, `backend/tz7z.cpp`, `tests/` and `scripts/` — is
licensed under the **GNU General Public License, version 3 (GPL-3.0)**. The full
text is in [`LICENSE`](LICENSE) at the repository root. If you redistribute the
application, ship that license text together with it (see the README section
"分发（自用 / 群分享）").

This GPL-3.0 grant covers the TyZip code only. The third-party components below
remain under their own licenses.

## 7-Zip 26.03

TyZip links against the official 7-Zip shared library (`7z.so`, built from the
`Format7zF` bundle) and includes a small C++ bridge (`backend/tz7z.cpp`) that uses
7-Zip's COM-style interfaces directly. No 7-Zip command-line executable is invoked.

7-Zip is Copyright (C) 1999-2026 Igor Pavlov.

License: GNU LGPL 2.1 or later, with the additional unRAR restriction described
in the upstream license. The complete upstream license and source are included in
`vendor/7zip-26.03/` (`DOC/License.txt`); they are also the source from which the
shipped `7z.so` is built by `scripts/build_7zip.sh`. If you redistribute TyZip,
keep the 7-Zip source offer and license notices, and comply with the LGPL
requirements for the combined work.

The unRAR code contained in 7-Zip may not be used to develop a RAR-compatible
archiver. TyZip only reads, tests and extracts RAR archives; it never creates or
updates one, and its create dialog does not offer RAR.

## TyControls

TyZip uses TyControls, Copyright (C) the TyControls authors, under the modified
LGPL terms of that project. TyControls is not bundled as source in this
repository; install it in Lazarus or obtain it from its upstream repository:
<https://github.com/ACTom/TyControls>.

## Lazarus / Free Pascal / LCL

The application is built with Lazarus and Free Pascal. Lazarus, LCL and the
runtime libraries are distributed under their respective licenses (LGPL,
modified LGPL, and GPL with the Lazarus exception). See the Lazarus and Free
Pascal projects for the exact terms and source:
<https://www.lazarus-ide.org> and <https://www.freepascal.org>.

## Source availability (LGPL)

The corresponding source of the LGPL components is available as follows:

- **7-Zip 26.03**: complete source in `vendor/7zip-26.03/` (including
  `DOC/License.txt`); the shipped library is built from it with
  `scripts/build_7zip.sh`.
- **TyControls**: <https://github.com/ACTom/TyControls> (or the local source
  package used by the build).
- **Lazarus / LCL / Free Pascal**: the upstream projects named above, matching
  the versions recorded in the build instructions.

No additional written offer is needed when this source is distributed alongside
the application; keep these notices with any redistributed copy.
