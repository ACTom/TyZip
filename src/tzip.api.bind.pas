unit tzip.api.bind;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DynLibs, tzip.api.errors;

const
  { ABI revision of the struct layouts below. Every struct crossing the ABI
    starts with its own size and this value; the library rejects a mismatch
    instead of writing into a buffer of the wrong shape. }
  TZ7Z_ABI_VERSION     =  4;

{ The three records below are handed to the C library byte for byte: their
  field offsets and total sizes must be C's, so their packing is stated
  explicitly instead of depending on the compiler default. }
{$PACKRECORDS C}
type
  TZ7ZEntryInfo = record
    { Filled in by the caller: SizeOf(this record) and TZ7Z_ABI_VERSION. }
    StructSize: LongWord;
    ABIVersion: LongWord;
    Size: QWord;
    PackedSize: QWord;
    MTime: QWord;
    CTime: QWord;
    ATime: QWord;
    CRC: LongWord;
    Attrib: LongWord;
    IsDir: LongInt;
    Encrypted: LongInt;
    IsAnti: LongInt;
    NumStreams: LongInt;
    Method: array[0..63] of AnsiChar;
    Comment: array[0..255] of AnsiChar;
  end;
  PZ7ZEntryInfo = ^TZ7ZEntryInfo;

  TZ7ZInput = record
    { Filled in by the caller for EVERY record, see TZ7ZEntryInfo above. }
    StructSize: LongWord;
    ABIVersion: LongWord;
    DiskPath: PAnsiChar;
    ArcPath: PAnsiChar;
    IsDir: LongInt;
  end;
  PZ7ZInput = ^TZ7ZInput;

  TZ7ZCreateOptions = record
    { Filled in by the caller, see TZ7ZEntryInfo above. }
    StructSize: LongWord;
    ABIVersion: LongWord;
    FormatName: PAnsiChar;
    Level: LongInt;
    Method: PAnsiChar;
    Solid: LongInt;
    Threads: LongInt;
    Password: PAnsiChar;
    EncryptNames: LongInt;
    ZipAES256: LongInt;
    VolumeSize: QWord;
    { Advanced. Zero/NULL means "use the engine default". }
    DictionarySize: QWord;
    WordSize: LongInt;
    MatchFinder: PAnsiChar;
    NumPasses: LongInt;
    Codepage: LongWord;
    ForceUtf8: LongInt;
    ExtraOptions: PAnsiChar;
    { Archive comment (UTF-8). HasComment decides whether it is applied: with
      HasComment false the existing comment is left alone, and with it true an
      empty Comment clears the stored one. }
    Comment: PAnsiChar;
    HasComment: LongInt;
  end;
  PZ7ZCreateOptions = ^TZ7ZCreateOptions;
{$PACKRECORDS 4}

  TZ7ZProgressFn = function(User: Pointer; Completed, Total: QWord): LongInt; cdecl;

  { ABI v4 detailed progress. Field order and packing are the C header's;
    item_name is UTF-8 and valid only during the callback. }
  TZ7ZProgressInfo = record
    StructSize: LongWord;
    ABIVersion: LongWord;
    Phase: LongWord;
    Event: LongWord;
    ItemIndex: LongWord;
    ItemCount: LongWord;
    IndexIsArc: LongWord;
    PackedKnown: LongInt;
    BytesDone: QWord;
    BytesTotal: QWord;
    PackedDone: QWord;
    ItemName: PAnsiChar;
  end;
  PZ7ZProgressInfo = ^TZ7ZProgressInfo;

  TZ7ZProgressExFn = function(User: Pointer;
    Info: PZ7ZProgressInfo): LongInt; cdecl;

  TZ7ZProgressSinkData = record
    StructSize: LongWord;
    ABIVersion: LongWord;
    Fn: TZ7ZProgressExFn;
    User: Pointer;
  end;
  PZ7ZProgressSink = ^TZ7ZProgressSinkData;

const
  TZ7Z_PH_OPEN = 0;
  TZ7Z_PH_EXTRACT = 1;
  TZ7Z_PH_CREATE = 2;
  TZ7Z_PH_TEST = 3;
  TZ7Z_EV_TICK = 0;
  TZ7Z_EV_ITEM = 1;
  TZ7Z_EV_ITEM_DONE = 2;

var
  FLib: TLibHandle = NilHandle;
  FLibPath: string;
  { Why the last load attempt failed. Empty after a successful load; used for
    the message an operation shows when it needs an engine that is not there. }
  FLibError: string;

  _abi_version: function: LongWord; cdecl;
  _format_json: function(Buffer: PAnsiChar; Capacity: LongInt): LongInt; cdecl;
  _open: function(Path, Password: PAnsiChar; out Archive: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _open_ex: function(Path, Password: PAnsiChar; Sink: PZ7ZProgressSink;
    out Archive: Pointer; Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _close: procedure(Archive: Pointer); cdecl;
  _entry_count: function(Archive: Pointer): LongInt; cdecl;
  _format_name: function(Archive: Pointer): PAnsiChar; cdecl;
  _has_encrypted: function(Archive: Pointer): LongInt; cdecl;
  _can_update: function(Archive: Pointer): LongInt; cdecl;
  _entry_name: function(Archive: Pointer; Index: LongWord; Buffer: PAnsiChar;
    Capacity: LongInt): LongInt; cdecl;
  _comment: function(Archive: Pointer; Buffer: PAnsiChar;
    Capacity: LongInt): LongInt; cdecl;
  _entry_info: function(Archive: Pointer; Index: LongWord;
    Info: PZ7ZEntryInfo): LongInt; cdecl;
  _extract: function(Archive: Pointer; Indices: PLongWord; Count: LongWord;
    OutDir, Password: PAnsiChar; Progress: TZ7ZProgressFn; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _extract_ex: function(Archive: Pointer; Indices: PLongWord; Count: LongWord;
    OutDir, Password: PAnsiChar; Progress: TZ7ZProgressFn; User: Pointer;
    Sink: PZ7ZProgressSink; Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _test: function(Archive: Pointer; Indices: PLongWord; Count: LongWord;
    Password: PAnsiChar; Progress: TZ7ZProgressFn; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _test_ex: function(Archive: Pointer; Indices: PLongWord; Count: LongWord;
    Password: PAnsiChar; Progress: TZ7ZProgressFn; User: Pointer;
    Sink: PZ7ZProgressSink; Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _extract_one: function(Archive: Pointer; Index: LongWord; OutFile, Password: PAnsiChar;
    Progress: TZ7ZProgressFn; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  { Extracts at most MaxBytes of one entry: the decoder stops when the limit is
    reached and the call still succeeds. 0 means no limit. No progress callback:
    it exists so a huge entry can be previewed without materialising it. }
  _extract_one_prefix: function(Archive: Pointer; Index: LongWord;
    OutFile, Password: PAnsiChar; MaxBytes: QWord;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _create: function(ArchivePath: PAnsiChar; Options: PZ7ZCreateOptions;
    Inputs: PZ7ZInput; Count: LongWord; Progress: TZ7ZProgressFn; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _create_ex: function(ArchivePath: PAnsiChar; Options: PZ7ZCreateOptions;
    Inputs: PZ7ZInput; Count: LongWord; Progress: TZ7ZProgressFn; User: Pointer;
    Sink: PZ7ZProgressSink; Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _modify: function(ArchivePath, Password: PAnsiChar; Options: PZ7ZCreateOptions;
    RemoveIndices: PLongWord; RemoveCount: LongWord;
    AddInputs: PZ7ZInput; AddCount: LongWord;
    Progress: TZ7ZProgressFn; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;
  _modify_ex: function(ArchivePath, Password: PAnsiChar; Options: PZ7ZCreateOptions;
    RemoveIndices: PLongWord; RemoveCount: LongWord;
    AddInputs: PZ7ZInput; AddCount: LongWord;
    Progress: TZ7ZProgressFn; User: Pointer; Sink: PZ7ZProgressSink;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;

function U8(const S: string): RawByteString;
function FromU8(const S: PAnsiChar): string;
function TzLibraryLoaded: Boolean;
function TzLoadLibrary(const AExplicitPath: string = ''): Boolean;
function TzLibraryPath: string;
function TzEngineMissingError: string;

implementation

type
  { tz7z_abi_version, taken as a pointer first so a library without it can be
    rejected before any other call. }
  TZ7ZAbiVersionFn = function: LongWord; cdecl;

function ExeDir: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0)));
end;

function TzLibraryPath: string;
begin
  Result := FLibPath;
end;

function TzLibFileName: string;
begin
  {$IFDEF MSWINDOWS}
  Result := 'tz7z.dll';
  {$ELSE}
    {$IFDEF DARWIN}
  Result := 'libtz7z.dylib';
    {$ELSE}
  Result := 'libtz7z.so';
    {$ENDIF}
  {$ENDIF}
end;

function CandidatePaths(const AExplicitPath: string): TStringList;
  procedure AddUnique(const P: string);
  begin
    if (P <> '') and (Result.IndexOf(P) < 0) then Result.Add(P);
  end;
var
  Base: string;
begin
  Result := TStringList.Create;
  if AExplicitPath <> '' then AddUnique(AExplicitPath);
  Base := ExeDir;
  AddUnique(Base + TzLibFileName);
  AddUnique(Base + 'lib' + PathDelim + TzLibFileName);
  AddUnique(Base + '..' + PathDelim + 'Frameworks' + PathDelim + TzLibFileName);
  AddUnique(Base + '..' + PathDelim + 'lib' + PathDelim + TzLibFileName);
  AddUnique(Base + '..' + PathDelim + 'Resources' + PathDelim + TzLibFileName);
  AddUnique(Base + '..' + PathDelim + '..' + PathDelim + 'lib' + PathDelim + TzLibFileName);
  AddUnique(Base + '..' + PathDelim + '..' + PathDelim + 'Frameworks' + PathDelim + TzLibFileName);
  AddUnique(GetEnvironmentVariable('TYZIP_LIB'));
  AddUnique(TzLibFileName);
end;

{ A library built against another ABI must be refused before anything else is
  called through it: the structs it reads have another shape. }
function AbiMismatchError(AFound: LongWord): string;
begin
  if AFound = 0 then
    Result := 'The TyZip engine library is too old for this build and has no ' +
      'ABI version. Rebuild it with scripts/build_backend.sh.'
  else
    Result := Format('The TyZip engine library reports ABI %d but this build ' +
      'needs ABI %d. Rebuild it with scripts/build_backend.sh.',
      [Int64(AFound), Int64(TZ7Z_ABI_VERSION)]);
end;

{ The message an operation reports when it needs an engine that is not loaded. }
function TzEngineMissingError: string;
begin
  if FLibError <> '' then
    Result := FLibError
  else
    Result := 'The TyZip engine is not loaded.';
end;

function TzLoadLibrary(const AExplicitPath: string): Boolean;
var
  Candidates: TStringList;
  I: Integer;
  H: TLibHandle;
  P, V: Pointer;
  Ver: LongWord;
begin
  if FLib <> NilHandle then Exit(True);
  FLibError := '';

  Candidates := CandidatePaths(AExplicitPath);
  try
    for I := 0 to Candidates.Count - 1 do
    begin
      H := LoadLibrary(Candidates[I]);
      if H = NilHandle then Continue;

      P := GetProcedureAddress(H, 'tz7z_format_json');
      if P = nil then
      begin
        FLibError := AbiMismatchError(0);
        UnloadLibrary(H);
        Continue;
      end;

      { ABI first: an older library may have every other symbol but the wrong
        struct layouts, and calling into it would corrupt memory, not error. }
      V := GetProcedureAddress(H, 'tz7z_abi_version');
      if V = nil then
      begin
        FLibError := AbiMismatchError(0);
        UnloadLibrary(H);
        Continue;
      end;
      Ver := TZ7ZAbiVersionFn(V)();
      if Ver <> TZ7Z_ABI_VERSION then
      begin
        FLibError := AbiMismatchError(Ver);
        UnloadLibrary(H);
        Continue;
      end;

      FLib := H;
      FLibPath := Candidates[I];
      FLibError := '';
      Break;
    end;
  finally
    Candidates.Free;
  end;

  if FLib = NilHandle then Exit(False);

  Pointer(_abi_version)   := GetProcedureAddress(FLib, 'tz7z_abi_version');
  Pointer(_format_json)   := GetProcedureAddress(FLib, 'tz7z_format_json');
  Pointer(_open)          := GetProcedureAddress(FLib, 'tz7z_open');
  Pointer(_open_ex)       := GetProcedureAddress(FLib, 'tz7z_open_ex');
  Pointer(_close)         := GetProcedureAddress(FLib, 'tz7z_close');
  Pointer(_entry_count)   := GetProcedureAddress(FLib, 'tz7z_entry_count');
  Pointer(_format_name)   := GetProcedureAddress(FLib, 'tz7z_format_name');
  Pointer(_has_encrypted) := GetProcedureAddress(FLib, 'tz7z_has_encrypted');
  Pointer(_can_update)    := GetProcedureAddress(FLib, 'tz7z_can_update');
  Pointer(_entry_name)    := GetProcedureAddress(FLib, 'tz7z_entry_name');
  Pointer(_comment)       := GetProcedureAddress(FLib, 'tz7z_comment');
  Pointer(_entry_info)    := GetProcedureAddress(FLib, 'tz7z_entry_info_get');
  Pointer(_extract)       := GetProcedureAddress(FLib, 'tz7z_extract');
  Pointer(_extract_ex)    := GetProcedureAddress(FLib, 'tz7z_extract_ex');
  Pointer(_test)          := GetProcedureAddress(FLib, 'tz7z_test');
  Pointer(_test_ex)       := GetProcedureAddress(FLib, 'tz7z_test_ex');
  Pointer(_extract_one)   := GetProcedureAddress(FLib, 'tz7z_extract_one');
  Pointer(_extract_one_prefix) := GetProcedureAddress(FLib, 'tz7z_extract_one_prefix');
  Pointer(_create)        := GetProcedureAddress(FLib, 'tz7z_create');
  Pointer(_create_ex)     := GetProcedureAddress(FLib, 'tz7z_create_ex');
  Pointer(_modify)        := GetProcedureAddress(FLib, 'tz7z_modify');
  Pointer(_modify_ex)     := GetProcedureAddress(FLib, 'tz7z_modify_ex');

  { Every symbol the code below calls: a library that has them all but one must be
    rejected as a whole, or the first call through the missing pointer crashes.
    _comment was missing from this list while TTzArchive.Comment already called
    it, so an older dylib loaded fine and then jumped through nil. }
  Result := Assigned(_abi_version) and Assigned(_format_json) and
            Assigned(_open) and Assigned(_close) and Assigned(_entry_count) and
            Assigned(_format_name) and Assigned(_has_encrypted) and
            Assigned(_can_update) and Assigned(_entry_name) and
            Assigned(_comment) and Assigned(_entry_info) and
            Assigned(_extract) and Assigned(_test) and
            Assigned(_extract_one) and Assigned(_extract_one_prefix) and
            Assigned(_create) and Assigned(_modify) and
            Assigned(_open_ex) and Assigned(_extract_ex) and Assigned(_test_ex) and
            Assigned(_create_ex) and Assigned(_modify_ex);
  if not Result then
  begin
    UnloadLibrary(FLib);
    FLib := NilHandle;
    FLibPath := '';
  end;
end;

function TzLibraryLoaded: Boolean;
begin
  Result := FLib <> NilHandle;
end;


function U8(const S: string): RawByteString;
begin
  Result := UTF8Encode(S);
end;

function FromU8(const S: PAnsiChar): string;
begin
  if S = nil then Exit('');
  Result := string(AnsiString(S));
end;

end.
