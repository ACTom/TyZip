program unit_appcache;
{$mode objfpc}{$H+}
{ Which .app bundles are recognised, which are cached, and what key they get.

  The scope rule is the one worth pinning: caching every .app ever browsed would
  grow without limit, so only the two application folders qualify. }
uses
  SysUtils, tzip.appcache;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

{ --- recognising a bundle ----------------------------------------------- }

procedure TestLooksLikeApp;
begin
  Check(LooksLikeAppBundle('/Applications/Safari.app'), 'look: plain bundle');
  Check(LooksLikeAppBundle('/Applications/Safari.app/'), 'look: trailing slash');
  Check(LooksLikeAppBundle('Some.app'), 'look: bare name');
  { Case-insensitive, because the filesystem is. }
  Check(LooksLikeAppBundle('/a/Thing.APP'), 'look: uppercase extension');
  Check(not LooksLikeAppBundle('/a/Thing.abc'), 'look: other extension');
  Check(not LooksLikeAppBundle('/a/Thing.appx'), 'look: longer extension');
  Check(not LooksLikeAppBundle('/a/.app'), 'look: just the extension');
  Check(not LooksLikeAppBundle(''), 'look: empty');
  { A file that merely starts with ".app". }
  Check(not LooksLikeAppBundle('/a/app.txt'), 'look: prefix only');
end;

{ --- which folders are cached ------------------------------------------- }

procedure TestShouldCache;
begin
  Check(ShouldCacheAppIcon('/Applications/Safari.app'), 'cache: /Applications');
  Check(ShouldCacheAppIcon('/System/Applications/Safari.app'),
    'cache: /System/Applications');
  Check(ShouldCacheAppIcon('/Applications/Utilities/Terminal.app') = False,
    'cache: a subfolder of /Applications is not the cache root');

  { The user's own Applications folder, however the home is spelled. }
  Check(ShouldCacheAppIcon(IncludeTrailingPathDelimiter(GetUserDir) + 'Applications/Foo.app'),
    'cache: the home Applications folder');

  Check(not ShouldCacheAppIcon('/tmp/Some.app'), 'cache: temp is not cached');
  Check(not ShouldCacheAppIcon('/Users/x/Downloads/Some.app'), 'cache: downloads are not cached');
  Check(not ShouldCacheAppIcon('/Applications/notes.txt'), 'cache: a non-bundle is never cached');
  Check(not ShouldCacheAppIcon(''), 'cache: empty');
end;

procedure TestRoots;
var
  R: TStringArray;
begin
  R := AppCacheRoots;
  Check(Length(R) >= 2, 'roots: several folders');
  { The system applications come first: they are most of what Open With offers. }
  EqStr(R[0], '/System/Applications', 'roots: the system folder comes first');
  Check(IsAppCacheRoot('/System/Applications'), 'roots: recognises the system folder');
  EqStr(R[1], '/Applications', 'roots: the local folder is second');
  Check(IsAppCacheRoot('/Applications'), 'roots: recognises the system folder');
  Check(IsAppCacheRoot('/Applications/'), 'roots: tolerates a trailing slash');
  Check(not IsAppCacheRoot('/'), 'roots: the volume root is not one');
end;

{ --- cache keys --------------------------------------------------------- }

procedure TestKeys;
var
  A, B, C: string;
begin
  A := AppIconCacheKey('/Applications/Safari.app');
  B := AppIconCacheKey('/Applications/Notes.app');
  C := AppIconCacheKey(IncludeTrailingPathDelimiter(GetUserDir) + 'Applications/Safari.app');

  Check(A <> '', 'key: produced');
  Check(A <> B, 'key: two bundles differ');
  { Same NAME, different folder: still different keys, or one would overwrite
    the other. }
  Check(A <> C, 'key: same name in another folder differs');
  { Stable across calls, or the cache would never be found again. }
  EqStr(AppIconCacheKey('/Applications/Safari.app'), A, 'key: stable');
  { Trailing slash and case must not fork the key. }
  EqStr(AppIconCacheKey('/Applications/Safari.app/'), A, 'key: trailing slash ignored');
  { The PATH keeps its case: /Applications and /applications are different
    directories. Only the .app extension is compared case-insensitively. }
  Check(AppIconCacheKey('/applications/safari.app') <> A,
    'key: a different path keeps a different key');
  EqStr(AppIconCacheKey('/Applications/Safari.APP'), A, 'key: extension case ignored');

  { The key has to be usable as a file name in a cache that only allows
    [a-z0-9_-+]. }
  Check(Pos('/', A) = 0, 'key: no separator');
  Check(Pos('.', A) = 0, 'key: no dot');
  Check(Copy(A, 1, 4) = 'app_', 'key: prefixed so it is recognisable');
  Check(Length(A) = 4 + 16, 'key: prefix plus two 32-bit words');
  { The icon cache stores file names lower cased (IconKeyName) and restores them
    from that table: an upper case key here made every restored app icon miss its
    slot, so the cache was full and the list stayed generic. }
  EqStr(A, LowerCase(A), 'key: lower case to match the cache file names');

  { Not a bundle, no key. }
  EqStr(AppIconCacheKey('/Applications/notes.txt'), '', 'key: non-bundle has no key');
  EqStr(AppIconCacheKey(''), '', 'key: empty has no key');
end;

begin
  Fails := 0; Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  TestLooksLikeApp;
  TestShouldCache;
  TestRoots;
  TestKeys;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
