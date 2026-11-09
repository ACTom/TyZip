program unit_main_iconkeys;
{$mode objfpc}{$H+}
{ The icon cache's keys and expiry, without any pictures.

  Pinned here: a suffix that must not become a file name, the "no suffix" entry,
  and the rule that a missing cache file is not "stale" (the caller creates it;
  only the window's refresh pass treats missing as stale, and it checks that
  itself). }
uses
  SysUtils, Classes, tzip.iconkeys;

var
  Fails, Passes: Integer;
  Root: string;

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

function Touch(const AName: string): string;
var
  H: THandle;
begin
  Result := Root + PathDelim + AName;
  H := FileCreate(Result);
  if H <> THandle(-1) then FileClose(H);
end;

procedure TestKeyName;
begin
  EqStr(IconKeyName('png'), 'png', 'name: plain');
  EqStr(IconKeyName('.PNG'), 'png', 'name: leading dot and case');
  EqStr(IconKeyName('  .Xlsx  '), 'xlsx', 'name: trimmed');
  EqStr(IconKeyName('..tar'), 'tar', 'name: several dots');
  EqStr(IconKeyName(''), '', 'name: empty');
  EqStr(IconKeyName('.'), '', 'name: only a dot');
  { Characters inside the suffix are not normalised away here; the FILE NAME
    check is where they are rejected. }
  EqStr(IconKeyName('a b'), 'a b', 'name: inner space kept');
end;

procedure TestFileName;
begin
  EqStr(IconKeyFileName('png'), 'png.png', 'file: plain');
  EqStr(IconKeyFileName('.PNG'), 'png.png', 'file: normalised');
  EqStr(IconKeyFileName('a-b_c+d'), 'a-b_c+d.png', 'file: allowed characters');
  { The one entry that stands for a file type with no suffix. }
  EqStr(IconKeyFileName(''), IconCacheNoExt + '.png', 'file: no suffix');
  EqStr(IconKeyFileName('.'), IconCacheNoExt + '.png', 'file: a dot means no suffix');
  { Anything that is not a safe file name is not cached under that suffix. }
  EqStr(IconKeyFileName('a b'), '', 'file: space rejected');
  EqStr(IconKeyFileName('a/b'), '', 'file: separator rejected');
  EqStr(IconKeyFileName('a.b'), '', 'file: inner dot rejected');
  EqStr(IconKeyFileName('é'), '', 'file: non-ascii rejected');
end;

procedure TestStaleness;
var
  P: string;
begin
  P := Touch('fresh.png');
  { A file written a moment ago is not older than a day. }
  Check(not IconKeyIsOlderThan(P, 1), 'stale: a fresh file is not stale');
  { Negative age means "always re-ask", which is how the tests pin the comparison
    without back-dating a file. }
  Check(IconKeyIsOlderThan(P, -1), 'stale: negative window is always stale');
  { A huge window keeps even an ancient file. }
  Check(not IconKeyIsOlderThan(P, 100000), 'stale: huge window');
  { A missing file has no age to compare; the caller creates it. }
  Check(not IconKeyIsOlderThan(Root + PathDelim + 'absent.png', 1),
    'stale: missing file is not stale');
  Check(not IconKeyIsOlderThan('', 1), 'stale: empty path is not stale');
  { The two call sites pass their own window; the helper must not hard-code one. }
  Check(not IconKeyIsOlderThan(P, IconCacheRefreshDays),
    'stale: the default window is generous');
end;

{ The gate: a launch grace period, no work while this window is frontmost and
  the user is busy, and free rein while it is in the background. }
procedure TestIconWorkAllowed;
begin
  Check(not TzIconWorkAllowed(999, 0, False),
    'work: no work in the launch grace even in the background');
  Check(not TzIconWorkAllowed(999, IconWorkStartDelayMs - 1, False),
    'work: grace ends exactly at the delay');
  Check(not TzIconWorkAllowed(0, IconWorkStartDelayMs + 5000, True),
    'work: frontmost with a moving mouse blocks it');
  Check(not TzIconWorkAllowed(IconWorkIdleSecondsActive - 0.01,
    IconWorkStartDelayMs + 5000, True),
    'work: frontmost needs a long pause');
  Check(TzIconWorkAllowed(IconWorkIdleSecondsActive,
    IconWorkStartDelayMs + 5000, True),
    'work: frontmost and idle long enough');
  Check(TzIconWorkAllowed(0, IconWorkStartDelayMs, False),
    'work: background runs without an idle pause');
  Check(not TzIconWorkAllowed(0, IconWorkStartDelayMs - 1, False),
    'work: background still waits for the grace');
  Check(IconWorkIdleSecondsActive > 0, 'work: active idle threshold is positive');
  Check(IconWorkStartDelayMs > 0, 'work: start delay is positive');
end;

begin
  Fails := 0; Passes := 0;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-iconkeys-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  TestKeyName;
  TestFileName;
  TestStaleness;
  TestIconWorkAllowed;
  DeleteFile(Root + PathDelim + 'fresh.png');
  RemoveDir(Root);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
