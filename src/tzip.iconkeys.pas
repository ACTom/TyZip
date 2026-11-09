{ The cache key and lifetime of a per-file-type icon, without the picture.

  tzip.ui.icons owns the PNGs and the platform lookup; the two decisions that are
  easy to get wrong and impossible to see by looking at the app are "what name is
  this file type stored under" and "is that file old enough to ask about again".
  Keeping them here means they can be exercised without a window, an image list,
  or an NSWorkspace call.

  There is deliberately no LCL and no BGRABitmap dependency: the icon cache's
  bookkeeping is not an image operation. }
unit tzip.iconkeys;

{$mode objfpc}{$H+}

interface

const
  { The one cached entry that stands for a file type with no suffix at all
    (README, Makefile, ...). It cannot be an empty file name. }
  IconCacheNoExt = '@none';

  { Default age after which a cached glyph is re-asked. Callers pass their own:
    the window refreshes its suffix icons after a day, while the application
    sweep is content to wait a month. }
  IconCacheRefreshDays = 30;

  { Icon work waits for a quiet moment: a platform icon request blocks the main
    thread for one to three seconds, so running one while the mouse moves is what
    made the whole window feel frozen. The start delay leaves the first seconds
    after launch alone; while the window is frontmost, only a long pause counts
    as permission (an 8 s idle user will not notice the lookup); once the user
    switches away, the work is invisible and runs freely. }
  IconWorkIdleSecondsActive = 8.0;
  IconWorkStartDelayMs = 2500;

{ The suffix a file type is keyed by: lower case, no leading dots, trimmed.
  '' when there is no suffix at all. }
function IconKeyName(const AExt: string): string;

{ The cache FILE name for AExt ("xlsx" -> "xlsx.png"). '' when the suffix cannot
  be a file name; an empty suffix becomes "@none.png". }
function IconKeyFileName(const AExt: string): string;

{ True when the file at APath has a timestamp older than AMaxAgeDays.

  A missing or unreadable file is NOT stale: there is nothing to age, and the
  caller's job is to create it. Callers that want "missing counts as stale" (the
  window's refresh pass does) check FileExists themselves. }
function IconKeyIsOlderThan(const APath: string; AMaxAgeDays: Double): Boolean;

{ True when the icon timers may spend a blocking platform lookup right now.
  ABackApp=True means this application is frontmost: then the user must have
  been quiet for IconWorkIdleSecondsActive. When it is not frontmost the lookup
  competes with nothing the user is doing here, so only the launch delay applies. }
function TzIconWorkAllowed(AIdleSeconds: Double; AUptimeMs: Int64;
  AAppActive: Boolean): Boolean;

implementation

uses
  SysUtils, DateUtils;

function IconKeyName(const AExt: string): string;
var
  E: string;
begin
  E := LowerCase(Trim(AExt));
  while (E <> '') and (E[1] = '.') do
    Delete(E, 1, 1);
  Result := E;
end;

function IconKeyFileName(const AExt: string): string;
var
  E: string;
  I: Integer;
begin
  E := IconKeyName(AExt);
  if E = '' then Exit(IconCacheNoExt + '.png');
  { A cache name is a file name: only characters that are safe on every
    filesystem the app runs on, and no separators. }
  for I := 1 to Length(E) do
    if not (E[I] in ['a'..'z', '0'..'9', '_', '-', '+']) then Exit('');
  Result := E + '.png';
end;

function IconKeyIsOlderThan(const APath: string; AMaxAgeDays: Double): Boolean;
var
  Age: TDateTime;
begin
  Result := False;
  if APath = '' then Exit;
  if not FileExists(APath) then Exit;
  Age := Now - FileDateToDateTime(FileAge(APath));
  Result := Age > AMaxAgeDays;
end;

function TzIconWorkAllowed(AIdleSeconds: Double; AUptimeMs: Int64;
  AAppActive: Boolean): Boolean;
begin
  Result := (AUptimeMs >= IconWorkStartDelayMs) and
    ((not AAppActive) or (AIdleSeconds >= IconWorkIdleSecondsActive));
end;

end.
