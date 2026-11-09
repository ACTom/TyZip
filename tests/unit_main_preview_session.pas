program unit_main_preview_session;
{$mode objfpc}{$H+}
{ Preview classification and image-viewer arithmetic.

  Pinned here: which names take the image/text path, what the binary sniff
  decides at its byte thresholds, the three size limits, and the four pieces of
  zoom arithmetic (fit, rest, clamp, anchor). These used to be spread through the
  window where only a GUI could exercise them. }
uses
  SysUtils, Classes, Process, tzip.preview.session;

var
  Fails, Passes: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

procedure EqInt(const AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

procedure Near(const AGot, AWant: Double; const AMsg: string);
begin
  if Abs(AGot - AWant) < 0.0001 then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %f want %f', [AMsg, AGot, AWant])); end;
end;

function WriteFile(const AName: string; const ABytes: array of Byte): string;
var
  FS: TFileStream;
begin
  Result := Root + PathDelim + AName;
  FS := TFileStream.Create(Result, fmCreate);
  try
    if Length(ABytes) > 0 then FS.Write(ABytes[0], Length(ABytes));
  finally FS.Free; end;
end;

function WriteText(const AName, AText: string): string;
var
  FS: TFileStream;
begin
  Result := Root + PathDelim + AName;
  FS := TFileStream.Create(Result, fmCreate);
  try
    if AText <> '' then FS.Write(AText[1], Length(AText));
  finally FS.Free; end;
end;

{ --- classification ----------------------------------------------------- }

procedure TestNames;
begin
  Check(PreviewIsImageName('photo.PNG'), 'names: images are matched case-insensitively');
  Check(PreviewIsImageName('a.b.jpeg'), 'names: jpeg');
  Check(PreviewIsImageName('scan.tiff'), 'names: tiff');
  Check(not PreviewIsImageName('notes.txt'), 'names: text is not an image');
  Check(not PreviewIsImageName('archive.7z'), 'names: archives are not images');
  Check(not PreviewIsImageName('noext'), 'names: no suffix is not an image');

  Check(PreviewIsTextName('README.md'), 'names: markdown is text');
  Check(PreviewIsTextName('x.JSON'), 'names: json is text, case-insensitively');
  Check(PreviewIsTextName('script.sh'), 'names: shell is text');
  Check(not PreviewIsTextName('photo.png'), 'names: an image is not text');
  Check(not PreviewIsTextName('noext'), 'names: no suffix is not known text');
  { Compound suffixes are classified by the last one, like ExtractFileExt. }
  Check(not PreviewIsTextName('a.tar.gz'), 'names: compound suffix uses the last one');
end;

{ --- sniffing ----------------------------------------------------------- }

procedure TestLooksText;
begin
  Check(PreviewLooksText(WriteText('empty.bin', '')), 'sniff: an empty file is text');
  Check(PreviewLooksText(WriteText('plain.dat', 'hello'#10'world'#10)),
    'sniff: plain ASCII is text');
  { High-bit bytes are UTF-8 text, not binary. }
  Check(PreviewLooksText(WriteText('cjk.dat', '中文内容')),
    'sniff: UTF-8 CJK is text');
  Check(PreviewLooksText(WriteText('tabs.dat', 'a'#9'b'#13#10'c')),
    'sniff: tabs and CRLF are text');
  { A NUL byte means binary immediately. }
  Check(not PreviewLooksText(WriteFile('nul.dat', [65, 0, 66, 67])),
    'sniff: a NUL byte is binary');
  { More than 5% control bytes is binary; fewer is tolerated. }
  Check(not PreviewLooksText(WriteFile('ctrl.dat',
    [1, 2, 3, 4, 5, 6, 7, 8, 65, 66, 67, 68])), 'sniff: many control bytes is binary');
  Check(PreviewLooksText(WriteFile('mostly.dat',
    [1, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,
     84, 85, 86, 87, 88, 89, 90, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107,
     108, 109, 110, 111])), 'sniff: a little control noise is still text');
  Check(not PreviewLooksText(Root + PathDelim + 'absent.dat'),
    'sniff: a missing file is not text');
end;

{ --- limits ------------------------------------------------------------- }

procedure TestLimits;
begin
  EqInt(PreviewTextExtractLimit, 2 * 1024 * 1024, 'limits: extract cap');
  { The viewer now shows as much as it is willing to read: the old 64 KB display
    cap cut off files that were already in memory. }
  EqInt(PreviewTextDisplayLimit, 2 * 1024 * 1024, 'limits: display cap');
  EqInt(PreviewImageLimit, 32 * 1024 * 1024, 'limits: image cap');
  Check(PreviewTextDisplayLimit = PreviewTextExtractLimit,
    'limits: display and extract caps agree');
  Check(PreviewImageLimit > PreviewTextExtractLimit,
    'limits: image protection stays in place');
end;

{ --- zoom arithmetic ---------------------------------------------------- }

procedure TestZoomClamp;
begin
  Near(ClampImageZoom(1.0), 1.0, 'zoom: unchanged inside the range');
  Near(ClampImageZoom(0.001), ImageZoomMin, 'zoom: below the minimum');
  Near(ClampImageZoom(100.0), ImageZoomMax, 'zoom: above the maximum');
end;

procedure TestFit;
begin
  Near(ImageFitZoomFor(100, 100, 400, 300), 3.0, 'fit: limited by width');
  Near(ImageFitZoomFor(100, 100, 300, 400), 3.0, 'fit: limited by height');
  Near(ImageFitZoomFor(200, 100, 400, 300), 2.0, 'fit: aspect ratio respected');
  { A tiny icon is not blown up to the whole pane. }
  Near(ImageFitZoomFor(1, 1, 400, 300), ImageFitMax, 'fit: capped for tiny images');
  Near(ImageFitZoomFor(100, 100, 0, 300), 1.0, 'fit: no usable area');
  Near(ImageFitZoomFor(0, 100, 400, 300), 1.0, 'fit: no usable image');
end;

procedure TestResting;
begin
  EqInt(ImageRestingPos(100, 300), 100, 'rest: a small picture is centred');
  EqInt(ImageRestingPos(300, 300), 0, 'rest: an exact fit rests at the origin');
  EqInt(ImageRestingPos(400, 300), 0, 'rest: a large picture rests at the origin');
end;

procedure TestClamp;
begin
  { Small picture: never leaves the area. }
  EqInt(ClampImagePos(100, 300, -5), 0, 'clamp: small picture cannot go left');
  EqInt(ClampImagePos(100, 300, 500), 200, 'clamp: small picture cannot go right');
  EqInt(ClampImagePos(100, 300, 150), 150, 'clamp: an inside position is kept');
  { Large picture: always covers the area. }
  EqInt(ClampImagePos(400, 300, 10), 0, 'clamp: large picture cannot leave a gap on the left');
  EqInt(ClampImagePos(400, 300, -200), -100, 'clamp: large picture stops at its edge');
end;

procedure TestAnchorZoom;
begin
  { Doubling about the middle: the anchor pixel keeps its position. CurPos 50,
    anchor 100 -> new absolute 0, resting 20 -> pan -20. }
  EqInt(ZoomedAnchorPan(100, 50, 20, 1.0, 2.0), -20, 'anchor: zoom in keeps the point');
  { Halving about the same point: 100 - (100 - 50) * 0.5 = 75 absolute, and the
    resting position is 20, so the pan is 55. }
  EqInt(ZoomedAnchorPan(100, 50, 20, 2.0, 1.0), 55, 'anchor: zoom out keeps the point');
  { From no zoom (defensive): the picture keeps its current offset. }
  EqInt(ZoomedAnchorPan(100, 70, 20, 0.0, 2.0), 50, 'anchor: no previous zoom keeps the offset');
end;

procedure TestPercent;
begin
  EqStr(ZoomPercentText(1.0), '100%', 'percent: 1x');
  EqStr(ZoomPercentText(0.5), '50%', 'percent: half');
  EqStr(ZoomPercentText(1.234), '123%', 'percent: rounded');
end;

begin
  Fails := 0; Passes := 0;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-session-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  TestNames;
  TestLooksText;
  TestLimits;
  TestZoomClamp;
  TestFit;
  TestResting;
  TestClamp;
  TestAnchorZoom;
  TestPercent;
  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
