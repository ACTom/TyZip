{ What the preview shows and how the image viewer scales it.

  The window used to keep all of this inline: two extension tables as concatenated
  strings, a binary sniff, three size limits, and the zoom arithmetic spread over
  ApplyImageZoom/CentrePreviewImage/SetImageZoomAt. None of it needs a widget or a
  bitmap:

  - classifying a name or the first bytes of a file is string work,
  - fitting, clamping and anchor-zooming are arithmetic on four integers.

  Keeping it here is what lets the rules be tested (which extensions are images,
  what a "text" file looks like at the byte level, where the picture rests, what
  a wheel notch does at the edges) without starting the GUI. }

unit tzip.preview.session;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  { A multi-megabyte single-line text file makes the Cocoa memo spend seconds
    laying out one paragraph, even when the extraction itself is fast. Extract a
    reasonable file, then show only its first chunk so the UI thread stays
    responsive. }
  { How much of a text file is read for the viewer. The user asked for more than
    the old 64 KB: SynEdit handles this fine and memory is the prefix alone. It is
    deliberately the same number as the extraction cap, so a file that fits in the
    viewer's memory budget is not cut short for any other reason. }
  PreviewTextExtractLimit = 2 * 1024 * 1024;
  PreviewTextDisplayLimit = 2 * 1024 * 1024;
  { Before the decode: a compressed preview image is copied from the archive to a
    temp file, and there is no point unpacking a huge one. The DECODED size is
    checked separately by the worker (tzip.imageinfo). }
  PreviewImageLimit = 32 * 1024 * 1024;

  { Image viewer zoom range and per-gesture factors. The wheel is finer than the
    buttons so a scroll over a detail is a nudge, not a jump. }
  ImageZoomMin = 0.05;
  ImageZoomMax = 16.0;
  ZoomWheelStep = 1.10;
  ZoomButtonStep = 1.25;
  { "Fit" never magnifies beyond this: a 16x16 icon should not be blown up to the
    whole pane. }
  ImageFitMax = 4.0;
  { Air around a fitted picture, so its edges are visibly inside the pane. }
  ImageFitMargin = 12;

{ True when AName's suffix is in the '|'-delimited AExts table. The table must
  start and end with '|'; that format is an implementation detail of the two
  tables below, not a caller contract. }
function PreviewHasExt(const AName, AExts: string): Boolean;

{ Every format BGRABitmap can decode from a file. The list gates which files take
  the image path at all. }
function PreviewIsImageName(const AName: string): Boolean;

{ Suffixes that are always shown as text; anything else still goes through
  PreviewLooksText, so this only decides which files skip the sniff. }
function PreviewIsTextName(const AName: string): Boolean;

{ Cheap binary sniff for files without a known text suffix. High-bit bytes are
  deliberately accepted: UTF-8 text is full of them. }
function PreviewLooksText(const APath: string): Boolean;

{ Clamp a zoom into the supported range. }
function ClampImageZoom(AZoom: Double): Double;

{ The zoom at which an AImageW x AImageH picture fits AAreaW x AAreaH, capped at
  ImageFitMax. 1.0 when either side of the area is unusable. }
function ImageFitZoomFor(AImageW, AImageH, AAreaW, AAreaH: Integer): Double;

{ Where a picture of AImageSize rests along one axis: centred while it fits,
  flush at the origin once it is larger. }
function ImageRestingPos(AImageSize, AAreaSize: Integer): Integer;

{ Clamp an absolute position along one axis so the picture cannot leave its area:
  a small picture stays fully inside, a large one always covers the area. }
function ClampImagePos(AImageSize, AAreaSize, ADesired: Integer): Integer;

{ The pan offset that keeps the pixel under AAnchor where it is when the zoom
  changes from AOldZoom to ANewZoom. ACurPos is the picture's current absolute
  position along the axis and AResting where it will rest at the new size; the
  result is relative to that new resting position, i.e. a pan offset. }
function ZoomedAnchorPan(AAnchor, ACurPos, AResting: Integer;
  AOldZoom, ANewZoom: Double): Integer;

{ "150%" -- the zoom label. }
function ZoomPercentText(AZoom: Double): string;

implementation

const
  PreviewImageExts =
    '|.png|.jpg|.jpeg|.jpe|.jfif|.gif|.bmp|.ico|.cur|.tif|.tiff|.webp|' +
    '.tga|.pcx|.psd|.psb|.xpm|.pnm|.pbm|.pgm|.ppm|.pam|' +
    '.jp2|.j2k|.jpx|.pct|.pict|.dds|.ktx|.hdr|.exr|.avif|';
  { Keep in step with the highlight languages in tzip.preview: a format with a
    highlighter belongs here, so a small file of it opens instantly. }
  PreviewTextExts =
    '|.txt|.text|.log|.md|.markdown|.mdown|.mkd|.mdx|.rst|.adoc|' +
    '.csv|.tsv|.json|.jsonc|.json5|.geojson|.har|.xml|.plist|.svg|' +
    '.xsd|.xsl|.xslt|.dtd|.ini|.cfg|.conf|.config|.properties|.env|' +
    '.yaml|.yml|.toml|.html|.htm|.xhtml|.css|.scss|.less|.sass|' +
    '.js|.mjs|cjs|.jsx|.ts|.tsx|.vue|.pas|.pp|.dpr|.lpr|.dfm|' +
    '.c|.h|.cc|.cpp|.cxx|.hpp|.hxx|.m|.mm|.cs|.java|.kt|.kts|.swift|' +
    '.go|.rs|.rb|.py|.pyw|.lua|.pl|.pm|.php|.sh|.bash|.zsh|.fish|' +
    '.bat|.cmd|.ps1|.vb|.sql|.tex|.bib|.diff|.patch|.mk|.gradle|' +
    '.editorconfig|.gitconfig|.gitignore|.dockerfile|.makefile|.lock|' +
    '.manifest|.conf.d|';

function PreviewHasExt(const AName, AExts: string): Boolean;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(AName));
  Result := (E <> '') and (Pos('|' + E + '|', AExts) > 0);
end;

function PreviewIsImageName(const AName: string): Boolean;
begin
  Result := PreviewHasExt(AName, PreviewImageExts);
end;

function PreviewIsTextName(const AName: string): Boolean;
begin
  Result := PreviewHasExt(AName, PreviewTextExts);
end;

function PreviewLooksText(const APath: string): Boolean;
var
  FS: TFileStream;
  Buf: array[0..4095] of Byte;
  N, I, Bad: Integer;
begin
  Result := False;
  try
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      N := FS.Read(Buf, SizeOf(Buf));
    finally
      FS.Free;
    end;
  except
    Exit;
  end;
  if N = 0 then Exit(True);
  Bad := 0;
  for I := 0 to N - 1 do
  begin
    if Buf[I] = 0 then Exit;
    if (Buf[I] < 32) and (Buf[I] <> 9) and (Buf[I] <> 10) and (Buf[I] <> 13) then
      Inc(Bad);
  end;
  Result := Bad * 100 <= N * 5;
end;

function ClampImageZoom(AZoom: Double): Double;
begin
  Result := AZoom;
  if Result < ImageZoomMin then Result := ImageZoomMin;
  if Result > ImageZoomMax then Result := ImageZoomMax;
end;

function ImageFitZoomFor(AImageW, AImageH, AAreaW, AAreaH: Integer): Double;
begin
  Result := 1.0;
  if (AImageW <= 0) or (AImageH <= 0) or (AAreaW <= 0) or (AAreaH <= 0) then Exit;
  { Fit both ways: the limiting side decides. }
  Result := AAreaW / AImageW;
  if (AImageH * Result) > AAreaH then
    Result := AAreaH / AImageH;
  if Result > ImageFitMax then Result := ImageFitMax;
end;

function ImageRestingPos(AImageSize, AAreaSize: Integer): Integer;
begin
  if AImageSize <= AAreaSize then
    Result := (AAreaSize - AImageSize) div 2
  else
    Result := 0;
end;

function ClampImagePos(AImageSize, AAreaSize, ADesired: Integer): Integer;
var
  MinPos, MaxPos: Integer;
begin
  if AImageSize <= AAreaSize then
  begin
    MinPos := 0;
    MaxPos := AAreaSize - AImageSize;
  end
  else
  begin
    MinPos := AAreaSize - AImageSize;
    MaxPos := 0;
  end;
  Result := ADesired;
  if Result < MinPos then Result := MinPos;
  if Result > MaxPos then Result := MaxPos;
end;

function ZoomedAnchorPan(AAnchor, ACurPos, AResting: Integer;
  AOldZoom, ANewZoom: Double): Integer;
var
  Ratio: Double;
begin
  { Nothing to scale from: keep the picture where it is. }
  if AOldZoom <= 0 then Exit(ACurPos - AResting);
  Ratio := ANewZoom / AOldZoom;
  { The vector from the anchor to the picture's top-left scales by the zoom ratio,
    so the pixel under the anchor stays under it. The result is relative to the
    NEW resting position, which is what the caller stores as the pan offset. }
  Result := Round(AAnchor - (AAnchor - ACurPos) * Ratio);
  Result := Result - AResting;
end;

function ZoomPercentText(AZoom: Double): string;
begin
  Result := IntToStr(Round(AZoom * 100)) + '%';
end;

end.
