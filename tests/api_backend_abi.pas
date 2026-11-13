program api_backend_abi;
{$mode objfpc}{$H+}
{$codepage utf8}
{ The C ABI contract of backend/tz7z.h (ticket 17).

  Every struct crossing the ABI starts with (struct_size, abi_version); the
  library validates both and refuses a caller built against another layout.
  These checks do not need the Pascal wrapper for the mismatch cases: they call
  the exported C functions directly, which is exactly what a stale dylib would
  see.  The struct sizes are pinned to the C layout, so changing that layout
  without bumping TZ7Z_ABI_VERSION and this test fails loudly. }

uses
  SysUtils, Classes, DynLibs, Process, tzip.api;

const
  { sizeof(tz7z_entry_info), sizeof(tz7z_input), sizeof(tz7z_create_options)
    on x86_64 with the ABI version 2 layout.  Keep in lockstep with tz7z.h. }
  C_ENTRY_INFO_SIZE = 392;
  C_INPUT_SIZE      = 32;
  C_OPTS_SIZE       = 128;
  { The ABI revision this test is written against; bump with tz7z.h. }
  C_ABI_VERSION     = 5;

type
  TAbiVersionFn = function: LongWord; cdecl;
  TEntryInfoFn = function(Archive: Pointer; Index: LongWord;
    Info: PZ7ZEntryInfo): LongInt; cdecl;
  TCreateFn = function(ArchivePath: PAnsiChar; Options: PZ7ZCreateOptions;
    Inputs: PZ7ZInput; Count: LongWord; Progress: Pointer; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  { Direct C-ABI calls for the name code page, ABI v5. }
  TZ7ZOpenFn = function(Path, Password: PAnsiChar; out Archive: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  TZ7ZEntryNameFn = function(Archive: Pointer; Index: LongWord;
    Buffer: PAnsiChar; Capacity: LongInt): LongInt; cdecl;
  TZ7ZSetNameCpFn = function(Archive: Pointer; Codepage: LongWord): LongInt; cdecl;
  TZ7ZCloseFn = procedure(Archive: Pointer); cdecl;

var
  Fails, Passes: Integer;
  Root: string;
  Lib: TLibHandle;
  CreateFn: TCreateFn;
  EntryInfoFn: TEntryInfoFn;
  OpenFn: TZ7ZOpenFn;
  EntryNameFn: TZ7ZEntryNameFn;
  SetNameCpFn: TZ7ZSetNameCpFn;
  CloseFn: TZ7ZCloseFn;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure CheckContains(const AHaystack, ANeedle, AMsg: string);
begin
  if Pos(ANeedle, AHaystack) > 0 then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: [%s] does not contain [%s]', [AMsg, AHaystack, ANeedle])); end;
end;

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally L.Free; end;
end;

function MakeInput(const ADisk, AArc: string): TZ7ZInput;
begin
  Result := Default(TZ7ZInput);
  Result.StructSize := SizeOf(TZ7ZInput);
  Result.ABIVersion := TZ7Z_ABI_VERSION;
  Result.DiskPath := PAnsiChar(UTF8Encode(ADisk));
  Result.ArcPath := PAnsiChar(UTF8Encode(AArc));
  Result.IsDir := 0;
end;

{ Build a real archive through the public wrapper, so the ABI tests have
  something to open. AArcName is the UTF-8 name inside the archive. }
function MakeArchive(const APath, AFormat, AArcName: string;
  ACodepage: LongWord; AForceUtf8: Boolean): Boolean;
var
  Inp: TZ7ZInput;
  DiskU, ArcU: RawByteString;
  S: TCreateSettings;
  Err: string;
begin
  WriteText(Root + '/payload.txt', 'abi-payload');
  DiskU := UTF8Encode(Root + '/payload.txt');
  ArcU := UTF8Encode(AArcName);
  Inp := Default(TZ7ZInput);
  Inp.StructSize := SizeOf(TZ7ZInput);
  Inp.ABIVersion := TZ7Z_ABI_VERSION;
  Inp.DiskPath := PAnsiChar(DiskU);
  Inp.ArcPath := PAnsiChar(ArcU);
  S := Default(TCreateSettings);
  S.FormatName := AFormat;
  S.Level := 5;
  S.Codepage := ACodepage;
  S.ForceUtf8 := AForceUtf8;
  Result := TzCreate(APath, S, [Inp], Err) = TZ7Z_OK;
  if not Result then WriteLn('   setup create: ', Err);
end;

function MakeZip(const APath: string): Boolean;
begin
  Result := MakeArchive(APath, 'zip', 'payload.txt', 0, True);
end;

{ Run a command and return its stdout (stderr included). }
function RunOut(const ACmd: string): string;
var
  P: TProcess;
  Buf: array[0..4095] of AnsiChar;
  N: LongInt;
begin
  Result := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(ACmd);
    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    P.Execute;
    while P.Running or (P.Output.NumBytesAvailable > 0) do
    begin
      N := P.Output.Read(Buf, SizeOf(Buf) - 1);
      if N <= 0 then Break;
      Buf[N] := #0;
      Result := Result + string(AnsiString(PAnsiChar(@Buf[0])));
    end;
    P.WaitOnExit;
  finally
    P.Free;
  end;
end;

function HexOf(const S: RawByteString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    Result := Result + LowerCase(IntToHex(Ord(S[I]), 2));
end;

function RawZipScript: string;
begin
  Result := Root + '/make-raw-zip.py';
  if not FileExists(Result) then
    WriteText(Result,
      'import struct, sys, zlib' + LineEnding +
      'path = sys.argv[1]' + LineEnding +
      'name = bytes.fromhex(sys.argv[2])' + LineEnding +
      'host = int(sys.argv[3])' + LineEnding +
      'flags = int(sys.argv[4])' + LineEnding +
      'data = b"abi-payload"' + LineEnding +
      'crc = zlib.crc32(data) & 0xffffffff' + LineEnding +
      'made = (host << 8) | 20' + LineEnding +
      'lfh = struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, flags, 0, 0, 0, crc,' +
      ' len(data), len(data), len(name), 0) + name' + LineEnding +
      'cdh = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, made, 20, flags,' +
      ' 0, 0, 0, crc, len(data), len(data), len(name), 0, 0, 0, 0, 0, 0) + name' +
      LineEnding +
      'eocd = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 1, 1, len(cdh),' +
      ' len(lfh) + len(data), 0)' + LineEnding +
      'open(path, "wb").write(lfh + data + cdh + eocd)' + LineEnding);
end;

function ProbeScript: string;
begin
  Result := Root + '/probe-zip.py';
  if not FileExists(Result) then
    WriteText(Result,
      'import struct, sys' + LineEnding +
      'd = open(sys.argv[1], "rb").read()' + LineEnding +
      'i = d.find(b"PK\x03\x04")' + LineEnding +
      'f = struct.unpack("<H", d[i+6:i+8])[0]' + LineEnding +
      'n = struct.unpack("<H", d[i+26:i+28])[0]' + LineEnding +
      'print("%d %s" % (f, d[i+30:i+30+n].hex()))' + LineEnding);
end;

{ A one-entry ZIP whose name bytes and UTF-8 flag are exactly what we choose.
  AHostOS: 0 = MS-DOS, 3 = Unix (the ZIP "version made by" host byte). }
function MakeRawZip(const APath: string; const ARawName: RawByteString;
  AHostOS: Word; AFlags: Word): Boolean;
var
  Cmd: string;
begin
  DeleteFile(APath);
  Cmd := '/usr/bin/python3 ' + QuotedStr(RawZipScript) + ' ' +
    QuotedStr(APath) + ' ' + HexOf(ARawName) + ' ' +
    IntToStr(AHostOS) + ' ' + IntToStr(AFlags);
  RunOut(Cmd);
  Result := FileExists(APath);
end;

{ The UTF-8 flag and the raw name bytes of a ZIP's first entry. }
procedure ProbeZip(const AZip: string; out AFlags: LongInt; out AHex: string);
var
  OutS: string;
  L: TStringList;
begin
  AFlags := -1;
  AHex := '';
  OutS := Trim(RunOut('/usr/bin/python3 ' + QuotedStr(ProbeScript) + ' ' +
    QuotedStr(AZip)));
  L := TStringList.Create;
  try
    L.Delimiter := ' ';
    L.StrictDelimiter := True;
    L.DelimitedText := OutS;
    if L.Count >= 2 then
    begin
      AFlags := StrToIntDef(L[0], -1);
      AHex := L[1];
    end;
  finally
    L.Free;
  end;
end;

function RawEntryName(AHandle: Pointer): string;
var
  Need: LongInt;
  Buf: RawByteString;
begin
  Result := '';
  Need := EntryNameFn(AHandle, 0, nil, 0);
  if Need <= 1 then Exit;
  SetLength(Buf, Need);
  if EntryNameFn(AHandle, 0, PAnsiChar(Buf), Need) > 0 then
    Result := string(AnsiString(PAnsiChar(Buf)));
end;

{ Open AZip through the C ABI, read the name with the engine default, then set
  ACodepage and read it again. SetR is what the setter returned. }
function RawOpenName(const AZip: string; ACodepage: LongWord;
  out ABeforeName: string; out ASetR: LongInt): string;
var
  H: Pointer;
  Err: array[0..1023] of AnsiChar;
  P: RawByteString;
begin
  Result := '';
  ABeforeName := '';
  ASetR := -999;
  H := nil;
  FillChar(Err, SizeOf(Err), 0);
  P := UTF8Encode(AZip);
  if OpenFn(PAnsiChar(P), nil, H, @Err[0], SizeOf(Err)) <> TZ7Z_OK then
  begin
    WriteLn('   raw open: ', string(AnsiString(PAnsiChar(@Err[0]))));
    Exit;
  end;
  try
    ABeforeName := RawEntryName(H);
    ASetR := SetNameCpFn(H, ACodepage);
    Result := RawEntryName(H);
  finally
    CloseFn(H);
  end;
end;

function DirectSetCodepage(const AZip: string; ACodepage: LongWord): LongInt;
var
  H: Pointer;
  Err: array[0..1023] of AnsiChar;
  P: RawByteString;
begin
  Result := -999;
  H := nil;
  FillChar(Err, SizeOf(Err), 0);
  P := UTF8Encode(AZip);
  if OpenFn(PAnsiChar(P), nil, H, @Err[0], SizeOf(Err)) <> TZ7Z_OK then Exit;
  try
    Result := SetNameCpFn(H, ACodepage);
  finally
    CloseFn(H);
  end;
end;

procedure TestVersionsAndSizes;
var
  VerFn: TAbiVersionFn;
  Ver: LongWord;
begin
  VerFn := TAbiVersionFn(GetProcedureAddress(Lib, 'tz7z_abi_version'));
  Check(Assigned(VerFn), 'tz7z_abi_version is exported');
  if Assigned(VerFn) then
  begin
    Ver := VerFn();
    Check(Ver = TZ7Z_ABI_VERSION,
      Format('tz7z_abi_version matches the Pascal constant (%d vs %d)', [Ver, TZ7Z_ABI_VERSION]));
    Check(Ver = C_ABI_VERSION,
      Format('this test documents ABI version %d (library says %d)', [C_ABI_VERSION, Ver]));
  end;
  Check(SizeOf(TZ7ZEntryInfo) = C_ENTRY_INFO_SIZE,
    Format('TZ7ZEntryInfo is %d bytes (got %d)', [C_ENTRY_INFO_SIZE, SizeOf(TZ7ZEntryInfo)]));
  Check(SizeOf(TZ7ZInput) = C_INPUT_SIZE,
    Format('TZ7ZInput is %d bytes (got %d)', [C_INPUT_SIZE, SizeOf(TZ7ZInput)]));
  Check(SizeOf(TZ7ZCreateOptions) = C_OPTS_SIZE,
    Format('TZ7ZCreateOptions is %d bytes (got %d)', [C_OPTS_SIZE, SizeOf(TZ7ZCreateOptions)]));
end;

procedure TestEntryInfoMismatch;
var
  Z: string;
  A: TTzArchive;
  Err: string;
  Info: TZ7ZEntryInfo;
  R: Integer;
begin
  Z := Root + '/abi.zip';
  Check(MakeZip(Z), 'entry info: setup zip');
  A := nil;
  if TzOpenArchive(Z, '', A, Err) <> TZ7Z_OK then
  begin
    Check(False, 'entry info: open (' + Err + ')');
    Exit;
  end;
  try
    Info := Default(TZ7ZEntryInfo);
    Info.StructSize := 0;
    Info.ABIVersion := TZ7Z_ABI_VERSION;
    R := EntryInfoFn(A.Handle, 0, @Info);
    Check(R = TZ7Z_E_ARG, Format('entry info: a zero struct_size is rejected (%d)', [R]));

    Info := Default(TZ7ZEntryInfo);
    Info.StructSize := SizeOf(TZ7ZEntryInfo);
    Info.ABIVersion := TZ7Z_ABI_VERSION + 1;
    R := EntryInfoFn(A.Handle, 0, @Info);
    Check(R = TZ7Z_E_ARG, Format('entry info: a wrong abi_version is rejected (%d)', [R]));

    Info := Default(TZ7ZEntryInfo);
    Info.StructSize := SizeOf(TZ7ZEntryInfo) - 8;
    Info.ABIVersion := TZ7Z_ABI_VERSION;
    R := EntryInfoFn(A.Handle, 0, @Info);
    Check(R = TZ7Z_E_ARG, Format('entry info: a short struct is rejected (%d)', [R]));

    Info := Default(TZ7ZEntryInfo);
    Info.StructSize := SizeOf(TZ7ZEntryInfo);
    Info.ABIVersion := TZ7Z_ABI_VERSION;
    R := EntryInfoFn(A.Handle, 0, @Info);
    Check(R = TZ7Z_OK, Format('entry info: the current layout is accepted (%d)', [R]));
  finally
    A.Free;
  end;
end;

procedure TestCreateMismatch;
var
  OutF, Disk, Arc, ErrS: string;
  Inp: TZ7ZInput;
  Opt: TZ7ZCreateOptions;
  Err: array[0..1023] of AnsiChar;
  R: Integer;
  Inp2: array[0..1] of TZ7ZInput;
  DiskU2, ArcU2: RawByteString;
begin
  OutF := Root + '/abi-mismatch.zip';
  DeleteFile(OutF);
  WriteText(Root + '/mismatch-src.txt', 'x');
  Disk := Root + '/mismatch-src.txt';
  Arc := 'payload.txt';

  FillChar(Opt, SizeOf(Opt), 0);
  Opt.StructSize := 0;
  Opt.ABIVersion := TZ7Z_ABI_VERSION;
  Opt.FormatName := 'zip';
  Opt.Level := 5;
  Inp := MakeInput(Disk, Arc);
  FillChar(Err, SizeOf(Err), 0);
  R := CreateFn(PAnsiChar(OutF), @Opt, @Inp, 1, nil, nil, @Err[0], SizeOf(Err));
  ErrS := string(AnsiString(PAnsiChar(@Err[0])));
  Check(R = TZ7Z_E_ARG, Format('create: a wrong options struct_size is rejected (%d)', [R]));
  CheckContains(ErrS, 'ABI', 'create: the mismatch error is readable');
  Check(not FileExists(OutF), 'create: nothing is written for a rejected caller');

  FillChar(Opt, SizeOf(Opt), 0);
  Opt.StructSize := SizeOf(Opt);
  Opt.ABIVersion := TZ7Z_ABI_VERSION;
  Opt.FormatName := 'zip';
  Opt.Level := 5;
  R := CreateFn(PAnsiChar(OutF), @Opt, @Inp, 1, nil, nil, @Err[0], SizeOf(Err));
  Check(R = TZ7Z_OK, Format('create: the current layout is accepted (%d, %s)',
    [R, string(AnsiString(PAnsiChar(@Err[0])))]));

  { One bad record in an input array must be named and rejected, not skipped. }
  OutF := Root + '/abi-input.zip';
  DeleteFile(OutF);
  DiskU2 := UTF8Encode(Disk);
  ArcU2 := 'payload.txt';
  Inp2[0] := MakeInput(Disk, Arc);
  Inp2[1] := Default(TZ7ZInput);
  Inp2[1].DiskPath := PAnsiChar(DiskU2);
  Inp2[1].ArcPath := PAnsiChar(ArcU2);
  Inp2[1].IsDir := 0;
  R := CreateFn(PAnsiChar(OutF), @Opt, @Inp2[0], 2, nil, nil, @Err[0], SizeOf(Err));
  ErrS := string(AnsiString(PAnsiChar(@Err[0])));
  Check(R = TZ7Z_E_ARG, Format('create: a record without abi_version is rejected (%d)', [R]));
  CheckContains(ErrS, 'ABI', 'create: the bad input error is readable');
  Check(not FileExists(OutF), 'create: no archive is written for a bad input record');
end;

{ ABI v5: a ZIP's name code page is selectable after opening, and the create
  side really writes the chosen code page. The fixtures carry raw name bytes
  because that is the only way to check what the engine actually does. }
procedure TestNameCodepage;
var
  GbkZip, Utf8Zip, SevenZip, CreatedZip: string;
  Before, NameA: string;
  SetR, R: LongInt;
  Flags: LongInt;
  Hex: string;
  RawName: RawByteString;
begin
  if not (Assigned(OpenFn) and Assigned(EntryNameFn) and Assigned(CloseFn) and
    Assigned(SetNameCpFn)) then
  begin
    Check(False, 'name codepage: the bridge is missing tz7z_set_name_codepage');
    Exit;
  end;

  { "中文名称.txt" in GBK, no UTF-8 flag, made by MS-DOS (0). }
  SetLength(RawName, 12);
  RawName[1] := AnsiChar($D6); RawName[2] := AnsiChar($D0);
  RawName[3] := AnsiChar($CE); RawName[4] := AnsiChar($C4);
  RawName[5] := AnsiChar($C3); RawName[6] := AnsiChar($FB);
  RawName[7] := AnsiChar($B3); RawName[8] := AnsiChar($C6);
  RawName[9] := '.'; RawName[10] := 't'; RawName[11] := 'x'; RawName[12] := 't';
  GbkZip := Root + '/gbk-name.zip';
  Check(MakeRawZip(GbkZip, RawName, 0, 0), 'name codepage: gbk fixture written');

  NameA := RawOpenName(GbkZip, 936, Before, SetR);
  Check(SetR = TZ7Z_OK, Format('name codepage: setter accepts a zip (%d)', [SetR]));
  Check(NameA = '中文名称.txt', 'name codepage: gbk name is decoded');
  Check(Before <> '中文名称.txt',
    'name codepage: the engine default does not decode gbk');

  Utf8Zip := Root + '/utf8-flag.zip';
  Check(MakeRawZip(Utf8Zip, UTF8Encode('中文名称.txt'), 0, $800),
    'name codepage: utf8 fixture written');
  NameA := RawOpenName(Utf8Zip, 936, Before, SetR);
  Check(NameA = '中文名称.txt',
    'name codepage: the utf8 flag wins over the code page');

  SevenZip := Root + '/abi-name.7z';
  DeleteFile(SevenZip);
  Check(MakeArchive(SevenZip, '7z', 'payload.txt', 0, True),
    'name codepage: 7z fixture');
  R := DirectSetCodepage(SevenZip, 936);
  Check(R = TZ7Z_E_FORMAT,
    Format('name codepage: a non-zip format is rejected (%d)', [R]));

  CreatedZip := Root + '/created-gbk.zip';
  DeleteFile(CreatedZip);
  Check(MakeArchive(CreatedZip, 'zip', '中文名称.txt', 936, False),
    'name codepage: create with code page 936');
  ProbeZip(CreatedZip, Flags, Hex);
  Check(Flags >= 0, 'name codepage: the created zip could be probed');
  Check((Flags and $800) = 0,
    Format('name codepage: code page 936 leaves the utf8 flag off (%d)', [Flags]));
  Check(Hex = 'd6d0cec4c3fbb3c62e747874',
    Format('name codepage: code page 936 writes gbk name bytes (%s)', [Hex]));
end;

begin
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-backend-abi-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  Lib := LoadLibrary(TzLibraryPath);
  if Lib = NilHandle then
  begin
    WriteLn('FAIL cannot reopen the engine library for direct ABI calls');
    Halt(2);
  end;
  CreateFn := TCreateFn(GetProcedureAddress(Lib, 'tz7z_create'));
  EntryInfoFn := TEntryInfoFn(GetProcedureAddress(Lib, 'tz7z_entry_info_get'));
  OpenFn := TZ7ZOpenFn(GetProcedureAddress(Lib, 'tz7z_open'));
  EntryNameFn := TZ7ZEntryNameFn(GetProcedureAddress(Lib, 'tz7z_entry_name'));
  CloseFn := TZ7ZCloseFn(GetProcedureAddress(Lib, 'tz7z_close'));
  SetNameCpFn := TZ7ZSetNameCpFn(GetProcedureAddress(Lib, 'tz7z_set_name_codepage'));
  if not Assigned(CreateFn) or not Assigned(EntryInfoFn) then
  begin
    WriteLn('FAIL the bridge does not export the expected functions');
    Halt(2);
  end;
  Check(Assigned(OpenFn) and Assigned(EntryNameFn) and Assigned(CloseFn),
    'the open/name/close functions are exported');
  Check(Assigned(SetNameCpFn), 'tz7z_set_name_codepage is exported');

  WriteLn('-- version and struct sizes');
  TestVersionsAndSizes;
  WriteLn('-- entry info rejects a mismatched struct');
  TestEntryInfoMismatch;
  WriteLn('-- create rejects mismatched options and input records');
  TestCreateMismatch;
  WriteLn('-- name code page decodes and writes legacy names');
  TestNameCodepage;

  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
