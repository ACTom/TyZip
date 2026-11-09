{ Renaming and moving entries inside an archive.

  7-Zip has no "rename" call: the archive is rewritten with the entry removed
  and re-added under its new path. That makes two things matter more than they
  would otherwise -- validating the new name before anything is rewritten, and
  knowing when a rename is really a move into another folder.

  The name rules live here so they can be checked without an archive. }
unit tzip.rename;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TRenameProblem = (
    rpNone,          { The name is usable. }
    rpEmpty,
    rpIllegalChars,  { A character the engine or the target filesystem rejects. }
    rpDot,           { "." or ".." -- a relative path, not a name. }
    rpAbsolute,      { Starts with a separator: that is a move, not a rename. }
    rpTrailingSlash, { A file cannot end in a separator. }
    rpDuplicate      { An entry of that name already exists in the folder. }
  );

{ Check a proposed entry name against the archive's existing paths.

  AName is what the user typed. ACurrentPath is the entry's path now, used to
  allow "keep the same name" and to resolve a relative name against the same
  folder. AExisting lists every path in the archive. }
function CheckEntryName(const AName, ACurrentPath: string;
  AExisting: TStrings): TRenameProblem;

{ The path the entry will have after renaming.

  AMoveIntoFolder decides what a name containing '/' means, because the string
  alone cannot say: typing "sub/x.txt" for "dir/a.txt" could mean "rename to
  sub/x.txt, relative to the archive root" or "move it into dir/sub/". The
  caller knows which it asked for. }
function ResolvedEntryPath(const AName, ACurrentPath: string;
  AMoveIntoFolder: Boolean): string;

{ A short English description of a problem, empty for rpNone. The dialog maps
  these onto translatable strings; keeping the messages here free would couple
  this unit to the UI toolkit, which the tests cannot load. }
function RenameProblemText(AProblem: TRenameProblem): string;

implementation

function DirOf(const APath: string): string;
var
  P: Integer;
begin
  P := LastDelimiter('/', APath);
  if P > 0 then Result := Copy(APath, 1, P) else Result := '';
end;

function ResolvedEntryPath(const AName, ACurrentPath: string;
  AMoveIntoFolder: Boolean): string;
var
  N: string;
begin
  N := Trim(AName);
  { Archive paths are '/' separated on every platform; a backslash the user
    typed is treated as the same separator rather than as part of the name. }
  N := StringReplace(N, '\', '/', [rfReplaceAll]);
  { An absolute path names its place outright, whatever the caller meant. }
  if (N <> '') and (N[1] = '/') then Exit(Copy(N, 2, MaxInt));
  if AMoveIntoFolder then
    Result := DirOf(ACurrentPath) + N
  else
    Result := N;
end;

function CheckEntryName(const AName, ACurrentPath: string;
  AExisting: TStrings): TRenameProblem;
var
  N, Resolved: string;
  I: Integer;
const
  { A name the engine or a target filesystem refuses. '/' is the path
    separator inside an archive and cannot be part of a component. }
  IllegalChars = ':*?"<>|';
begin
  Result := rpNone;
  N := Trim(AName);
  if N = '' then Exit(rpEmpty);
  if (N = '.') or (N = '..') then Exit(rpDot);
  if N[1] = '/' then Exit(rpAbsolute);
  if N[Length(N)] = '/' then Exit(rpTrailingSlash);

  { Checked per component, because a move ("a/b/c.txt") may contain '/' as the
    separator while still having an illegal character in one of its parts. }
  for I := 1 to Length(N) do
    if (Pos(N[I], IllegalChars) > 0) or (N[I] < ' ') then
      Exit(rpIllegalChars);

  Resolved := ResolvedEntryPath(AName, ACurrentPath, False);
  { Renaming to what it is already called is not a change, not a conflict. }
  if SameText(Resolved, ACurrentPath) then Exit(rpNone);
  if AExisting <> nil then
    for I := 0 to AExisting.Count - 1 do
      if SameText(StringReplace(AExisting[I], '\', '/', [rfReplaceAll]), Resolved) then
        Exit(rpDuplicate);
end;

function RenameProblemText(AProblem: TRenameProblem): string;
begin
  case AProblem of
    rpNone: Result := '';
    rpEmpty: Result := 'The name cannot be empty.';
    rpIllegalChars: Result := 'A name cannot contain any of : * ? " < > |';
    rpDot: Result := 'A name cannot be "." or "..".';
    rpAbsolute: Result := 'A name cannot start with "/".';
    rpTrailingSlash: Result := 'A file name cannot end with "/".';
    rpDuplicate: Result := 'An entry with that name already exists here.';
  else
    Result := 'The name cannot be empty.';
  end;
end;

end.
