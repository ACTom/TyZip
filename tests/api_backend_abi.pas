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
  C_ABI_VERSION     = 4;

type
  TAbiVersionFn = function: LongWord; cdecl;
  TEntryInfoFn = function(Archive: Pointer; Index: LongWord;
    Info: PZ7ZEntryInfo): LongInt; cdecl;
  TCreateFn = function(ArchivePath: PAnsiChar; Options: PZ7ZCreateOptions;
    Inputs: PZ7ZInput; Count: LongWord; Progress: Pointer; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;

var
  Fails, Passes: Integer;
  Root: string;
  Lib: TLibHandle;
  CreateFn: TCreateFn;
  EntryInfoFn: TEntryInfoFn;

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

{ Build one real zip through the public wrapper, so the entry-info mismatch
  test has something to open. }
function MakeZip(const APath: string): Boolean;
var
  Inp: TZ7ZInput;
  DiskU, ArcU: RawByteString;
  S: TCreateSettings;
  Err: string;
begin
  WriteText(Root + '/payload.txt', 'abi-payload');
  DiskU := UTF8Encode(Root + '/payload.txt');
  ArcU := 'payload.txt';
  Inp := Default(TZ7ZInput);
  Inp.StructSize := SizeOf(TZ7ZInput);
  Inp.ABIVersion := TZ7Z_ABI_VERSION;
  Inp.DiskPath := PAnsiChar(DiskU);
  Inp.ArcPath := PAnsiChar(ArcU);
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 5;
  S.ForceUtf8 := True;
  Result := TzCreate(APath, S, [Inp], Err) = TZ7Z_OK;
  if not Result then WriteLn('   setup create: ', Err);
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

begin
  Fails := 0;
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
  if not Assigned(CreateFn) or not Assigned(EntryInfoFn) then
  begin
    WriteLn('FAIL the bridge does not export the expected functions');
    Halt(2);
  end;

  WriteLn('-- version and struct sizes');
  TestVersionsAndSizes;
  WriteLn('-- entry info rejects a mismatched struct');
  TestEntryInfoMismatch;
  WriteLn('-- create rejects mismatched options and input records');
  TestCreateMismatch;

  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
