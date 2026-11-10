{ How extraction decides where the files go and what to do about collisions.

  This is deliberately separate from the dialog and from the engine: the parts
  that are easy to get wrong -- which folder a "smart" destination is, what
  "rename" produces, whether a name is safe to write -- are pure functions here
  and can be tested without a window or a real archive. }
unit tzip.extract;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { What to do when the destination already has a file of that name. }
  TExtractConflict = (
    ecAsk,       { Stop and let the caller ask; the engine cannot resume, so
                   callers resolve this before extraction starts. }
    ecOverwrite, { Replace the existing file. }
    ecSkip,      { Leave the existing file alone. }
    ecRename     { Write beside it under a numbered name. }
  );

  { Everything the extract dialog collects. }
  TExtractOptions = record
    Destination: string;
    { Put the files in a new folder named after the archive. }
    SmartFolder: Boolean;
    { Lay the archive's own tree out by structure: one root folder is stripped,
      a single file is written directly, several roots get a folder named after
      the archive. Mutually exclusive with SmartFolder. }
    SmartExtract: Boolean;
    Conflict: TExtractConflict;
    { Remove the archive once the extraction succeeded. }
    DeleteArchiveAfter: Boolean;
    OpenAfter: Boolean;
    Password: string;
  end;

function DefaultExtractOptions(const ADestination: string): TExtractOptions;

{ The folder the files actually go into, given the option to wrap them in a
  new one.

  A smart folder is only created when it would not swallow the files: extracting
  "photos.zip" whose single top-level entry is already a folder called "photos"
  must not produce photos/photos. }
function ResolveExtractDir(const AArchivePath: string;
  const AOptions: TExtractOptions): string;

{ The base name a smart folder gets: the archive's own name without the
  extension chain ("photos.tar.gz" -> "photos"). }
function SmartFolderName(const AArchivePath: string): string;

{ A free path beside APath: "a.txt" -> "a (2).txt", "a (2).txt" -> "a (3).txt".
  The first call for an existing APath never returns APath itself. }
function UniquePath(const APath: string): string;

{ The shortcut destinations offered in the dialog, in display order. }
function QuickDestinations: TStringArray;

{ The same list with a caption for each, so the dialog and the tests agree on
  what the entries are. }
function QuickDestinationLabels: TStringArray;

{ Remove APath after a successful extraction. Best effort: a file the user has
  since opened elsewhere simply stays. }
function DeleteArchiveAfterExtract(const AArchivePath: string): Boolean;

{ Where an extraction goes when no dialog has chosen a folder: the configured
  default, else the folder the archive itself lives in, else the user's home.
  Each may be empty -- an archive that is not on disk has no folder -- which is
  why the last fallback exists. }
function ResolveFallbackExtractDir(const ADefaultDir, AArchiveDir,
  AUserDir: string): string;

{ Where the Extract dialog starts. Extracting an archive that is on disk starts
  beside it; the configured default folder and the user's home are only the
  fallbacks for an archive with no filesystem location (a nested archive opened
  from inside another archive) (ticket 38). }
function ResolveDialogExtractDir(const AArchiveDir, AConfiguredDefault,
  AUserDir: string): string;

{ One entry an extraction is about to write, exactly as the archive names it.

  The conflict policy works on these, not on the destination folder: the folder
  holds files that have nothing to do with this archive, and a policy must never
  touch them. }
type
  TExtractEntry = record
    Name: string;            { path inside the archive, '/'-separated }
    IsDir: Boolean;
  end;
  TExtractEntryArray = array of TExtractEntry;
  { Index-aligned with TExtractEntryArray: False means "do not write this one". }
  TExtractEntryKeep = array of Boolean;

{ True when AEntryName can be written under a destination folder as it is: no
  absolute name, no drive prefix, and no '..' segment that would climb out. }
function ExtractEntryNameIsSafe(const AEntryName: string): Boolean;

{ Where AEntryName lands under ADestDir, or '' when the name is unsafe or empty.
  A trail of separators or a '\' is tolerated; the result uses PathDelim. }
function ExtractEntryPath(const ADestDir, AEntryName: string): string;

{ Resolve the conflict policy for the entries that are about to be written.

  The engine always overwrites and cannot stop mid-run to ask, so the decision
  has to be made before it starts -- and it has to be made for THE ENTRIES BEING
  WRITTEN, never for whatever else happens to live in the destination folder.
  Walking the destination (what this used to do) turned "overwrite" into "delete
  every existing file in the folder": the default destination is the archive's
  own folder, so extracting one archive into ~/Downloads emptied it.

  ecOverwrite  Nothing to do: the engine replaces each colliding file itself.
  ecSkip       The colliding entries are marked not to be written.
  ecRename     Each colliding existing file is moved aside to a numbered name,
               so both it and the archive's entry survive; the entry keeps its
               own name. If moving the existing file fails, the entry is skipped
               instead -- the file that is already on disk must not be lost.
  ecAsk        Treated as ecSkip: the caller is expected to have asked first.

  AKeep is index-aligned with AEntries; only entries it marks True may be handed
  to the engine. Returns the number of collisions found. }
function ResolveExtractConflicts(const ADestDir: string;
  const AEntries: TExtractEntryArray; AConflict: TExtractConflict;
  out AKeep: TExtractEntryKeep): Integer;

{ Smart extraction: where each entry of the archive ends up when the layout is
  decided from the archive's own structure instead of the user's choice. }
type
  TSmartLayout = (
    slNothing,       { nothing to write: empty archive, or only macOS junk }
    slDirect,        { the single root file lands directly in the destination }
    slStripOneRoot,  { one root folder: its contents land in the destination }
    slChildFolder    { a folder named after the archive holds the entries }
  );
  TSmartPlan = record
    Layout: TSmartLayout;
    Dest: string;    { folder the files finally land in; '' for slNothing }
    Root: string;    { slStripOneRoot: the single top-level segment to strip }
  end;

{ True for the bookkeeping entries smart extraction drops: a path with a
  '__MACOSX' segment, or an entry named '.DS_Store'. }
function TzIsJunkEntry(const AEntryName: string): Boolean;

{ The layout smart extraction uses for an archive whose entries are AEntries.
  ADest is the base destination folder. }
function TzSmartPlan(const AArchivePath, ADest: string;
  const AEntries: TExtractEntryArray): TSmartPlan;

{ Index-aligned with AEntries, with each Name replaced by its path relative to
  APlan.Dest; an entry that will not be written gets an empty Name. }
function TzSmartTargetEntries(const APlan: TSmartPlan;
  const AEntries: TExtractEntryArray): TExtractEntryArray;

{ Where AEntryName is written, relative to APlan.Dest; '' when the entry is
  junk, unsafe, a directory, or the plan writes nothing. }
function TzSmartTargetPath(const APlan: TSmartPlan;
  const AEntryName: string): string;

implementation

function DefaultExtractOptions(const ADestination: string): TExtractOptions;
begin
  Result := Default(TExtractOptions);
  Result.Destination := ADestination;
  { Finder's own default: never silently replace a file. }
  Result.Conflict := ecAsk;
  { Extracting next to an existing folder of the same name should not merge
    into it, which is what a plain destination does. }
  Result.SmartFolder := False;
  Result.SmartExtract := False;
  Result.DeleteArchiveAfter := False;
  Result.OpenAfter := False;
  Result.Password := '';
end;

function SmartFolderName(const AArchivePath: string): string;
var
  N: string;
  E: string;
begin
  Result := '';
  N := ExtractFileName(AArchivePath);
  if N = '' then Exit;
  { Strip the whole chain: "photos.tar.gz" is photos, not photos.tar. }
  E := LowerCase(ExtractFileExt(N));
  if (E = '.gz') or (E = '.bz2') or (E = '.xz') or (E = '.zst') or (E = '.lzma') then
    N := ChangeFileExt(N, '');
  N := ChangeFileExt(N, '');
  Result := N;
end;

function ResolveExtractDir(const AArchivePath: string;
  const AOptions: TExtractOptions): string;
var
  Base, Name: string;
begin
  Base := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(
    AOptions.Destination));
  if not AOptions.SmartFolder then Exit(Base);
  Name := SmartFolderName(AArchivePath);
  if Name = '' then Exit(Base);
  Result := Base + Name + PathDelim;
end;

function UniquePath(const APath: string): string;
var
  Dir, Name, Stem, Ext: string;
  N: Integer;
begin
  if (APath = '') or ((not FileExists(APath)) and (not DirectoryExists(APath))) then
    Exit(APath);
  Dir := ExtractFileDir(APath);
  Name := ExtractFileName(APath);
  Ext := ExtractFileExt(Name);
  Stem := ChangeFileExt(Name, '');
  { "a (2).txt" already ends in a number: continue from it rather than making
    "a (2) (2).txt". }
  if (Length(Stem) > 3) and (Stem[Length(Stem)] = ')') then
  begin
    N := Pos(' (', Stem);
    if N > 0 then
      if StrToIntDef(Copy(Stem, N + 2, Length(Stem) - N - 2), -1) > 0 then
        Stem := Copy(Stem, 1, N - 1);
  end;
  N := 2;
  repeat
    if Dir = '' then
      Result := Format('%s (%d)%s', [Stem, N, Ext])
    else
      Result := IncludeTrailingPathDelimiter(Dir) + Format('%s (%d)%s',
        [Stem, N, Ext]);
    Inc(N);
  until (not FileExists(Result)) and (not DirectoryExists(Result));
end;

function QuickDestinations: TStringArray;
var
  Home: string;
begin
  Home := IncludeTrailingPathDelimiter(GetUserDir);
  Result := nil;
  SetLength(Result, 4);
  Result[0] := Home + 'Desktop';
  Result[1] := Home + 'Downloads';
  Result[2] := Home + 'Documents';
  { Extracting next to the archive is the most common choice of all, so it is
    offered alongside the three fixed folders rather than buried in browsing. }
  Result[3] := '';
end;

function QuickDestinationLabels: TStringArray;
begin
  Result := nil;
  SetLength(Result, 4);
  Result[0] := 'Desktop';
  Result[1] := 'Downloads';
  Result[2] := 'Documents';
  Result[3] := 'Beside the archive';
end;

function ExtractEntryNameIsSafe(const AEntryName: string): Boolean;
var
  P, Seg: string;
  I, Start: Integer;
begin
  Result := False;
  P := StringReplace(Trim(AEntryName), '\', '/', [rfReplaceAll]);
  if P = '' then Exit;
  { An absolute name would land outside the destination. The engine refuses these
    too (SafeJoin); this copy exists so the conflict step does not touch a disk
    path the file will never be written to. }
  if P[1] = '/' then Exit;
  if (Length(P) >= 2) and (P[2] = ':') then Exit;
  { '..' anywhere in the path climbs out of the destination. }
  Start := 1;
  for I := 1 to Length(P) + 1 do
    if (I > Length(P)) or (P[I] = '/') then
    begin
      Seg := Copy(P, Start, I - Start);
      if Seg = '..' then Exit;
      Start := I + 1;
    end;
  Result := True;
end;

function ExtractEntryPath(const ADestDir, AEntryName: string): string;
var
  Rel: string;
begin
  Result := '';
  if ADestDir = '' then Exit;
  if not ExtractEntryNameIsSafe(AEntryName) then Exit;
  Rel := StringReplace(Trim(AEntryName), '\', '/', [rfReplaceAll]);
  while (Rel <> '') and (Rel[1] = '/') do Delete(Rel, 1, 1);
  if Rel = '' then Exit;
  Result := IncludeTrailingPathDelimiter(ADestDir) +
    StringReplace(Rel, '/', PathDelim, [rfReplaceAll]);
end;

function ResolveExtractConflicts(const ADestDir: string;
  const AEntries: TExtractEntryArray; AConflict: TExtractConflict;
  out AKeep: TExtractEntryKeep): Integer;
var
  I: Integer;
  P: string;
begin
  Result := 0;
  SetLength(AKeep, Length(AEntries));
  for I := 0 to High(AKeep) do
    AKeep[I] := True;
  if ADestDir = '' then Exit;
  if not DirectoryExists(ADestDir) then Exit;
  for I := 0 to High(AEntries) do
  begin
    { A folder entry merges into an existing folder; there is nothing to decide.
      Only files can be replaced, skipped or moved aside. }
    if AEntries[I].IsDir then Continue;
    P := ExtractEntryPath(ADestDir, AEntries[I].Name);
    if P = '' then Continue;
    if (not FileExists(P)) and (not DirectoryExists(P)) then Continue;
    Inc(Result);
    case AConflict of
      ecOverwrite:
        { The engine truncates and rewrites the file itself; pre-deleting it would
          only lose the old copy when the extraction later fails. }
        ;
      ecSkip, ecAsk:
        AKeep[I] := False;
      ecRename:
        { The existing file moves aside so both survive. If it cannot be moved,
          skip the entry rather than overwrite it: the user asked for "keep
          both", and losing the file that is already there is the worse outcome. }
        if not RenameFile(P, UniquePath(P)) then
          AKeep[I] := False;
    end;
  end;
end;

function ResolveFallbackExtractDir(const ADefaultDir, AArchiveDir,
  AUserDir: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(Trim(ADefaultDir));
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(Trim(AArchiveDir));
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(Trim(AUserDir));
end;

function ResolveDialogExtractDir(const AArchiveDir, AConfiguredDefault,
  AUserDir: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(Trim(AArchiveDir));
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(Trim(AConfiguredDefault));
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(Trim(AUserDir));
end;

function DeleteArchiveAfterExtract(const AArchivePath: string): Boolean;
begin
  Result := False;
  { No path means there is nothing to delete, which is a success for the caller. }
  if AArchivePath = '' then Exit(True);
  if not FileExists(AArchivePath) then Exit(True);
  try
    Result := DeleteFile(AArchivePath);
  except
    Result := False;
  end;
end;

{ --- smart extraction layout -------------------------------------------- }

function NormalizedEntryName(const AName: string): string;
begin
  Result := StringReplace(Trim(AName), '\', '/', [rfReplaceAll]);
  while (Result <> '') and (Result[1] = '/') do Delete(Result, 1, 1);
end;

function FirstSegmentOf(const ANormalizedName: string): string;
var
  I: Integer;
begin
  I := Pos('/', ANormalizedName);
  if I > 0 then
    Result := Copy(ANormalizedName, 1, I - 1)
  else
    Result := ANormalizedName;
end;

function SegmentCountOf(const ANormalizedName: string): Integer;
var
  I, Start: Integer;
begin
  Result := 0;
  Start := 1;
  for I := 1 to Length(ANormalizedName) + 1 do
    if (I > Length(ANormalizedName)) or (ANormalizedName[I] = '/') then
    begin
      if I > Start then Inc(Result);
      Start := I + 1;
    end;
end;

function TzIsJunkEntry(const AEntryName: string): Boolean;
var
  P, Seg: string;
  I, Start: Integer;
begin
  Result := False;
  P := NormalizedEntryName(AEntryName);
  If P = '' then Exit;
  Start := 1;
  for I := 1 to Length(P) + 1 do
    if (I > Length(P)) or (P[I] = '/') then
    begin
      Seg := Copy(P, Start, I - Start);
      { Finder's resource forks live in __MACOSX/; .DS_Store can appear at any
        depth. Both are noise a smart extraction should not leave behind. }
      if SameText(Seg, '__MACOSX') or SameText(Seg, '.DS_Store') then
        Exit(True);
      Start := I + 1;
    end;
end;

function TzSmartPlan(const AArchivePath, ADest: string;
  const AEntries: TExtractEntryArray): TSmartPlan;
var
  Base, N, Seg: string;
  Roots, RootIsDir: TStringList;
  I, J: Integer;
begin
  Result := Default(TSmartPlan);
  Result.Layout := slNothing;
  Base := ExcludeTrailingPathDelimiter(ADest);
  if Base <> '' then Base := IncludeTrailingPathDelimiter(Base);
  Roots := TStringList.Create;
  RootIsDir := TStringList.Create;
  try
    for I := 0 to High(AEntries) do
    begin
      N := NormalizedEntryName(AEntries[I].Name);
      if N = '' then Continue;
      if TzIsJunkEntry(AEntries[I].Name) then Continue;
      if not ExtractEntryNameIsSafe(AEntries[I].Name) then Continue;
      Seg := FirstSegmentOf(N);
      if Seg = '' then Continue;
      J := Roots.IndexOf(Seg);
      if J < 0 then
      begin
        J := Roots.Add(Seg);
        RootIsDir.Add('0');
      end;
      { A root is a folder when the entries below it go deeper, or when the
        listing also names it as a directory in its own right. }
      if (SegmentCountOf(N) > 1) or AEntries[I].IsDir then
        RootIsDir[J] := '1';
    end;

    if Roots.Count = 0 then
      Exit;                             { slNothing: Dest stays '' }
    if Roots.Count = 1 then
    begin
      Result.Dest := Base;
      if RootIsDir[0] = '1' then
      begin
        Result.Layout := slStripOneRoot;
        Result.Root := Roots[0];
      end
      else
        Result.Layout := slDirect;
      Exit;
    end;

    Result.Layout := slChildFolder;
    Result.Dest := Base + SmartFolderName(AArchivePath) + PathDelim;
  finally
    RootIsDir.Free;
    Roots.Free;
  end;
end;

function TzSmartTargetPath(const APlan: TSmartPlan;
  const AEntryName: string): string;
var
  N, Prefix: string;
begin
  Result := '';
  if APlan.Layout = slNothing then Exit;
  if TzIsJunkEntry(AEntryName) then Exit;
  if not ExtractEntryNameIsSafe(AEntryName) then Exit;
  N := NormalizedEntryName(AEntryName);
  if N = '' then Exit;
  { Directory entries are not files to write; the engine makes their parents. }
  if (N[Length(N)] = '/') or (N = '.') then Exit;
  if APlan.Layout = slStripOneRoot then
  begin
    if APlan.Root = '' then Exit;
    Prefix := APlan.Root + '/';
    if Copy(N, 1, Length(Prefix)) <> Prefix then Exit;
    N := Copy(N, Length(Prefix) + 1, MaxInt);
    if N = '' then Exit;
  end;
  Result := N;
end;

function TzSmartTargetEntries(const APlan: TSmartPlan;
  const AEntries: TExtractEntryArray): TExtractEntryArray;
var
  I: Integer;
begin
  SetLength(Result, Length(AEntries));
  for I := 0 to High(AEntries) do
  begin
    Result[I] := AEntries[I];
    Result[I].Name := TzSmartTargetPath(APlan, AEntries[I].Name);
  end;
end;

end.
