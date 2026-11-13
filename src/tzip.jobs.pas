unit tzip.jobs;
{ Background work for the UI.

  Every operation whose cost grows with the archive (opening/indexing, listing a
  huge folder, extracting, testing, creating or updating) runs on one of these
  workers.  The main thread keeps painting, polls with a timer, and only touches
  LCL when the job reports its result.

  Each kind carries its inputs in its own payload record; the flat accessors on
  TZJob are compatibility properties that dispatch to the payload of the kind
  the job was created with. Execute does not touch them: it dispatches to a
  TZJobExecutor, which reads the payload. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, tzip.api, tzip.engine, tzip.search, tzip.extract,
  tzip.i18n;

type
  TZJobKind = (jkOpen, jkList, jkExtract, jkTest, jkExtractOne, jkCreate, jkModify,
    jkRename, jkConvert, jkSearch);

  { What Completed/Total mean for the current job. Opening counts entries (the
    only quantity known before the index exists); everything else counts bytes. }
  TZJobProgressKind = (jpkBytes, jpkItems);

  TZJob = class;

  { The ABI-v4 detail the busy card shows beside the byte progress.  Name is a
    copy: the bridge's item_name is only valid during the callback. }
  TZJobProgressDetail = record
    Phase: LongWord;
    ItemIndex: LongWord;
    ItemCount: LongWord;
    ItemName: string;
    PackedKnown: Boolean;
    PackedDone: QWord;
    BytesDone: QWord;
    { GetTickCount64 when this phase began (convert has extract then create);
      the UI uses it for rate/ETA so the two phases are not mixed. }
    PhaseStartedAt: QWord;
  end;

  { What a open job carries. }
  TZJobOpenPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Parent: TArchiveContext;
    IsNested: Boolean;
    OpenedFromFs: string;
  end;

  { What a list job carries. }
  TZJobListPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Entries: TArchiveEntries;
    CtxRef: TArchiveContext;
    InnerPath: string;
    Filter: string;
    SortCol: TArchiveSortColumn;
    SortDesc: Boolean;
  end;

  { What a extract job carries. }
  TZJobExtractPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Dest: string;
    Indices: TLongWordArray;
    { Smart extraction: open through TzOpenContext so a compound archive
      extracts its inner tree instead of the bare inner stream. }
    Unwrap: Boolean;
    { Non-empty: extract into a staging folder, then commit the tree with this
      single top-level segment stripped (the smart "one root folder" layout). }
    StripRoot: string;
  end;

  { What a test job carries. }
  TZJobTestPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Indices: TLongWordArray;
  end;

  { What a extractone job carries. }
  TZJobExtractOnePayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    EntryIndex: Integer;
    OutFile: string;
  end;

  { What a create job carries. }
  TZJobCreatePayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    ArcPrefix: string;
    Sources: TStringList;
    Settings: TCreateSettings;
  end;

  { What a modify job carries. }
  TZJobModifyPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    ArcPrefix: string;
    Sources: TStringList;
    RemoveIndices: TLongWordArray;
    NewComment: string;
    SetComment: Boolean;
    Settings: TCreateSettings;
  end;

  { What a rename job carries. }
  TZJobRenamePayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    RenameIndex: Integer;
    RenameFrom: string;
    RenameTo: string;
    NewComment: string;
    SetComment: Boolean;
    Settings: TCreateSettings;
  end;

  { What a convert job carries. }
  TZJobConvertPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Dest: string;
    Settings: TCreateSettings;
  end;

  { A search over the whole archive. Options carries the query and how to
    compare it; the job opens the archive itself, so it never shares the UI's
    handle. }
  TZJobSearchPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Options: TSearchOptions;
  end;

  { Values a caller writes on a kind that does not own that input. Kept so the
    old "set any field on any job" behaviour survives the payload split; the
    executor never reads this record. }
  TZJobScratchPayload = record
    Path: string;
    DisplayName: string;
    Password: string;
    Parent: TArchiveContext;
    CtxRef: TArchiveContext;
    IsNested: Boolean;
    OpenedFromFs: string;
    InnerPath: string;
    Filter: string;
    SortCol: TArchiveSortColumn;
    SortDesc: Boolean;
    OutFile: string;
    EntryIndex: Integer;
    Dest: string;
    Sources: TStringList;
    ArcPrefix: string;
    Indices: TLongWordArray;
    RemoveIndices: TLongWordArray;
    NewComment: string;
    SetComment: Boolean;
    RenameIndex: Integer;
    RenameFrom: string;
    RenameTo: string;
    Settings: TCreateSettings;
    Options: TSearchOptions;
  end;

  { Routes the bridge progress callback to the owning job. }
  TZJobSink = class(TZ7ZProgressSink)
  private
    FJob: TZJob;
  public
    constructor Create(AJob: TZJob);
    function Tick(Completed, Total: QWord): Boolean; override;
    function Progress(const AInfo: TZ7ZProgressInfo): Boolean; override;
  end;

  { What one job kind does with the engine. The default (GDefaultExecutor, see
    the implementation) is the real tzip.api/engine pair; a test injects a fake
    to assert what TZJob asks for. Execute only dispatches: the payload record
    carries the inputs, the executor reads them. }
  TZJobExecutor = class
  public
    function OpenJob(AJob: TZJob; out AError: string): Integer; virtual;
    function ListJob(AJob: TZJob; out AError: string): Integer; virtual;
    function ExtractJob(AJob: TZJob; out AError: string): Integer; virtual;
    function TestJob(AJob: TZJob; out AError: string): Integer; virtual;
    function ExtractOneJob(AJob: TZJob; out AError: string): Integer; virtual;
    function CreateJob(AJob: TZJob; out AError: string): Integer; virtual;
    function ConvertJob(AJob: TZJob; out AError: string): Integer; virtual;
    function RenameJob(AJob: TZJob; out AError: string): Integer; virtual;
    function ModifyJob(AJob: TZJob; out AError: string): Integer; virtual;
    function SearchJob(AJob: TZJob; out AError: string): Integer; virtual;
  end;

  TZJob = class(TThread)
  private
    FExecutor: TZJobExecutor;
    FLock: TCriticalSection;
    FSink: TZJobSink;
    FDoneBytes, FTotalBytes: QWord;
    FProgressKind: TZJobProgressKind;
    FItemDetail: TZJobProgressDetail;
    FStartedAt: QWord;
    FPaused: Boolean;
    FPauseEvent: TEvent;
    FDetail: string;
    FCancelRequested: Boolean;
    FFinished: Boolean;
    FResult: Integer;
    FError: string;
    FKind: TZJobKind;
    { ZIP name code page for every archive this job opens. 0 = "not chosen by a
      context"; StartJobNow then fills the application default. }
    FNameCodepage: LongWord;
    FScratch: TZJobScratchPayload;
    FOpen: TZJobOpenPayload;
    FList: TZJobListPayload;
    FExtract: TZJobExtractPayload;
    FTest: TZJobTestPayload;
    FExtractOne: TZJobExtractOnePayload;
    FCreate: TZJobCreatePayload;
    FModify: TZJobModifyPayload;
    FRename: TZJobRenamePayload;
    FConvert: TZJobConvertPayload;
    FSearch: TZJobSearchPayload;
    function GetPath: string;
    procedure SetPath(const AValue: string);
    function GetDisplayName: string;
    procedure SetDisplayName(const AValue: string);
    function GetPassword: string;
    procedure SetPassword(const AValue: string);
    function GetParent: TArchiveContext;
    procedure SetParent(const AValue: TArchiveContext);
    function GetCtxRef: TArchiveContext;
    procedure SetCtxRef(const AValue: TArchiveContext);
    function GetIsNested: Boolean;
    procedure SetIsNested(const AValue: Boolean);
    function GetOpenedFromFs: string;
    procedure SetOpenedFromFs(const AValue: string);
    function GetInnerPath: string;
    procedure SetInnerPath(const AValue: string);
    function GetFilter: string;
    procedure SetFilter(const AValue: string);
    function GetSortCol: TArchiveSortColumn;
    procedure SetSortCol(const AValue: TArchiveSortColumn);
    function GetSortDesc: Boolean;
    procedure SetSortDesc(const AValue: Boolean);
    function GetOutFile: string;
    procedure SetOutFile(const AValue: string);
    function GetEntryIndex: Integer;
    procedure SetEntryIndex(const AValue: Integer);
    function GetDest: string;
    procedure SetDest(const AValue: string);
    function GetSources: TStringList;
    procedure SetSources(const AValue: TStringList);
    function GetArcPrefix: string;
    procedure SetArcPrefix(const AValue: string);
    function GetIndices: TLongWordArray;
    procedure SetIndices(const AValue: TLongWordArray);
    function GetUnwrap: Boolean;
    procedure SetUnwrap(const AValue: Boolean);
    function GetStripRoot: string;
    procedure SetStripRoot(const AValue: string);
    function GetRemoveIndices: TLongWordArray;
    procedure SetRemoveIndices(const AValue: TLongWordArray);
    function GetNewComment: string;
    procedure SetNewComment(const AValue: string);
    function GetSetComment: Boolean;
    procedure SetSetComment(const AValue: Boolean);
    function GetRenameIndex: Integer;
    procedure SetRenameIndex(const AValue: Integer);
    function GetRenameFrom: string;
    procedure SetRenameFrom(const AValue: string);
    function GetRenameTo: string;
    procedure SetRenameTo(const AValue: string);
    function GetSettings: TCreateSettings;
    procedure SetSettings(const AValue: TCreateSettings);
    procedure ClearPayloads;
    procedure SetProgress(ADone, ATotal: QWord; const ADetail: string);
    function GetExecutor: TZJobExecutor;
    function GetOptions: TSearchOptions;
    procedure SetOptions(const AValue: TSearchOptions);
  protected
    procedure Execute; override;
  public
    { --- results; valid once TakeResult returned True --- }
    Ctx: TArchiveContext;
    Listing: TListing;

    { The kind this job was created with. Changing it discards the payload so
      nothing from the old kind can be read as the new one. }
    procedure SetKindValue(AValue: TZJobKind);
    property Kind: TZJobKind read FKind write SetKindValue;
    property Path: string read GetPath write SetPath;
    property DisplayName: string read GetDisplayName write SetDisplayName;
    property Password: string read GetPassword write SetPassword;
    property Parent: TArchiveContext read GetParent write SetParent;
    property CtxRef: TArchiveContext read GetCtxRef write SetCtxRef;
    property IsNested: Boolean read GetIsNested write SetIsNested;
    property OpenedFromFs: string read GetOpenedFromFs write SetOpenedFromFs;
    property InnerPath: string read GetInnerPath write SetInnerPath;
    property Filter: string read GetFilter write SetFilter;
    property SortCol: TArchiveSortColumn read GetSortCol write SetSortCol;
    property SortDesc: Boolean read GetSortDesc write SetSortDesc;
    property OutFile: string read GetOutFile write SetOutFile;
    property EntryIndex: Integer read GetEntryIndex write SetEntryIndex;
    property Sources: TStringList read GetSources write SetSources;
    property Dest: string read GetDest write SetDest;
    property ArcPrefix: string read GetArcPrefix write SetArcPrefix;
    property Indices: TLongWordArray read GetIndices write SetIndices;
    { Smart extraction switches: valid on jkExtract only. }
    property Unwrap: Boolean read GetUnwrap write SetUnwrap;
    property StripRoot: string read GetStripRoot write SetStripRoot;
    property RemoveIndices: TLongWordArray read GetRemoveIndices write SetRemoveIndices;
    property NewComment: string read GetNewComment write SetNewComment;
    property SetComment: Boolean read GetSetComment write SetSetComment;
    property RenameIndex: Integer read GetRenameIndex write SetRenameIndex;
    property RenameFrom: string read GetRenameFrom write SetRenameFrom;
    property RenameTo: string read GetRenameTo write SetRenameTo;
    property Settings: TCreateSettings read GetSettings write SetSettings;
    property Options: TSearchOptions read GetOptions write SetOptions;
    { ZIP name code page used for every archive this job opens. }
    property NameCodepage: LongWord read FNameCodepage write FNameCodepage;

    constructor Create(AKind: TZJobKind);
    destructor Destroy; override;

    { Inject a different engine side (tests, or a later split of the payloads).
      nil means the real engine; the job does not own the object. }
    property Executor: TZJobExecutor read GetExecutor write FExecutor;

    { Hand the worker an immutable snapshot of the archive index for jkList. }
    procedure SetEntries(const AEntries: TArchiveEntries);

    { Copy the inputs into a fresh thread.  A TThread cannot run twice, so a
      retry after a wrong password needs a new object. }
    function Clone: TZJob;

    function TakeResult(out AResult: Integer; out AError: string): Boolean;
    { True while the user has asked to cancel; the smart extract commit asks this
      between files, because the engine sink is no longer involved there. }
    function CancelledNow: Boolean;
    function GetStartedAt: QWord;
    function Snapshot(out ADone, ATotal: QWord; out ADetail: string): Boolean;
    { Latest per-item/ratio detail; valid while the job runs. }
    function SnapshotDetail(out ADetail: TZJobProgressDetail): Boolean;
    property ProgressKind: TZJobProgressKind read FProgressKind write FProgressKind;
    { GetTickCount64 when Execute began; 0 until the thread runs. }
    property StartedAt: QWord read GetStartedAt;
    procedure RequestCancel;
    property CancelRequested: Boolean read FCancelRequested;
    { Pause blocks the engine inside the progress sink (the same technique
      7-Zip's GUI uses); it takes effect at callback boundaries.  Cancel wins
      over pause and wakes the wait. }
    procedure Pause;
    procedure Resume;
    property Paused: Boolean read FPaused;
    function WaitWhilePaused: Boolean;
  end;

implementation

{ ---------------------------------------------------------------------------
  TZJobSink
  --------------------------------------------------------------------------- }

constructor TZJobSink.Create(AJob: TZJob);
begin
  inherited Create;
  FJob := AJob;
end;

function TZJobSink.Tick(Completed, Total: QWord): Boolean;
begin
  if not FJob.WaitWhilePaused then
    Exit(False);
  FJob.SetProgress(Completed, Total, '');
  Result := not FJob.CancelRequested;
end;

function TZJobSink.Progress(const AInfo: TZ7ZProgressInfo): Boolean;
begin
  if not FJob.WaitWhilePaused then
    Exit(False);
  { Runs on the worker thread.  Copy the strings and numbers; never touch the
    UI here.  Phase and item count also arrive on TICK events (open progress). }
  FJob.FLock.Enter;
  try
    if FJob.FItemDetail.Phase <> AInfo.Phase then
      FJob.FItemDetail.PhaseStartedAt := GetTickCount64;
    FJob.FItemDetail.Phase := AInfo.Phase;
    if AInfo.ItemCount > 0 then
      FJob.FItemDetail.ItemCount := AInfo.ItemCount;
    if AInfo.Event in [tzip.api.TZ7Z_EV_ITEM,
      tzip.api.TZ7Z_EV_ITEM_DONE] then
    begin
      FJob.FItemDetail.ItemIndex := AInfo.ItemIndex;
      if AInfo.Name <> '' then
        FJob.FItemDetail.ItemName := AInfo.Name;
    end;
    FJob.FItemDetail.BytesDone := AInfo.BytesDone;
    if AInfo.PackedKnown then
    begin
      FJob.FItemDetail.PackedKnown := True;
      FJob.FItemDetail.PackedDone := AInfo.PackedDone;
    end;
  finally
    FJob.FLock.Leave;
  end;
  if AInfo.Event = tzip.api.TZ7Z_EV_TICK then
    Result := Tick(AInfo.BytesDone, AInfo.BytesTotal)
  else
    Result := not FJob.CancelRequested;
end;

{ ---------------------------------------------------------------------------
  TZJobExecutor
  --------------------------------------------------------------------------- }

var
  GDefaultExecutor: TZJobExecutor = nil;

function DefaultExecutor: TZJobExecutor;
begin
  if GDefaultExecutor = nil then GDefaultExecutor := TZJobExecutor.Create;
  Result := GDefaultExecutor;
end;

function TZJobExecutor.OpenJob(AJob: TZJob; out AError: string): Integer;
begin
  AJob.SetProgress(0, 0, '');
  Result := TzOpenContext(AJob.FOpen.Path, AJob.FOpen.DisplayName,
    AJob.FOpen.Password, AJob.FOpen.Parent, AJob.FOpen.IsNested,
    AJob.FOpen.OpenedFromFs, AJob.Ctx, AError, AJob.FSink, AJob.NameCodepage);
  { Whether switching the name encoding could change anything. Answered here, on
    the worker, so a large archive is never scanned on the UI thread when the
    View menu refreshes. }
  if (Result = TZ7Z_OK) and (AJob.Ctx <> nil) then
    AJob.Ctx.NameCodepageUsed := TzArchiveNameCodepageUsed(AJob.Ctx.Archive);
end;

function TZJobExecutor.ListJob(AJob: TZJob; out AError: string): Integer;
begin
  AError := '';
  { Two ways to list: a snapshot the UI handed over (jkList after an open), and
    a path only (a big archive listed without touching the UI's context). }
  if (AJob.FList.CtxRef = nil) and (AJob.FList.Path <> '') then
  begin
    Result := TzListArchiveByPath(AJob.FList.Path, AJob.FList.Password,
      AJob.Listing, AJob.FSink, AJob.NameCodepage);
    Exit;
  end;
  AJob.Listing := TzListEntries(AJob.FList.Entries, AJob.FList.InnerPath,
    AJob.FList.Filter, AJob.FList.SortCol, AJob.FList.SortDesc);
  Result := TZ7Z_OK;
end;

{ Best-effort recursive delete of a staging folder this job created. Files are
  removed first; a directory that refuses to go simply stays behind. }
procedure DeleteJobTree(const APath: string);
var
  SR: TSearchRec;
  Item: string;
begin
  if APath = '' then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Item := IncludeTrailingPathDelimiter(APath) + SR.Name;
      { A symlink to a directory is a file to delete, not a tree to walk. }
      if ((SR.Attr and faDirectory) <> 0) and (not TzPathIsSymlink(Item)) then
        DeleteJobTree(Item)
      else
        DeleteFile(Item);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(APath);
end;

function TZJobExecutor.ExtractJob(AJob: TZJob; out AError: string): Integer;
var
  A: TTzArchive;
  Staging: string;
begin
  AError := '';
  if AJob.FExtract.Unwrap then
  begin
    { Smart extraction opens through the archive context, so a compound archive
      extracts the tree its inner archive holds instead of a bare inner stream. }
    if AJob.FExtract.StripRoot = '' then
      Exit(TzExtractInContext(AJob.FExtract.Path, AJob.FExtract.Password,
        AJob.FExtract.Indices, AJob.FExtract.Dest, AError, AJob.FSink,
        AJob.NameCodepage));

    { Flatten: extract into a staging folder inside the destination (same volume,
      so the commit is a rename), then move the contents up. Both steps are here
      on the worker; the window only sees the result. }
    Staging := IncludeTrailingPathDelimiter(AJob.FExtract.Dest) +
      '.tyzip-smart-' + IntToHex(GetTickCount64, 12) + '-' +
      IntToHex(Random(MaxInt), 8) + PathDelim;
    try
      ForceDirectories(Staging);
      Result := TzExtractInContext(AJob.FExtract.Path, AJob.FExtract.Password,
        AJob.FExtract.Indices, Staging, AError, AJob.FSink, AJob.NameCodepage);
      if Result = TZ7Z_OK then
        if not TzCommitStagedTree(Staging, AJob.FExtract.Dest,
          AJob.FExtract.StripRoot, True, @AJob.CancelledNow) then
        begin
          if AJob.CancelledNow then
            Result := TZ7Z_E_CANCEL
          else
          begin
            Result := TZ7Z_E_EXTRACT;
            AError := rsErrSmartExtractPlace;
          end;
        end;
    finally
      { The staging folder is ours: it goes away on success, failure and cancel
        alike. }
      DeleteJobTree(Staging);
    end;
    Exit;
  end;

  A := nil;
  Result := TzOpenArchive(AJob.FExtract.Path, AJob.FExtract.Password, A, AError,
    nil, AJob.NameCodepage);
  try
    if Result = TZ7Z_OK then
      Result := TzExtract(A, AJob.FExtract.Indices, AJob.FExtract.Dest,
        AJob.FExtract.Password, AError, AJob.FSink);
  finally
    A.Free;
  end;
end;

function TZJobExecutor.TestJob(AJob: TZJob; out AError: string): Integer;
var
  A: TTzArchive;
begin
  A := nil;
  AError := '';
  Result := TzOpenArchive(AJob.FTest.Path, AJob.FTest.Password, A, AError,
    nil, AJob.NameCodepage);
  try
    if Result = TZ7Z_OK then
      Result := TzTest(A, AJob.FTest.Indices, AJob.FTest.Password, AError,
        AJob.FSink);
  finally
    A.Free;
  end;
end;

function TZJobExecutor.ExtractOneJob(AJob: TZJob; out AError: string): Integer;
var
  A: TTzArchive;
begin
  A := nil;
  AError := '';
  Result := TzOpenArchive(AJob.FExtractOne.Path, AJob.FExtractOne.Password, A, AError,
    nil, AJob.NameCodepage);
  try
    if Result = TZ7Z_OK then
      Result := TzExtractOne(A, AJob.FExtractOne.EntryIndex,
        AJob.FExtractOne.OutFile, AJob.FExtractOne.Password, AError, AJob.FSink);
  finally
    A.Free;
  end;
end;

function TZJobExecutor.CreateJob(AJob: TZJob; out AError: string): Integer;
var
  Set1: TZInputSet;
begin
  AError := '';
  Set1 := TzCollectInputs(AJob.FCreate.Sources, AJob.FCreate.ArcPrefix);
  try
    if Length(Set1.Recs) = 0 then
      Result := TZ7Z_E_ARG
    else
      Result := TzCreateArchive(AJob.FCreate.Path, AJob.FCreate.Settings,
        Set1.Recs, AError, AJob.FSink);
  finally
    TzInputSetFree(Set1);
  end;
end;

function TZJobExecutor.ConvertJob(AJob: TZJob; out AError: string): Integer;
begin
  AError := '';
  Result := TzConvertArchive(AJob.FConvert.Path, AJob.FConvert.Dest,
    AJob.FConvert.Settings, AError, AJob.FSink, AJob.NameCodepage);
end;

function TZJobExecutor.RenameJob(AJob: TZJob; out AError: string): Integer;
var
  A: TTzArchive;
  Set2: TZInputSet;
  Tmp: string;
  TmpList, ArcList: TStringList;
  Rem: TLongWordArray;
begin
  A := nil;
  AError := '';
  Tmp := '';
  { 7-Zip has no rename: extract the entry to a temporary file, add it back under
    the new path, then remove the old entry. One rewrite, two engine calls, so a
    failure midway leaves the archive as it was. }
  Tmp := GetTempDir(False) + 'tyzip-rename-' + IntToStr(GetProcessID) + '-' +
    IntToStr(GetTickCount64);
  try
    Result := TzOpenArchive(AJob.FRename.Path, AJob.FRename.Password, A, AError,
      nil, AJob.NameCodepage);
    if Result = TZ7Z_OK then
    begin
      { The index comes from the caller (and from a Clone on retry); never hand a
        negative or out-of-range value to the engine, where the LongWord cast
        would turn -1 into "the last entry". }
      if (AJob.FRename.RenameIndex < 0) or (AJob.FRename.RenameIndex >= A.Count) then
      begin
        Result := TZ7Z_E_ARG;
        AError := 'no entry to rename';
      end
      else
      begin
        Result := TzExtractOne(A, LongWord(AJob.FRename.RenameIndex), Tmp,
          AJob.FRename.Password, AError, AJob.FSink);
        if Result = TZ7Z_OK then
        begin
          TmpList := TStringList.Create;
          ArcList := TStringList.Create;
          try
            TmpList.Add(Tmp);
            ArcList.Add(AJob.FRename.RenameTo);
            Set2 := TzCollectInputsMapped(TmpList, ArcList);
            try
              Rem := TLongWordArray([LongWord(AJob.FRename.RenameIndex)]);
              Result := TzModify(AJob.FRename.Path, AJob.FRename.Password,
                AJob.FRename.Settings, Rem, Set2.Recs, AError, AJob.FSink,
                AJob.FRename.NewComment, AJob.FRename.SetComment);
            finally
              TzInputSetFree(Set2);
            end;
          finally
            ArcList.Free;
            TmpList.Free;
          end;
        end;
      end;
    end;
  finally
    A.Free;
    if (Tmp <> '') and FileExists(Tmp) then DeleteFile(Tmp);
  end;
end;

function TZJobExecutor.ModifyJob(AJob: TZJob; out AError: string): Integer;
var
  Set1: TZInputSet;
begin
  AError := '';
  Set1 := TzCollectInputs(AJob.FModify.Sources, AJob.FModify.ArcPrefix);
  try
    Result := TzModify(AJob.FModify.Path, AJob.FModify.Password,
      AJob.FModify.Settings, AJob.FModify.RemoveIndices, Set1.Recs, AError,
      AJob.FSink, AJob.FModify.NewComment, AJob.FModify.SetComment);
  finally
    TzInputSetFree(Set1);
  end;
end;

function TZJobExecutor.SearchJob(AJob: TZJob; out AError: string): Integer;
begin
  { The engine fills AJob.Listing directly; on cancel it delivers nothing and
    reports that through the result code, so a half-walked list never reaches
    the UI. }
  AError := '';
  Result := TzSearchArchive(AJob.FSearch.Path, AJob.FSearch.Password,
    AJob.FSearch.Options, AJob.Listing, AJob.FSink, AJob.NameCodepage);
end;

{ ---------------------------------------------------------------------------
  TZJob
  --------------------------------------------------------------------------- }


procedure TZJob.ClearPayloads;
begin
  FCreate.Sources.Free;
  FCreate.Sources := nil;
  FModify.Sources.Free;
  FModify.Sources := nil;
  FScratch.Sources.Free;
  FScratch.Sources := nil;
  FOpen := Default(TZJobOpenPayload);
  FList := Default(TZJobListPayload);
  FExtract := Default(TZJobExtractPayload);
  FTest := Default(TZJobTestPayload);
  FExtractOne := Default(TZJobExtractOnePayload);
  FCreate := Default(TZJobCreatePayload);
  FModify := Default(TZJobModifyPayload);
  FRename := Default(TZJobRenamePayload);
  FConvert := Default(TZJobConvertPayload);
  FSearch := Default(TZJobSearchPayload);
  FScratch := Default(TZJobScratchPayload);
  FScratch.EntryIndex := -1;
  FScratch.RenameIndex := -1;
end;

constructor TZJob.Create(AKind: TZJobKind);
begin
  { Start suspended: the caller still has to fill in the inputs. }
  inherited Create(True);
  FreeOnTerminate := False;
  FKind := AKind;
  { Opening counts entries, everything else counts bytes. Set before the thread
    starts so the UI never reads a value a worker is writing. }
  if AKind = jkOpen then FProgressKind := jpkItems;
  FLock := TCriticalSection.Create;
  FSink := TZJobSink.Create(Self);
  FPauseEvent := TEvent.Create(nil, False, False, '');
  { -1 means "no entry selected", for both the single-entry and rename kinds. }
  FExtractOne.EntryIndex := -1;
  FRename.RenameIndex := -1;
  FScratch.EntryIndex := -1;
  FScratch.RenameIndex := -1;
end;

destructor TZJob.Destroy;
begin
  FPauseEvent.Free;
  FSink.Free;
  FLock.Free;
  { Ctx is handed to the form on success; only an unclaimed context is freed
    here (a cancelled open cannot leave it behind). }
  Ctx.Free;
  ClearPayloads;
  inherited Destroy;
end;

function TZJob.GetSources: TStringList;
begin
  case FKind of
    jkCreate: Result := FCreate.Sources;
    jkModify: Result := FModify.Sources;
  else
    Result := FScratch.Sources;
  end;
end;

procedure TZJob.SetSources(const AValue: TStringList);
begin
  case FKind of
    jkCreate:
      begin
        if FCreate.Sources <> AValue then FCreate.Sources.Free;
        FCreate.Sources := AValue;
      end;
    jkModify:
      begin
        if FModify.Sources <> AValue then FModify.Sources.Free;
        FModify.Sources := AValue;
      end;
  else
    begin
      if FScratch.Sources <> AValue then FScratch.Sources.Free;
      FScratch.Sources := AValue;
    end;
  end;
end;

procedure TZJob.SetKindValue(AValue: TZJobKind);
begin
  if FKind = AValue then Exit;
  { Nothing from the old kind may be read as the new one: a rename index or a
    temporary source list left behind would be applied to the wrong payload. }
  ClearPayloads;
  FKind := AValue;
  FExtractOne.EntryIndex := -1;
  FRename.RenameIndex := -1;
end;

procedure TZJob.SetEntries(const AEntries: TArchiveEntries);
begin
  FList.Entries := TzCopyEntries(AEntries);
end;

procedure TZJob.SetProgress(ADone, ATotal: QWord; const ADetail: string);
begin
  FLock.Enter;
  try
    FDoneBytes := ADone;
    FTotalBytes := ATotal;
    if ADetail <> '' then FDetail := ADetail;
  finally
    FLock.Leave;
  end;
end;

function TZJob.GetStartedAt: QWord;
begin
  FLock.Enter;
  try
    Result := FStartedAt;
  finally
    FLock.Leave;
  end;
end;

function TZJob.Snapshot(out ADone, ATotal: QWord; out ADetail: string): Boolean;
begin
  FLock.Enter;
  try
    Result := not FFinished;
    ADone := FDoneBytes;
    ATotal := FTotalBytes;
    ADetail := FDetail;
  finally
    FLock.Leave;
  end;
end;

function TZJob.SnapshotDetail(out ADetail: TZJobProgressDetail): Boolean;
begin
  ADetail := Default(TZJobProgressDetail);
  FLock.Enter;
  try
    Result := not FFinished;
    ADetail := FItemDetail;
  finally
    FLock.Leave;
  end;
end;

procedure TZJob.RequestCancel;
begin
  FCancelRequested := True;
  { A paused job is parked in FPauseEvent.WaitFor; wake it so it can observe
    the cancel instead of waiting for a resume that will never come. }
  FPauseEvent.SetEvent;
end;

procedure TZJob.Pause;
begin
  FLock.Enter;
  try
    FPaused := True;
  finally
    FLock.Leave;
  end;
end;

procedure TZJob.Resume;
begin
  FLock.Enter;
  try
    FPaused := False;
  finally
    FLock.Leave;
  end;
  FPauseEvent.SetEvent;
end;

function TZJob.WaitWhilePaused: Boolean;
var
  IsPaused: Boolean;
begin
  Result := True;
  repeat
    if FCancelRequested then
      Exit(False);
    FLock.Enter;
    try
      IsPaused := FPaused;
    finally
      FLock.Leave;
    end;
    if not IsPaused then
      Exit(True);
    { A timeout keeps the loop simple and lets a cancel be observed even if a
      resume event was consumed by another waiter. }
    FPauseEvent.WaitFor(100);
  until False;
end;

function TZJob.GetPath: string;
begin
  case FKind of
    jkOpen: Result := FOpen.Path;
    jkList: Result := FList.Path;
    jkExtract: Result := FExtract.Path;
    jkTest: Result := FTest.Path;
    jkExtractOne: Result := FExtractOne.Path;
    jkCreate: Result := FCreate.Path;
    jkModify: Result := FModify.Path;
    jkRename: Result := FRename.Path;
    jkConvert: Result := FConvert.Path;
    jkSearch: Result := FSearch.Path
  else
    Result := FScratch.Path;
  end;
end;

procedure TZJob.SetPath(const AValue: string);
begin
  case FKind of
    jkOpen: FOpen.Path := AValue;
    jkList: FList.Path := AValue;
    jkExtract: FExtract.Path := AValue;
    jkTest: FTest.Path := AValue;
    jkExtractOne: FExtractOne.Path := AValue;
    jkCreate: FCreate.Path := AValue;
    jkModify: FModify.Path := AValue;
    jkRename: FRename.Path := AValue;
    jkConvert: FConvert.Path := AValue;
    jkSearch: FSearch.Path := AValue;
  else
    FScratch.Path := AValue;
  end;
end;

function TZJob.GetDisplayName: string;
begin
  case FKind of
    jkOpen: Result := FOpen.DisplayName;
    jkList: Result := FList.DisplayName;
    jkExtract: Result := FExtract.DisplayName;
    jkTest: Result := FTest.DisplayName;
    jkExtractOne: Result := FExtractOne.DisplayName;
    jkCreate: Result := FCreate.DisplayName;
    jkModify: Result := FModify.DisplayName;
    jkRename: Result := FRename.DisplayName;
    jkConvert: Result := FConvert.DisplayName;
    jkSearch: Result := FSearch.DisplayName
  else
    Result := FScratch.DisplayName;
  end;
end;

procedure TZJob.SetDisplayName(const AValue: string);
begin
  case FKind of
    jkOpen: FOpen.DisplayName := AValue;
    jkList: FList.DisplayName := AValue;
    jkExtract: FExtract.DisplayName := AValue;
    jkTest: FTest.DisplayName := AValue;
    jkExtractOne: FExtractOne.DisplayName := AValue;
    jkCreate: FCreate.DisplayName := AValue;
    jkModify: FModify.DisplayName := AValue;
    jkRename: FRename.DisplayName := AValue;
    jkConvert: FConvert.DisplayName := AValue;
    jkSearch: FSearch.DisplayName := AValue;
  else
    FScratch.DisplayName := AValue;
  end;
end;

function TZJob.GetPassword: string;
begin
  case FKind of
    jkOpen: Result := FOpen.Password;
    jkList: Result := FList.Password;
    jkExtract: Result := FExtract.Password;
    jkTest: Result := FTest.Password;
    jkExtractOne: Result := FExtractOne.Password;
    jkCreate: Result := FCreate.Password;
    jkModify: Result := FModify.Password;
    jkRename: Result := FRename.Password;
    jkConvert: Result := FConvert.Password;
    jkSearch: Result := FSearch.Password
  else
    Result := FScratch.Password;
  end;
end;

procedure TZJob.SetPassword(const AValue: string);
begin
  case FKind of
    jkOpen: FOpen.Password := AValue;
    jkList: FList.Password := AValue;
    jkExtract: FExtract.Password := AValue;
    jkTest: FTest.Password := AValue;
    jkExtractOne: FExtractOne.Password := AValue;
    jkCreate: FCreate.Password := AValue;
    jkModify: FModify.Password := AValue;
    jkRename: FRename.Password := AValue;
    jkConvert: FConvert.Password := AValue;
    jkSearch: FSearch.Password := AValue;
  else
    FScratch.Password := AValue;
  end;
end;

function TZJob.GetParent: TArchiveContext;
begin
  case FKind of
    jkOpen: Result := FOpen.Parent;
  else
    Result := FScratch.Parent;
  end;
end;

procedure TZJob.SetParent(const AValue: TArchiveContext);
begin
  case FKind of
    jkOpen: FOpen.Parent := AValue;
  else
    FScratch.Parent := AValue;
  end;
end;

function TZJob.GetCtxRef: TArchiveContext;
begin
  case FKind of
    jkList: Result := FList.CtxRef;
  else
    Result := FScratch.CtxRef;
  end;
end;

procedure TZJob.SetCtxRef(const AValue: TArchiveContext);
begin
  case FKind of
    jkList: FList.CtxRef := AValue;
  else
    FScratch.CtxRef := AValue;
  end;
end;

function TZJob.GetIsNested: Boolean;
begin
  case FKind of
    jkOpen: Result := FOpen.IsNested;
  else
    Result := FScratch.IsNested;
  end;
end;

procedure TZJob.SetIsNested(const AValue: Boolean);
begin
  case FKind of
    jkOpen: FOpen.IsNested := AValue;
  else
    FScratch.IsNested := AValue;
  end;
end;

function TZJob.GetOpenedFromFs: string;
begin
  case FKind of
    jkOpen: Result := FOpen.OpenedFromFs;
  else
    Result := FScratch.OpenedFromFs;
  end;
end;

procedure TZJob.SetOpenedFromFs(const AValue: string);
begin
  case FKind of
    jkOpen: FOpen.OpenedFromFs := AValue;
  else
    FScratch.OpenedFromFs := AValue;
  end;
end;

function TZJob.GetInnerPath: string;
begin
  case FKind of
    jkList: Result := FList.InnerPath;
  else
    Result := FScratch.InnerPath;
  end;
end;

procedure TZJob.SetInnerPath(const AValue: string);
begin
  case FKind of
    jkList: FList.InnerPath := AValue;
  else
    FScratch.InnerPath := AValue;
  end;
end;

function TZJob.GetFilter: string;
begin
  case FKind of
    jkList: Result := FList.Filter;
  else
    Result := FScratch.Filter;
  end;
end;

procedure TZJob.SetFilter(const AValue: string);
begin
  case FKind of
    jkList: FList.Filter := AValue;
  else
    FScratch.Filter := AValue;
  end;
end;

function TZJob.GetSortCol: TArchiveSortColumn;
begin
  case FKind of
    jkList: Result := FList.SortCol;
  else
    Result := FScratch.SortCol;
  end;
end;

procedure TZJob.SetSortCol(const AValue: TArchiveSortColumn);
begin
  case FKind of
    jkList: FList.SortCol := AValue;
  else
    FScratch.SortCol := AValue;
  end;
end;

function TZJob.GetSortDesc: Boolean;
begin
  case FKind of
    jkList: Result := FList.SortDesc;
  else
    Result := FScratch.SortDesc;
  end;
end;

procedure TZJob.SetSortDesc(const AValue: Boolean);
begin
  case FKind of
    jkList: FList.SortDesc := AValue;
  else
    FScratch.SortDesc := AValue;
  end;
end;

function TZJob.GetOutFile: string;
begin
  case FKind of
    jkExtractOne: Result := FExtractOne.OutFile;
  else
    Result := FScratch.OutFile;
  end;
end;

procedure TZJob.SetOutFile(const AValue: string);
begin
  case FKind of
    jkExtractOne: FExtractOne.OutFile := AValue;
  else
    FScratch.OutFile := AValue;
  end;
end;

function TZJob.GetEntryIndex: Integer;
begin
  case FKind of
    jkExtractOne: Result := FExtractOne.EntryIndex;
  else
    Result := FScratch.EntryIndex;
  end;
end;

procedure TZJob.SetEntryIndex(const AValue: Integer);
begin
  case FKind of
    jkExtractOne: FExtractOne.EntryIndex := AValue;
  else
    FScratch.EntryIndex := AValue;
  end;
end;

function TZJob.GetDest: string;
begin
  case FKind of
    jkExtract: Result := FExtract.Dest;
    jkConvert: Result := FConvert.Dest;
  else
    Result := FScratch.Dest;
  end;
end;

procedure TZJob.SetDest(const AValue: string);
begin
  case FKind of
    jkExtract: FExtract.Dest := AValue;
    jkConvert: FConvert.Dest := AValue;
  else
    FScratch.Dest := AValue;
  end;
end;



function TZJob.GetArcPrefix: string;
begin
  case FKind of
    jkCreate: Result := FCreate.ArcPrefix;
    jkModify: Result := FModify.ArcPrefix;
  else
    Result := FScratch.ArcPrefix;
  end;
end;

procedure TZJob.SetArcPrefix(const AValue: string);
begin
  case FKind of
    jkCreate: FCreate.ArcPrefix := AValue;
    jkModify: FModify.ArcPrefix := AValue;
  else
    FScratch.ArcPrefix := AValue;
  end;
end;

function TZJob.GetIndices: TLongWordArray;
begin
  case FKind of
    jkExtract: Result := FExtract.Indices;
    jkTest: Result := FTest.Indices;
  else
    Result := FScratch.Indices;
  end;
end;

procedure TZJob.SetIndices(const AValue: TLongWordArray);
begin
  case FKind of
    jkExtract: FExtract.Indices := AValue;
    jkTest: FTest.Indices := AValue;
  else
    FScratch.Indices := AValue;
  end;
end;

function TZJob.GetUnwrap: Boolean;
begin
  case FKind of
    jkExtract: Result := FExtract.Unwrap;
  else
    Result := False;
  end;
end;

procedure TZJob.SetUnwrap(const AValue: Boolean);
begin
  case FKind of
    jkExtract: FExtract.Unwrap := AValue;
  else
    begin end;
  end;
end;

function TZJob.GetStripRoot: string;
begin
  case FKind of
    jkExtract: Result := FExtract.StripRoot;
  else
    Result := '';
  end;
end;

procedure TZJob.SetStripRoot(const AValue: string);
begin
  case FKind of
    jkExtract: FExtract.StripRoot := AValue;
  else
    begin end;
  end;
end;

function TZJob.GetRemoveIndices: TLongWordArray;
begin
  case FKind of
    jkModify: Result := FModify.RemoveIndices;
  else
    Result := FScratch.RemoveIndices;
  end;
end;

procedure TZJob.SetRemoveIndices(const AValue: TLongWordArray);
begin
  case FKind of
    jkModify: FModify.RemoveIndices := AValue;
  else
    FScratch.RemoveIndices := AValue;
  end;
end;

function TZJob.GetNewComment: string;
begin
  case FKind of
    jkModify: Result := FModify.NewComment;
    jkRename: Result := FRename.NewComment;
  else
    Result := FScratch.NewComment;
  end;
end;

procedure TZJob.SetNewComment(const AValue: string);
begin
  case FKind of
    jkModify: FModify.NewComment := AValue;
    jkRename: FRename.NewComment := AValue;
  else
    FScratch.NewComment := AValue;
  end;
end;

function TZJob.GetSetComment: Boolean;
begin
  case FKind of
    jkModify: Result := FModify.SetComment;
    jkRename: Result := FRename.SetComment;
  else
    Result := FScratch.SetComment;
  end;
end;

procedure TZJob.SetSetComment(const AValue: Boolean);
begin
  case FKind of
    jkModify: FModify.SetComment := AValue;
    jkRename: FRename.SetComment := AValue;
  else
    FScratch.SetComment := AValue;
  end;
end;

function TZJob.GetRenameIndex: Integer;
begin
  case FKind of
    jkRename: Result := FRename.RenameIndex;
  else
    Result := FScratch.RenameIndex;
  end;
end;

procedure TZJob.SetRenameIndex(const AValue: Integer);
begin
  case FKind of
    jkRename: FRename.RenameIndex := AValue;
  else
    FScratch.RenameIndex := AValue;
  end;
end;

function TZJob.GetRenameFrom: string;
begin
  case FKind of
    jkRename: Result := FRename.RenameFrom;
  else
    Result := FScratch.RenameFrom;
  end;
end;

procedure TZJob.SetRenameFrom(const AValue: string);
begin
  case FKind of
    jkRename: FRename.RenameFrom := AValue;
  else
    FScratch.RenameFrom := AValue;
  end;
end;

function TZJob.GetRenameTo: string;
begin
  case FKind of
    jkRename: Result := FRename.RenameTo;
  else
    Result := FScratch.RenameTo;
  end;
end;

procedure TZJob.SetRenameTo(const AValue: string);
begin
  case FKind of
    jkRename: FRename.RenameTo := AValue;
  else
    FScratch.RenameTo := AValue;
  end;
end;

function TZJob.GetSettings: TCreateSettings;
begin
  case FKind of
    jkCreate: Result := FCreate.Settings;
    jkModify: Result := FModify.Settings;
    jkRename: Result := FRename.Settings;
    jkConvert: Result := FConvert.Settings;
  else
    Result := FScratch.Settings;
  end;
end;

procedure TZJob.SetSettings(const AValue: TCreateSettings);
begin
  case FKind of
    jkCreate: FCreate.Settings := AValue;
    jkModify: FModify.Settings := AValue;
    jkRename: FRename.Settings := AValue;
    jkConvert: FConvert.Settings := AValue;
  else
    FScratch.Settings := AValue;
  end;
end;

function TZJob.GetOptions: TSearchOptions;
begin
  case FKind of
    jkSearch: Result := FSearch.Options;
  else
    Result := FScratch.Options;
  end;
end;

procedure TZJob.SetOptions(const AValue: TSearchOptions);
begin
  case FKind of
    jkSearch: FSearch.Options := AValue;
  else
    FScratch.Options := AValue;
  end;
end;


function TZJob.Clone: TZJob;
begin
  { The ACTIVE payload is copied whole; a hand-picked subset is how a rename
    retry once rewrote entry 0 instead of the entry the user asked for. }
  Result := TZJob.Create(Kind);
  case Kind of
    jkOpen: Result.FOpen := FOpen;
    jkList:
      begin
        { The entry snapshot is read-only, so it is shared rather than copied. }
        Result.FList := FList;
      end;
    jkExtract: Result.FExtract := FExtract;
    jkTest: Result.FTest := FTest;
    jkExtractOne: Result.FExtractOne := FExtractOne;
    jkCreate:
      begin
        Result.FCreate := FCreate;
        Result.FCreate.Sources := nil;
        if FCreate.Sources <> nil then
        begin
          Result.FCreate.Sources := TStringList.Create;
          Result.FCreate.Sources.Assign(FCreate.Sources);
        end;
      end;
    jkModify:
      begin
        Result.FModify := FModify;
        Result.FModify.Sources := nil;
        if FModify.Sources <> nil then
        begin
          Result.FModify.Sources := TStringList.Create;
          Result.FModify.Sources.Assign(FModify.Sources);
        end;
      end;
    jkRename: Result.FRename := FRename;
    jkConvert: Result.FConvert := FConvert;
    jkSearch: Result.FSearch := FSearch;
  end;
  Result.FScratch := FScratch;
  Result.FNameCodepage := FNameCodepage;
  Result.FScratch.Sources := nil;
  if FScratch.Sources <> nil then
  begin
    Result.FScratch.Sources := TStringList.Create;
    Result.FScratch.Sources.Assign(FScratch.Sources);
  end;
end;

function TZJob.CancelledNow: Boolean;
begin
  Result := FCancelRequested;
end;

function TZJob.TakeResult(out AResult: Integer; out AError: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FFinished;
    if Result then
    begin
      AResult := FResult;
      AError := FError;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TZJob.Execute;
var
  R: Integer;
  Err: string;
  Exec: TZJobExecutor;
begin
  R := TZ7Z_OK;
  Err := '';
  FLock.Enter;
  try
    FStartedAt := GetTickCount64;
  finally
    FLock.Leave;
  end;
  try
    try
      Exec := GetExecutor;
      case Kind of
        jkOpen: R := Exec.OpenJob(Self, Err);
        jkList: R := Exec.ListJob(Self, Err);
        jkExtract: R := Exec.ExtractJob(Self, Err);
        jkTest: R := Exec.TestJob(Self, Err);
        jkExtractOne: R := Exec.ExtractOneJob(Self, Err);
        jkCreate: R := Exec.CreateJob(Self, Err);
        jkConvert: R := Exec.ConvertJob(Self, Err);
        jkRename: R := Exec.RenameJob(Self, Err);
        jkModify: R := Exec.ModifyJob(Self, Err);
        jkSearch: R := Exec.SearchJob(Self, Err);
      end;
    except
      on E: Exception do
      begin
        R := TZ7Z_E_EXTRACT;
        Err := E.Message;
      end;
    end;
  finally
    { A cancel that arrives after the engine finished must not relabel a
      completed operation. Only the engine decides that an operation was
      cancelled. }
    FLock.Enter;
    try
      FResult := R;
      FError := Err;
      FFinished := True;
    finally
      FLock.Leave;
    end;
  end;
end;

function TZJob.GetExecutor: TZJobExecutor;
begin
  if FExecutor <> nil then
    Result := FExecutor
  else
    Result := DefaultExecutor;
end;

finalization
  GDefaultExecutor.Free;

end.
