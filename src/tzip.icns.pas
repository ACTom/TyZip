{ Reading a .icns bundle icon without AppKit.

  Every .app ships its icon as a file (Contents/Resources/<name>.icns). Modern
  icons are a container whose chunks are mostly PNG: icp4/icp5/icp6/ic07..ic14.
  Copying the right PNG chunk into the icon cache needs no NSWorkspace, no
  IconServices XPC and therefore no main-thread stall: the whole operation is
  file I/O plus a byte comparison, and it can run wherever the caller likes.

  Legacy chunks (is32/il32/ih32/it32 RLE) are intentionally not decoded: the
  caller falls back to the platform query for those few bundles. }
unit tzip.icns;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ The PNG representation closest to AWantedPx inside AData.

  Prefers the smallest image at least AWantedPx wide, so 64 stays 64 and a
  256 px icon is used only when nothing smaller exists; when every image is
  smaller, the largest is returned (upscaling one is still better than a blank
  page). False when the data is not an icns, holds no PNG chunk, or every chunk
  is malformed. }
function TzIcnsBestPng(const AData: TBytes; AWantedPx: Integer;
  out APng: TBytes): Boolean;

implementation

function BE32(const AData: TBytes; AOffset: Integer): Cardinal;
begin
  Result := (Cardinal(AData[AOffset]) shl 24) or
    (Cardinal(AData[AOffset + 1]) shl 16) or
    (Cardinal(AData[AOffset + 2]) shl 8) or
    Cardinal(AData[AOffset + 3]);
end;

function PngSize(const AData: TBytes; AStart, ALen: Integer;
  out AWidth, AHeight: Int64): Boolean;
begin
  Result := False;
  AWidth := 0;
  AHeight := 0;
  { Signature (8) + IHDR length (4) + 'IHDR' (4) + width (4) + height (4). }
  if ALen < 24 then Exit;
  if (AData[AStart] <> $89) or (AData[AStart + 1] <> $50) or
     (AData[AStart + 2] <> $4E) or (AData[AStart + 3] <> $47) then Exit;
  if (AData[AStart + 12] <> Ord('I')) or (AData[AStart + 13] <> Ord('H')) or
     (AData[AStart + 14] <> Ord('D')) or (AData[AStart + 15] <> Ord('R')) then Exit;
  AWidth := BE32(AData, AStart + 16);
  AHeight := BE32(AData, AStart + 20);
  Result := (AWidth > 0) and (AWidth <= 8192) and
    (AHeight > 0) and (AHeight <= 8192);
end;

function TzIcnsBestPng(const AData: TBytes; AWantedPx: Integer;
  out APng: TBytes): Boolean;
var
  Total, Off, Len, W, H, Score, BestScore: Int64;
begin
  Result := False;
  APng := nil;
  if Length(AData) < 8 then Exit;
  if (AData[0] <> Ord('i')) or (AData[1] <> Ord('c')) or
     (AData[2] <> Ord('n')) or (AData[3] <> Ord('s')) then Exit;
  Total := BE32(AData, 4);
  { A truncated download or a hand-edited file can claim more than it holds. }
  if Total > Length(AData) then Total := Length(AData);
  Off := 8;
  BestScore := High(Int64);
  while Off + 8 <= Total do
  begin
    Len := BE32(AData, Off + 4);
    if (Len < 8) or (Off + Len > Total) then Break;
    if PngSize(AData, Off + 8, Len - 8, W, H) then
    begin
      if W >= AWantedPx then
        Score := W - AWantedPx
      else
        Score := 100000 + (AWantedPx - W);
      if Score < BestScore then
      begin
        BestScore := Score;
        APng := Copy(AData, Off + 8, Len - 8);
        Result := True;
      end;
    end;
    Inc(Off, Len);
  end;
end;

end.
