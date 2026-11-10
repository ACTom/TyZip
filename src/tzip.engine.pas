unit tzip.engine;
{ Higher level model shared by the UI: archive contexts, virtual folder
  listings and small path/format helpers.  Nothing here touches LCL. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileUtil, DateUtils, SyncObjs, tzip.api, tzip.search,
  tzip.formats;

type
  TArchiveEntry = record
    Name: string;          { path inside the archive, '/' separated }
    IsDir: Boolean;
    Size: QWord;
    PackedSize: QWord;
    MTime: QWord;          { unix seconds }
    CTime: QWord;
    ATime: QWord;
    CRC: LongWord;
    Attrib: LongWord;
    Encrypted: Boolean;
    IsAnti: Boolean;
    NumStreams: Integer;
    Method: string;
    Comment: string;
    Index: Integer;
  end;
  TArchiveEntries = array of TArchiveEntry;

  TArchiveContext = class
  private
    FArchive: TTzArchive;
    FEntries: TArchiveEntries;
    FDisplayName: string;
    FParent: TArchiveContext;
    FPassword: string;
    FIsNested: Boolean;
    FSourcePath: string;
    FOpenedFromFs: string;
    FTemporarySource: Boolean;
    FCancelled: Boolean;
  public
    constructor Create(AArchive: TTzArchive; const ADisplayName, ASourcePath: string;
      AParent: TArchiveContext; AIsNested: Boolean; const AOpenedFromFs: string;
      AProgress: TZ7ZProgressSink = nil);
    destructor Destroy; override;
    { Re-reads every entry into memory. Returns False when AProgress refused to
      continue; the partial entry array must then be thrown away. }
    function Reload(AProgress: TZ7ZProgressSink = nil): Boolean;
    property Archive: TTzArchive read FArchive;
    property Entries: TArchiveEntries read FEntries;
    property DisplayName: string read FDisplayName;
    property Parent: TArchiveContext read FParent;
    property Password: string read FPassword write FPassword;
    property IsNested: Boolean read FIsNested;
    property SourcePath: string read FSourcePath;   { actual file on disk }
    property OpenedFromFs: string read FOpenedFromFs;
    { True when SourcePath is a temporary file created by TyZip (wrapper
      unwrapping or a nested archive extracted for viewing). }
    property TemporarySource: Boolean read FTemporarySource write FTemporarySource;
    property Cancelled: Boolean read FCancelled;
    function FormatName: string;
    function HasEncrypted: Boolean;
    function CanUpdate: Boolean;
    function EntryByIndex(AIndex: Integer): TArchiveEntry;
    function AllFileCount: Integer;
    function TotalSize: QWord;
  end;

  TListingItem = record
    Name: string;
    FullPath: string;
    IsDir: Boolean;
    IsArchive: Boolean;
    Encrypted: Boolean;
    EntryIndex: Integer;
    Size: QWord;
    PackedSize: QWord;
    MTime: QWord;
    CTime: QWord;
    ATime: QWord;
    CRC: LongWord;
    Attrib: LongWord;
    IsAnti: Boolean;
    NumStreams: Integer;
    Method: string;
    Comment: string;
    { Synthetic ".." row prepended by the UI; never a real archive entry. }
    IsParent: Boolean;
  end;
  TListing = array of TListingItem;
  PListingItem = ^TListingItem;
  TLongWordArray = array of LongWord;

  TArchiveContextArray = array of TArchiveContext;

  TArchiveSortColumn = (ascName, ascType, ascSize, ascPacked, ascRatio,
    ascModified, ascCreated, ascAccessed, ascAttrib, ascCRC, ascMethod,
    ascEncrypted, ascFolder);

function TzNormalizeArcPath(const P: string): string;
function TzIsArchiveName(const AName: string): Boolean;
{ Office/OpenDocument containers are ZIP files internally, so 7-Zip advertises
  their extensions as ZIP.  For double-click semantics they are documents, not
  archives: open them with the user's associated application by default, and let
  the context menu's explicit "Open as Archive" override that. }
function TzIsDocumentName(const AName: string): Boolean;
function TzParentArcPath(const P: string): string;
function TzArcBaseName(const P: string): string;
function TzCompressedInnerName(const APath, ADisplayName: string): string;
function TzIsTarWrapper(const AName: string): Boolean;
function TzOpenContext(const APath, ADisplayName, APassword: string;
  AParent: TArchiveContext; AIsNested: Boolean; const AOpenedFromFs: string;
  out AContext: TArchiveContext; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;

{ Extract AIndices to ADest through an archive context, so a compound archive
  (.tar.gz and friends) extracts the tree its inner archive holds instead of the
  bare inner stream. The context is freed here, which also removes any temporary
  file the unwrap needed. }
function TzExtractInContext(const APath, APassword: string;
  const AIndices: TLongWordArray; const ADest: string;
  out AError: string; AProgress: TZ7ZProgressSink = nil): Integer;

function TzListArchive(AContext: TArchiveContext; const AInnerPath, AFilter: string;
  ASort: TArchiveSortColumn; ADescending: Boolean): TListing;

{ Listing of every entry in the archive that matches a search, ignoring the
  current folder. Name searches match the entry's path; content searches (and
  "both") read the entry through the engine, skipping anything over
  MaxContentBytes. Hits carry their whole path inside the archive, because two
  entries called readme.txt in different folders are otherwise indistinguishable
  in a flat result list.

  No parent row: a search result list is not a folder you can leave. }
function TzSearchListing(AContext: TArchiveContext;
  const AOptions: TSearchOptions): TListing;

{ The same search as a worker can run: it opens its own context (so it can
  unwrap a compound archive and never touches the UI's handle), reports progress
  once per entry and stops when the sink says so. A cancelled search returns
  TZ7Z_E_CANCEL and no partial listing: a half-walked result applied to the UI
  would silently drop hits the user expected. }
function TzSearchArchive(const APath, APassword: string;
  const AOptions: TSearchOptions; out AListing: TListing;
  AProgress: TZ7ZProgressSink = nil): Integer;

{ The whole archive as one flat listing, from a path instead of a context: it
  opens its own context (unwrap included) so a worker can list a big archive
  without the UI's handle or its entries snapshot. Every entry is a row (there
  is no folder view here, so no ".." row), sorted by path like a search result.
  A refused progress tick cancels the operation and delivers no listing. }
function TzListArchiveByPath(const APath, APassword: string;
  out AListing: TListing; AProgress: TZ7ZProgressSink = nil): Integer;

{ Listing built from an entries snapshot instead of a live context, so it can
  run on a worker thread while the UI keeps painting. }
function TzListEntries(const AEntries: TArchiveEntries;
  const AInnerPath, AFilter: string; ASort: TArchiveSortColumn;
  ADescending: Boolean): TListing;
function TzCopyEntries(const AEntries: TArchiveEntries): TArchiveEntries;

{ Collect disk paths (recursively for folders) into the UTF-8 record array the
  bridge expects for create/update.  The record pointers stay valid while the
  set is alive, and the set owns the backing strings, so it can be built on a
  worker thread and freed there afterwards. }
type
  TZInputSet = record
    Recs: array of TZ7ZInput;
    Disk: TStringList;      { disk paths, index-aligned with Recs }
    Arc: TStringList;       { archive paths, index-aligned with Recs }
    DiskU, ArcU: array of RawByteString;   { UTF-8 backing store for Recs }
    Flags: array of Boolean;
  end;



function TzCollectInputs(APaths: TStrings; const APrefix: string): TZInputSet;
procedure TzInputSetFree(var AInputs: TZInputSet);

{ Collect disk paths with a name inside the archive chosen per entry, instead of
  a shared prefix under the file's own name.

  This is what renaming needs: 7-Zip cannot rename, so the entry is extracted,
  re-added under its new path and the old one removed. ADisk and AArc are
  index-aligned; a pair whose Arc name is empty uses the file's own name. }
function TzCollectInputsMapped(ADisk, AArc: TStrings): TZInputSet;

{ Convert the rows selected in a listing into ascending archive indices,
  expanding directories to every entry below them. }
function TzSelectedIndices(AContext: TArchiveContext; const AListing: TListing;
  const ASelected: array of Boolean): TLongWordArray;
function TzAllIndices(AContext: TArchiveContext): TLongWordArray;

{ Delete the inputs a create job consumed, after the archive is known good.
  Files go first; directories are then removed deepest-first, and only when they
  are empty -- a folder that picked up a new file meanwhile must survive.
  ARoots are the paths the user selected (folders stay as folders even when
  everything inside was deleted). Returns the number of paths that could not be
  removed; AErrors collects one line per failure when it is not nil. }
function TzDeleteSources(ASources: TStrings; AErrors: TStrings = nil): Integer;

{ True when APath is one part of a split archive: a numeric volume name
  ("x.7z.001", "x.7z.002", "x.z01"), or an archive that has such volumes beside
  it ("x.7z" next to "x.7z.001", "x.zip" next to "x.z01"). Updating such a set in
  place rewrites only the named part and leaves the rest of the volume
  inconsistent, so callers refuse rather than corrupt it. }
function TzIsSplitArchivePart(const APath: string): Boolean;

{ Convert an archive to another format.

  There is no repack call in 7-Zip's ABI: the entries are extracted to a
  temporary directory and then packed again, which is also where the entries'
  disk names come from.

  The output is written under a temporary name beside the target and moved into
  place only when both steps succeeded, so a failure never leaves a half-written
  archive where a good one used to be. The source is left untouched. }
function TzConvertArchive(const ASourcePath, AOutPath: string;
  const ASettings: TCreateSettings; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;

{ The file name to give an entry extracted to a temp directory.

  Only bytes that act as a path separator or are illegal on NTFS are replaced;
  everything else survives, because the file is handed to the system to open and
  must keep the name shown in the listing. Replacing every non-ASCII byte turned
  a CJK name into a run of underscores -- one per UTF-8 byte. }
function TzSafeEntryFileName(const AName: string): string;

{ Create an archive, handling the compound names that a single-stream format
  forces: writing a folder into .tar.gz means packing a tar first and then
  compressing that tar, because gzip/bzip2/xz can only wrap ONE stream and the
  engine's create call takes one format at a time. A plain .gz of a single file
  goes straight through. AArchivePath decides which case applies. }

function TzCreateArchive(const AArchivePath: string; const ASettings: TCreateSettings;
  const AInputs: array of TZ7ZInput; out AError: string;
  AProgress: TZ7ZProgressSink = nil): Integer;

implementation

{ Add every child of ADir to AList, so a tree can be collected without its own
  name becoming part of the archive paths. }
procedure ListChildren(const ADir: string; AList: TStrings);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      AList.Add(IncludeTrailingPathDelimiter(ADir) + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function TzConvertArchive(const ASourcePath, AOutPath: string;
  const ASettings: TCreateSettings; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  A: TTzArchive;
  Work, TmpOut, Name, Disk: string;
  Idx: TLongWordArray;
  DiskList, ArcList: TStringList;
  Set1: TZInputSet;
  I: Integer;
begin
  AError := '';
  Result := TZ7Z_E_ARG;
  if (ASourcePath = '') or (AOutPath = '') then Exit;
  if not FileExists(ASourcePath) then
  begin
    AError := 'source archive does not exist';
    Exit;
  end;

  { A private directory per conversion: two running at once must not collide,
    and a crash leaves a directory that is obvious to clean up. }
  Work := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-convert-' +
    IntToStr(GetProcessID) + '-' + IntToStr(GetTickCount64);
  if not ForceDirectories(Work) then
  begin
    AError := 'cannot create a temporary directory';
    Exit;
  end;

  A := nil;
  Idx := nil;
  DiskList := TStringList.Create;
  ArcList := TStringList.Create;
  try
    Result := TzOpenArchive(ASourcePath, '', A, AError);
    if Result <> TZ7Z_OK then Exit;
    try
      SetLength(Idx, A.Count);
      for I := 0 to A.Count - 1 do Idx[I] := LongWord(I);
      if Length(Idx) = 0 then
      begin
        AError := 'the source archive has no entries';
        Result := TZ7Z_E_ARG;
        Exit;
      end;
      Result := TzExtract(A, Idx, Work, '', AError, AProgress);
      if Result <> TZ7Z_OK then Exit;

      { The entry names come from the SOURCE archive, not from scanning the
        extracted tree: a scan cannot see an empty folder (nothing on disk), drops
        the trailing slash that marks a directory, and re-derives non-ASCII names
        through the filesystem. Pairing each extracted path with the source's own
        name keeps all three exactly as they were. }
      for I := 0 to A.Count - 1 do
      begin
        Name := A.EntryName(I);
        { A directory row may arrive without a trailing slash; the extracted
          path is a directory either way. }
        if (Name <> '') and (Name[Length(Name)] = '/') then
          Disk := IncludeTrailingPathDelimiter(Work) +
            StringReplace(Copy(Name, 1, Length(Name) - 1), '/',
              PathDelim, [rfReplaceAll])
        else
          Disk := IncludeTrailingPathDelimiter(Work) +
            StringReplace(Name, '/', PathDelim, [rfReplaceAll]);
        { Skip a missing extraction: an anti-item or a failed optional entry has
          nothing on disk and cannot be re-added. }
        if not FileExists(Disk) and not DirectoryExists(Disk) then Continue;
        DiskList.Add(ExcludeTrailingPathDelimiter(Disk));
        ArcList.Add(Name);
      end;
    finally
      A.Free;
    end;

    if DiskList.Count = 0 then
    begin
      AError := 'nothing was extracted from the source archive';
      Result := TZ7Z_E_EXTRACT;
      Exit;
    end;

    Set1 := TzCollectInputsMapped(DiskList, ArcList);
    try
      { Write beside the target and move: a convert that dies halfway must not
        destroy an archive already sitting at AOutPath. }
      TmpOut := AOutPath + '.tyzip-convert';
      DeleteFile(TmpOut);
      Result := TzCreateArchive(TmpOut, ASettings, Set1.Recs, AError, AProgress);
      if Result <> TZ7Z_OK then
      begin
        DeleteFile(TmpOut);
        Exit;
      end;
      { rename(2) replaces an existing target atomically, so this either swaps in
        the complete new archive or changes nothing. The old code deleted the
        user's archive first and tried again: when the second rename failed too,
        the conversion had thrown away a good file to produce none. Never delete
        what is already at the target -- report the failure and keep both the old
        archive and the reason. }
      if not RenameFile(TmpOut, AOutPath) then
      begin
        DeleteFile(TmpOut);
        AError := 'cannot write the converted archive';
        Result := TZ7Z_E_IO;
      end;
    finally
      TzInputSetFree(Set1);
    end;
  finally
    ArcList.Free;
    DiskList.Free;
    if DirectoryExists(Work) then
    begin
      DeleteDirectory(Work, False);
      RemoveDir(Work);
    end;
  end;
end;

function CompareListingPaths(List: TStringList; Index1, Index2: Integer): Integer;
begin
  Result := CompareText(List[Index1], List[Index2]);
end;

{ Order a listing by its path, so the same search returns the same order every
  time. A TStringList's sort is used rather than an insertion sort: a common
  letter can match most entries of a 200,000-entry archive, and the old nested
  loop was O(n^2) -- tens of billions of comparisons on the UI thread. }
procedure SortListingByPath(var AListing: TListing);
var
  Order: TStringList;
  Sorted: TListing;
  I: Integer;
begin
  Sorted := nil;
  if Length(AListing) < 2 then Exit;
  Order := TStringList.Create;
  try
    for I := 0 to High(AListing) do
      Order.AddObject(AListing[I].FullPath, TObject(PtrInt(I)));
    Order.CustomSort(@CompareListingPaths);
    SetLength(Sorted, Length(AListing));
    for I := 0 to Order.Count - 1 do
      Sorted[I] := AListing[PtrInt(Order.Objects[I])];
    AListing := Sorted;
  finally
    Order.Free;
  end;
end;

{ Does this entry's text match? The bytes live behind the engine handle, so a
  small entry is extracted to a private temporary file and read as text. Binary
  content is scanned as text too: a false match there is unlikely, an exception
  on the UI thread is not acceptable. Entries over MaxContentBytes are never
  read. }
function EntryContentMatches(AArchive: TTzArchive; const AEntry: TArchiveEntry;
  const AOptions: TSearchOptions; const AMatcher: TSearchMatcher;
  const ATempDir: string): Boolean;
var
  Tmp, Err: string;
  Lines: TStringList;
begin
  Result := False;
  if AArchive = nil then Exit;
  if AEntry.IsDir or AEntry.IsAnti then Exit;
  if TooBigToSearch(AEntry.Size, AOptions) then Exit;
  Tmp := IncludeTrailingPathDelimiter(ATempDir) + 'entry-' +
    IntToStr(AEntry.Index) + '.txt';
  Err := '';
  if TzExtractOne(AArchive, AEntry.Index, Tmp, AArchive.Password, Err) <> TZ7Z_OK then
  begin
    if FileExists(Tmp) then DeleteFile(Tmp);
    Exit;
  end;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Tmp);
    except
      { Unreadable content is a non-match, not a failed search. }
      Exit;
    end;
    Result := AMatcher.ContentMatches(Lines);
  finally
    Lines.Free;
    DeleteFile(Tmp);
  end;
end;

{ The shared walk behind both searches: the context version (no progress
  reporting) and the archive version a job uses. Building the result array at
  its final size and sorting once keeps a big archive at O(n log n); appending
  and inserting would make a flat result quadratic. }
function TzSearchEntries(AArchive: TTzArchive;
  const AEntries: TArchiveEntries; const AOptions: TSearchOptions;
  AProgress: TZ7ZProgressSink; out ACancelled: Boolean): TListing;
var
  I, N: Integer;
  E: TArchiveEntry;
  Item: TListingItem;
  Matcher: TSearchMatcher;
  TempDir: string;
  Found: Boolean;
begin
  Result := nil;
  ACancelled := False;
  if AOptions.Query = '' then Exit;
  Matcher := TSearchMatcher.Create(AOptions);
  TempDir := '';
  try
    { Content matching needs the entry's bytes; the engine handle is the only
      reader, so the entries it may touch get one private temp directory. }
    if AOptions.Scope in [ssContent, ssBoth] then
    begin
      TempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-search-' +
        IntToStr(GetProcessID) + '-' + IntToStr(GetTickCount64);
      ForceDirectories(TempDir);
    end;
    SetLength(Result, Length(AEntries));
    N := 0;
    for I := 0 to High(AEntries) do
    begin
      { One tick per entry: the caller's counter is about "how much is left",
        and an entry is the unit of work a search has. }
      if (AProgress <> nil) and not AProgress.Tick(I + 1, Length(AEntries)) then
      begin
        ACancelled := True;
        Result := nil;
        Exit;
      end;
      E := AEntries[I];
      case AOptions.Scope of
        ssName: Found := Matcher.NameMatches(E.Name);
        ssContent: Found := EntryContentMatches(AArchive, E, AOptions,
          Matcher, TempDir);
        ssBoth: Found := Matcher.NameMatches(E.Name) or
          EntryContentMatches(AArchive, E, AOptions, Matcher, TempDir);
      else
        Found := False;
      end;
      if not Found then Continue;
      Item := Default(TListingItem);
      Item.Name := E.Name;
      Item.FullPath := E.Name;
      Item.IsDir := E.IsDir;
      Item.Size := E.Size;
      Item.PackedSize := E.PackedSize;
      Item.MTime := E.MTime;
      Item.CTime := E.CTime;
      Item.ATime := E.ATime;
      Item.CRC := E.CRC;
      Item.Attrib := E.Attrib;
      Item.Encrypted := E.Encrypted;
      Item.IsAnti := E.IsAnti;
      Item.EntryIndex := E.Index;
      Result[N] := Item;
      Inc(N);
    end;
    SetLength(Result, N);
    if N > 1 then SortListingByPath(Result);
  finally
    if TempDir <> '' then
      if DirectoryExists(TempDir) then DeleteDirectory(TempDir, False);
    Matcher.Free;
  end;
end;

function TzSearchListing(AContext: TArchiveContext;
  const AOptions: TSearchOptions): TListing;
var
  Cancelled: Boolean;
begin
  Result := nil;
  if (AContext = nil) or (AContext.Archive = nil) then Exit;
  Result := TzSearchEntries(AContext.Archive, AContext.Entries, AOptions, nil,
    Cancelled);
end;

function TzListArchiveByPath(const APath, APassword: string;
  out AListing: TListing; AProgress: TZ7ZProgressSink): Integer;
var
  Ctx: TArchiveContext;
  Err: string;
  I, N: Integer;
  E: TArchiveEntry;
  Item: TListingItem;
begin
  AListing := nil;
  Result := TzOpenContext(APath, ExtractFileName(APath), APassword, nil, False,
    APath, Ctx, Err);
  if Result <> TZ7Z_OK then Exit;
  try
    N := Length(Ctx.Entries);
    { The cancel check comes before any work: a listing is one cheap pass, so
      there is no halfway point worth handing back. }
    if (AProgress <> nil) and not AProgress.Tick(0, N) then
      Exit(TZ7Z_E_CANCEL);
    SetLength(AListing, N);
    for I := 0 to N - 1 do
    begin
      E := Ctx.Entries[I];
      Item := Default(TListingItem);
      Item.Name := E.Name;
      Item.FullPath := E.Name;
      Item.IsDir := E.IsDir;
      Item.Encrypted := E.Encrypted;
      Item.EntryIndex := E.Index;
      Item.Size := E.Size;
      Item.PackedSize := E.PackedSize;
      Item.MTime := E.MTime;
      Item.CTime := E.CTime;
      Item.ATime := E.ATime;
      Item.CRC := E.CRC;
      Item.Attrib := E.Attrib;
      Item.IsAnti := E.IsAnti;
      Item.NumStreams := E.NumStreams;
      Item.Method := E.Method;
      Item.Comment := E.Comment;
      Item.IsParent := False;
      AListing[I] := Item;
    end;
    if N > 1 then SortListingByPath(AListing);
    if AProgress <> nil then AProgress.Tick(N, N);
    Result := TZ7Z_OK;
  finally
    Ctx.Free;
  end;
end;

function TzSearchArchive(const APath, APassword: string;
  const AOptions: TSearchOptions; out AListing: TListing;
  AProgress: TZ7ZProgressSink): Integer;
var
  Ctx: TArchiveContext;
  Err: string;
  Cancelled: Boolean;
begin
  AListing := nil;
  Result := TzOpenContext(APath, ExtractFileName(APath), APassword, nil, False,
    APath, Ctx, Err);
  if Result <> TZ7Z_OK then Exit;
  try
    AListing := TzSearchEntries(Ctx.Archive, Ctx.Entries, AOptions, AProgress,
      Cancelled);
    if Cancelled then
    begin
      AListing := nil;
      Result := TZ7Z_E_CANCEL;
    end
    else
      Result := TZ7Z_OK;
  finally
    Ctx.Free;
  end;
end;


var
  GSortColumn: TArchiveSortColumn;
  GSortDesc: Boolean;
  { CompareListing reads the sort key from these globals, so two concurrent
    listings would corrupt each other's order. }
  GListLock: TCriticalSection;

function TzNormalizeArcPath(const P: string): string;
var
  I: Integer;
begin
  Result := StringReplace(P, '\', '/', [rfReplaceAll]);
  while Pos('//', Result) > 0 do
    Result := StringReplace(Result, '//', '/', [rfReplaceAll]);
  while (Length(Result) > 0) and (Result[1] = '/') do Delete(Result, 1, 1);
  while (Length(Result) > 1) and (Copy(Result, 1, 2) = './') do Delete(Result, 1, 2);
  while (Length(Result) > 0) and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
  { strip unsafe components }
  if Result = '.' then Result := '';
  if Result = '..' then Result := '';
  I := Pos('../', Result);
  if I = 1 then Result := '';
end;

function TzParentArcPath(const P: string): string;
var
  N: string;
begin
  N := TzNormalizeArcPath(P);
  Result := ExtractFileDir(N);
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  if Result = '.' then Result := '';
end;

function TzArcBaseName(const P: string): string;
var
  N: string;
begin
  N := TzNormalizeArcPath(P);
  Result := ExtractFileName(N);
end;

function TzCompressedInnerName(const APath, ADisplayName: string): string;
begin
  { The suffix rules live in tzip.formats so the create and read sides cannot
    disagree about what a compound name means. }
  Result := tzip.formats.TzCompressedInnerName(APath, ADisplayName);
end;

function TzIsTarWrapper(const AName: string): Boolean;
begin
  Result := tzip.formats.TzIsReadableWrapperName(AName);
end;

var
  GArchiveExts: TStringList = nil;
  { Guards the one-time construction: TzIsArchiveName is called from the main
    thread (icons) and from the jkList worker, and two threads creating the same
    TStringList would corrupt the heap. }
  GArchiveLock: TCriticalSection;

procedure BuildArchiveExts;
var
  Formats: TFormatInfoArray;
  F: TFormatInfo;
  Parts: TStringList;
  I: Integer;
  procedure AddExt(const E: string);
  var
    X: string;
  begin
    X := LowerCase(Trim(E));
    if (X = '') or (X = '*') or (X[1] = '.') then Exit;
    if Pos(' ', X) > 0 then Exit;
    if GArchiveExts.IndexOf(X) < 0 then GArchiveExts.Add(X);
  end;
begin
  { Cached once, after the first caller. The table below is added BEFORE
    TzLoadFormats, so a call that happens while the engine is still missing (icon
    building does happen first) already yields a usable answer that includes the
    ZIP-based documents; the engine's own formats are merged on that same pass. }
  if GArchiveExts <> nil then Exit;
  GArchiveLock.Enter;
  try
    if GArchiveExts <> nil then Exit;
    GArchiveExts := TStringList.Create;
    GArchiveExts.Sorted := True;
    GArchiveExts.Duplicates := dupIgnore;
  { Common formats even if a particular engine build lacks a handler: opening will
    fail gracefully and the generic icon is still more useful than none. The
    static knowledge lives in tzip.formats; only the engine's own list is merged
    here. }
  tzip.formats.TzAppendArchiveExtensions(GArchiveExts);
  Formats := TzLoadFormats;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    for F in Formats do
    begin
      Parts.DelimitedText := LowerCase(F.Ext);
      for I := 0 to Parts.Count - 1 do AddExt(Parts[I]);
      Parts.DelimitedText := LowerCase(F.AddExt);
      for I := 0 to Parts.Count - 1 do AddExt(Parts[I]);
    end;
  finally
    Parts.Free;
  end;
  finally
    GArchiveLock.Leave;
  end;
end;

{ The suffix for an unwrapped stream, taken from the entry's own name: a
  ".cpio.zst" entry is still zstd data, so the suffix is ".cpio.zst" and 7-Zip
  recognises the compression from it. A name with no usable extension gets
  ".tar", the common single-stream case. }
{ A stand-in name for the stream a compressed file holds, so the inner type can
  be recognised from it: "x.zip.zst" gives "x.zip", "x.tar.gz" gives "x.tar", and
  "data.zst" gives "data.tar" (a bare stream with nothing to go on).

  A leading dot would NOT work here: ExtractFileExt treats ".zip" as a hidden
  file with no extension, so a real file stem is kept in front of it. }
function TzUname(const APath: string): string;
var
  N: string;
  I: Integer;
begin
  N := ExtractFileName(APath);
  I := LastDelimiter('.', N);
  if I > 1 then
    Result := Copy(N, 1, I - 1)
  else
    Result := N;
  if ExtractFileExt(Result) = '' then Result := Result + '.tar';
end;

function TzInnerSuffix(const AName: string): string;
begin
  Result := tzip.formats.TzStreamInnerSuffix(AName);
end;

function TzIsArchiveName(const AName: string): Boolean;
var
  E: string;
begin
  BuildArchiveExts;
  E := LowerCase(ExtractFileExt(AName));
  if (E <> '') and (E[1] = '.') then Delete(E, 1, 1);
  Result := (E <> '') and (GArchiveExts.IndexOf(E) >= 0);
end;
function TzIsDocumentName(const AName: string): Boolean;
begin
  Result := tzip.formats.TzIsDocumentName(AName);
end;


constructor TArchiveContext.Create(AArchive: TTzArchive;
  const ADisplayName, ASourcePath: string; AParent: TArchiveContext;
  AIsNested: Boolean; const AOpenedFromFs: string;
  AProgress: TZ7ZProgressSink = nil);
begin
  inherited Create;
  FArchive := AArchive;
  FDisplayName := ADisplayName;
  FSourcePath := ASourcePath;
  FParent := AParent;
  FIsNested := AIsNested;
  FOpenedFromFs := AOpenedFromFs;
  if AArchive <> nil then FPassword := AArchive.Password;
  FCancelled := not Reload(AProgress);
end;

destructor TArchiveContext.Destroy;
begin
  FArchive.Free;
  if FTemporarySource and (FSourcePath <> '') and FileExists(FSourcePath) then
    DeleteFile(FSourcePath);
  inherited Destroy;
end;

function TArchiveContext.Reload(AProgress: TZ7ZProgressSink): Boolean;
const
  { A per-entry callback would take the job lock 800k times on a huge archive.
    Report every stride, plus the final entry so the bar reaches 100%. }
  ProgressStride = 128;
var
  I, N: Integer;
  Info: TZ7ZEntryInfo;
begin
  Result := True;
  SetLength(FEntries, 0);
  if FArchive = nil then Exit;
  N := FArchive.Count;
  SetLength(FEntries, N);
  for I := 0 to N - 1 do
  begin
    Info := FArchive.EntryInfo(I);
    FEntries[I].Name := TzNormalizeArcPath(FArchive.EntryName(I));
    FEntries[I].IsDir := Info.IsDir <> 0;
    FEntries[I].Size := Info.Size;
    FEntries[I].PackedSize := Info.PackedSize;
    FEntries[I].MTime := Info.MTime;
    FEntries[I].CTime := Info.CTime;
    FEntries[I].ATime := Info.ATime;
    FEntries[I].CRC := Info.CRC;
    FEntries[I].Attrib := Info.Attrib;
    FEntries[I].Encrypted := Info.Encrypted <> 0;
    FEntries[I].IsAnti := Info.IsAnti <> 0;
    FEntries[I].NumStreams := Info.NumStreams;
    FEntries[I].Method := FArchive.EntryMethod(I);
    FEntries[I].Comment := string(AnsiString(PAnsiChar(@Info.Comment[0])));
    if (FEntries[I].Name = '') and (N = 1) and (not FEntries[I].IsDir) then
      FEntries[I].Name := TzCompressedInnerName(FDisplayName, FSourcePath);
    FEntries[I].Index := I;
    { Reading EntryInfo/Name/Method is the whole cost of opening a large
      archive; report it as a determinate count. The sink runs on the worker
      thread and only stores the numbers, so no per-entry UI work happens here. }
    if (AProgress <> nil) and
       (((I + 1) mod ProgressStride = 0) or (I = N - 1)) then
      if not AProgress.Tick(I + 1, N) then
        Exit(False);
  end;
end;

function TArchiveContext.FormatName: string;
begin
  if FArchive <> nil then Result := FArchive.FormatName else Result := '';
end;

function TArchiveContext.HasEncrypted: Boolean;
begin
  Result := (FArchive <> nil) and FArchive.HasEncrypted;
end;

function TArchiveContext.CanUpdate: Boolean;
begin
  { A split set cannot be updated through one of its parts: the engine would
    rewrite that part alone and leave the sibling volumes disagreeing with the
    index. The check is on the file on disk, because the engine's own CanUpdate
    only looks at the format. }
  Result := (FArchive <> nil) and FArchive.CanUpdate and (not FIsNested) and
    (not TzIsSplitArchivePart(FSourcePath));
end;

function TArchiveContext.EntryByIndex(AIndex: Integer): TArchiveEntry;
begin
  if (AIndex >= 0) and (AIndex < Length(FEntries)) then
    Result := FEntries[AIndex]
  else
    Result := Default(TArchiveEntry);
end;

function TArchiveContext.AllFileCount: Integer;
var
  E: TArchiveEntry;
begin
  Result := 0;
  for E in FEntries do
    if not E.IsDir then Inc(Result);
end;

function TArchiveContext.TotalSize: QWord;
var
  E: TArchiveEntry;
begin
  Result := 0;
  for E in FEntries do
    if not E.IsDir then Inc(Result, E.Size);
end;

function CompareListing(List: TStringList; Index1, Index2: Integer): Integer;
var
  A, B: TListingItem;
  C: Integer;
begin
  A := PListingItem(List.Objects[Index1])^;
  B := PListingItem(List.Objects[Index2])^;
  if A.IsDir <> B.IsDir then
  begin
    if A.IsDir then Exit(-1) else Exit(1);
  end;
  C := 0;
  case GSortColumn of
    ascName: C := CompareText(A.Name, B.Name);
    ascType: C := CompareText(ExtractFileExt(A.Name), ExtractFileExt(B.Name));
    ascSize: if A.Size < B.Size then C := -1 else if A.Size > B.Size then C := 1;
    ascPacked: if A.PackedSize < B.PackedSize then C := -1
               else if A.PackedSize > B.PackedSize then C := 1;
    ascRatio:
      begin
        if A.Size = 0 then C := -1 else if B.Size = 0 then C := 1
        else if A.PackedSize * B.Size < B.PackedSize * A.Size then C := -1
        else if A.PackedSize * B.Size > B.PackedSize * A.Size then C := 1;
      end;
    ascModified: if A.MTime < B.MTime then C := -1
                 else if A.MTime > B.MTime then C := 1;
    ascCreated: if A.CTime < B.CTime then C := -1
                else if A.CTime > B.CTime then C := 1;
    ascAccessed: if A.ATime < B.ATime then C := -1
                 else if A.ATime > B.ATime then C := 1;
    ascAttrib: if A.Attrib < B.Attrib then C := -1
               else if A.Attrib > B.Attrib then C := 1;
    ascCRC: if A.CRC < B.CRC then C := -1 else if A.CRC > B.CRC then C := 1;
    ascMethod: C := CompareText(A.Method, B.Method);
    ascEncrypted: if Ord(A.Encrypted) < Ord(B.Encrypted) then C := -1
                  else if Ord(A.Encrypted) > Ord(B.Encrypted) then C := 1;
    ascFolder: if Ord(A.IsDir) < Ord(B.IsDir) then C := -1
               else if Ord(A.IsDir) > Ord(B.IsDir) then C := 1;
  end;
  if C = 0 then C := CompareText(A.Name, B.Name);
  if GSortDesc then C := -C;
  Result := C;
end;

type
  { Recursive totals for one child folder of the folder being listed.  The
    listing itself is one level deep, but 7-Zip shows a folder's size as the sum
    of everything below it, so the same pass that discovers the folders also
    accumulates their contents. }
  TDirTotal = record
    Size: QWord;
    PackedBytes: QWord;
    Files: Integer;
  end;

function TzListEntries(const AEntries: TArchiveEntries;
  const AInnerPath, AFilter: string; ASort: TArchiveSortColumn;
  ADescending: Boolean): TListing;
var
  Prefix, Rel, Child, Filt: string;
  E: TArchiveEntry;
  DirNames, FileNames, DirTotals: TStringList;
  Totals: array of TDirTotal;
  I, K, Slash, T: Integer;
  CtxPath: string;
  procedure TotalFor(const AChild: string; const AEntry: TArchiveEntry);
  var
    J: Integer;
  begin
    J := DirTotals.IndexOf(AChild);
    if J < 0 then
    begin
      J := DirTotals.Count;
      DirTotals.AddObject(AChild, TObject(PtrInt(J)));
      SetLength(Totals, J + 1);
    end
    else
      J := PtrInt(DirTotals.Objects[J]);
    if not AEntry.IsDir then
    begin
      Inc(Totals[J].Size, AEntry.Size);
      Inc(Totals[J].PackedBytes, AEntry.PackedSize);
      Inc(Totals[J].Files);
    end;
  end;
  procedure AddItem(const AName: string; AIsDir: Boolean; const AEntry: TArchiveEntry);
  var
    P: ^TListingItem;
  begin
    New(P);
    P^.IsParent := False;
    P^.Name := AName;
    P^.FullPath := Prefix + AName;
    P^.IsDir := AIsDir;
    P^.IsArchive := (not AIsDir) and TzIsArchiveName(AName);
    P^.EntryIndex := AEntry.Index;
    if AIsDir then
    begin
      P^.Size := 0;
      P^.PackedSize := 0;
      P^.Method := '';
    end
    else
    begin
      P^.Size := AEntry.Size;
      P^.PackedSize := AEntry.PackedSize;
      P^.Method := AEntry.Method;
    end;
    P^.MTime := AEntry.MTime;
    P^.CTime := AEntry.CTime;
    P^.ATime := AEntry.ATime;
    P^.CRC := AEntry.CRC;
    P^.Attrib := AEntry.Attrib;
    if AIsDir then
      P^.Encrypted := False
    else
      P^.Encrypted := AEntry.Encrypted;
    P^.IsAnti := AEntry.IsAnti;
    P^.NumStreams := AEntry.NumStreams;
    P^.Comment := AEntry.Comment;
    if AIsDir then
      DirNames.AddObject(AName, TObject(P))
    else
      FileNames.AddObject(AName, TObject(P));
  end;
var
  SeenDirs: TStringList;
begin
  Result := nil;
  if Length(AEntries) = 0 then Exit;
  Prefix := TzNormalizeArcPath(AInnerPath);
  if Prefix <> '' then Prefix := Prefix + '/';
  Filt := LowerCase(Trim(AFilter));
  CtxPath := Prefix;

  DirNames := TStringList.Create;
  FileNames := TStringList.Create;
  SeenDirs := TStringList.Create;
  SeenDirs.Sorted := True;
  SeenDirs.CaseSensitive := False;
  DirTotals := TStringList.Create;
  DirTotals.Sorted := True;
  DirTotals.Duplicates := dupIgnore;
  DirTotals.CaseSensitive := False;
  try
    for E in AEntries do
    begin
      Rel := E.Name;
      if CtxPath <> '' then
      begin
        if not SameText(Copy(Rel, 1, Length(CtxPath)), CtxPath) then Continue;
        Rel := Copy(Rel, Length(CtxPath) + 1, MaxInt);
      end;
      if Rel = '' then Continue;
      Slash := Pos('/', Rel);
      if Slash > 0 then
      begin
        Child := Copy(Rel, 1, Slash - 1);
        if Child = '' then Continue;
        if (Filt <> '') and (Pos(Filt, LowerCase(Child)) = 0) then Continue;
        { Accumulate before the seen-check: the first entry below a folder is
          what creates its row, and every later sibling still belongs to it. }
        TotalFor(Child, E);
        if SeenDirs.IndexOf(Child) >= 0 then Continue;
        SeenDirs.Add(Child);
        AddItem(Child, True, E);
      end
      else if E.IsDir then
      begin
        if (Filt <> '') and (Pos(Filt, LowerCase(Rel)) = 0) then Continue;
        if SeenDirs.IndexOf(Rel) >= 0 then Continue;
        SeenDirs.Add(Rel);
        AddItem(Rel, True, E);
      end
      else
      begin
        if (Filt <> '') and (Pos(Filt, LowerCase(Rel)) = 0) then Continue;
        AddItem(Rel, False, E);
      end;
    end;

    { Apply the accumulated totals to the folder rows. }
    for K := 0 to DirNames.Count - 1 do
    begin
      T := DirTotals.IndexOf(PListingItem(DirNames.Objects[K])^.Name);
      if T >= 0 then
      begin
        PListingItem(DirNames.Objects[K])^.Size := Totals[T].Size;
        PListingItem(DirNames.Objects[K])^.PackedSize := Totals[T].PackedBytes;
      end;
    end;

    GListLock.Enter;
    try
      GSortColumn := ASort;
      GSortDesc := ADescending;
      DirNames.CustomSort(@CompareListing);
      FileNames.CustomSort(@CompareListing);
    finally
      GListLock.Leave;
    end;

    SetLength(Result, DirNames.Count + FileNames.Count);
    I := 0;
    for K := 0 to DirNames.Count - 1 do
    begin
      Result[I] := PListingItem(DirNames.Objects[K])^;
      Inc(I);
    end;
    for K := 0 to FileNames.Count - 1 do
    begin
      Result[I] := PListingItem(FileNames.Objects[K])^;
      Inc(I);
    end;
  finally
    for I := 0 to DirNames.Count - 1 do Dispose(PListingItem(DirNames.Objects[I]));
    for I := 0 to FileNames.Count - 1 do Dispose(PListingItem(FileNames.Objects[I]));
    DirNames.Free;
    FileNames.Free;
    SeenDirs.Free;
    DirTotals.Free;
  end;
end;

function TzListArchive(AContext: TArchiveContext; const AInnerPath, AFilter: string;
  ASort: TArchiveSortColumn; ADescending: Boolean): TListing;
begin
  if AContext = nil then Exit(nil);
  Result := TzListEntries(AContext.Entries, AInnerPath, AFilter, ASort, ADescending);
end;

function TzCopyEntries(const AEntries: TArchiveEntries): TArchiveEntries;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AEntries));
  for I := 0 to High(AEntries) do
    Result[I] := AEntries[I];
end;

{ True for a compression-only stream: gzip, zstd, xz, bzip2 and friends hold
  BYTES with no directory structure of their own, so whatever they contain is an
  opaque stream. Archives proper (tar, zip, 7z, cpio, rpm) have entries and a
  directory tree even when they happen to hold a single file. }

function TzIsPureCompression(const APath: string): Boolean;
begin
  { The bytes have no directory tree. Which extensions mean that is in the
    single format table, together with whether such a file can be written. }
  Result := tzip.formats.TzIsPureCompressionName(APath);
end;

function TzOpenContext(const APath, ADisplayName, APassword: string;
  AParent: TArchiveContext; AIsNested: Boolean; const AOpenedFromFs: string;
  out AContext: TArchiveContext; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  A, Inner: TTzArchive;
  Info: TZ7ZEntryInfo;
  Tmp, TmpDir, E2: string;
  IsWrapper: Boolean;
  InnerName, UnwrapName: string;
  Depth: Integer;
  Temps: TStringList;
  CurrentPath: string;
  CurrentIsTemp: Boolean;
  KeepPath: string;

  { A context created with our sink may have stopped because the user cancelled.
    Free it and report so the caller exits without a half-built context. }
  function FreeIfCancelled: Boolean;
  begin
    Result := (AContext <> nil) and AContext.Cancelled;
    if Result then
    begin
      AContext.Free;
      AContext := nil;
    end;
  end;

  { Delete every temporary file this call made, except the one a context took
    over (that file IS the context's source and outlives us). }
  procedure CleanTemps;
  var
    I: Integer;
  begin
    for I := 0 to Temps.Count - 1 do
      if (Temps[I] <> KeepPath) and FileExists(Temps[I]) then
        DeleteFile(Temps[I]);
    Temps.Clear;
  end;

begin
  AContext := nil;
  A := nil;
  Result := TzOpenArchive(APath, APassword, A, AError);
  if Result <> TZ7Z_OK then Exit;
  Temps := TStringList.Create;
  CurrentPath := APath;
  CurrentIsTemp := False;
  KeepPath := '';
  try
  { .tar.gz/.tgz/.tar.bz2/... are two nested formats.  7-Zip's gzip handler
    exposes the inner tar as a single stream with no name; open it directly so
    the user sees the tar contents, exactly like 7-Zip's own shell extension. }
  try
    { A wrapper is a SINGLE-STREAM container holding one file that is itself an
      archive: .cpio.zst, .zip.zst, and the compound .tar.gz handled above. A
      real archive (7z, zip, tar, cpio, rpm, deb) has its own entries and is
      always shown as itself, even when it happens to hold one archive-like
      document. Without that distinction a 7z holding a single .xlsx was
      unwrapped into the xlsx's ZIP internals, with no parent context to go
      back to (ticket 39). }
    IsWrapper := (A.Count = 1) and TzIsTarWrapper(APath);
    if IsWrapper then
      { A known ".tar.zst"-style pair. The stream inside is still zstd, so the
        temporary file keeps the SOURCE file's whole suffix; stripping the
        compression extension here produced a ".tar" full of zstd data that would
        not open, which is what hid the tar layer entirely. }
      UnwrapName := ExtractFileName(APath);
    if not IsWrapper and (A.Count = 1) and TzIsPureCompression(APath) then
    begin
      Info := A.EntryInfo(0);
      { Single-stream handlers (zstd, gzip) report the entry with NO NAME at all,
        so the inner type has to come from the container's own name:
        "x.zip.zst" unwraps to something called ".zip". }
      InnerName := A.EntryName(0);
      if InnerName = '' then InnerName := TzUname(APath);
      IsWrapper := (Info.IsDir = 0) and TzIsArchiveName(InnerName);
      { The name drives the temporary file's suffix. An entry that CARRIES a name
        ("package.tar.zst") must keep it whole, compression extension included:
        the bytes just extracted are still zstd, so saving them as ".tar" made the
        next open fail and the tar layer unreachable. }
      if IsWrapper then
      begin
        UnwrapName := A.EntryName(0);
        if UnwrapName = '' then UnwrapName := InnerName;
      end;
    end;
    if IsWrapper then
    begin
      Info := A.EntryInfo(0);
      IsWrapper := Info.IsDir = 0;
    end;
    { Unwrap repeatedly. One layer is not enough for real packages: a Fedora RPM
      holds x.cpio.zst, which is zstd over cpio, and a .zip wrapped in zstd holds
      zstd over zip. Stopping after the first layer left the user staring at a
      single row named after the file they had just clicked.
      Depth drives the temporary names and the 8-layer cap, so it must start at a
      known value: an uninitialised local held whatever the stack had, which could
      refuse a legitimate first layer or never stop the walk at all. }
    Depth := 0;
    while IsWrapper do
    begin
      TmpDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
        'TyZip-' + IntToStr(GetProcessID) + PathDelim;
      ForceDirectories(TmpDir);
      { Keep the INNER name's extension. The unwrapped stream is whatever the
        single entry contained -- .tar for a .tar.gz, .cpio.zst for the stream a
        Fedora RPM holds. Naming every unwrapped file ".tar" made 7-Zip parse a
        cpio archive as a tar and fail. }
      Tmp := TmpDir + 'wrap_' + IntToHex(GetTickCount64, 12) + IntToStr(Depth) +
        TzInnerSuffix(UnwrapName);
      Inc(Depth);
      Inner := nil;
      if TzExtractOne(A, 0, Tmp, APassword, E2) <> TZ7Z_OK then
      begin
        if FileExists(Tmp) then DeleteFile(Tmp);
        Break;
      end;
      { From here on the file exists and belongs to this call. If the walk stops
        before a context takes it over, it is deleted on the way out. }
      Temps.Add(Tmp);
      if TzOpenArchive(Tmp, APassword, Inner, E2) <> TZ7Z_OK then
      begin
        if FileExists(Tmp) then DeleteFile(Tmp);
        Temps.Delete(Temps.Count - 1);
        Break;
      end;
      if Depth >= 8 then
      begin
        { Absurdly deep nesting is more likely a corrupt file than a real
          package; keep what we have rather than unwrap forever. }
        try
          AContext := TArchiveContext.Create(Inner, ADisplayName, Tmp, AParent,
            True, AOpenedFromFs, AProgress);
        except
          Inner.Free;
          raise;
        end;
        if FreeIfCancelled then Exit(TZ7Z_E_CANCEL);
        AContext.TemporarySource := True;
        KeepPath := Tmp;
        A.Free;
        A := nil;
        Exit(TZ7Z_OK);
      end;
      { Keep going only through COMPRESSION streams. A real archive -- tar, zip,
        7z, cpio -- is something the user can browse and double-click into, so it
        stops the walk even when it holds a single file. Without this distinction
        an outer .tar.zst was unrolled all the way down to the 7z inside it, and
        the layers in between became unreachable. }
      UnwrapName := '';
      if TzIsPureCompression(Tmp) and (Inner.Count = 1) then
      begin
        Info := Inner.EntryInfo(0);
        UnwrapName := Inner.EntryName(0);
        if UnwrapName = '' then UnwrapName := TzUname(Tmp);
        if (Info.IsDir <> 0) or (not TzIsArchiveName(UnwrapName)) then
          UnwrapName := '';
      end;
      if UnwrapName <> '' then
      begin
        { Another compression layer: drop the current one and continue. The next
          layer's file becomes the current source, so a later failure reports the
          archive the user can actually see. }
        A.Free;
        A := Inner;
        Inner := nil;
        CurrentPath := Tmp;
        CurrentIsTemp := True;
        IsWrapper := True;
        Continue;
      end;
      { Not a wrapper any more: this is what the user should see. }
      try
        AContext := TArchiveContext.Create(Inner, ADisplayName, Tmp, AParent,
          True, AOpenedFromFs, AProgress);
        if FreeIfCancelled then Exit(TZ7Z_E_CANCEL);
        AContext.TemporarySource := True;
        KeepPath := Tmp;
        A.Free;
        A := nil;
        Exit(TZ7Z_OK);
      except
        Inner.Free;
        raise;
      end;
    end;
  except
    on E: Exception do
    begin
      { A wrapper that cannot be unwrapped is still a valid archive: show the
        deepest layer that did open. Caught BY TYPE -- a bare except also
        swallowed out-of-memory and real programming errors -- and the temporary
        files are cleaned up on the way out. }
      KeepPath := '';
    end;
  end;

  { No context took over a wrapper. A is the deepest archive that opened; when
    layers were unwrapped before the walk stopped, A lives in one of our
    temporary files. Keep that file, name it as the source, and mark the context
    so the file is deleted when the context is. }
  if CurrentIsTemp then KeepPath := CurrentPath;
  try
    AContext := TArchiveContext.Create(A, ADisplayName, CurrentPath, AParent,
      AIsNested or CurrentIsTemp, AOpenedFromFs, AProgress);
    if AContext.Cancelled then
    begin
      AContext.Free;
      AContext := nil;
      A := nil;
      Exit(TZ7Z_E_CANCEL);
    end;
    AContext.TemporarySource := CurrentIsTemp;
    A := nil;
  except
    A.Free;
    A := nil;
    raise;
  end;
  finally
    CleanTemps;
    Temps.Free;
    A.Free;
  end;
end;

function TzAllIndices(AContext: TArchiveContext): TLongWordArray;
var
  I: Integer;
begin
  Result := nil;
  if AContext = nil then Exit;
  SetLength(Result, Length(AContext.Entries));
  for I := 0 to High(AContext.Entries) do
    Result[I] := LongWord(I);
end;

function TzSelectedIndices(AContext: TArchiveContext; const AListing: TListing;
  const ASelected: array of Boolean): TLongWordArray;
var
  Mark: array of Boolean;
  I, J, N: Integer;
  Prefix: string;
  E: TArchiveEntry;
  Item: TListingItem;
  K: Integer;
begin
  Result := nil;
  Mark := nil;
  if AContext = nil then Exit;
  SetLength(Mark, Length(AContext.Entries));
  for I := 0 to High(ASelected) do
  begin
    if (I > High(AListing)) or (not ASelected[I]) then Continue;
    Item := AListing[I];
    if Item.IsParent then Continue;
    if not Item.IsDir then
    begin
      if (Item.EntryIndex >= 0) and (Item.EntryIndex < Length(Mark)) then
        Mark[Item.EntryIndex] := True;
    end
    else
    begin
      Prefix := Item.FullPath + '/';
      for J := 0 to High(AContext.Entries) do
      begin
        E := AContext.Entries[J];
        if SameText(Copy(E.Name, 1, Length(Prefix)), Prefix) then Mark[J] := True;
      end;
    end;
  end;
  N := 0;
  for I := 0 to High(Mark) do if Mark[I] then Inc(N);
  SetLength(Result, N);
  K := 0;
  for I := 0 to High(Mark) do
    if Mark[I] then
    begin
      Result[K] := LongWord(I);
      Inc(K);
    end;
end;

function TzCollectInputs(APaths: TStrings; const APrefix: string): TZInputSet;
var
  I: Integer;

  procedure AddOne(const ADisk, AArc: string; AIsDir: Boolean);
  var
    N: Integer;
  begin
    N := Result.Disk.Count;
    Result.Disk.Add(ADisk);
    if APrefix <> '' then
      Result.Arc.Add(TzNormalizeArcPath(APrefix + '/' + AArc))
    else
      Result.Arc.Add(TzNormalizeArcPath(AArc));
    SetLength(Result.Flags, N + 1);
    Result.Flags[N] := AIsDir;
  end;

  procedure AddTree(const ADisk, AArc: string; AIsDir: Boolean);
  var
    SR: TSearchRec;
    ChildDisk, ChildArc: string;
  begin
    AddOne(ADisk, AArc, AIsDir);
    if not AIsDir then Exit;
    if FindFirst(IncludeTrailingPathDelimiter(ADisk) + '*', faAnyFile, SR) <> 0 then Exit;
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Name = '.DS_Store') or (Copy(SR.Name, 1, 2) = '._') then Continue;
        {$IFDEF UNIX}
        { Windows has no symlink attribute; on Unix a symlink is skipped rather
          than stored as the file it points at. The symbol is Unix-only by
          design, so the portability warning is silenced here. }
        {$PUSH}{$WARN 5044 OFF}
        if (SR.Attr and faSymLink) <> 0 then Continue;
        {$POP}
        {$ENDIF}
        ChildDisk := IncludeTrailingPathDelimiter(ADisk) + SR.Name;
        ChildArc := AArc + '/' + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          AddTree(ChildDisk, ChildArc, True)
        else
          AddOne(ChildDisk, ChildArc, False);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

var
  P: string;
begin
  Result.Disk := TStringList.Create;
  Result.Arc := TStringList.Create;
  SetLength(Result.Recs, 0);
  SetLength(Result.Flags, 0);
  for I := 0 to APaths.Count - 1 do
  begin
    P := ExcludeTrailingPathDelimiter(APaths[I]);
    if (P = '') then Continue;
    if not FileExists(P) and not DirectoryExists(P) then Continue;
    AddTree(P, ExtractFileName(P), DirectoryExists(P));
  end;
  if Result.Disk.Count = 0 then Exit;
  SetLength(Result.Recs, Result.Disk.Count);
  SetLength(Result.DiskU, Result.Disk.Count);
  SetLength(Result.ArcU, Result.Disk.Count);
  for I := 0 to Result.Disk.Count - 1 do
  begin
    { The strings already hold UTF-8 (the app sets DefaultSystemCodePage to
      CP_UTF8 and macOS names are UTF-8). Calling UTF8Encode here converts them
      a SECOND time -- "名字" (6 bytes) becomes 12 -- and 7-Zip then fails with
      "cannot stat input file" on the mangled path. Copy the bytes verbatim. }
    Result.DiskU[I] := RawByteString(Result.Disk[I]);
    Result.ArcU[I] := RawByteString(Result.Arc[I]);
    Result.Recs[I].DiskPath := PAnsiChar(Result.DiskU[I]);
    Result.Recs[I].ArcPath := PAnsiChar(Result.ArcU[I]);
    if Result.Flags[I] then Result.Recs[I].IsDir := 1 else Result.Recs[I].IsDir := 0;
  end;
end;

procedure TzInputSetFree(var AInputs: TZInputSet);
begin
  AInputs.Disk.Free;
  AInputs.Arc.Free;
  SetLength(AInputs.Recs, 0);
  SetLength(AInputs.DiskU, 0);
  SetLength(AInputs.ArcU, 0);
  SetLength(AInputs.Flags, 0);
end;

function TzCollectInputsMapped(ADisk, AArc: TStrings): TZInputSet;
var
  I: Integer;
  P, Name: string;
begin
  Result.Disk := TStringList.Create;
  Result.Arc := TStringList.Create;
  SetLength(Result.Recs, 0);
  SetLength(Result.Flags, 0);
  if (ADisk = nil) or (AArc = nil) then Exit;
  for I := 0 to ADisk.Count - 1 do
  begin
    P := ExcludeTrailingPathDelimiter(ADisk[I]);
    if P = '' then Continue;
    if not FileExists(P) and not DirectoryExists(P) then Continue;
    { The mapped name wins; a blank one means "keep the file's own name". }
    if I <= AArc.Count - 1 then Name := AArc[I] else Name := '';
    if Name = '' then Name := ExtractFileName(P);
    Result.Disk.Add(P);
    Result.Arc.Add(TzNormalizeArcPath(Name));
    SetLength(Result.Flags, Result.Disk.Count);
    Result.Flags[Result.Disk.Count - 1] := DirectoryExists(P);
  end;
  if Result.Disk.Count = 0 then Exit;
  { Same verbatim copy as TzCollectInputs: the strings are already UTF-8, so
    encoding them again would mangle every non-ASCII name. }
  SetLength(Result.Recs, Result.Disk.Count);
  SetLength(Result.DiskU, Result.Disk.Count);
  SetLength(Result.ArcU, Result.Disk.Count);
  for I := 0 to Result.Disk.Count - 1 do
  begin
    Result.DiskU[I] := RawByteString(Result.Disk[I]);
    Result.ArcU[I] := RawByteString(Result.Arc[I]);
    Result.Recs[I].DiskPath := PAnsiChar(Result.DiskU[I]);
    Result.Recs[I].ArcPath := PAnsiChar(Result.ArcU[I]);
    if Result.Flags[I] then Result.Recs[I].IsDir := 1 else Result.Recs[I].IsDir := 0;
  end;
end;


{ True when AName ends in a compound name TyZip can CREATE: the read side also
  knows ".tar.zst" etc., but the table only marks the ones whose outer
  compression the engine can write. }
function IsCompoundTarName(const AName: string): Boolean;
begin
  Result := tzip.formats.TzIsCompoundTarName(AName);
end;

{ tar stores bytes and compresses nothing, so any level/method handed to it makes
  the handler reject the whole job ("archive handler rejected compression
  options"). The dialog hides those fields, but the settings record still carries
  defaults, so they are cleared here rather than trusted to be empty. }
function SanitizeForFormat(const ASettings: TCreateSettings): TCreateSettings;
begin
  Result := ASettings;
  if SameText(Result.FormatName, 'tar') then
  begin
    Result.Level := -1;
    Result.Method := '';
    Result.Solid := False;
    Result.DictionarySize := 0;
    Result.WordSize := 0;
    Result.MatchFinder := '';
    Result.NumPasses := 0;
    Result.ExtraOptions := '';
  end;
end;

function TzSafeEntryFileName(const AName: string): string;
var
  I: Integer;
begin
  Result := ExtractFileName(AName);
  for I := 1 to Length(Result) do
    if Result[I] in [#0, '/', '\', ':', '*', '?', '"', '<', '>', '|', #1..#31] then
      Result[I] := '_';
  { NTFS rejects a trailing dot or space, and a name of only dots is a path
    component rather than a file. }
  while (Result <> '') and (Result[Length(Result)] in ['.', ' ']) do
    Delete(Result, Length(Result), 1);
  if (Result = '') or (Result = '.') or (Result = '..') then
    Result := 'entry.bin';
end;

{ ".001" / ".002" / ... -- the numeric volume suffix 7-Zip uses. }
function IsNumericVolumeSuffix(const AExt: string): Boolean;
var
  I: Integer;
begin
  Result := Length(AExt) = 4;
  if not Result then Exit;
  if AExt[1] <> '.' then Exit(False);
  for I := 2 to 4 do
    if not (AExt[I] in ['0'..'9']) then Exit(False);
end;

function TzIsSplitArchivePart(const APath: string): Boolean;
var
  Ext, Stem: string;
begin
  Result := False;
  if APath = '' then Exit;
  Ext := LowerCase(ExtractFileExt(APath));

  { A volume passed directly: "archive.7z.001" (any numeric part), or the ".z01"
    style a split ZIP uses for everything but its last volume. A lone .001 still
    counts: writing to it cannot recreate the rest of the set. }
  if Ext = '.001' then Exit(True);
  if IsNumericVolumeSuffix(Ext) then Exit(True);
  if (Length(Ext) = 4) and (Ext[1] = '.') and (Ext[2] = 'z') and
     (Ext[3] in ['0'..'9']) and (Ext[4] in ['0'..'9']) then Exit(True);

  { The base name passed instead of a part: "archive.7z" beside
    "archive.7z.001", or "archive.zip" beside "archive.z01". Looking at the
    directory is what makes updating the base file safe to refuse. }
  if FileExists(APath + '.001') then Exit(True);
  Stem := ChangeFileExt(APath, '');
  if (Stem <> '') and (Stem <> APath) and FileExists(Stem + '.z01') then Exit(True);
end;

{ Remove one entry, returning True when it is gone afterwards. }
function TryRemove(const APath: string; AErrors: TStrings): Boolean;
begin
  Result := False;
  if DirectoryExists(APath) then
    Result := RemoveDir(APath)
  else
    Result := DeleteFile(APath);
  if (not Result) and (AErrors <> nil) then
    AErrors.Add(APath);
end;

function TzDeleteSources(ASources: TStrings; AErrors: TStrings): Integer;
var
  Dirs, Files: TStringList;
  I: Integer;
begin
  Result := 0;
  if ASources = nil then Exit;
  Files := TStringList.Create;
  Dirs := TStringList.Create;
  try
    { Split first: deleting a file can make its parent empty, so the directory
      pass has to run after every file is gone. }
    for I := 0 to ASources.Count - 1 do
    begin
      if ASources[I] = '' then Continue;
      if DirectoryExists(ASources[I]) then
      begin
        if Dirs.IndexOf(ASources[I]) < 0 then Dirs.Add(ASources[I]);
      end
      else if FileExists(ASources[I]) then
      begin
        if Files.IndexOf(ASources[I]) < 0 then Files.Add(ASources[I]);
      end;
      { Already gone: not a failure, and nothing to count. }
    end;

    for I := 0 to Files.Count - 1 do
      if not TryRemove(Files[I], AErrors) then Inc(Result);

    { Deepest first, so a nested tree unwinds completely in one pass. }
    Dirs.Sort;
    for I := Dirs.Count - 1 downto 0 do
    begin
      if not DirectoryExists(Dirs[I]) then Continue;
      { RemoveDir fails on a non-empty directory, which is exactly the guard we
        want: a folder that gained a file since the archive was made stays. }
      if not TryRemove(Dirs[I], AErrors) then
      begin
        { A directory that merely still has content is not an error worth
          reporting; count it only when it could not be removed at all. }
        if not DirectoryExists(Dirs[I]) then Continue;
        Inc(Result);
      end;
    end;
  finally
    Dirs.Free;
    Files.Free;
  end;
end;

function TzCreateArchive(const AArchivePath: string; const ASettings: TCreateSettings;
  const AInputs: array of TZ7ZInput; out AError: string;
  AProgress: TZ7ZProgressSink): Integer;
var
  TmpTar: string;
  TarSettings: TCreateSettings;
  Clean: TCreateSettings;
  Inner: array[0..0] of TZ7ZInput;
  InnerDisk, InnerArc: RawByteString;
  InnerName: string;
  OuterSettings: TCreateSettings;
begin
  AError := '';
  Clean := SanitizeForFormat(ASettings);
  if not IsCompoundTarName(AArchivePath) then
    Exit(TzCreate(AArchivePath, Clean, AInputs, AError, AProgress));

  { Step 1: pack a real tar next to the destination. }
  TmpTar := AArchivePath + '.tmp.tar';
  if FileExists(TmpTar) then DeleteFile(TmpTar);
  TarSettings := Default(TCreateSettings);
  TarSettings.FormatName := 'tar';
  TarSettings.Level := -1;
  Result := TzCreate(TmpTar, TarSettings, AInputs, AError, nil);
  if Result <> TZ7Z_OK then
  begin
    if FileExists(TmpTar) then DeleteFile(TmpTar);
    Exit;
  end;

  { Step 2: compress that tar as a single stream. The inner entry is named after
    the destination so tools that look at the stored name see the usual
    "something.tar". }
  InnerDisk := UTF8Encode(TmpTar);
  { Strip the whole compound extension, not just the last dot-segment:
    "out.tar.gz" must yield "out.tar", not "out.tar.tar". }
  InnerName := ExtractFileName(AArchivePath);
  if SameText(Copy(InnerName, Length(InnerName) - 6, 7), '.tar.gz') then
    InnerName := Copy(InnerName, 1, Length(InnerName) - 3)
  else if SameText(Copy(InnerName, Length(InnerName) - 7, 8), '.tar.bz2') then
    InnerName := Copy(InnerName, 1, Length(InnerName) - 4)
  else if SameText(Copy(InnerName, Length(InnerName) - 6, 7), '.tar.xz') then
    InnerName := Copy(InnerName, 1, Length(InnerName) - 3)
  else
    InnerName := ChangeFileExt(InnerName, '.tar');
  InnerArc := UTF8Encode(InnerName);
  Inner[0].DiskPath := PAnsiChar(InnerDisk);
  Inner[0].ArcPath := PAnsiChar(InnerArc);
  Inner[0].IsDir := 0;
  OuterSettings := Clean;
  OuterSettings.FormatName := ASettings.FormatName;
  OuterSettings.VolumeSize := 0;
  Result := TzCreate(AArchivePath, OuterSettings, Inner, AError, AProgress);
  if FileExists(TmpTar) then DeleteFile(TmpTar);
  if Result = TZ7Z_OK then
    AError := '';
end;

function TzExtractInContext(const APath, APassword: string;
  const AIndices: TLongWordArray; const ADest: string;
  out AError: string; AProgress: TZ7ZProgressSink): Integer;
var
  Ctx: TArchiveContext;
  Err: string;
begin
  AError := '';
  Result := TzOpenContext(APath, ExtractFileName(APath), APassword, nil, False,
    APath, Ctx, Err, AProgress);
  if Result <> TZ7Z_OK then
  begin
    AError := Err;
    Exit;
  end;
  try
    Result := TzExtract(Ctx.Archive, AIndices, ADest, APassword, AError,
      AProgress);
  finally
    Ctx.Free;
  end;
end;

initialization
  GListLock := TCriticalSection.Create;
  GArchiveLock := TCriticalSection.Create;




finalization
  GArchiveLock.Free;
  GListLock.Free;


end.
