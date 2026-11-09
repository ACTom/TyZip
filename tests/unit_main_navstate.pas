program unit_main_navstate;
{$mode objfpc}{$H+}
{ Navigation bookkeeping: the back/forward stacks and the breadcrumb trail.

  Pure: no widget is asked anything. A state names a folder or an archive
  location; the stacks must never repeat a state, a new branch kills the forward
  trail, and following a crumb must have a meaning the caller can act on. }
uses
  SysUtils, tzip.navstate;

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

procedure EqInt(const AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

function FsState(const APath: string): TNavState;
begin
  Result := Default(TNavState);
  Result.Kind := nkFiles;
  Result.FsPath := APath;
end;

function ArchiveState(const AInner: string): TNavState;
begin
  Result := Default(TNavState);
  Result.Kind := nkArchive;
  Result.Inner := AInner;
end;

{ --- history ------------------------------------------------------------ }

procedure TestHistory;
var
  H: TNavHistory;
  S: TNavState;
begin
  H := TNavHistory.Create;
  try
    Check(not H.CanGoBack, 'history: a new history has nothing behind it');
    Check(not H.CanGoForward, 'history: and nothing ahead');

    { Two moves: /a, then /b. }
    H.PushBack(FsState('/a'));
    H.PushBack(FsState('/b'));
    EqInt(H.BackCount, 2, 'history: two previous places');

    { The same place pushed twice is one entry, not two. }
    H.PushBack(FsState('/b'));
    EqInt(H.BackCount, 2, 'history: a repeated state is not pushed again');

    Check(H.Back(FsState('/c'), S), 'history: can step back');
    EqStr(S.FsPath, '/b', 'history: the last pushed state comes back first');
    EqInt(H.BackCount, 1, 'history: back shortens the back stack');
    EqInt(H.ForwardCount, 1, 'history: back fills the forward stack');

    Check(H.Back(FsState('/b'), S), 'history: can step back again');
    EqStr(S.FsPath, '/a', 'history: oldest state last');

    { Forward replays them in the order they were left. }
    Check(H.Forward(FsState('/a'), S), 'history: can step forward');
    EqStr(S.FsPath, '/b', 'history: forward returns the first place left');
    EqInt(H.BackCount, 1, 'history: forward fills the back stack');
    Check(H.Forward(FsState('/b'), S), 'history: can step forward again');
    EqStr(S.FsPath, '/c', 'history: forward then the second place');
    EqInt(H.ForwardCount, 0, 'history: forward stack drained');

    { A new location after going back discards the forward branch. }
    H.PushBack(FsState('/d'));
    EqInt(H.ForwardCount, 0, 'history: a new branch clears the forward stack');
  finally H.Free; end;
end;

procedure TestHistoryKinds;
var
  H: TNavHistory;
  S: TNavState;
begin
  H := TNavHistory.Create;
  try
    H.PushBack(FsState('/x'));
    H.PushBack(ArchiveState('docs'));
    Check(H.Back(ArchiveState(''), S), 'kinds: stepping out of an archive');
    EqStr(S.Inner, 'docs', 'kinds: the inner folder is part of the state');
    Check(S.Kind = nkArchive, 'kinds: the state keeps its kind');
  finally H.Free; end;
end;

{ --- breadcrumbs -------------------------------------------------------- }

procedure TestFsCrumbs;
var
  C: TCrumbArray;
begin
  C := FsBreadcrumbs('MacOS', '/');
  EqInt(Length(C), 1, 'fs crumbs: root only');
  EqStr(C[0].Text, 'MacOS', 'fs crumbs: volume root caption');
  EqStr(C[0].Path, '/', 'fs crumbs: volume root target');

  C := FsBreadcrumbs('MacOS', '/Users/tom');
  EqInt(Length(C), 3, 'fs crumbs: root plus two segments');
  EqStr(C[1].Text, 'Users', 'fs crumbs: first segment');
  EqStr(C[1].Path, '/Users', 'fs crumbs: first segment target is absolute');
  EqStr(C[2].Text, 'tom', 'fs crumbs: second segment');
  EqStr(C[2].Path, '/Users/tom', 'fs crumbs: accumulated target');
  Check(C[2].Kind = ckFs, 'fs crumbs: every crumb is a filesystem target');

  { Empty segments (a trailing slash, a doubled one) are not crumbs. }
  C := FsBreadcrumbs('MacOS', '/Users//tom/');
  EqInt(Length(C), 3, 'fs crumbs: empty segments dropped');
end;

procedure TestArchiveCrumbs;
var
  C: TCrumbArray;
  Chain: TNavNameArray;
begin
  SetLength(Chain, 2);
  Chain[0] := 'outer.zip';
  Chain[1] := 'inner.7z';
  C := ArchiveBreadcrumbs('MacOS', '/Users/tom', Chain, 'docs/sub');
  EqInt(Length(C), 7, 'archive crumbs: root, two path segments, two archives, two folders');
  EqStr(C[1].Text, 'Users', 'archive crumbs: the filesystem trail comes first');
  Check(C[3].Kind = ckArchive, 'archive crumbs: the archive crumb is an archive target');
  EqInt(C[3].ArchiveIndex, 0, 'archive crumbs: outermost archive first');
  EqStr(C[3].Text, 'outer.zip', 'archive crumbs: archive caption is its display name');
  EqInt(C[4].ArchiveIndex, 1, 'archive crumbs: nested archive second');
  Check(C[5].Kind = ckInner, 'archive crumbs: inner folders are inner targets');
  EqStr(C[5].Path, '/docs', 'archive crumbs: inner target is relative to the archive root');
  EqStr(C[6].Path, '/docs/sub', 'archive crumbs: accumulated inner path');

  { An archive with no folder inside has no inner crumbs. }
  C := ArchiveBreadcrumbs('MacOS', '', Chain, '');
  EqInt(Length(C), 3, 'archive crumbs: no inner folders');
  EqStr(C[0].Path, '/', 'archive crumbs: empty origin is the volume root');
end;

procedure TestBreadcrumbPathText;
var
  Chain: TNavNameArray;
begin
  EqStr(BreadcrumbPathText('/tmp/x', '', nil, ''), '/tmp/x',
    'path text: filesystem location');
  EqStr(BreadcrumbPathText('', '', nil, ''), '/',
    'path text: empty filesystem location');

  SetLength(Chain, 2);
  Chain[0] := 'a.zip';
  Chain[1] := 'b.7z';
  EqStr(BreadcrumbPathText('', '/Users/tom', Chain, ''),
    '/Users/tom/a.zip/b.7z', 'path text: archive chain');
  EqStr(BreadcrumbPathText('', '/Users/tom', Chain, 'docs'),
    '/Users/tom/a.zip/b.7z/docs/', 'path text: inner folder gets a trailing separator');
  EqStr(BreadcrumbPathText('', '/', Chain, ''),
    '/a.zip/b.7z', 'path text: the volume root does not double its separator');
end;

begin
  Fails := 0; Passes := 0;
  TestHistory;
  TestHistoryKinds;
  TestFsCrumbs;
  TestArchiveCrumbs;
  TestBreadcrumbPathText;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
