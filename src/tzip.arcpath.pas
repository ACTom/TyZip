{ Names inside an archive: the string handling the window does when it copies a
  path out of the archive or names a file dropped into one.

  Pure and LCL-free, because these are exactly the pieces a window cannot test in
  place: the copy-path command read the wrong row and the drop target name lost
  its separator, and neither defect is visible without a real archive and a
  mouse. The normalisation mirrors tzip.engine's TzNormalizeArcPath; the rule is
  repeated here rather than imported so this unit stays headless (the engine
  pulls in the 7-Zip bridge), and both copies are deliberately identical. }
unit tzip.arcpath;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ A path inside an archive with one canonical spelling: '/'-separated, no
  leading or trailing separator, no empty segments. '' for an empty path. }
function ArcPathNormalize(const APath: string): string;

{ Join a folder inside an archive with a child name, using the archive's own
  notation: exactly one '/' between them. APrefix may be '' (the archive root)
  or already carry a trailing '/'. }
function ArcChildPath(const APrefix, AName: string): string;

{ The names of the selected rows of a listing, in row order.

  A listing row and an entry's EntryIndex are different numbers: the index is the
  position in the ARCHIVE, so sorting, filtering or a search result breaks any
  mapping between them. Commands that act on selected entries must read the row
  they are selected in; the old "Copy Path" used the entry index as a row number
  and copied an unrelated entry. Empty names (the synthetic ".." row) are not
  paths and are skipped. }
function PickedRowNames(const ARowNames: array of string;
  const ASelected: array of Boolean): TStringArray;

implementation

function ArcPathNormalize(const APath: string): string;
var
  S: string;
  I: Integer;
begin
  Result := '';
  S := Trim(APath);
  if S = '' then Exit;
  { A backslash is a separator in the formats that were written on Windows. }
  S := StringReplace(S, '\', '/', [rfReplaceAll]);
  while S <> '' do
    if S[1] = '/' then Delete(S, 1, 1)
    else if Copy(S, 1, 2) = './' then Delete(S, 1, 2)
    else Break;
  while S <> '' do
  begin
    I := Pos('/', S);
    if I = 0 then
    begin
      Result := Result + '/' + S;
      Break;
    end;
    if I > 1 then Result := Result + '/' + Copy(S, 1, I - 1);
    S := Copy(S, I + 1, MaxInt);
  end;
  { The loop above prepends a separator for every segment; drop the first. }
  if (Result <> '') and (Result[1] = '/') then Delete(Result, 1, 1);
end;

function ArcChildPath(const APrefix, AName: string): string;
var
  P, N: string;
begin
  P := ArcPathNormalize(APrefix);
  N := ArcPathNormalize(AName);
  if P = '' then Exit(N);
  if N = '' then Exit(P);
  Result := P + '/' + N;
end;

function PickedRowNames(const ARowNames: array of string;
  const ASelected: array of Boolean): TStringArray;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(ARowNames) do
  begin
    if (I > High(ASelected)) or (not ASelected[I]) then Continue;
    if ARowNames[I] = '' then Continue;
    SetLength(Result, N + 1);
    Result[N] := ARowNames[I];
    Inc(N);
  end;
end;

end.
