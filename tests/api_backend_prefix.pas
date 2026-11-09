program api_backend_prefix;
{$mode objfpc}{$H+}
{$codepage utf8}
{ tz7z_extract_one_prefix (ticket 26, ABI v3).

  The archive preview needs "the first N bytes of this entry" without writing a
  full temporary file: the C function stops the decoder when the limit is
  reached and reports success.  This test covers the exact-size cases, a limit
  larger than the entry, max_bytes = 0 (no limit, same as extract_one), and the
  argument checks. }

uses
  SysUtils, Classes, DynLibs, Process, tzip.api;

const
  ENTRY_SIZE = 3 * 1024 * 1024;   { > 2 MB, so the old preview path refused it }

type
  TPrefixFn = function(Archive: Pointer; Index: LongWord;
    OutFile, Password: PAnsiChar; MaxBytes: QWord;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;

var
  Fails, Passes: Integer;
  Root: string;
  Lib: TLibHandle;
  PrefixFn: TPrefixFn;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure GenerateData(const APath: string; ASize: Integer);
var
  F: TFileStream;
  Buf: TBytes;
  I: Integer;
begin
  SetLength(Buf, ASize);
  for I := 0 to ASize - 1 do
    Buf[I] := Byte((I * 37 + 11) and $FF);
  F := TFileStream.Create(APath, fmCreate);
  try
    F.WriteBuffer(Buf[0], ASize);
  finally F.Free; end;
end;

function ReadFileBytes(const APath: string): TBytes;
var
  F: TFileStream;
begin
  Result := nil;
  F := TFileStream.Create(APath, fmOpenRead);
  try
    SetLength(Result, F.Size);
    if Length(Result) > 0 then
      F.ReadBuffer(Result[0], Length(Result));
  finally F.Free; end;
end;

function SamePrefix(const APrefixPath, ASourcePath: string; out AWhy: string): Boolean;
var
  Prefix, Source: TBytes;
  I: Integer;
begin
  Result := False;
  Prefix := ReadFileBytes(APrefixPath);
  Source := ReadFileBytes(ASourcePath);
  if Length(Prefix) > Length(Source) then
  begin
    AWhy := Format('the prefix (%d) is longer than the entry (%d)', [Length(Prefix), Length(Source)]);
    Exit;
  end;
  for I := 0 to High(Prefix) do
    if Prefix[I] <> Source[I] then
    begin
      AWhy := Format('byte %d differs', [I]);
      Exit;
    end;
  Result := True;
end;

function RunPrefix(A: TTzArchive; AIndex: LongWord; const AOut: string;
  AMaxBytes: QWord; out AErr: string): Integer;
var
  ErrBuf: array[0..1023] of AnsiChar;
begin
  FillChar(ErrBuf, SizeOf(ErrBuf), 0);
  Result := PrefixFn(A.Handle, AIndex, PAnsiChar(UTF8Encode(AOut)), '',
    AMaxBytes, @ErrBuf[0], SizeOf(ErrBuf));
  AErr := string(AnsiString(PAnsiChar(@ErrBuf[0])));
end;

procedure TestPrefixSizes;
var
  Z, Src, OutF, Err: string;
  A: TTzArchive;
  R: Integer;
  B: TBytes;
  Why: string;
  S: TCreateSettings;
  Inps: array[0..0] of TZ7ZInput;
  DiskU, ArcU: RawByteString;
begin
  Src := Root + '/big.bin';
  GenerateData(Src, ENTRY_SIZE);
  Z := Root + '/big.7z';
  DiskU := UTF8Encode(Src);
  ArcU := 'big.bin';
  Inps[0] := Default(TZ7ZInput);
  Inps[0].StructSize := SizeOf(TZ7ZInput);
  Inps[0].ABIVersion := TZ7Z_ABI_VERSION;
  Inps[0].DiskPath := PAnsiChar(DiskU);
  Inps[0].ArcPath := PAnsiChar(ArcU);
  Inps[0].IsDir := 0;
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 0;   { store: the test is about byte prefixes, not compression }
  R := TzCreate(Z, S, Inps, Err);
  Check(R = TZ7Z_OK, Format('setup create 7z (%d)', [R]));
  if R <> TZ7Z_OK then Exit;

  A := nil;
  if TzOpenArchive(Z, '', A, Err) <> TZ7Z_OK then
  begin
    Check(False, 'setup open (' + Err + ')');
    Exit;
  end;
  try
    { 64 KiB prefix }
    OutF := Root + '/prefix-64k.bin';
    DeleteFile(OutF);
    R := RunPrefix(A, 0, OutF, 64 * 1024, Err);
    Check(R = TZ7Z_OK, Format('64 KiB: reported success (%d, %s)', [R, Err]));
    Check(FileExists(OutF), '64 KiB: the prefix file exists');
    if FileExists(OutF) then
    begin
      B := ReadFileBytes(OutF);
      Check(Length(B) = 64 * 1024,
        Format('64 KiB: the file is exactly the limit (%d bytes)', [Length(B)]));
      Check(SamePrefix(OutF, Src, Why), '64 KiB: the bytes are the head of the entry (' + Why + ')');
    end;

    { 2 MiB prefix: the old preview limit, still a prefix }
    OutF := Root + '/prefix-2m.bin';
    DeleteFile(OutF);
    R := RunPrefix(A, 0, OutF, 2 * 1024 * 1024, Err);
    Check(R = TZ7Z_OK, Format('2 MiB: reported success (%d, %s)', [R, Err]));
    if FileExists(OutF) then
    begin
      B := ReadFileBytes(OutF);
      Check(Length(B) = 2 * 1024 * 1024,
        Format('2 MiB: the file is exactly the limit (%d bytes)', [Length(B)]));
      Check(SamePrefix(OutF, Src, Why), '2 MiB: the bytes are the head of the entry (' + Why + ')');
    end
    else
      Check(False, '2 MiB: the prefix file exists');

    { max_bytes = 0 means "no limit": the whole entry }
    OutF := Root + '/prefix-all.bin';
    DeleteFile(OutF);
    R := RunPrefix(A, 0, OutF, 0, Err);
    Check(R = TZ7Z_OK, Format('no limit: reported success (%d, %s)', [R, Err]));
    if FileExists(OutF) then
    begin
      B := ReadFileBytes(OutF);
      Check(Length(B) = ENTRY_SIZE,
        Format('no limit: the whole entry was extracted (%d bytes)', [Length(B)]));
      Check(SamePrefix(OutF, Src, Why), 'no limit: the bytes match the entry (' + Why + ')');
    end
    else
      Check(False, 'no limit: the output file exists');

    { A limit above the entry size is not an error and does not pad the file. }
    OutF := Root + '/prefix-huge.bin';
    DeleteFile(OutF);
    R := RunPrefix(A, 0, OutF, QWord(ENTRY_SIZE) * 4, Err);
    Check(R = TZ7Z_OK, Format('limit above entry: reported success (%d, %s)', [R, Err]));
    if FileExists(OutF) then
      Check(Length(ReadFileBytes(OutF)) = ENTRY_SIZE,
        'limit above entry: the file holds the whole entry, not padding');
  finally
    A.Free;
  end;
end;

procedure TestArgumentChecks;
var
  Z, OutF, Err, Src: string;
  A: TTzArchive;
  R: Integer;
  S: TCreateSettings;
  Inp: TZ7ZInput;
  Inps: array[0..0] of TZ7ZInput;
  DiskU, ArcU: RawByteString;
begin
  Src := Root + '/small.txt';
  with TStringList.Create do
  begin
    try
      Text := 'small';
      SaveToFile(Src);
    finally
      Free;
    end;
  end;
  Z := Root + '/small.zip';
  Err := '';
  DiskU := UTF8Encode(Src);
  ArcU := 'small.txt';
  Inp := Default(TZ7ZInput);
  Inp.StructSize := SizeOf(TZ7ZInput);
  Inp.ABIVersion := TZ7Z_ABI_VERSION;
  Inp.DiskPath := PAnsiChar(DiskU);
  Inp.ArcPath := PAnsiChar(ArcU);
  Inp.IsDir := 0;
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 5;
  Inps[0] := Inp;
  R := TzCreate(Z, S, Inps, Err);
  Check(R = TZ7Z_OK, 'args: setup zip (' + Err + ')');
  A := nil;
  if TzOpenArchive(Z, '', A, Err) <> TZ7Z_OK then
  begin
    Check(False, 'args: open (' + Err + ')');
    Exit;
  end;
  try
    OutF := Root + '/arg-out.bin';
    R := PrefixFn(nil, 0, PAnsiChar(UTF8Encode(OutF)), '', 10, nil, 0);
    Check(R = TZ7Z_E_ARG, Format('args: NULL archive is rejected (%d)', [R]));
    R := PrefixFn(A.Handle, 0, nil, '', 10, nil, 0);
    Check(R = TZ7Z_E_ARG, Format('args: NULL output path is rejected (%d)', [R]));
    R := PrefixFn(A.Handle, 0, '', '', 10, nil, 0);
    Check(R = TZ7Z_E_ARG, Format('args: empty output path is rejected (%d)', [R]));
    DeleteFile(Root + '/arg-oor.bin');
    R := PrefixFn(A.Handle, 99, PAnsiChar(UTF8Encode(Root + '/arg-oor.bin')), '', 10, nil, 0);
    Check(R = TZ7Z_E_ARG, Format('args: an out-of-range index is rejected (%d)', [R]));
    Check(not FileExists(Root + '/arg-oor.bin'),
      'args: nothing is written for an out-of-range index');
  finally
    A.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-backend-prefix-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  Lib := LoadLibrary(TzLibraryPath);
  PrefixFn := TPrefixFn(GetProcedureAddress(Lib, 'tz7z_extract_one_prefix'));
  if not Assigned(PrefixFn) then
  begin
    WriteLn('FAIL tz7z_extract_one_prefix is not exported');
    Halt(2);
  end;
  Check(TZ7Z_ABI_VERSION = 4, Format('the Pascal side expects ABI 4 (%d)', [TZ7Z_ABI_VERSION]));

  WriteLn('-- prefix sizes and contents');
  TestPrefixSizes;
  WriteLn('-- argument checks');
  TestArgumentChecks;

  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
