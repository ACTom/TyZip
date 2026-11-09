program unit_editwrite;
{$mode objfpc}{$H+}
{ Deciding whether a file extracted for editing was actually changed.

  The costly mistake in either direction: asking to write back a file the user
  only looked at, or silently losing their edit because the check was too
  strict. }
uses
  SysUtils, Classes, Process, DateUtils, tzip.editwrite;

var
  Fails, Passes: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

function SizeOfFile(const APath: string): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(APath, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

{ --- session creation --------------------------------------------------- }

procedure TestSession;
var
  S: TEditSession;
  P: string;
begin
  P := Root + '/a.txt';
  with TStringList.Create do
  try
    Add('hello');
    SaveToFile(P);
  finally Free; end;

  S := StartEditSession('/arch/x.zip', 'dir/a.txt', P, Now);
  Check(S.TempPath = P, 'session: temp path recorded');
  Check(S.EntryPath = 'dir/a.txt', 'session: entry path recorded');
  Check(S.ArchivePath = '/arch/x.zip', 'session: archive recorded');
  Check(S.OriginalSize = SizeOfFile(P), 'session: original size recorded');

  { A missing temporary file yields an unusable session rather than an error. }
  S := StartEditSession('/arch/x.zip', 'dir/a.txt', Root + '/missing.txt', Now);
  Check(FileWasEdited(S, P) = False, 'session: missing temp file is not an edit');
end;

{ --- the change decision ------------------------------------------------ }

procedure TestUnchanged;
var
  S: TEditSession;
  Reason: string;
  P: string;
begin
  P := Root + '/same.txt';
  with TStringList.Create do
  try
    Add('content');
    SaveToFile(P);
  finally Free; end;
  { Recorded AFTER the file was written, which is the real ordering. }
  S := StartEditSession('/a/x.zip', 'same.txt', P, Now);
  Check(not FileWasEdited(S, Reason), 'unchanged: an untouched file is not an edit (' + Reason + ')');
  Check(Reason = 'unchanged', 'unchanged: the reason says so (' + Reason + ')');
end;

procedure TestSizeChange;
var
  S: TEditSession;
  Reason: string;
  P: string;
begin
  P := Root + '/grow.txt';
  with TStringList.Create do
  try
    Add('short');
    SaveToFile(P);
  finally Free; end;
  S := StartEditSession('/a/x.zip', 'grow.txt', P, Now - 1);
  { Appending is the common case: the size moved, which is decisive on its own
    regardless of timestamp resolution. }
  with TStringList.Create do
  try
    Add('short');
    Add('and a new line');
    SaveToFile(P);
  finally Free; end;
  Check(FileWasEdited(S, Reason), 'size: a larger file is an edit');
  Check(Pos('size', Reason) > 0, 'size: the reason mentions the size (' + Reason + ')');
end;

procedure TestSameSizeDifferentTime;
var
  S: TEditSession;
  Reason: string;
  P: string;
begin
  P := Root + '/retime.txt';
  with TStringList.Create do
  try
    Add('abcd');
    SaveToFile(P);
  finally Free; end;
  { Extracted "an hour ago", file touched now with the same size: an editor that
    rewrote the same number of bytes. }
  S := StartEditSession('/a/x.zip', 'retime.txt', P, Now - 1);
  Check(FileWasEdited(S, Reason), 'mtime: a later timestamp is an edit');
  Check(Pos('mtime', Reason) > 0, 'mtime: the reason mentions the time (' + Reason + ')');
end;

procedure TestGracePeriod;
var
  S: TEditSession;
  Reason: string;
  P: string;
begin
  P := Root + '/grace.txt';
  with TStringList.Create do
  try
    Add('x');
    SaveToFile(P);
  finally Free; end;
  { Extraction time slightly AFTER the file's stored (whole-second) timestamp is
    what a fresh extraction looks like on a filesystem with one-second
    resolution. That must not be reported as an edit. }
  S := StartEditSession('/a/x.zip', 'grace.txt', P, Now + (5 / SecsPerDay));
  Check(not FileWasEdited(S, Reason),
    'grace: a one-second rounding is not an edit (' + Reason + ')');
end;

procedure TestDeleted;
var
  S: TEditSession;
  Reason: string;
begin
  S := StartEditSession('/a/x.zip', 'gone.txt', Root + '/deleted.txt', Now);
  Check(not FileWasEdited(S, Reason), 'deleted: a missing file is not an edit');
  { StartEditSession refuses a file that is not there, so the session is already
    unusable; FileWasEdited says so rather than claiming a change. }
  Check(Reason <> '', 'deleted: a reason is given (' + Reason + ')');
end;

begin
  Fails := 0; Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-edit-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  TestSession;
  TestUnchanged;
  TestSizeChange;
  TestSameSizeDifferentTime;
  TestGracePeriod;
  TestDeleted;
  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
