program unit_main_icns;
{$mode objfpc}{$H+}
{ The .icns chunk chooser: which PNG inside an app icon wins, without AppKit.

  Pinned here: the wanted size is a floor (never upscale when a larger PNG
  exists), a smaller-only container still yields its largest image, and broken
  containers fail instead of returning half a picture. }
uses
  SysUtils, tzip.icns;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

function BE32(AValue: Cardinal): TBytes;
begin
  SetLength(Result, 4);
  Result[0] := Byte(AValue shr 24);
  Result[1] := Byte(AValue shr 16);
  Result[2] := Byte(AValue shr 8);
  Result[3] := Byte(AValue);
end;

function Concat(const A, B: TBytes): TBytes;
var
  L: Integer;
begin
  L := Length(A);
  SetLength(Result, L + Length(B));
  if L > 0 then Move(A[0], Result[0], L);
  if Length(B) > 0 then Move(B[0], Result[L], Length(B));
end;

{ A PNG-shaped payload: the parser only checks the signature and the IHDR
  dimensions, so a 33 byte stand-in is enough to exercise the chooser. }
function FakePng(AWidth, AHeight: Cardinal): TBytes;
begin
  SetLength(Result, 33);
  Result[0] := $89; Result[1] := $50; Result[2] := $4E; Result[3] := $47;
  Result[4] := $0D; Result[5] := $0A; Result[6] := $1A; Result[7] := $0A;
  Move(BE32(13)[0], Result[8], 4);
  Result[12] := Ord('I'); Result[13] := Ord('H');
  Result[14] := Ord('D'); Result[15] := Ord('R');
  Move(BE32(AWidth)[0], Result[16], 4);
  Move(BE32(AHeight)[0], Result[20], 4);
  Result[24] := 8;  { bit depth }
  Result[25] := 6;  { RGBA }
end;

function Chunk(const AType: string; const APayload: TBytes): TBytes;
var
  Head: TBytes;
begin
  SetLength(Head, 4);
  Move(AType[1], Head[0], 4);
  Result := Concat(Concat(Head, BE32(Length(APayload) + 8)), APayload);
end;

function BuildIcns(const AChunks: array of TBytes): TBytes;
var
  I: Integer;
  Body: TBytes;
  Head: TBytes;
begin
  Body := nil;
  for I := 0 to High(AChunks) do
    Body := Concat(Body, AChunks[I]);
  SetLength(Head, 4);
  Head[0] := Ord('i'); Head[1] := Ord('c');
  Head[2] := Ord('n'); Head[3] := Ord('s');
  Result := Concat(Concat(Head, BE32(8 + Length(Body))), Body);
end;

procedure CheckPick(const AData: TBytes; AWanted, AExpectW, AExpectH: Integer;
  const AMsg: string);
var
  Png: TBytes;
  W, H: Cardinal;
begin
  Check(TzIcnsBestPng(AData, AWanted, Png), AMsg + ': found a png');
  if Length(Png) >= 24 then
  begin
    W := (Cardinal(Png[16]) shl 24) or (Cardinal(Png[17]) shl 16) or
      (Cardinal(Png[18]) shl 8) or Cardinal(Png[19]);
    H := (Cardinal(Png[20]) shl 24) or (Cardinal(Png[21]) shl 16) or
      (Cardinal(Png[22]) shl 8) or Cardinal(Png[23]);
    Check((Integer(W) = AExpectW) and (Integer(H) = AExpectH),
      Format('%s: got %dx%d want %dx%d', [AMsg, W, H, AExpectW, AExpectH]));
  end
  else
    Check(False, AMsg + ': payload too short');
end;

procedure TestSelection;
var
  Data, Png: TBytes;
begin
  Data := BuildIcns([Chunk('ic07', FakePng(128, 128)),
    Chunk('ic12', FakePng(64, 64))]);
  CheckPick(Data, 64, 64, 64, 'select: exact 64 beats 128');

  Data := BuildIcns([Chunk('ic09', FakePng(512, 512)),
    Chunk('ic11', FakePng(32, 32))]);
  CheckPick(Data, 64, 512, 512, 'select: smallest at least the wanted size');

  Data := BuildIcns([Chunk('icp4', FakePng(16, 16))]);
  CheckPick(Data, 64, 16, 16, 'select: only smaller images -> largest');

  Data := BuildIcns([Chunk('ic07', FakePng(128, 128)),
    Chunk('ic08', FakePng(256, 256))]);
  CheckPick(Data, 64, 128, 128, 'select: ties pick the first');

  { Order in the container must not matter. }
  Data := BuildIcns([Chunk('ic12', FakePng(64, 64)),
    Chunk('ic07', FakePng(128, 128))]);
  CheckPick(Data, 64, 64, 64, 'select: order independent');

  { Non-PNG chunks are skipped, not mistaken for images. }
  Data := BuildIcns([Chunk('TOC ', BE32(1)),
    Chunk('ic12', FakePng(64, 64))]);
  CheckPick(Data, 64, 64, 64, 'select: TOC chunk skipped');
end;

procedure TestRejection;
var
  Data, Png: TBytes;
begin
  Check(not TzIcnsBestPng(nil, 64, Png), 'reject: empty');
  Data := BE32(1234);
  Check(not TzIcnsBestPng(Data, 64, Png), 'reject: too short');
  Data := BuildIcns([]);
  Check(not TzIcnsBestPng(Data, 64, Png), 'reject: no chunks');
  Data := BuildIcns([Chunk('ic07', FakePng(128, 128))]);
  Data[0] := Ord('X');
  Check(not TzIcnsBestPng(Data, 64, Png), 'reject: wrong magic');
  { A PNG chunk with an impossible width cannot become the choice. }
  Data := BuildIcns([Chunk('ic07', FakePng(0, 128))]);
  Check(not TzIcnsBestPng(Data, 64, Png), 'reject: zero width png');
  { A chunk length past the container stops the walk instead of reading on. }
  Data := BuildIcns([Chunk('ic07', FakePng(128, 128))]);
  SetLength(Data, Length(Data) - 4);
  Check(not TzIcnsBestPng(Data, 64, Png), 'reject: truncated chunk');
end;

begin
  Fails := 0;
  Passes := 0;
  TestSelection;
  TestRejection;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
