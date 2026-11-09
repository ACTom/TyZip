{ Per-file-type icons: the on-disk cache and the bundle sweep.

  Split out of tzip.main because none of it needs the window: it answers "what
  glyph stands for this suffix" and nothing else. The form keeps the image list
  and asks this module for pictures.

  Two things live here:

  - TIconCache, a directory of <suffix>.png files, so a cold start does not ask
    NSWorkspace about every file type it meets and watch the list fill in.
  - TAppIconPrefetcher, a ticked (NOT threaded) sweep that caches the icons of
    the application bundles in the two Applications folders.

  There is deliberately no worker thread here. NSWorkspace is a Cocoa API and
  must be called on the main thread: calling it from a TThread produced "Thread
  was created from extern. Press OK to ignore and risk data corruption", which is
  why the bundle sweep was already a ticked object. The suffix lookups moved to
  the window's timer for the same reason (see IconTimerTick in tzip.main). }
unit tzip.ui.icons;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LazFileUtils, BGRABitmap, BGRABitmapTypes, tzip.appcache,
  tzip.iconkeys;

const
  { 32 px: the list slot is 16 logical px, so this covers a Retina display
    exactly. 64/128 px only gave the app-icon restore batch more pixels to
    decode and resample -- restoring /Applications was most of the old start-up
    time -- for no visible gain. }
  IconCachedPx = 32;

type
  { Per-suffix platform icons on disk.

    ADir holds one PNG per lowercase suffix, literally "<suffix>.png" (no dot):
    a file type with no suffix is the one file called "@none.png". Names are not
    hashed because the suffix itself is already a safe file name; a suffix
    containing anything else is simply not cached. }
  TIconCache = class
  private
    FDir: string;
    FNames: TStringList;
    procedure Scan;
  public
    constructor Create(const ADir: string);
    destructor Destroy; override;
    { Re-read the directory. Files written since construction -- by the bundle
      sweep, or by another run -- become visible without restarting the app. }
    procedure Rescan;
    function PathFor(const AExt: string): string;
    { Delete every base_*.png. Those four glyphs are the only entries a wrong one
      is unrecoverable from: an extension icon is re-asked when it goes stale,
      but a base glyph is what the tree and list fall back on, so a blank page
      saved by an early build stayed until the user deleted it by hand. }
    function PurgeBaseGlyphs: Integer;
    { Delete every cached app_*.png. Bundle icons are cheap to rebuild from the
      .icns, so a smaller cache format can replace them without a migration. }
    function PurgeAppGlyphs: Integer;
    { Suffixes that have a cache file, in the order of the directory listing. }
    property Names: TStringList read FNames;
    property Dir: string read FDir;
  end;

{ The cache file name for AExt ("xlsx" -> "xlsx.png"), or '' when the suffix
  cannot be a file name. Kept here as the name tzip.main already calls; the
  decision itself lives in tzip.iconkeys so it can be tested. }
function IconCacheFileName(const AExt: string): string;

{ AName=Value into a SORTED TStringList. Values[] cannot be used there (it raises
  "Operation not allowed on sorted list"), so an existing name is rewritten in
  place and a new one appended, which the sorted list then re-inserts. }
procedure IconCacheNamePut(AList: TStringList; const AName, AValue: string);

{ True when APath already holds the same picture as ABitmap, at the cache size. }
function IconCacheMatches(ABitmap: TBGRABitmap; const APath: string): Boolean;

{ Write ABitmap as a PNG at the size the icon slots actually draw. }
procedure SaveIconPng(ABitmap: TBGRABitmap; const APath: string);

{ True when the cache file is old enough to be re-asked in the background.
  A missing file is not stale: this cache creates it. }
function CacheEntryIsStale(const APath: string): Boolean;

{ A real, existing file with this extension, for the platform to resolve an icon
  from.

  NSWorkspace's iconForFile returns the coloured, fully styled glyph; its
  iconForFileType returns the type's template outline, which is why every
  document row looked like a blank sheet. The probe files are empty, created
  once per extension, and left for the session. }
function TzIconProbePath(const AExt: string): string;

{ Where the on-disk icon cache lives. Preferred: an 'iconcache' folder beside the
  settings file. Not every environment lets an app create a subdirectory in the
  config folder (sandboxed or TCC-managed home, a managed Mac), and icons are
  only a cache -- so the OS temp root is the fallback, where the app's own
  environment always allows a write. Tried ONCE per run. }
function ChooseIconCacheDir: string;

{ Total size of the cache directory in bytes, and how many files it holds. }
procedure TIconCacheSize(ADir: string; out ABytes: Int64; out AFiles: Integer);

{ Delete every cached icon. Returns how many files were removed. }
function TIconCacheClear(ADir: string): Integer;

type
  { Walks /Applications and ~/Applications in the background and writes an icon
    file for each bundle that does not have one yet.

    Exists because naming an .app is the only way to get its real icon (a type
    query answers for the BUNDLE type, not the application), and that costs
    NSWorkspace about 0.7 ms per bundle once warm. 89 bundles is 60 ms --
    invisible in a background thread, a visible stutter while scrolling.

    Nothing waits for it. A bundle whose icon is not cached yet is painted with
    the generic one and corrected when the thread reaches it, which is the same
    rule the extension icons already follow. }
  { Works through the application folders a few bundles per call.

    NOT a thread: NSWorkspace is a Cocoa API, and calling it off the main thread
    is what produced "Thread was created from extern. Press OK to ignore and risk
    data corruption". The extension-icon worker gets away with it because it asks
    for one glyph and hands it straight back; a sweep that asks for a hundred and
    thirty in a row does not.

    The caller ticks this from a timer, so the work is spread over seconds and
    no single frame pays for more than one glyph. }
  TAppIconPrefetcher = class
  private
    FDir: string;
    FWork: TStringList;
    { Bundles whose own icon file had no PNG we could read (legacy .icns or an
      asset catalogue). The window resolves those with the platform query, under
      the idle gate that keeps the blocking call away from the user. }
    FFallbacks: TStringList;
    FStopped: Boolean;
    FCollected: Boolean;
    procedure Collect;
    function AlreadyCached(const APath: string): Boolean;
  public
    constructor Create(const AIconDir: string);
    destructor Destroy; override;
    { Cache up to AMax bundles now. Returns True while work remains. }
    function Step(AMax: Integer): Boolean;
    { The next bundle that needs the platform fallback, '' when none is left. }
    function TakeFallback: string;
    procedure Stop;
    function Pending: Integer;
  end;

implementation

uses
  tzip.platform, tzip.i18n;

const
  { A cache entry older than this is re-asked in the background. The value and the
    rule live in tzip.iconkeys; tzip.main passes a shorter window for the suffix
    icons it refreshes after a day. }
  IconCacheMaxAgeDays = IconCacheRefreshDays;

{ ---------------------------------------------------------------------------
  TIconCache
  --------------------------------------------------------------------------- }

{ Why there is no icon worker thread here any more.

  tzip.main used to resolve one suffix at a time on a TThread, and NSWorkspace
  must not be called off the main thread: this unit already carried the note
  that a background sweep doing so produced "Thread was created from extern ...
  risk data corruption". Extensions were no different -- the worker just made the
  crash less frequent -- so the suffix lookups now happen on the window's timer,
  one per tick, exactly like the application sweep below. }

function IconCacheFileName(const AExt: string): string;
begin
  Result := IconKeyFileName(AExt);
end;

function IconCacheNamePutEx(AList: TStringList; const AName, AValue: string): Boolean;
var
  I: Integer;
  WasSorted: Boolean;
begin
  Result := False;
  if (AList = nil) or (AName = '') then Exit;
  I := AList.IndexOfName(AName);
  if I >= 0 then
  begin
    { Rewriting an EXISTING entry by index is not allowed either: AList[I] := ...
      is TStringList.Put, and Put asks the sorted guard about the name it is
      about to write. FPC raises "Operation not allowed on sorted list" for it
      even though the index came from IndexOfName. Drop sort for the rewrite and
      put it back, so the list ends up correctly ordered. }
    WasSorted := AList.Sorted;
    if WasSorted then AList.Sorted := False;
    try
      AList[I] := AName + '=' + AValue;
    finally
      if WasSorted then AList.Sorted := True;
    end;
  end
  else
    AList.Add(AName + '=' + AValue);
  Result := True;
end;

procedure IconCacheNamePut(AList: TStringList; const AName, AValue: string);
begin
  IconCacheNamePutEx(AList, AName, AValue);
end;

{ True when APath already holds the same picture as ABitmap, at the cache size. }
function IconCacheMatches(ABitmap: TBGRABitmap; const APath: string): Boolean;
var
  Old, New: TBGRABitmap;
  X, Y: Integer;
begin
  Result := False;
  if (ABitmap = nil) or (APath = '') or (not FileExists(APath)) then Exit;
  Old := nil;
  New := nil;
  try
    try
      Old := TBGRABitmap.Create(APath);
    except
      Exit;
    end;
    New := ABitmap.Resample(IconCachedPx, IconCachedPx) as TBGRABitmap;
    if (Old.Width <> New.Width) or (Old.Height <> New.Height) then Exit;
    Result := True;
    for Y := 0 to Old.Height - 1 do
      for X := 0 to Old.Width - 1 do
        if Old.GetPixel(X, Y) <> New.GetPixel(X, Y) then
          Exit(False);
  finally
    New.Free;
    Old.Free;
  end;
end;

procedure SaveIconPng(ABitmap: TBGRABitmap; const APath: string);
var
  Tmp: TBGRABitmap;
begin
  if (ABitmap = nil) or (APath = '') then Exit;
  { Anything already at or below the slot size is stored as-is; only a bigger
    one is scaled down. }
  if (ABitmap.Width <= IconCachedPx) and (ABitmap.Height <= IconCachedPx) then
  begin
    ABitmap.SaveToFile(APath, ifPng);
    Exit;
  end;
  Tmp := ABitmap.Resample(IconCachedPx, IconCachedPx) as TBGRABitmap;
  try
    Tmp.SaveToFile(APath, ifPng);
  finally
    Tmp.Free;
  end;
end;

function CacheEntryIsStale(const APath: string): Boolean;
begin
  Result := IconKeyIsOlderThan(APath, IconCacheMaxAgeDays);
end;

constructor TIconCache.Create(const ADir: string);
begin
  inherited Create;
  { An empty directory means "no cache" (ChooseIconCacheDir could not create
    one). IncludeTrailingPathDelimiter('') is '/' in FPC, which made the scan read
    the volume root for *.png and PathFor write files straight into '/'. }
  if ADir = '' then
    FDir := ''
  else
    FDir := IncludeTrailingPathDelimiter(ADir);
  FNames := TStringList.Create;
  FNames.Sorted := True;
  FNames.Duplicates := dupIgnore;
  FNames.CaseSensitive := False;
  Scan;
end;

destructor TIconCache.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

procedure TIconCache.Rescan;
begin
  Scan;
end;

procedure TIconCache.Scan;
var
  Search: TSearchRec;
  N: string;
begin
  FNames.Clear;
  if (FDir = '') or (not DirectoryExists(FDir)) then Exit;
  if FindFirst(FDir + '*.png', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then Continue;
      N := ChangeFileExt(Search.Name, '');
      { base_*.png are the four generic glyphs tzip.main writes into the same
        folder. They are not file types; treating them as suffixes registered
        "file:base_folder" style slots that nothing ever asks for. }
      if Copy(LowerCase(N), 1, 5) = 'base_' then Continue;
      if N = IconCacheNoExt then
        FNames.Add('')
      else
        FNames.Add(LowerCase(N));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

{ Decode the PNG the sweep read from a bundle, then store it at the cache size.
  Writing the original chunk (128/256 px) made every later restore decode and
  resample a much larger image than the 16 px slot ever shows. }
procedure CacheAppIconFromPng(const ADir, AKey: string; const APng: TBytes);
var
  Tmp: string;
  FS: TFileStream;
  B: TBGRABitmap;
begin
  if (ADir = '') or (AKey = '') or (Length(APng) = 0) then Exit;
  Tmp := IncludeTrailingPathDelimiter(GetTempDir) + 'tyzip-icon-' +
    IntToHex(GetProcessID, 8) + '.png';
  FS := TFileStream.Create(Tmp, fmCreate);
  try
    FS.WriteBuffer(APng[0], Length(APng));
  finally
    FS.Free;
  end;
  B := nil;
  try
    try
      B := TBGRABitmap.Create(Tmp);
    except
      B := nil;
    end;
    if B <> nil then
      SaveIconPng(B, ADir + IconCacheFileName(AKey));
  finally
    B.Free;
    DeleteFile(Tmp);
  end;
end;

constructor TAppIconPrefetcher.Create(const AIconDir: string);
begin
  inherited Create;
  FDir := AIconDir;
  FWork := TStringList.Create;
  FFallbacks := TStringList.Create;
end;

destructor TAppIconPrefetcher.Destroy;
begin
  FFallbacks.Free;
  FWork.Free;
  inherited Destroy;
end;

function TAppIconPrefetcher.TakeFallback: string;
begin
  Result := '';
  if FFallbacks.Count = 0 then Exit;
  Result := FFallbacks[0];
  FFallbacks.Delete(0);
end;

procedure TAppIconPrefetcher.Stop;
begin
  FStopped := True;
end;

function TAppIconPrefetcher.Pending: Integer;
begin
  Result := FWork.Count;
end;

procedure TAppIconPrefetcher.Collect;
var
  Roots: TStringArray;
  I: Integer;
  Search: TSearchRec;
  Path: string;
begin
  FCollected := True;
  if (FDir = '') or (not DirectoryExists(FDir)) then Exit;
  Roots := AppCacheRoots;
  for I := 0 to High(Roots) do
  begin
    if not DirectoryExists(Roots[I]) then Continue;
    if FindFirst(IncludeTrailingPathDelimiter(Roots[I]) + '*.app', faAnyFile, Search) <> 0 then
      Continue;
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        Path := IncludeTrailingPathDelimiter(Roots[I]) + Search.Name;
        if not LooksLikeAppBundle(Path) then Continue;
        { A symlink to a bundle is the same bundle; skipping it saves a query.
          FileIsSymlink is portable; the search record's faSymLink attribute is
          not (FPC warns about it and not every filesystem fills it in). }
        if FileIsSymlink(Path) then Continue;
        if AlreadyCached(Path) then Continue;
        FWork.Add(Path);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  end;
end;

function TAppIconPrefetcher.AlreadyCached(const APath: string): Boolean;
var
  Key: string;
begin
  Key := AppIconCacheKey(APath);
  Result := (Key <> '') and FileExists(FDir + IconCacheFileName(Key));
end;

function TAppIconPrefetcher.Step(AMax: Integer): Boolean;
var
  N: Integer;
  Path, Key: string;
  Png: TBytes;
begin
  Result := False;
  if FStopped then Exit;
  if not FCollected then
  begin
    Collect;
    if FWork.Count = 0 then Exit;
  end;
  N := 0;
  while (N < AMax) and (FWork.Count > 0) and (not FStopped) do
  begin
    Path := FWork[0];
    FWork.Delete(0);
    Inc(N);
    try
      { The bundle's own .icns is a plain file: reading it needs no AppKit and
        no main-thread icon service, so the sweep stays cheap even on a cold
        cache. Only bundles without a readable PNG go to the fallback queue. }
      if TzBundleIconPng(Path, IconCachedPx, Png) then
      begin
        Key := AppIconCacheKey(Path);
        if Key <> '' then
          CacheAppIconFromPng(FDir, Key, Png);
      end
      else
        FFallbacks.Add(Path);
    except
      { One unreadable bundle must not stop the sweep. }
      FFallbacks.Add(Path);
    end;
  end;
  Result := FWork.Count > 0;
end;

function TIconCache.PurgeAppGlyphs: Integer;
var
  Search: TSearchRec;
  Path: string;
begin
  Result := 0;
  if (FDir = '') or (not DirectoryExists(FDir)) then Exit;
  if FindFirst(FDir + 'app_*.png', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then Continue;
      Path := FDir + Search.Name;
      if DeleteFile(Path) then Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TIconCache.PurgeBaseGlyphs: Integer;
var
  Search: TSearchRec;
  Path: string;
begin
  Result := 0;
  if (FDir = '') or (not DirectoryExists(FDir)) then Exit;
  if FindFirst(FDir + 'base_*.png', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      Path := FDir + Search.Name;
      if DeleteFile(Path) then Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure TIconCacheSize(ADir: string; out ABytes: Int64; out AFiles: Integer);
var
  Search: TSearchRec;
  Dir: string;
begin
  ABytes := 0;
  AFiles := 0;
  Dir := IncludeTrailingPathDelimiter(ADir);
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(Dir + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then Continue;
      Inc(ABytes, Search.Size);
      Inc(AFiles);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TIconCacheClear(ADir: string): Integer;
var
  Search: TSearchRec;
  Dir, Path: string;
begin
  Result := 0;
  Dir := IncludeTrailingPathDelimiter(ADir);
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(Dir + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then Continue;
      Path := Dir + Search.Name;
      if DeleteFile(Path) then Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TIconCache.PathFor(const AExt: string): string;
var
  N: string;
begin
  Result := '';
  { No directory, no cache file. Returning a bare name here would make callers
    write into whatever the process working directory happens to be. }
  if FDir = '' then Exit;
  N := IconCacheFileName(AExt);
  if N = '' then Exit;
  Result := FDir + N;
end;

{ ---------------------------------------------------------------------------
  Probe files and cache location
  --------------------------------------------------------------------------- }

{ A real, existing file with this extension, for the platform to resolve an icon
  from. NSWorkspace's iconForFile returns the coloured, fully styled glyph; its
  iconForFileType returns the type's template outline, which is why every
  document row looked like a blank sheet. The probe files are empty, created once
  per extension, and left for the session. }
function TzIconProbePath(const AExt: string): string;
var
  E, Dir, P: string;
  H: THandle;
begin
  Result := '';
  E := LowerCase(Trim(AExt));
  while (E <> '') and (E[1] = '.') do Delete(E, 1, 1);
  if E = '' then Exit;
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'TyZip-iconprobe' + PathDelim;
  ForceDirectories(Dir);
  P := Dir + 'probe.' + E;
  if FileExists(P) then Exit(P);
  H := FileCreate(P);
  if H <> THandle(-1) then FileClose(H);
  if FileExists(P) then Result := P;
end;

{ Where the on-disk icon cache lives. Preferred: an 'iconcache' folder beside the
  settings file. Not every environment lets an app create a subdirectory in the
  config folder (sandboxed or TCC-managed home, a managed Mac), and icons are
  only a cache -- so the OS temp root is the fallback, where the app's own
  environment always allows a write. Tried ONCE per run: a failure here just
  means icons resolve live. }
function ChooseIconCacheDir: string;
var
  Candidates: array[0..1] of string;
  I: Integer;
begin
  Candidates[0] := TzConfigDir + 'iconcache';
  Candidates[1] := IncludeTrailingPathDelimiter(GetTempDir) + 'TyZip-iconcache';
  for I := 0 to High(Candidates) do
  begin
    if DirectoryExists(Candidates[I]) then Exit(Candidates[I]);
    try
      if ForceDirectories(Candidates[I]) then Exit(Candidates[I]);
    except
      { try the next candidate }
    end;
  end;
  Result := '';
end;

end.
