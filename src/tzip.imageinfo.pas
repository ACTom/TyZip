{ How big a decoded image will be, decided before decoding it.

  The image preview used to be gated on the COMPRESSED file size only. A few
  megabytes of a highly compressible format can decode into gigabytes of pixels,
  and the viewer holds two full-size copies at once (the source the zoom works
  from, plus LCL's bitmap), so a small file could exhaust memory and take the
  whole process down. The budget therefore has to be in PIXELS, and it has to be
  checked before the decoder allocates anything.

  Reading the size out of a file header is BGRABitmap's job (GetImageSizeInFile);
  what belongs here is the arithmetic and the limit, so they can be tested
  without a window, an image decoder, or a 3 GB allocation. }
unit tzip.imageinfo;

{$mode objfpc}{$H+}

interface

const
  { 64M pixels is 256 MB of BGRA. That is already far more than a preview pane
    needs to show, and the viewer keeps two copies while fitting an image, so
    this is the ceiling that keeps one click on a huge picture from deciding how
    much memory the whole application may use. }
  PreviewImageMaxPixels = 64 * 1024 * 1024;

{ The bytes a decoded BGRA copy of AWidth x AHeight occupies. Zero when either
  side is not positive (a header that could not be read). }
function PreviewPixelBytes(AWidth, AHeight: Integer): Int64;

{ True when an image of that size is inside the preview budget. An unreadable
  size never fits. }
function PreviewImageFits(AWidth, AHeight: Integer;
  AMaxPixels: Int64 = PreviewImageMaxPixels): Boolean;

implementation

function PreviewPixelBytes(AWidth, AHeight: Integer): Int64;
begin
  Result := 0;
  if (AWidth <= 0) or (AHeight <= 0) then Exit;
  { 64-bit on purpose: 60000 x 60000 is 3.6e9 pixels, which overflows a 32-bit
    Integer before it can be compared with any budget. }
  Result := Int64(AWidth) * Int64(AHeight) * 4;
end;

function PreviewImageFits(AWidth, AHeight: Integer; AMaxPixels: Int64): Boolean;
var
  Pixels: Int64;
begin
  Result := False;
  if (AWidth <= 0) or (AHeight <= 0) then Exit;
  if AMaxPixels <= 0 then Exit;
  Pixels := Int64(AWidth) * Int64(AHeight);
  Result := Pixels <= AMaxPixels;
end;

end.
