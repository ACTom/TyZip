unit tzip.api;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes,
  tzip.api.errors, tzip.api.bind, tzip.api.formats;

const
  TZ7Z_ABI_VERSION     = tzip.api.bind.TZ7Z_ABI_VERSION;

  TZ7Z_OK              = tzip.api.errors.TZ7Z_OK;
  TZ7Z_E_ARG           = tzip.api.errors.TZ7Z_E_ARG;
  TZ7Z_E_MEMORY        = tzip.api.errors.TZ7Z_E_MEMORY;
  TZ7Z_E_OPEN          = tzip.api.errors.TZ7Z_E_OPEN;
  TZ7Z_E_NOT_ARCHIVE   = tzip.api.errors.TZ7Z_E_NOT_ARCHIVE;
  TZ7Z_E_PASSWORD      = tzip.api.errors.TZ7Z_E_PASSWORD;
  TZ7Z_E_FORMAT        = tzip.api.errors.TZ7Z_E_FORMAT;
  TZ7Z_E_UPDATE        = tzip.api.errors.TZ7Z_E_UPDATE;
  TZ7Z_E_EXTRACT       = tzip.api.errors.TZ7Z_E_EXTRACT;
  TZ7Z_E_CANCEL        = tzip.api.errors.TZ7Z_E_CANCEL;
  TZ7Z_E_IO            = tzip.api.errors.TZ7Z_E_IO;
  TZ7Z_E_UNSUPPORTED   = tzip.api.errors.TZ7Z_E_UNSUPPORTED;

  TZ7Z_PH_OPEN         = tzip.api.bind.TZ7Z_PH_OPEN;
  TZ7Z_PH_EXTRACT      = tzip.api.bind.TZ7Z_PH_EXTRACT;
  TZ7Z_PH_CREATE       = tzip.api.bind.TZ7Z_PH_CREATE;
  TZ7Z_PH_TEST         = tzip.api.bind.TZ7Z_PH_TEST;
  TZ7Z_EV_TICK         = tzip.api.bind.TZ7Z_EV_TICK;
  TZ7Z_EV_ITEM         = tzip.api.bind.TZ7Z_EV_ITEM;
  TZ7Z_EV_ITEM_DONE    = tzip.api.bind.TZ7Z_EV_ITEM_DONE;

type
  TZ7ZEntryInfo = tzip.api.bind.TZ7ZEntryInfo;
  PZ7ZEntryInfo = tzip.api.bind.PZ7ZEntryInfo;
  TZ7ZInput = tzip.api.bind.TZ7ZInput;
  PZ7ZInput = tzip.api.bind.PZ7ZInput;
  TZ7ZCreateOptions = tzip.api.bind.TZ7ZCreateOptions;
  PZ7ZCreateOptions = tzip.api.bind.PZ7ZCreateOptions;
  TZ7ZProgressFn = tzip.api.bind.TZ7ZProgressFn;

  { ABI v4 detailed progress in Pascal form: the bridge's item_name is copied
    into Name, so it stays valid after the callback returns. }
  TZ7ZProgressInfo = record
    Phase: LongWord;
    Event: LongWord;
    ItemIndex: LongWord;
    ItemCount: LongWord;
    IndexIsArc: Boolean;
    PackedKnown: Boolean;
    BytesDone: QWord;
    BytesTotal: QWord;
    PackedDone: QWord;
    Name: string;
  end;

  TFormatInfo = tzip.api.formats.TFormatInfo;
  TFormatInfoArray = tzip.api.formats.TFormatInfoArray;

  { High level settings used by the UI. }
  TCreateSettings = record
    FormatName: string;
    Level: Integer;
    Method: string;
    Solid: Boolean;
    Threads: Integer;
    Password: string;
    EncryptNames: Boolean;
    ZipAES256: Boolean;
    VolumeSize: QWord;
    { Advanced. 0 / '' = let the engine choose. }
    DictionarySize: QWord;
    WordSize: Integer;
    MatchFinder: string;
    NumPasses: Integer;
    { ZIP name encoding: 0 = engine default, otherwise a Windows code page
      (936 GBK, 932 Shift-JIS, 65001 UTF-8). ForceUtf8 wins over it. }
    Codepage: LongWord;
    ForceUtf8: Boolean;
    { Raw "name=value:name=value" pairs, applied last. }
    ExtraOptions: string;
    { Application-level: remove the source files once the archive is written.
      The engine never deletes anything, so this is honoured by the caller. }
    DeleteSources: Boolean;
  end;

type
  { Per-call progress target.  The bridge passes a user pointer through to the
    cdecl trampoline, so a worker thread can route progress to its own object
    instead of the process-wide GlobalProgress.  Tick returns False to abort. }
  TZ7ZProgressSink = class
  public
    function Tick(Completed, Total: QWord): Boolean; virtual; abstract;
    { ABI v4 hook.  The default keeps old sinks working: only TICK events are
      routed to Tick, item events are ignored.  Override to see per-item events
      and the live packed byte count. }
    function Progress(const AInfo: TZ7ZProgressInfo): Boolean; virtual;
  end;

function TzProgressTrampoline(User: Pointer; Completed, Total: QWord): LongInt; cdecl;
function TzProgressExTrampoline(User: Pointer;
  Info: tzip.api.bind.PZ7ZProgressInfo): LongInt; cdecl;

function TzErrorText(Code: Integer): string;
function TzFormatSize(Bytes: QWord): string;

{ Should the UI ask for the password again after an extraction failed? A
  data-encrypted 7z reports a wrong password as a data error (7-Zip cannot tell
  it from corrupt ciphertext), so the only retryable case is a data error on an
  encrypted entry for which a password was supplied. See tzip.api.errors. }
function TzShouldRetryPasswordAfterExtractError(AResult: Integer;
  AEntryEncrypted, APasswordSupplied, AAlreadyRetried: Boolean): Boolean;

type
  ETzError = class(Exception)
  public
    Code: Integer;
    constructor Create(ACode: Integer; const AMsg: string);
  end;

  TTzArchive = class
  private
    FHandle: Pointer;
    FPath: string;
    FPassword: string;
    FFormatName: string;
    FHasEncrypted: Boolean;
    FCanUpdate: Boolean;
    FCount: Integer;
  public
    constructor Create(AHandle: Pointer; const APath, APassword: string);
    destructor Destroy; override;
    property Handle: Pointer read FHandle;
    property Path: string read FPath;
    property Password: string read FPassword write FPassword;
    property FormatName: string read FFormatName;
    property HasEncrypted: Boolean read FHasEncrypted;
    property CanUpdate: Boolean read FCanUpdate;
    property Count: Integer read FCount;
    function EntryName(AIndex: Integer): string;
    function EntryInfo(AIndex: Integer): TZ7ZEntryInfo;
    function EntryMethod(AIndex: Integer): string;
    function Comment: string;
  end;


function TzLibraryLoaded: Boolean;
function TzLoadLibrary(const AExplicitPath: string = ''): Boolean;
function TzLibraryPath: string;
function TzLoadFormats: TFormatInfoArray;
function TzParseFormatsJSON(const AJSON: string): TFormatInfoArray;
function TzFormatByName(const AName: string): TFormatInfo;

function TzOpenArchive(const APath, APassword: string; out AArchive: TTzArchive;
  out AError: string; AProgress: TZ7ZProgressSink = nil): Integer;
function TzExtract(AArchive: TTzArchive; const AIndices: array of LongWord;
  const AOutDir, APassword: string; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;
function TzExtractOne(AArchive: TTzArchive; AIndex: Integer; const AOutFile,
  APassword: string; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;
{ Extract at most AMaxBytes of one entry (0 = no limit). The file on disk is the
  prefix when the entry is longer; the decoder stops at the limit, so a huge
  entry is never fully materialised. Used by the text/unknown preview path. }
function TzExtractOnePrefix(AArchive: TTzArchive; AIndex: Integer;
  const AOutFile, APassword: string; AMaxBytes: QWord;
  out AError: string): Integer;
function TzTest(AArchive: TTzArchive; const AIndices: array of LongWord;
  const APassword: string; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;
function TzCreate(const AArchivePath: string; const ASettings: TCreateSettings;
  const AInputs: array of TZ7ZInput; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;
{ Rewrite an archive. AComment replaces the archive's comment when
  ASetComment is true; when it is false the stored comment is left alone, which
  is what every caller that is not editing the comment wants. }
function TzModify(const AArchivePath, APassword: string;
  const ASettings: TCreateSettings;
  const ARemoveIndices: array of LongWord;
  const AAddInputs: array of TZ7ZInput; out AError: string;
  AProgress: TZ7ZProgressSink = nil;
  const AComment: string = ''; ASetComment: Boolean = False): Integer;


implementation

function TzErrorText(Code: Integer): string;
begin
  Result := tzip.api.errors.TzErrorText(Code);
end;

function TzShouldRetryPasswordAfterExtractError(AResult: Integer;
  AEntryEncrypted, APasswordSupplied, AAlreadyRetried: Boolean): Boolean;
begin
  Result := tzip.api.errors.TzShouldRetryPasswordAfterExtractError(AResult,
    AEntryEncrypted, APasswordSupplied, AAlreadyRetried);
end;

function TzLibraryLoaded: Boolean;
begin
  Result := tzip.api.bind.TzLibraryLoaded;
end;

function TzLoadLibrary(const AExplicitPath: string): Boolean;
begin
  Result := tzip.api.bind.TzLoadLibrary(AExplicitPath);
end;

function TzLibraryPath: string;
begin
  Result := tzip.api.bind.TzLibraryPath;
end;

function TzLoadFormats: TFormatInfoArray;
begin
  Result := tzip.api.formats.TzLoadFormats;
end;

function TzParseFormatsJSON(const AJSON: string): TFormatInfoArray;
begin
  Result := tzip.api.formats.TzParseFormatsJSON(AJSON);
end;

function TzFormatByName(const AName: string): TFormatInfo;
begin
  Result := tzip.api.formats.TzFormatByName(AName);
end;

function TzProgressTrampoline(User: Pointer; Completed, Total: QWord): LongInt; cdecl;
begin
  if User <> nil then
  begin
    { Runs on the thread that called into the bridge; the sink must be thread
      safe and must not touch the UI. }
    if TZ7ZProgressSink(User).Tick(Completed, Total) then Result := 1 else Result := 0;
  end
  else
    { No per-call sink: keep going. There is deliberately no process-wide
      progress target -- one would be shared by concurrent operations, and the
      bridge calls it on its own worker thread, where touching the UI is not
      allowed. }
    Result := 1;
end;

{ ABI v4 default: old sinks keep receiving their byte ticks; item events are
  opt-in by overriding Progress. }
function TZ7ZProgressSink.Progress(const AInfo: TZ7ZProgressInfo): Boolean;
begin
  if AInfo.Event = tzip.api.bind.TZ7Z_EV_TICK then
    Result := Tick(AInfo.BytesDone, AInfo.BytesTotal)
  else
    Result := True;
end;

function TzProgressExTrampoline(User: Pointer;
  Info: tzip.api.bind.PZ7ZProgressInfo): LongInt; cdecl;
var
  P: TZ7ZProgressInfo;
begin
  if (User = nil) or (Info = nil) then
    Exit(1);
  P := Default(TZ7ZProgressInfo);
  P.Phase := Info^.Phase;
  P.Event := Info^.Event;
  P.ItemIndex := Info^.ItemIndex;
  P.ItemCount := Info^.ItemCount;
  P.IndexIsArc := Info^.IndexIsArc <> 0;
  P.PackedKnown := Info^.PackedKnown <> 0;
  P.BytesDone := Info^.BytesDone;
  P.BytesTotal := Info^.BytesTotal;
  P.PackedDone := Info^.PackedDone;
  if Info^.ItemName <> nil then
    P.Name := string(AnsiString(Info^.ItemName))
  else
    P.Name := '';
  if TZ7ZProgressSink(User).Progress(P) then
    Result := 1
  else
    Result := 0;
end;

function MakeProgressSink(AProgress: TZ7ZProgressSink;
  out ASink: tzip.api.bind.TZ7ZProgressSinkData): tzip.api.bind.PZ7ZProgressSink;
begin
  if AProgress = nil then
    Exit(nil);
  ASink.StructSize := SizeOf(ASink);
  ASink.ABIVersion := TZ7Z_ABI_VERSION;
  ASink.Fn := @TzProgressExTrampoline;
  ASink.User := AProgress;
  Result := @ASink;
end;

function TzFormatSize(Bytes: QWord): string;
const
  KB = QWord(1024);
  MB = KB * 1024;
  GB = MB * 1024;
  TB = GB * 1024;
begin
  if Bytes < KB then
    Result := IntToStr(Bytes) + ' B'
  else if Bytes < MB then
    Result := FormatFloat('0.0', Bytes / KB) + ' KB'
  else if Bytes < GB then
    Result := FormatFloat('0.0', Bytes / MB) + ' MB'
  else if Bytes < TB then
    Result := FormatFloat('0.00', Bytes / GB) + ' GB'
  else
    Result := FormatFloat('0.00', Bytes / TB) + ' TB';
end;

constructor ETzError.Create(ACode: Integer; const AMsg: string);
begin
  Code := ACode;
  inherited Create(AMsg);
end;

constructor TTzArchive.Create(AHandle: Pointer; const APath, APassword: string);
begin
  inherited Create;
  FHandle := AHandle;
  FPath := APath;
  FPassword := APassword;
  if FHandle <> nil then
  begin
    FCount := tzip.api.bind._entry_count(FHandle);
    FFormatName := tzip.api.bind.FromU8(tzip.api.bind._format_name(FHandle));
    FHasEncrypted := tzip.api.bind._has_encrypted(FHandle) <> 0;
    FCanUpdate := tzip.api.bind._can_update(FHandle) <> 0;
  end;
end;

destructor TTzArchive.Destroy;
begin
  if FHandle <> nil then
  begin
    tzip.api.bind._close(FHandle);
    FHandle := nil;
  end;
  inherited Destroy;
end;

function TTzArchive.EntryName(AIndex: Integer): string;
var
  Need: Integer;
  Buf: RawByteString;
begin
  Result := '';
  if (FHandle = nil) or (AIndex < 0) or (AIndex >= FCount) then Exit;
  Need := tzip.api.bind._entry_name(FHandle, LongWord(AIndex), nil, 0);
  if Need <= 1 then Exit;
  SetLength(Buf, Need);
  if tzip.api.bind._entry_name(FHandle, LongWord(AIndex), PAnsiChar(Buf), Need) > 0 then
    Result := string(AnsiString(PAnsiChar(Buf)));
end;

function TTzArchive.EntryInfo(AIndex: Integer): TZ7ZEntryInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  { The library refuses a struct it does not recognise instead of writing into
    it, so the caller's idea of its own layout has to be stated first. }
  Result.StructSize := SizeOf(Result);
  Result.ABIVersion := TZ7Z_ABI_VERSION;
  if (FHandle = nil) or (AIndex < 0) or (AIndex >= FCount) then Exit;
  tzip.api.bind._entry_info(FHandle, LongWord(AIndex), @Result);
end;

{ The archive-level comment, empty when there is none. }
function TTzArchive.Comment: string;
var
  Need: Integer;
  Buf: array of AnsiChar;
begin
  Result := '';
  if FHandle = nil then Exit;
  Need := tzip.api.bind._comment(FHandle, nil, 0);
  if Need <= 1 then Exit;
  SetLength(Buf, Need);
  if tzip.api.bind._comment(FHandle, PAnsiChar(Buf), Need) > 0 then
    Result := string(AnsiString(PAnsiChar(Buf)));
end;

function TTzArchive.EntryMethod(AIndex: Integer): string;
var
  Info: TZ7ZEntryInfo;
begin
  Info := EntryInfo(AIndex);
  Result := string(AnsiString(PAnsiChar(@Info.Method[0])));
end;


function TzOpenArchive(const APath, APassword: string; out AArchive: TTzArchive;
  out AError: string; AProgress: TZ7ZProgressSink): Integer;
var
  H: Pointer;
  Err: array[0..1023] of AnsiChar;
  P, Pw: RawByteString;
  Sink: tzip.api.bind.TZ7ZProgressSinkData;
  SinkPtr: tzip.api.bind.PZ7ZProgressSink;
begin
  AArchive := nil;
  AError := '';
  if not TzLibraryLoaded then
  begin
    AError := TzEngineMissingError;
    Exit(TZ7Z_E_OPEN);
  end;
  P := tzip.api.bind.U8(APath);
  Pw := tzip.api.bind.U8(APassword);
  FillChar(Err, SizeOf(Err), 0);
  H := nil;
  if AProgress <> nil then
  begin
    SinkPtr := MakeProgressSink(AProgress, Sink);
    Result := tzip.api.bind._open_ex(PAnsiChar(P), PAnsiChar(Pw), SinkPtr,
      H, @Err[0], SizeOf(Err));
  end
  else
    Result := tzip.api.bind._open(PAnsiChar(P), PAnsiChar(Pw), H,
      @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  { Told apart by CODE, never by the wording of AError: the bridge returns
    TZ7Z_E_PASSWORD when opening needed a password (the one supplied was missing
    or wrong) and TZ7Z_E_NOT_ARCHIVE when the file is not a readable archive.
    Sniffing the message for the word "password" classified every unreadable
    file -- a .txt dropped on the window, a truncated zip -- as "needs a
    password", and it would silently stop working the day the engine changed its
    wording. }
  if Result = TZ7Z_OK then
    AArchive := TTzArchive.Create(H, APath, APassword)
  else if AError = '' then
    AError := TzErrorText(Result);
end;

function TzExtract(AArchive: TTzArchive; const AIndices: array of LongWord;
  const AOutDir, APassword: string; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  Err: array[0..1023] of AnsiChar;
  OutDir, Pw: RawByteString;
  Idx: array of LongWord;
  PIdx: PLongWord;
  I: Integer;
  Sink: tzip.api.bind.TZ7ZProgressSinkData;
  SinkPtr: tzip.api.bind.PZ7ZProgressSink;
begin
  AError := '';
  if AArchive = nil then Exit(TZ7Z_E_ARG);
  OutDir := tzip.api.bind.U8(AOutDir);
  Pw := tzip.api.bind.U8(APassword);
  FillChar(Err, SizeOf(Err), 0);
  PIdx := nil;
  if Length(AIndices) > 0 then
  begin
    SetLength(Idx, Length(AIndices));
    for I := 0 to High(AIndices) do Idx[I] := AIndices[I];
    PIdx := @Idx[0];
  end;
  if AProgress <> nil then
  begin
    SinkPtr := MakeProgressSink(AProgress, Sink);
    Result := tzip.api.bind._extract_ex(AArchive.Handle, PIdx, Length(AIndices),
      PAnsiChar(OutDir), PAnsiChar(Pw), nil, nil, SinkPtr,
      @Err[0], SizeOf(Err));
  end
  else
    Result := tzip.api.bind._extract(AArchive.Handle, PIdx, Length(AIndices),
      PAnsiChar(OutDir), PAnsiChar(Pw), @TzProgressTrampoline, nil,
      @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  if (Result <> TZ7Z_OK) and (AError = '') then AError := TzErrorText(Result);
end;

function TzExtractOne(AArchive: TTzArchive; AIndex: Integer; const AOutFile,
  APassword: string; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  Err: array[0..1023] of AnsiChar;
  OutFile, Pw: RawByteString;
begin
  AError := '';
  if (AArchive = nil) or (AIndex < 0) then Exit(TZ7Z_E_ARG);
  OutFile := tzip.api.bind.U8(AOutFile);
  Pw := tzip.api.bind.U8(APassword);
  FillChar(Err, SizeOf(Err), 0);
  Result := tzip.api.bind._extract_one(AArchive.Handle, LongWord(AIndex), PAnsiChar(OutFile),
    PAnsiChar(Pw), @TzProgressTrampoline, AProgress, @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  if (Result <> TZ7Z_OK) and (AError = '') then AError := TzErrorText(Result);
end;

function TzExtractOnePrefix(AArchive: TTzArchive; AIndex: Integer;
  const AOutFile, APassword: string; AMaxBytes: QWord;
  out AError: string): Integer;
var
  Err: array[0..1023] of AnsiChar;
  OutFile, Pw: RawByteString;
begin
  AError := '';
  if (AArchive = nil) or (AIndex < 0) or (AOutFile = '') then
    Exit(TZ7Z_E_ARG);
  OutFile := tzip.api.bind.U8(AOutFile);
  Pw := tzip.api.bind.U8(APassword);
  FillChar(Err, SizeOf(Err), 0);
  Result := tzip.api.bind._extract_one_prefix(AArchive.Handle, LongWord(AIndex),
    PAnsiChar(OutFile), PAnsiChar(Pw), AMaxBytes, @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  if (Result <> TZ7Z_OK) and (AError = '') then AError := TzErrorText(Result);
end;

function TzTest(AArchive: TTzArchive; const AIndices: array of LongWord;
  const APassword: string; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  Err: array[0..1023] of AnsiChar;
  Pw: RawByteString;
  Idx: array of LongWord;
  PIdx: PLongWord;
  I: Integer;
  Sink: tzip.api.bind.TZ7ZProgressSinkData;
  SinkPtr: tzip.api.bind.PZ7ZProgressSink;
begin
  AError := '';
  if AArchive = nil then Exit(TZ7Z_E_ARG);
  Pw := tzip.api.bind.U8(APassword);
  FillChar(Err, SizeOf(Err), 0);
  PIdx := nil;
  if Length(AIndices) > 0 then
  begin
    SetLength(Idx, Length(AIndices));
    for I := 0 to High(AIndices) do Idx[I] := AIndices[I];
    PIdx := @Idx[0];
  end;
  if AProgress <> nil then
  begin
    SinkPtr := MakeProgressSink(AProgress, Sink);
    Result := tzip.api.bind._test_ex(AArchive.Handle, PIdx, Length(AIndices),
      PAnsiChar(Pw), nil, nil, SinkPtr, @Err[0], SizeOf(Err));
  end
  else
    Result := tzip.api.bind._test(AArchive.Handle, PIdx, Length(AIndices),
      PAnsiChar(Pw), @TzProgressTrampoline, nil, @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  if (Result <> TZ7Z_OK) and (AError = '') then AError := TzErrorText(Result);
end;

function TzCreate(const AArchivePath: string; const ASettings: TCreateSettings;
  const AInputs: array of TZ7ZInput; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  Err: array[0..1023] of AnsiChar;
  Path, Fmt, Method, Pw, MF, Extra: RawByteString;
  Opt: TZ7ZCreateOptions;
  Recs: array of TZ7ZInput;
  Disk, Arc: array of RawByteString;
  I: Integer;
  Sink: tzip.api.bind.TZ7ZProgressSinkData;
  SinkPtr: tzip.api.bind.PZ7ZProgressSink;
begin
  AError := '';
  if not TzLibraryLoaded then
  begin
    AError := TzEngineMissingError;
    Exit(TZ7Z_E_OPEN);
  end;
  Path := tzip.api.bind.U8(AArchivePath);
  Fmt := tzip.api.bind.U8(ASettings.FormatName);
  Method := tzip.api.bind.U8(ASettings.Method);
  Pw := tzip.api.bind.U8(ASettings.Password);
  FillChar(Opt, SizeOf(Opt), 0);
  Opt.StructSize := SizeOf(Opt);
  Opt.ABIVersion := TZ7Z_ABI_VERSION;
  Opt.FormatName := PAnsiChar(Fmt);
  Opt.Level := ASettings.Level;
  Opt.Method := PAnsiChar(Method);
  if ASettings.Solid then Opt.Solid := 1 else Opt.Solid := 0;
  Opt.Threads := ASettings.Threads;
  Opt.Password := PAnsiChar(Pw);
  if ASettings.EncryptNames then Opt.EncryptNames := 1;
  if ASettings.ZipAES256 then Opt.ZipAES256 := 1;
  Opt.VolumeSize := ASettings.VolumeSize;
  Opt.DictionarySize := ASettings.DictionarySize;
  Opt.WordSize := ASettings.WordSize;
  Opt.NumPasses := ASettings.NumPasses;
  Opt.Codepage := ASettings.Codepage;
  if ASettings.ForceUtf8 then Opt.ForceUtf8 := 1;
  MF := tzip.api.bind.U8(ASettings.MatchFinder);
  Opt.MatchFinder := PAnsiChar(MF);
  Extra := tzip.api.bind.U8(ASettings.ExtraOptions);
  Opt.ExtraOptions := PAnsiChar(Extra);

  SetLength(Disk, Length(AInputs));
  SetLength(Arc, Length(AInputs));
  SetLength(Recs, Length(AInputs));
  for I := 0 to High(AInputs) do
  begin
    { TZ7ZInput paths are ALREADY UTF-8 -- that is the contract of this ABI, and
      every caller fills them from UTF8Strings. Running them through tzip.api.bind.U8() (which
      is UTF8Encode) converted them a second time, so a Chinese path reached
      7-Zip as mojibake and the job died with "cannot stat input file".
      Copy the bytes verbatim. }
    { Every record carries its own size and the ABI revision; the library
      validates each one, so a partly-filled array is refused by name. }
    FillChar(Recs[I], SizeOf(Recs[I]), 0);
    Recs[I].StructSize := SizeOf(Recs[I]);
    Recs[I].ABIVersion := TZ7Z_ABI_VERSION;
    Disk[I] := AnsiString(AInputs[I].DiskPath);
    Arc[I] := AnsiString(AInputs[I].ArcPath);
    Recs[I].DiskPath := PAnsiChar(Disk[I]);
    Recs[I].ArcPath := PAnsiChar(Arc[I]);
    Recs[I].IsDir := AInputs[I].IsDir;
  end;

  FillChar(Err, SizeOf(Err), 0);
  if AProgress <> nil then
  begin
    SinkPtr := MakeProgressSink(AProgress, Sink);
    if Length(Recs) > 0 then
      Result := tzip.api.bind._create_ex(PAnsiChar(Path), @Opt, @Recs[0],
        Length(Recs), nil, nil, SinkPtr, @Err[0], SizeOf(Err))
    else
      Result := tzip.api.bind._create_ex(PAnsiChar(Path), @Opt, nil, 0,
        nil, nil, SinkPtr, @Err[0], SizeOf(Err));
  end
  else if Length(Recs) > 0 then
    Result := tzip.api.bind._create(PAnsiChar(Path), @Opt, @Recs[0], Length(Recs),
      @TzProgressTrampoline, nil, @Err[0], SizeOf(Err))
  else
    Result := tzip.api.bind._create(PAnsiChar(Path), @Opt, nil, 0,
      @TzProgressTrampoline, nil, @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  if (Result <> TZ7Z_OK) and (AError = '') then AError := TzErrorText(Result);
end;

function TzModify(const AArchivePath, APassword: string;
  const ASettings: TCreateSettings;
  const ARemoveIndices: array of LongWord;
  const AAddInputs: array of TZ7ZInput; out AError: string;
  AProgress: TZ7ZProgressSink; const AComment: string;
  ASetComment: Boolean): Integer;
var
  Err: array[0..1023] of AnsiChar;
  Path, Fmt, Method, Pw, MF, Extra, Cmt: RawByteString;
  Opt: TZ7ZCreateOptions;
  Recs: array of TZ7ZInput;
  Disk, Arc: array of RawByteString;
  Rem: array of LongWord;
  PRem: PLongWord;
  I: Integer;
  Sink: tzip.api.bind.TZ7ZProgressSinkData;
  SinkPtr: tzip.api.bind.PZ7ZProgressSink;
begin
  AError := '';
  if not TzLibraryLoaded then
  begin
    AError := TzEngineMissingError;
    Exit(TZ7Z_E_OPEN);
  end;
  Path := tzip.api.bind.U8(AArchivePath);
  Fmt := tzip.api.bind.U8(ASettings.FormatName);
  Method := tzip.api.bind.U8(ASettings.Method);
  Pw := tzip.api.bind.U8(APassword);
  FillChar(Opt, SizeOf(Opt), 0);
  Opt.StructSize := SizeOf(Opt);
  Opt.ABIVersion := TZ7Z_ABI_VERSION;
  Opt.FormatName := PAnsiChar(Fmt);
  Opt.Level := ASettings.Level;
  Opt.Method := PAnsiChar(Method);
  if ASettings.Solid then Opt.Solid := 1 else Opt.Solid := 0;
  Opt.Threads := ASettings.Threads;
  Opt.Password := PAnsiChar(Pw);
  if ASettings.EncryptNames then Opt.EncryptNames := 1;
  if ASettings.ZipAES256 then Opt.ZipAES256 := 1;
  { Every advanced option the create path carries, or a modify silently rewrites
    the archive with the engine's defaults: a 16 MB dictionary, the chosen match
    finder and the extra options all vanished from an archive that was updated
    rather than created. Without the codepage pair a modify also rewrites the
    archive with its DEFAULT name encoding, which on Unix means every non-ASCII
    entry the rewrite touches comes back as mojibake. }
  Opt.VolumeSize := ASettings.VolumeSize;
  Opt.DictionarySize := ASettings.DictionarySize;
  Opt.WordSize := ASettings.WordSize;
  Opt.NumPasses := ASettings.NumPasses;
  Opt.Codepage := ASettings.Codepage;
  if ASettings.ForceUtf8 then Opt.ForceUtf8 := 1;
  MF := tzip.api.bind.U8(ASettings.MatchFinder);
  Opt.MatchFinder := PAnsiChar(MF);
  Extra := tzip.api.bind.U8(ASettings.ExtraOptions);
  Opt.ExtraOptions := PAnsiChar(Extra);
  if ASetComment then
  begin
    Cmt := RawByteString(AComment);
    Opt.Comment := PAnsiChar(Cmt);
    Opt.HasComment := 1;
  end;

  PRem := nil;
  if Length(ARemoveIndices) > 0 then
  begin
    SetLength(Rem, Length(ARemoveIndices));
    for I := 0 to High(ARemoveIndices) do Rem[I] := ARemoveIndices[I];
    PRem := @Rem[0];
  end;

  SetLength(Disk, Length(AAddInputs));
  SetLength(Arc, Length(AAddInputs));
  SetLength(Recs, Length(AAddInputs));
  for I := 0 to High(AAddInputs) do
  begin
    { The incoming paths are ALREADY UTF-8 (the caller built them from UTF-8
      strings). Copying the bytes is correct; running them through U8/UTF8Encode
      encodes them a SECOND time, so "新增.txt" reaches the engine as 16 bytes of
      mojibake and is stored that way. TzCreate has always copied verbatim --
      this path did not, which is why an entry ADDED to an existing archive came
      out garbled while the same entry in a fresh archive was fine. }
    FillChar(Recs[I], SizeOf(Recs[I]), 0);
    Recs[I].StructSize := SizeOf(Recs[I]);
    Recs[I].ABIVersion := TZ7Z_ABI_VERSION;
    Disk[I] := AnsiString(AAddInputs[I].DiskPath);
    Arc[I] := AnsiString(AAddInputs[I].ArcPath);
    Recs[I].DiskPath := PAnsiChar(Disk[I]);
    Recs[I].ArcPath := PAnsiChar(Arc[I]);
    Recs[I].IsDir := AAddInputs[I].IsDir;
  end;

  FillChar(Err, SizeOf(Err), 0);
  if AProgress <> nil then
  begin
    SinkPtr := MakeProgressSink(AProgress, Sink);
    if Length(Recs) > 0 then
      Result := tzip.api.bind._modify_ex(PAnsiChar(Path), PAnsiChar(Pw), @Opt,
        PRem, Length(ARemoveIndices), @Recs[0], Length(Recs),
        nil, nil, SinkPtr, @Err[0], SizeOf(Err))
    else
      Result := tzip.api.bind._modify_ex(PAnsiChar(Path), PAnsiChar(Pw), @Opt,
        PRem, Length(ARemoveIndices), nil, 0,
        nil, nil, SinkPtr, @Err[0], SizeOf(Err));
  end
  else if Length(Recs) > 0 then
    Result := tzip.api.bind._modify(PAnsiChar(Path), PAnsiChar(Pw), @Opt, PRem,
      Length(ARemoveIndices), @Recs[0], Length(Recs),
      @TzProgressTrampoline, nil, @Err[0], SizeOf(Err))
  else
    Result := tzip.api.bind._modify(PAnsiChar(Path), PAnsiChar(Pw), @Opt, PRem,
      Length(ARemoveIndices), nil, 0,
      @TzProgressTrampoline, nil, @Err[0], SizeOf(Err));
  AError := string(AnsiString(PAnsiChar(@Err[0])));
  if (Result <> TZ7Z_OK) and (AError = '') then AError := TzErrorText(Result);
end;

end.
