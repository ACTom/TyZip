# Manual smoke checklist

The headless suites cover the engine, API, model/controller units and preview
scanners, but not the window. Run this list before packaging a release or after
touching `tzip.main.pas`, `tzip.ui.*`, `tzip.preview.pane.pas` or
`tzip.dialogs.pas`. It takes about five minutes and catches the class of
regression the unit tests cannot see. For the release gate, `scripts/ci.sh`
runs `tests/run_all.sh` and then the packaging/deployment checks.

Record the result in the PR/commit that ships the change: date, build (commit
hash), and any item that failed.

## Launch and navigation

- [ ] App starts without a crash; window and menu bar appear in the OS language.
- [ ] Toolbar and menus are enabled/disabled as expected with no archive open.
- [ ] Back / Forward / Up move between folders; hidden files toggle works.
- [ ] Name filter narrows the current folder; clearing it restores the list.
- [ ] Double-click the breadcrumb and enter `~/Downloads` — it navigates (tilde).
- [ ] An invalid path in the breadcrumb shows an error, not a crash.

## Archive open / browse

- [ ] Open a 7z, a zip, a tar and a `.tar.gz` — all list their entries.
- [ ] Open a split archive by its `.001` part.
- [ ] Double-click an inner archive — it opens as a nested read-only context.
- [ ] Open a password-protected archive — the password prompt appears; wrong
      password can be retried; cancelling leaves the previous view intact.
- [ ] The archive tree expands, selects the current folder and shows the right
      icon per node.
- [ ] Click a folder row in the left archive tree: the listing switches to that
      folder (arrow keys do the same); clicking the expander chevron only
      expands/collapses, it does not navigate.

## ZIP file-name encoding

- [ ] Open a zip whose Chinese names are GBK bytes without the UTF-8 flag
      (create it on Windows, or take a known fixture): with the Simplified
      Chinese UI the listing shows the correct names out of the box (auto ->
      GB18030). With the English UI auto -> Windows-1252 cannot decode GBK, so
      this archive needs View -> Name Encoding -> GB18030.
- [ ] View → Name Encoding → switch to UTF-8: the names become mojibake; switch
      back to GB18030/GBK: the names are correct again. The setting survives
      navigation inside the archive but resets after closing it.
- [ ] The Name Encoding submenu is grayed out for an archive whose names all
      carry the UTF-8 flag or the Info-ZIP Unicode extra field (a zip TyZip
      itself created with a legacy code page qualifies), and enabled for a raw
      GBK archive without those markers.
- [ ] The Name Encoding menu is grayed out inside a nested archive, for a
      non-zip archive, and while a job is running.
- [ ] Extract an entry with a CJK name from the GBK zip — the file on disk has
      the correct name.
- [ ] Create a zip with two Chinese-named files, encoding GBK: `unzip -l` (or a
      Windows tool) lists the correct names and no `_` substitutions.
- [ ] Edit that GBK zip (add a file, delete the other, rename an entry to
      something GBK can represent): before and after, the raw name bytes of the
      untouched entries are unchanged (`python3 - <<'PY'` walking the central
      directory is enough) and the UTF-8 flag is still off.
- [ ] Rename an entry in the GBK zip to an emoji: that one entry gets the UTF-8
      flag and the correct name; the other entries stay GBK.
- [ ] Settings → ZIP name encoding changed and saved: reopening the same archive
      after closing it uses the new default.

## Search

- [ ] Search a large archive by names, by contents and by both: the window stays
      interactive, the overlay shows progress, and Cancel stops the job and
      leaves the previous listing.
- [ ] Search results respect the current name filter; changing the name filter
      after the search re-applies it to the results.
- [ ] Clear Search (or close the archive, or leave it for the file list)
      discards a late-arriving result instead of showing it.
- [ ] The status bar reports "Found N matches" / "No matches"; ⌘F opens the
      search dialog.

## Extraction

- [ ] Extract all to an empty folder — files and timestamps are correct.
- [ ] Extract into a folder that already has some of the files, with the
      conflict policy set to skip: the existing files are untouched and the
      status bar says nothing was extracted when every entry collides.
- [ ] Repeat with overwrite and rename: only the colliding entries change; any
      unrelated file already in the destination folder stays byte-identical.
- [ ] Extract with "delete archive after" — the view leaves the archive first,
      the file is removed, and a failure to delete is reported.
- [ ] Open an archive whose only top-level entry is a folder (or a Finder-made
      zip with `__MACOSX/` beside it), tick "Smart extract": the contents land
      directly in the destination, with no extra folder and no `__MACOSX`.
- [ ] Select a few entries inside an open archive: the "Smart extract" box is
      greyed out, and hovering it explains that it needs the whole archive.
- [ ] Right-click a single archive in Finder → Services → "TyZip: Smart Extract":
      the progress card appears without any dialog, and the files land by the
      archive's structure. Repeat with 2+ archives selected (each lands next to
      itself).
- [ ] With a file of the same name already in the destination, the smart service
      asks once (Overwrite / Keep both / Skip / Cancel); Cancel stops the batch.
- [ ] Smart-extract a `.tar.gz`: the inner tree appears, not a bare `.tar` file.

## Batch / queue

- [ ] Select 3+ archives and batch-extract them with the conflict policy on
      skip: each archive is listed first, colliding entries are skipped, files
      already in the destination that are not part of the archives stay
      untouched, and the summary counts the skipped/failed archives.
- [ ] Repeat with rename and overwrite: only the colliding entries change in
      each target folder; unrelated files stay byte-identical.
- [ ] Start a batch on large archives — the current archive can be cancelled;
      the cancelled one stops, no later archive starts, and the summary still
      appears.
- [ ] Batch-test several archives — per-archive results are counted and the app
      stays usable between jobs.

## Preview (pane behaviour)

- [ ] Select a text file: the pane shows text, line numbers and the guessed
      encoding.
- [ ] Switch encoding and word-wrap: the same bytes redraw; toggling wrap keeps
      the reading position; switch language: colours change and "None" is plain
      text.
- [ ] Select an image: it fits; +/-/1:1/Fit, wheel and drag work; widen the pane
      and the image stays centred.
- [ ] Select a directory, binary or encrypted entry: the hint and bar are
      restored/hidden as before; both light and dark themes update the text and
      the gutter.
- [ ] Select a very large text file (for example 50 MB): the pane shows the
      first 2 MB and the truncation marker; there is no "too large" refusal.
- [ ] Preview a very large text entry inside an archive (for example 100 MB):
      only the 2 MB prefix is extracted to the temp file and shown; no
      "too large" refusal.
- [ ] Select another file while an image is loading — no freeze, no stale image;
      an archive entry previews by extracting in the background; closing the
      window while a preview loads does not hang; a huge image is refused with a
      "too large" hint instead of freezing.

## Icons, settings, comment, services

- [ ] File-list icons appear progressively (they load on the main thread); `.app`
      bundles outside the cache directory get their real icon on demand.
- [ ] Change sidebar/preview visibility and width, save settings, restart — the
      layout is restored (width never drops to 0).
- [ ] Apply a create preset — level, method, dictionary, volume, encryption name,
      AES and delete-sources all match the preset; deleting sources is not
      persisted into the preset.
- [ ] Right-click empty space in the archive list → Archive Comment…; save a
      comment in a zip, reopen the archive and see it; a 7z shows read-only.
- [ ] Right-click a file in Finder → Services → TyZip actions appear and work.

## Packaging (release or shared build)

- [ ] `./scripts/release.sh` finishes and writes `dist/TyZip.app`,
      `dist/TyZip-arm64.app` and `dist/TyZip-<version>-<arch>.zip` (add
      `SKIP_ARM64=1` to skip the cross build; it also creates the release
      Lazarus config on demand).
- [ ] `dist/TyZip.app` opens and behaves like the debug build; its
      `Contents/MacOS/TyZip` is the stripped release binary (`ls -l` is several
      MB smaller than `lib/x86_64-darwin/TyZip`, `nm` reports only a handful of
      dynamic symbols).
- [ ] `./scripts/package_app.sh` finishes and `bin/TyZip.app` opens (the debug
      test bundle; `bin/` is not the release output).
- [ ] `codesign --verify --deep --strict dist/TyZip.app` (and
      `bin/TyZip.app`) passes and `codesign -dv` reports an ad-hoc signature
      (`Signature=adhoc`), as expected for the current self-use/shared build
      policy (no Developer ID, no notarization).
- [ ] The bundle contains `LICENSE` (GPL-3.0), `THIRD_PARTY_NOTICES.md` and
      `Resources/licenses/`.
- [ ] A copy from another machine (or one with a quarantine attribute) opens
      after right-click → Open, or after
      `xattr -dr com.apple.quarantine dist/TyZip.app`. No notarization is
      expected.
- [ ] arm64: `scripts/release.sh` cross-builds it (`file` and `otool -l` show
      arm64 and minos 11.0 for the app and both libraries). The manual path
      still works too:
      `TYZIP_TARGET=aarch64-darwin APP_BUNDLE="$PWD/bin/TyZip-arm64.app"
      ./scripts/package_app.sh`.
- [ ] arm64: the packaged `.app` must be launched and smoke-tested on an Apple
      Silicon Mac (the Intel host cannot run it); right-click → Open once, then
      check launch, archive open and extract.
- [ ] `plutil -lint packaging/Info.plist` passes and the version matches the
      release tag.
