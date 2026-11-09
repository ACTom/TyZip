# TyControls issues — from building TyZip

Observed against main `6b74052b`, Lazarus 4.8 / FPC 3.2.4, macOS (Cocoa), x86_64.
Both bodies are bilingual, matching the repo's existing issues: English first, `---`, then Chinese.

---

# Issue 1

## Title

Report-view cell margin does not apply to the icon: `imgLead` is `ScaleI(2)` while `textLead` uses `margin`

## Labels

`bug`

## Body

## Symptom

In `lvsReport`, increasing the cell inset — the `--listview-text-margin` theme token, or anything else that feeds `margin` — moves the caption to the right but leaves the leading icon glued to the cell's left edge, 2 px from it. The icon/label gap therefore grows while the icon-to-border gap stays at 2 px, so the row reads as "the icon is clipped against the border".

This affects every report list with images, `TTyShellListView` (file lists) included.

To reproduce:

1. `TTyCustomListView` with `ViewStyle := lvsReport`, `OwnerData := True`, a `SmallImages` list, and rows with a non-negative image index.
2. In the active theme set `--listview-text-margin: 16px;` (default 4, DensityPack 6).
3. Captions jump right; icons do not move.

## Cause

`source/tyControls.ListView.pas`, `TTyCustomListView.RenderReportRow`, around 3128–3138:

```pascal
textLead := lead + sign * (cbShift + margin);
ii := GetItemImageIndex(AIndex, colIdx);
if (FSmallImages <> nil) and (ii >= 0) then
begin
  imgLead := lead + sign * (cbShift + ScaleI(2));   // hard-coded 2 px, margin ignored
  if RtlLayout then Dec(imgLead, imgPx);
  DrawImage(P, FSmallImages, ii, imgLead,
    ACell.Top + (ACell.Bottom - ACell.Top - imgPx) div 2, imgPx);
  textLead := lead + sign * (cbShift + margin + imgPx + ScaleI(2));
end;
```

Inside the same `if`, `textLead` uses `margin` and `imgLead` uses the literal `ScaleI(2)`. `margin` is resolved a few lines above as `--listview-text-margin`, so the token is documented to inset the cell but only reaches the text.

## Fix

Let both start at the same inset:

```pascal
imgLead := lead + sign * (cbShift + margin);
```

The icon/label gap is still guaranteed by `imgPx + ScaleI(2)` in `textLead`, so the margin token gains one consistent meaning for the whole cell, the icon/label gap does not change with density or theme, and the RTL branch (`Dec(imgLead, imgPx)`) is unaffected because `margin` already carries `sign`.

Row contents shift by (`margin` − 2) px for image rows: 2 px on the default theme, 4 px on DensityPack. Text-only rows and non-report view styles are untouched; a theme that relied on the 2 px lead can restore it with `--listview-text-margin: 2px`.

---

## 现象

报表视图（`lvsReport`）里把单元格内边距调大——也就是主题令牌 `--listview-text-margin`，以及任何喂给 `margin` 的取值——标题文字会右移，前置图标却仍贴在单元格左边缘、距边 2 px。结果是图标与文字的间距变大，而图标与边框的间距始终是 2 px，整行看起来像“图标被压在边框上”。

所有带图标的报表视图都受影响，`TTyShellListView`（文件列表）同样如此。

复现：

1. 建一个 `TTyCustomListView`，`ViewStyle := lvsReport`，`OwnerData := True`，接一个 `SmallImages`，行上有非负的图像索引。
2. 在主题里把 `--listview-text-margin` 改成 `16px`（默认 4px，DensityPack 是 6px）。
3. 观察：文字右移，图标不动。

## 原因

`source/tyControls.ListView.pas` 的 `TTyCustomListView.RenderReportRow`，约 3128–3138 行：

```pascal
textLead := lead + sign * (cbShift + margin);
ii := GetItemImageIndex(AIndex, colIdx);
if (FSmallImages <> nil) and (ii >= 0) then
begin
  imgLead := lead + sign * (cbShift + ScaleI(2));   // 硬编码 2 px，没用 margin
  if RtlLayout then Dec(imgLead, imgPx);
  DrawImage(P, FSmallImages, ii, imgLead,
    ACell.Top + (ACell.Bottom - ACell.Top - imgPx) div 2, imgPx);
  textLead := lead + sign * (cbShift + margin + imgPx + ScaleI(2));
end;
```

同一个 `if` 块里，`textLead` 用了 `margin`，`imgLead` 却用了字面量 `ScaleI(2)`。`margin` 就在上面几行按 `--listview-text-margin` 解析出来，也就是说这个令牌名义上是单元格内边距，实际只作用到文字。

## 修复

让两者从同一个起点开始：

```pascal
imgLead := lead + sign * (cbShift + margin);
```

图标与文字的间距仍由 `textLead` 里的 `imgPx + ScaleI(2)` 保证，因此：令牌对整个单元格只剩一种含义；图标与文字的间距不随密度或主题变化；RTL 分支 `Dec(imgLead, imgPx)` 不受影响，因为 `margin` 已经带了 `sign`。

带图标的行会整体右移 (`margin` − 2) px：默认主题 2 px，DensityPack 4 px。纯文字行和其他视图样式不受影响；如果某个主题依赖原来的 2 px，可以把 `--listview-text-margin` 设成 2px 还原。

---

# Issue 2

## Title

Tree rows cannot be given a leading inset: at level 0 the icon starts at the cell's left edge, and `Indent` is the image-slot width rather than a margin

## Labels

`bug` (or `enhancement` if a new inset property is the preferred shape of the fix — see "Fix")

## Body

## Symptom

A `TTyCustomTreeView` used as a plain listing — an archive's folder tree, `ShowRoot := False`, one level of rows most of the time — draws its level-0 icons flush against the cell's left edge. Nothing the application can set moves the icon (and the caption with it) inward without also changing the row's hierarchy geometry.

The visible consequence is a tree standing next to a `TTyShellListView`: the list has an inset, the tree has none, and the two columns of content do not line up.

## Cause

`TyTreeCaptionSlots` (`source/tyControls.TreeView.pas`, ~1943–1968):

```pascal
Result.IndentPx    := MulDiv((ALevel + Ord(AShowRoot)) * AIndent, APPI, 96);
...
Result.ImageX := Result.CaptionX;      // CaptionX starts at ACellLeft + IndentPx
Inc(Result.CaptionX, Result.ImageW);
...
Result.TextPad := MulDiv(2, APPI, 96);
```

- `IndentPx` is `level × Indent`, so at `level = 0` with `ShowRoot = False` it is 0 and the image starts exactly at the cell's left edge.
- `Indent` is also the image SLOT width (`ImageW := MulDiv(AIndent, ...)`), so raising it widens the slot instead of adding padding: the glyph recentres in a wider slot rather than moving in.
- `TextPad` is 2 px and surrounds the caption only.

So there is no value that means "keep the hierarchy geometry, add N px of leading space", and the icon-caption gap cannot be set independently of the indent either.

## Fix

Add a leading inset, in logical px, applied to the main column before `IndentPx`:

```pascal
Result.IndentPx := MulDiv(AContentInset + (ALevel + Ord(AShowRoot)) * AIndent, APPI, 96);
```

with `--treeview-content-inset` as the theme token and a matching published property. One change then moves the icon, the caption, the expander and the tree lines together, because all of them are anchored on `IndentPx`, and a tree used as a flat list lines up with `TTyListView` rows, whose cells carry `--listview-text-margin`.

If a new property is unwanted, applying the existing text-margin token as a leading inset on the main column would already make the two controls agree.

---

## 现象

把 `TTyCustomTreeView` 当普通列表用——例如压缩包里的文件夹树，`ShowRoot := False`，大部分时候只有一层——第一层的图标会紧贴单元格左边缘。应用侧没有任何设置能在不影响层级几何的前提下，把图标（连同文字）往里挪。

直接可见的后果是：树和 `TTyShellListView` 并排时，列表有内边距、树没有，两列内容对不齐。

## 原因

`TyTreeCaptionSlots`（`source/tyControls.TreeView.pas`，约 1943–1968 行）：

```pascal
Result.IndentPx    := MulDiv((ALevel + Ord(AShowRoot)) * AIndent, APPI, 96);
...
Result.ImageX := Result.CaptionX;      // CaptionX 从 ACellLeft + IndentPx 起
Inc(Result.CaptionX, Result.ImageW);
...
Result.TextPad := MulDiv(2, APPI, 96);
```

- `IndentPx` 是 `层级 × Indent`，所以 `ShowRoot = False` 时第一层的 `IndentPx` 为 0，图像正好落在单元格左边缘。
- `Indent` 同时也是图像**槽宽**（`ImageW := MulDiv(AIndent, ...)`），调大它只会把槽加宽，图标在更宽的槽里重新居中，而不是作为内边距往里移。
- `TextPad` 是 2 px，只作用在标题文字两侧。

因此没有哪个取值能表达“保持层级几何、加 N px 前导留白”，图标与文字之间的间距也没法独立于缩进设置。

## 修复

给主列加一个逻辑像素的前导内边距，加在 `IndentPx` 之前：

```pascal
Result.IndentPx := MulDiv(AContentInset + (ALevel + Ord(AShowRoot)) * AIndent, APPI, 96);
```

令牌命名为 `--treeview-content-inset`，配一个同名 published 属性。改这一处，图标、文字、展开按钮和树线会一起移动，因为它们都锚在 `IndentPx` 上；当普通列表用的树也能和 `TTyListView` 的行对齐（后者的单元格带 `--listview-text-margin`）。

如果不想新增属性，把现有的文字内边距令牌同样作为主列的前导内边距应用，两者就已经能对齐。
