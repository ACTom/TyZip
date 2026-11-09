program unit_extract;
{$mode objfpc}{$H+}
{ Extraction policy: destination resolution, conflict naming, and the
  delete-after decision.

  These are the parts of extracting that are easy to get subtly wrong and
  impossible to notice afterwards: a smart folder that doubles a name, a
  "rename" that overwrites the file it was meant to preserve, a delete that
  removes the archive when the extraction did not actually happen. }
uses
  SysUtils, Classes, Process, tzip.extract;

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
  TestDeleteAfter;

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.