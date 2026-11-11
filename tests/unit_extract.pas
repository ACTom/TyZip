program unit_extract;
{$mode objfpc}{$H+}
{ Extraction policy: destination resolution, conflict naming, and the
  delete-after decision.

  These are the parts of extracting that are easy to get subtly wrong and
  impossible to notice afterwards: a smart folder that doubles a name, a
  "rename" that overwrites the file it was meant to preserve, a delete that
  removes the archive when the extraction did not actually happen. }
uses
  SysUtils, Classes, Process, tzip.extract
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

var
  Fails, Passes: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant]));
  end;
end;

function Opt(const ADest: string): TExtractOptions;
begin
  Result := DefaultExtractOptions(ADest);
end;

{ Build entries the way a listing would: a name ending in '/' is a directory. }
function SmartEntries(const ANames: array of string): TExtractEntryArray;
var
  I: Integer;
  N: string;
begin
  SetLength(Result, Length(ANames));
  for I := 0 to High(ANames) do
  begin
    N := ANames[I];
    Result[I].Name := N;
    Result[I].IsDir := (N <> '') and (N[Length(N)] = '/');
  end;
end;

{ --- smart folder ------------------------------------------------------- }

procedure TestSmartFolderName;
begin
  EqStr(SmartFolderName('/tmp/photos.zip'), 'photos', 'smart: simple');
  EqStr(SmartFolderName('/a/b/report.7z'), 'report', 'smart: with dirs');
  { A compound name must lose the whole chain, not just the last suffix. }
  EqStr(SmartFolderName('/tmp/photos.tar.gz'), 'photos', 'smart: tar.gz');
  EqStr(SmartFolderName('/tmp/photos.tar.bz2'), 'photos', 'smart: tar.bz2');
  EqStr(SmartFolderName('/tmp/photos.tar.xz'), 'photos', 'smart: tar.xz');
  EqStr(SmartFolderName('/tmp/data.7z.001'), 'data.7z', 'smart: first volume');
  EqStr(SmartFolderName(''), '', 'smart: empty');
  EqStr(SmartFolderName('/tmp/noext'), 'noext', 'smart: no extension');
end;

procedure TestResolveExtractDir;
var
  O: TExtractOptions;
begin
  { Plain destination: files land exactly there. }
  O := Opt('/tmp/out');
  EqStr(ResolveExtractDir('/tmp/photos.zip', O),
    IncludeTrailingPathDelimiter('/tmp/out'), 'resolve: plain destination');

  { Smart folder: one level deeper, named after the archive. }
  O := Opt('/tmp/out');
  O.SmartFolder := True;
  EqStr(ResolveExtractDir('/tmp/photos.zip', O),
    '/tmp/out/photos/', 'resolve: smart folder');

  { A trailing separator in the destination must not become a double one. }
  O := Opt('/tmp/out/');
  O.SmartFolder := True;
  EqStr(ResolveExtractDir('/tmp/photos.zip', O),
    '/tmp/out/photos/', 'resolve: trailing slash tolerated');

  { An archive with no usable name falls back to the plain destination rather
    than making a folder called "". }
  O := Opt('/tmp/out');
  O.SmartFolder := True;
  EqStr(ResolveExtractDir('', O), IncludeTrailingPathDelimiter('/tmp/out'),
    'resolve: unnamed archive');
end;

{ --- conflict naming ---------------------------------------------------- }

procedure Touch(const APath: string);
var
  H: THandle;
begin
  ForceDirectories(ExtractFileDir(APath));
  H := FileCreate(APath);
  if H <> THandle(-1) then FileClose(H);
end;

procedure TestUniquePath;
var
  P: string;
begin
  { A free path is returned unchanged. This matters because callers use it to
    decide whether a rename is needed at all. }
  EqStr(UniquePath(Root + '/free.txt'), Root + '/free.txt', 'unique: free path');

  { The first collision skips past the existing file. }
  P := Root + '/taken.txt';
  Touch(P);
  EqStr(UniquePath(P), Root + '/taken (2).txt', 'unique: first collision');

  { The next one continues the sequence instead of nesting parentheses. }
  Touch(Root + '/taken (2).txt');
  EqStr(UniquePath(P), Root + '/taken (3).txt', 'unique: second collision');

  { A file whose own name already ends in a number continues the sequence
    rather than nesting parentheses into "photo (2) (2).png". }
  Touch(Root + '/photo (2).png');
  EqStr(UniquePath(Root + '/photo (2).png'), Root + '/photo (3).png',
    'unique: numbered name continues the sequence');

  { A directory blocks the name just like a file does. }
  ForceDirectories(Root + '/folder');
  Check(UniquePath(Root + '/folder') <> Root + '/folder',
    'unique: a directory also collides');

  EqStr(UniquePath(''), '', 'unique: empty');
end;

{ --- entry names -------------------------------------------------------- }

procedure TestEntryNames;
begin
  Check(ExtractEntryNameIsSafe('folder/file.txt'), 'name: nested path');
  Check(ExtractEntryNameIsSafe('file.txt'), 'name: bare file');
  Check(ExtractEntryNameIsSafe('a b/c d.txt'), 'name: spaces');
  Check(not ExtractEntryNameIsSafe('../escape.txt'), 'name: rejects a leading ..');
  Check(not ExtractEntryNameIsSafe('a/../../escape.txt'), 'name: rejects .. in the middle');
  Check(not ExtractEntryNameIsSafe('/etc/passwd'), 'name: rejects an absolute path');
  Check(not ExtractEntryNameIsSafe('C:/windows'), 'name: rejects a drive prefix');
  Check(not ExtractEntryNameIsSafe(''), 'name: empty is not safe');
  { ".." as a whole segment, not as a prefix of a real name. }
  Check(ExtractEntryNameIsSafe('..hidden/file'), 'name: dot-dot prefix is a name');
  Check(ExtractEntryNameIsSafe('a/..b/c'), 'name: ..b is a name');

  EqStr(ExtractEntryPath('/out', 'docs/readme.txt'),
    '/out' + PathDelim + 'docs' + PathDelim + 'readme.txt', 'path: nested');
  EqStr(ExtractEntryPath('/out/', 'readme.txt'),
    '/out' + PathDelim + 'readme.txt', 'path: trailing separator tolerated');
  EqStr(ExtractEntryPath('/out', '../x'), '', 'path: unsafe name has no path');
  EqStr(ExtractEntryPath('', 'x'), '', 'path: no destination has no path');
end;

{ --- conflict policy ---------------------------------------------------- }

{ The regression that matters: the destination folder also holds files this
  archive knows nothing about. Whatever the policy, those must not change. }
procedure TestConflictPolicy;
var
  Dir: string;
  Entries: TExtractEntryArray;
  Keep: TExtractEntryKeep;
  N: Integer;
begin
  { Overwrite: the engine replaces the colliding file itself, and this step must
    not touch anything -- not even the file it could delete. }
  Dir := Root + '/c1';
  ForceDirectories(Dir);
  Touch(Dir + '/a.txt');
  Touch(Dir + '/unrelated.txt');
  SetLength(Entries, 2);
  Entries[0].Name := 'a.txt';
  Entries[1].Name := 'b.txt';
  N := ResolveExtractConflicts(Dir, Entries, ecOverwrite, Keep);
  Check(N = 1, 'conflict: overwrite counts the collision');
  Check(Keep[0] and Keep[1], 'conflict: overwrite keeps every entry');
  Check(FileExists(Dir + '/a.txt'), 'conflict: overwrite leaves the file to the engine');
  Check(FileExists(Dir + '/unrelated.txt'), 'conflict: overwrite keeps unrelated files');

  { Skip: the colliding entry is marked not to be written; the other one and the
    unrelated file stay as they are. }
  Dir := Root + '/c2';
  ForceDirectories(Dir + '/sub');
  Touch(Dir + '/b.txt');
  Touch(Dir + '/sub/c.txt');
  Touch(Dir + '/unrelated.txt');
  SetLength(Entries, 3);
  Entries[0].Name := 'b.txt';
  Entries[1].Name := 'new.txt';
  Entries[2].Name := 'sub/c.txt';
  N := ResolveExtractConflicts(Dir, Entries, ecSkip, Keep);
  Check(N = 2, 'conflict: skip counts both colliding entries');
  Check(not Keep[0], 'conflict: skip drops the top-level collision');
  Check(Keep[1], 'conflict: skip keeps a free name');
  Check(not Keep[2], 'conflict: skip drops a nested collision');
  Check(FileExists(Dir + '/b.txt'), 'conflict: skip keeps the existing file');
  Check(FileExists(Dir + '/sub/c.txt'), 'conflict: skip keeps the nested file');
  Check(FileExists(Dir + '/unrelated.txt'), 'conflict: skip keeps unrelated files');

  { Rename: the existing file moves aside under a numbered name, the entry is
    still written, and the unrelated file is untouched. }
  Dir := Root + '/c3';
  ForceDirectories(Dir);
  Touch(Dir + '/d.txt');
  Touch(Dir + '/unrelated.txt');
  SetLength(Entries, 2);
  Entries[0].Name := 'd.txt';
  Entries[1].Name := 'e.txt';
  N := ResolveExtractConflicts(Dir, Entries, ecRename, Keep);
  Check(N = 1, 'conflict: rename counts the collision');
  Check(Keep[0] and Keep[1], 'conflict: rename keeps every entry');
  Check(not FileExists(Dir + '/d.txt'), 'conflict: rename moves the original');
  Check(FileExists(Dir + '/d (2).txt'), 'conflict: rename leaves a numbered copy');
  Check(FileExists(Dir + '/unrelated.txt'), 'conflict: rename keeps unrelated files');

  { Ask: the caller was supposed to ask already; without an answer the safe
    reading is the same as skip. }
  Dir := Root + '/c4';
  ForceDirectories(Dir);
  Touch(Dir + '/e.txt');
  Touch(Dir + '/unrelated.txt');
  SetLength(Entries, 1);
  Entries[0].Name := 'e.txt';
  N := ResolveExtractConflicts(Dir, Entries, ecAsk, Keep);
  Check(N = 1, 'conflict: ask counts the collision');
  Check(not Keep[0], 'conflict: ask skips until it is answered');
  Check(FileExists(Dir + '/e.txt'), 'conflict: ask keeps the file');
  Check(FileExists(Dir + '/unrelated.txt'), 'conflict: ask keeps unrelated files');

  { An entry that is already a folder merges; it is never a collision. }
  Dir := Root + '/c5';
  ForceDirectories(Dir + '/folder');
  SetLength(Entries, 1);
  Entries[0].Name := 'folder';
  Entries[0].IsDir := True;
  Check(ResolveExtractConflicts(Dir, Entries, ecSkip, Keep) = 0,
    'conflict: a directory entry is not a collision');
  Check(Keep[0], 'conflict: a directory entry is kept');

  { An empty or missing destination has nothing to collide with. }
  SetLength(Entries, 1);
  Entries[0].Name := 'x.txt';
  Check(ResolveExtractConflicts('', Entries, ecOverwrite, Keep) = 0,
    'conflict: empty destination is a no-op');
  Check(Keep[0], 'conflict: empty destination keeps the entry');
  Check(ResolveExtractConflicts(Root + '/nope', Entries, ecOverwrite, Keep) = 0,
    'conflict: missing destination is a no-op');

  { An unsafe name is left to the engine, which refuses it; no disk path built
    from it may be touched. }
  Dir := Root + '/c6';
  ForceDirectories(Dir);
  Touch(Root + '/outside.txt');
  SetLength(Entries, 1);
  Entries[0].Name := '../outside.txt';
  Check(ResolveExtractConflicts(Dir, Entries, ecRename, Keep) = 0,
    'conflict: an unsafe name is not a collision');
  Check(Keep[0], 'conflict: an unsafe name is left to the engine');
  Check(FileExists(Root + '/outside.txt'), 'conflict: unsafe name touches nothing');
end;

{ --- defaults ----------------------------------------------------------- }

procedure TestDefaults;
var
  O: TExtractOptions;
begin
  O := DefaultExtractOptions('/tmp/out');
  EqStr(O.Destination, '/tmp/out', 'default: destination kept');
  { Finder's rule: never replace a file without asking. }
  Check(O.Conflict = ecAsk, 'default: ask before overwriting');
  Check(not O.SmartFolder, 'default: no smart folder');
  Check(not O.DeleteArchiveAfter, 'default: archive is kept');
  Check(not O.OpenAfter, 'default: does not open after');
end;

{ --- shortcuts ---------------------------------------------------------- }

procedure TestQuickDestinations;
var
  D, L: TStringArray;
  I: Integer;
begin
  D := QuickDestinations;
  L := QuickDestinationLabels;
  Check(Length(D) = Length(L), 'shortcuts: one label per destination');
  Check(Length(D) >= 3, 'shortcuts: several offered');
  for I := 0 to High(D) do
    Check(L[I] <> '', Format('shortcuts: entry %d is labelled', [I]));
  { The three fixed folders are under the home directory. }
  Check(Pos(GetUserDir, D[0]) = 1, 'shortcuts: first is under home');
  { The last one is the empty path, which the caller reads as "beside the
    archive" -- it cannot be a fixed location. }
  EqStr(D[High(D)], '', 'shortcuts: last one is beside the archive');
  Check(Length(D) = 4, 'shortcuts: exactly four');
end;

{ --- fallback destination ------------------------------------------------ }

procedure TestFallbackDir;
begin
  { The configured default wins when it is set. }
  EqStr(ResolveFallbackExtractDir('/default', '/archive/dir', '/Users/x'),
    '/default', 'fallback: configured default first');
  { No configured default: beside the archive. }
  EqStr(ResolveFallbackExtractDir('', '/archive/dir', '/Users/x'),
    '/archive/dir', 'fallback: the archive folder');
  { An archive with no folder (a nested/temporary source) falls back to home. }
  EqStr(ResolveFallbackExtractDir('', '', '/Users/x'),
    '/Users/x', 'fallback: home last');
  { Trailing separators are normalised so the caller can concatenate. }
  EqStr(ResolveFallbackExtractDir('  /default/  ', '', ''), '/default',
    'fallback: trailing separator and spaces stripped');
  EqStr(ResolveFallbackExtractDir('', '', ''), '', 'fallback: nothing at all');
end;

{ --- dialog destination -------------------------------------------------- }

procedure TestDialogExtractDir;
begin
  { Extracting a file the user right-clicked should offer the folder it sits
    in, not the configured default (ticket 38). }
  EqStr(ResolveDialogExtractDir('/archive/dir', '/default', '/Users/x'),
    '/archive/dir', 'dialog: archive folder first');
  { No archive folder (a nested archive opened from another archive): the
    configured default is still the fallback. }
  EqStr(ResolveDialogExtractDir('', '/default', '/Users/x'), '/default',
    'dialog: configured default when the archive has no folder');
  EqStr(ResolveDialogExtractDir('', '', '/Users/x'), '/Users/x',
    'dialog: home last');
  EqStr(ResolveDialogExtractDir(' /archive/dir/ ', '', ''), '/archive/dir',
    'dialog: trailing separator stripped');
end;

{ --- smart extract layout ----------------------------------------------- }

procedure TestSmartPlan;
var
  P: TSmartPlan;
begin
  Check(not Opt('/tmp/out').SmartExtract, 'smart plan: option off by default');

  { One root folder: its contents land directly in the destination. }
  P := TzSmartPlan('/tmp/photos.zip', '/tmp/out',
    SmartEntries(['photos/a.jpg', 'photos/sub/b.jpg']));
  Check(P.Layout = slStripOneRoot, 'smart plan: one root folder strips');
  EqStr(P.Dest, IncludeTrailingPathDelimiter('/tmp/out'), 'smart plan: dest');
  EqStr(P.Root, 'photos', 'smart plan: root name');

  { The folder name matching the archive stem still strips: that is the point. }
  P := TzSmartPlan('/tmp/photos.zip', '/tmp/out',
    SmartEntries(['photos/a.jpg']));
  Check(P.Layout = slStripOneRoot, 'smart plan: root equals stem still strips');

  { One root file: written directly. }
  P := TzSmartPlan('/tmp/data.zip', '/tmp/out', SmartEntries(['data.txt']));
  Check(P.Layout = slDirect, 'smart plan: single file direct');
  EqStr(P.Dest, IncludeTrailingPathDelimiter('/tmp/out'), 'smart plan: direct dest');

  { Several roots: a folder named after the archive, two suffixes stripped. }
  P := TzSmartPlan('/tmp/photos.tar.gz', '/tmp/out',
    SmartEntries(['photos/a.jpg', 'docs/b.txt']));
  Check(P.Layout = slChildFolder, 'smart plan: several roots make a folder');
  EqStr(P.Dest, '/tmp/out/photos/', 'smart plan: child folder name');

  { macOS junk does not make a second root. }
  P := TzSmartPlan('/tmp/photos.zip', '/tmp/out',
    SmartEntries(['photos/a.jpg', '__MACOSX/._a.jpg', '.DS_Store']));
  Check(P.Layout = slStripOneRoot, 'smart plan: junk ignored for roots');

  { Empty and junk-only archives write nothing. }
  P := TzSmartPlan('/tmp/empty.zip', '/tmp/out', SmartEntries([]));
  Check(P.Layout = slNothing, 'smart plan: empty archive');
  EqStr(P.Dest, '', 'smart plan: empty archive has no dest');
  P := TzSmartPlan('/tmp/junk.zip', '/tmp/out',
    SmartEntries(['__MACOSX/x', '.DS_Store']));
  Check(P.Layout = slNothing, 'smart plan: junk only');

  { Unsafe names take no part in the root set. }
  P := TzSmartPlan('/tmp/a.zip', '/tmp/out',
    SmartEntries(['a/x.txt', '../evil', '/abs/path']));
  Check(P.Layout = slStripOneRoot, 'smart plan: only safe roots count');
end;

procedure TestSmartTargets;
var
  P: TSmartPlan;
  T: TExtractEntryArray;
begin  P := TzSmartPlan('/tmp/photos.zip', '/tmp/out',
    SmartEntries(['photos/a.jpg', 'photos/sub/b.jpg']));
  EqStr(TzSmartTargetPath(P, 'photos/a.jpg'), 'a.jpg', 'smart target: stripped');
  EqStr(TzSmartTargetPath(P, 'photos/sub/b.jpg'), 'sub/b.jpg', 'smart target: nested');
  EqStr(TzSmartTargetPath(P, 'photos/'), '', 'smart target: root folder itself');
  EqStr(TzSmartTargetPath(P, '__MACOSX/._a.jpg'), '', 'smart target: junk');
  EqStr(TzSmartTargetPath(P, 'a/.DS_Store'), '', 'smart target: nested .DS_Store');
  EqStr(TzSmartTargetPath(P, '../evil'), '', 'smart target: unsafe');

  { Entries keep their order; unwritable ones get an empty target. }
  T := TzSmartTargetEntries(P, SmartEntries(['photos/a.jpg', 'photos/']));
  Check(Length(T) = 2, 'smart target entries: index-aligned');
  EqStr(T[0].Name, 'a.jpg', 'smart target entries: file target');
  EqStr(T[1].Name, '', 'smart target entries: directory target empty');

  P := TzSmartPlan('/tmp/data.zip', '/tmp/out', SmartEntries(['data.txt']));
  EqStr(TzSmartTargetPath(P, 'data.txt'), 'data.txt', 'smart target: direct');

  P := TzSmartPlan('/tmp/many.zip', '/tmp/out', SmartEntries(['a.txt', 'b.txt']));
  EqStr(TzSmartTargetPath(P, 'a.txt'), 'a.txt', 'smart target: child folder file');

  P := TzSmartPlan('/tmp/empty.zip', '/tmp/out', SmartEntries([]));
  EqStr(TzSmartTargetPath(P, 'a.txt'), '', 'smart target: nothing planned');
end;

{ --- dialog mode rules ------------------------------------------------ }

procedure TestSmartModes;
var
  Smart, Folder: Boolean;
begin
  TzResolveExtractModes(True, False, False, Smart, Folder);
  Check(Smart and not Folder, 'modes: smart checked');
  TzResolveExtractModes(False, True, False, Smart, Folder);
  Check(not Smart and Folder, 'modes: folder checked');
  { Two layout modes at once: smart wins, the folder one is greyed out anyway. }
  TzResolveExtractModes(True, True, False, Smart, Folder);
  Check(Smart and not Folder, 'modes: smart wins over folder');
  { Smart extraction needs the whole archive. }
  TzResolveExtractModes(True, False, True, Smart, Folder);
  Check(not Smart and not Folder, 'modes: partial selection disables smart');
  TzResolveExtractModes(False, True, True, Smart, Folder);
  Check(not Smart and Folder, 'modes: partial keeps the folder option');
  TzResolveExtractModes(False, False, False, Smart, Folder);
  Check(not Smart and not Folder, 'modes: neither');
end;

{ --- partial selection -------------------------------------------------- }

procedure TestPartialExtraction;
begin
  Check(not TzIsPartialExtraction(True, 0), 'partial: extract all is whole');
  Check(not TzIsPartialExtraction(True, 3),
    'partial: extract all ignores a leftover selection');
  Check(not TzIsPartialExtraction(False, 0),
    'partial: nothing selected means the whole archive');
  Check(TzIsPartialExtraction(False, 3), 'partial: a selection is partial');
end;

{ --- commit rules and real-listing shapes ------------------------------ }

function EntriesOf(const ANames: array of string;
  const ADirs: array of Boolean): TExtractEntryArray;
var
  I: Integer;
begin
  SetLength(Result, Length(ANames));
  for I := 0 to High(ANames) do
  begin
    Result[I].Name := ANames[I];
    if I <= High(ADirs) then Result[I].IsDir := ADirs[I];
  end;
end;

procedure TestSmartPackageRoot;
var
  P: TSmartPlan;
  T: TExtractEntryArray;
begin
  { A single top-level folder is flattened -- unless it is a macOS package:
    a ZIP holding a.app must keep a.app, not dump its insides. }
  P := TzSmartPlan('/tmp/a.zip', '/tmp/out',
    EntriesOf(['a.app', 'a.app/Contents', 'a.app/Contents/Info.plist'],
      [True, True, False]));
  Check(P.Layout = slDirect, 'smart: a single .app root is not stripped');
  EqStr(TzSmartTargetPath(P, 'a.app/Contents/Info.plist'),
    'a.app/Contents/Info.plist', 'smart: the bundle keeps its name');
  T := TzSmartTargetEntries(P,
    EntriesOf(['a.app/Contents/Info.plist'], [False]));
  EqStr(T[0].Name, 'a.app/Contents/Info.plist',
    'smart entries: bundle path kept');

  P := TzSmartPlan('/tmp/f.zip', '/tmp/out',
    EntriesOf(['Foo.framework/Versions/A/Foo'], [False]));
  Check(P.Layout = slDirect, 'smart: a framework root is kept');

  { A plain single folder still flattens: that is the whole point. }
  P := TzSmartPlan('/tmp/photos.zip', '/tmp/out',
    EntriesOf(['photos', 'photos/a.jpg'], [True, False]));
  Check(P.Layout = slStripOneRoot, 'smart: a plain folder still flattens');
end;

procedure TestSmartDirectoryTargets;
var
  P: TSmartPlan;
  Es, T: TExtractEntryArray;
  K: TExtractEntryKeep;
begin
  { Real listings report a directory through IsDir; the name has no trailing
    slash. A directory is never a file target. }
  Es := EntriesOf(['photos', 'photos/a.jpg'], [True, False]);
  P := TzSmartPlan('/tmp/photos.zip', '/tmp/out', Es);
  T := TzSmartTargetEntries(P, Es);
  EqStr(T[0].Name, '', 'smart target entries: directory target empty');
  EqStr(T[1].Name, 'a.jpg', 'smart target entries: file stripped');

  SetLength(K, 2);
  K[0] := True;
  K[1] := True;
  TzSmartDropEmptyTargets(T, K);
  Check(not K[0], 'smart drop: empty target is not written');
  Check(K[1], 'smart drop: a real file stays');
end;

type
  TCancelProbe = class
  public
    Calls: Integer;
    function Cancelled: Boolean;
  end;

function TCancelProbe.Cancelled: Boolean;
begin
  Inc(Calls);
  { Let the first file move, then cancel. }
  Result := Calls > 1;
end;

procedure TestCommitCancel;
var
  Probe: TCancelProbe;
  Staging, Dest: string;
  I, Moved: Integer;
begin
  Staging := Root + '/cancel-stage';
  Dest := Root + '/cancel-dest';
  ForceDirectories(Staging);
  ForceDirectories(Dest);
  for I := 1 to 3 do
    with TStringList.Create do
    begin
      Text := 'x';
      SaveToFile(Staging + '/f' + IntToStr(I) + '.txt');
      Free;
    end;
  Probe := TCancelProbe.Create;
  try
    Check(not TzCommitStagedTree(Staging, Dest, '', True, @Probe.Cancelled),
      'commit: a cancel stops the move');
    Check(Probe.Calls > 0, 'commit: cancel is asked while moving');
    Moved := 0;
    for I := 1 to 3 do
      if FileExists(Dest + '/f' + IntToStr(I) + '.txt') then Inc(Moved);
    Check(Moved < 3, 'commit: cancel leaves some files staged');
  finally
    Probe.Free;
  end;
end;

{$IFDEF UNIX}
procedure TestCommitSymlink;
var
  Staging, Dest, TargetName, LinkPath: string;
begin
  { A directory symlink in an archive must not be walked into: the staged tree
    would list the same files twice and the commit would fail half-way. }
  Staging := Root + '/link-stage';
  Dest := Root + '/link-dest';
  ForceDirectories(Staging + '/real');
  with TStringList.Create do
  begin
    Text := 'x';
    SaveToFile(Staging + '/real/a.txt');
    Free;
  end;
  TargetName := 'real';
  LinkPath := Staging + '/link';
  Check(fpSymLink(PChar(TargetName), PChar(LinkPath)) = 0,
    'commit: symlink fixture');
  Check(TzCommitStagedTree(Staging, Dest, '', True),
    'commit: a symlinked directory does not break the move');
  Check(FileExists(Dest + '/real/a.txt'), 'commit: real file moved');
  Check(DirectoryExists(Dest + '/link') or FileExists(Dest + '/link'),
    'commit: the link itself moved');
end;
{$ENDIF}

{ --- delete after ------------------------------------------------------- }

procedure TestDeleteAfter;
var
  P: string;
begin
  P := Root + '/gone.zip';
  Touch(P);
  Check(DeleteArchiveAfterExtract(P), 'delete: removed');
  Check(not FileExists(P), 'delete: really gone');
  { Calling it again is not an error: the caller may retry after a crash. }
  Check(DeleteArchiveAfterExtract(P), 'delete: missing file is not a failure');
  { No path means nothing to delete, which is not a failure for the caller. }
  Check(DeleteArchiveAfterExtract(''), 'delete: empty path is not a failure');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-extract-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);

  TestSmartFolderName;
  TestResolveExtractDir;
  TestUniquePath;
  TestEntryNames;
  TestConflictPolicy;
  TestFallbackDir;
  TestDialogExtractDir;
  TestDefaults;
  TestQuickDestinations;
  TestSmartPlan;
  TestSmartTargets;
  TestSmartPackageRoot;
  TestSmartModes;
  TestPartialExtraction;
  TestSmartDirectoryTargets;
  TestCommitCancel;
  {$IFDEF UNIX}TestCommitSymlink;{$ENDIF}
  TestDeleteAfter;

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.