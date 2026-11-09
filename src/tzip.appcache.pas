{ Which .app bundles get their icons cached, and under what cache key.

  An application's icon comes from its bundle, so it cannot be answered by a
  type query -- the file has to be named. That costs NSWorkspace about 0.7 ms per
  bundle once LaunchServices is warm, and 89 bundles in /Applications take 60 ms
  warm and 180 ms cold, so asking on every paint is a stutter on a folder the
  user is scrolling. They are therefore cached like any other icon.

  The scope matters because caching EVERY .app ever browsed would grow without
  limit as the user wanders the disk. Only the two application folders are
  cached; an .app anywhere else is still shown with its real icon, just asked
  for each time. }
unit tzip.appcache;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ True when APath is one of the folders whose .app bundles are cached:
  /Applications and ~/Applications. A trailing separator is tolerated. }
function IsAppCacheRoot(const APath: string): Boolean;

{ The two folders, existing or not. }
function AppCacheRoots: TStringArray;

{ True when APath ends in .app (case-insensitive), with or without a trailing
  separator. Used both for real paths and for entry names inside an archive. }
function LooksLikeAppBundle(const APath: string): Boolean;

{ The cache key for a .app bundle at APath.

  Cache file names only admit [a-z0-9_-+], and a bundle path is neither flat nor
  stable across machines, so the key is a hash of the full path with an
  "app_" prefix. Absolute paths go in, so a same-named bundle in another folder
  stays a different key.

  Empty when the path cannot be keyed (empty, or not an .app). }
function AppIconCacheKey(const APath: string): string;

{ True when APath is a bundle whose icon THIS CACHE is allowed to store: an .app
  inside one of AppCacheRoots. }
function ShouldCacheAppIcon(const APath: string): Boolean;

implementation

function Normalise(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(Trim(APath));
end;

function LooksLikeAppBundle(const APath: string): Boolean;
var
  P, Name: string;
begin
  P := Normalise(APath);
  if Length(P) <= 4 then Exit(False);
  if not SameText(Copy(P, Length(P) - 3, 4), '.app') then Exit(False);
  { The name has to be more than the extension: "/a/.app" is a hidden file that
    happens to be called .app, not a bundle. }
  Name := ExtractFileName(P);
  Result := Length(Name) > 4;
end;

function AppCacheRoots: TStringArray;
var
  Home: string;
begin
  Result := nil;
  SetLength(Result, 3);
  { The system applications live here, and they are most of what the Open With
    menu offers: Safari, Mail, Calendar, the whole Apple set. Leaving them out
    meant the menu had no icons for the applications a user is most likely to
    pick. }
  Result[0] := '/System/Applications';
  Result[1] := '/Applications';
  Home := ExcludeTrailingPathDelimiter(GetUserDir);
  if Home = '' then
  begin
    SetLength(Result, 2);
    Exit;
  end;
  Result[2] := Home + PathDelim + 'Applications';
end;

function IsAppCacheRoot(const APath: string): Boolean;
var
  P: string;
  Roots: TStringArray;
  I: Integer;
begin
  Result := False;
  P := Normalise(APath);
  if P = '' then Exit;
  Roots := AppCacheRoots;
  for I := 0 to High(Roots) do
    if SameText(P, Roots[I]) then Exit(True);
end;

{ A small, stable string hash. Deliberately not a crypto digest: the key only
  has to avoid collisions in one directory, and this keeps the unit free of
  dependencies. Two 32-bit rounds make an accidental collision unlikely at the
  size of a real cache. }
function PathHash(const APath: string): string;
var
  H1, H2: LongWord;
  I: Integer;
  B: Byte;
begin
  H1 := 2166136261;
  H2 := 5381;
  for I := 1 to Length(APath) do
  begin
    B := Ord(APath[I]);
    H1 := (H1 xor B) * 16777619;
    H2 := ((H2 shl 5) + H2) xor B;
  end;
  Result := IntToHex(H1, 8) + IntToHex(H2, 8);
end;

function AppIconCacheKey(const APath: string): string;
var
  P: string;
begin
  Result := '';
  P := Normalise(APath);
  if not LooksLikeAppBundle(P) then Exit;
  { The full path, so two different bundles with one name stay apart. Only the
    EXTENSION is normalised: "/Applications" and "/applications" are different
    directories on a case-sensitive volume, so the rest of the path keeps its
    case -- but "Safari.app" and "Safari.APP" are one bundle and must share a
    key. }
  { Lower case: the icon cache stores file names lower cased (IconKeyName), and
    the window compares this key with those names. Upper case here made every
    restored app icon miss its slot: the cache was full and the list stayed
    generic. }
  Result := 'app_' + LowerCase(PathHash(Copy(P, 1, Length(P) - 4) + '.app'));
end;

function ShouldCacheAppIcon(const APath: string): Boolean;
var
  P, Dir: string;
begin
  Result := False;
  P := Normalise(APath);
  if not LooksLikeAppBundle(P) then Exit;
  Dir := ExtractFileDir(P);
  Result := IsAppCacheRoot(Dir);
end;

end.
