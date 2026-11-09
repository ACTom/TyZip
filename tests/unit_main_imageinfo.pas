program unit_main_imageinfo;
{$mode objfpc}{$H+}
{ The preview's decoded-pixel budget.

  The bug this pins: gating image previews on COMPRESSED bytes let a small,
  highly compressible picture decode into gigabytes of pixels and take the app
  down. The budget has to be in pixels and must not overflow. }
uses
  SysUtils, tzip.imageinfo;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqInt(const AGot, AWant: Int64; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

procedure TestBytes;
begin
  EqInt(PreviewPixelBytes(1, 1), 4, 'bytes: one pixel');
  EqInt(PreviewPixelBytes(100, 100), 40000, 'bytes: square');
  EqInt(PreviewPixelBytes(0, 100), 0, 'bytes: zero width');
  EqInt(PreviewPixelBytes(-1, 100), 0, 'bytes: negative height');
  { A 60000 x 60000 image is 3.6e9 pixels. A 32-bit multiply would wrap; the
    64-bit result is what makes the budget check trustworthy. }
  EqInt(PreviewPixelBytes(60000, 60000), Int64(60000) * 60000 * 4,
    'bytes: huge image does not overflow');
end;

procedure TestFits;
begin
  Check(PreviewImageFits(1, 1), 'fits: trivial');
  Check(PreviewImageFits(4000, 3000), 'fits: a normal photo');
  { Exactly at the budget fits; one pixel over does not. }
  Check(PreviewImageFits(PreviewImageMaxPixels, 1, PreviewImageMaxPixels),
    'fits: exactly the budget');
  Check(not PreviewImageFits(PreviewImageMaxPixels + 1, 1, PreviewImageMaxPixels),
    'fits: one pixel over the budget');
  { The compressed-size trap: a 4000x4000 sheet is 16M pixels, fine; a
    30000x30000 one is 900M pixels and not fine, however small the file is. }
  Check(not PreviewImageFits(30000, 30000), 'fits: 900M pixels is too much');
  { Unreadable sizes never fit: a header that could not be parsed must not be
    treated as a small image. }
  Check(not PreviewImageFits(0, 0), 'fits: zero size');
  Check(not PreviewImageFits(-5, 10), 'fits: negative size');
  { A budget of zero or less disables previewing rather than allowing it. }
  Check(not PreviewImageFits(10, 10, 0), 'fits: zero budget');
  Check(not PreviewImageFits(10, 10, -1), 'fits: negative budget');
  { A caller-supplied budget is honoured. }
  Check(PreviewImageFits(10, 10, 100), 'fits: custom budget');
  Check(not PreviewImageFits(11, 10, 100), 'fits: custom budget exceeded');
end;

begin
  Fails := 0; Passes := 0;
  TestBytes;
  TestFits;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
