program unit_model_job_pause;
{$mode objfpc}{$H+}
{ Pause is implemented by blocking the worker inside the progress sink, the
  same technique 7-Zip's GUI uses.  These tests pin the two properties that
  matter: a paused job really keeps running (the thread is parked, not
  finished), and cancel wins over pause and wakes the wait. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.api.bind, tzip.engine, tzip.jobs;

var
  Fails, Passes: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

function MakeSources: TStringList;
var
  I: Integer;
  L: TStringList;
begin
  ForceDirectories(Root + '/src');
  L := TStringList.Create;
  try
    for I := 0 to 3 do
    begin
      L.Clear;
      L.Add(StringOfChar('x', 512 * 1024));
      L.SaveToFile(Root + '/src/f' + IntToStr(I) + '.txt');
    end;
  finally
    L.Free;
  end;
  Result := TStringList.Create;
  for I := 0 to 3 do
    Result.Add(Root + '/src/f' + IntToStr(I) + '.txt');
end;

function Settings: TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := 'zip';
  Result.Level := 1;
end;

procedure TestPauseResume;
var
  J: TZJob;
  Src: TStringList;
  Err, Detail: string;
  D, T: QWord;
  R: Integer;
  OutPath: string;
begin
  OutPath := Root + '/paused.zip';
  DeleteFile(OutPath);
  Src := MakeSources;
  J := TZJob.Create(jkCreate);
  try
    J.Path := OutPath;
    J.Sources := Src;
    J.Settings := Settings;
    J.Pause;
    Check(J.Paused, 'pause: the job reports paused before start');
    J.Start;
    Sleep(250);
    Check(J.Paused, 'pause: still paused while the worker waits');
    Check(J.Snapshot(D, T, Detail), 'pause: the job has not finished while parked');
    J.Resume;
    Check(not J.Paused, 'resume: the flag clears');
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'resume: job reports a result');
    EqInt(R, TZ7Z_OK, 'resume: job completes (' + Err + ')');
    Check(FileExists(OutPath), 'resume: the archive is written');
  finally
    J.Free;
  end;
end;

procedure TestCancelWhilePaused;
var
  J: TZJob;
  Src: TStringList;
  Err: string;
  R: Integer;
  OutPath: string;
begin
  OutPath := Root + '/cancel-paused.zip';
  DeleteFile(OutPath);
  Src := MakeSources;
  J := TZJob.Create(jkCreate);
  try
    J.Path := OutPath;
    J.Sources := Src;
    J.Settings := Settings;
    J.Pause;
    J.Start;
    Sleep(250);
    J.RequestCancel;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'cancel: a result is reported');
    EqInt(R, TZ7Z_E_CANCEL, 'cancel: wins over pause');
  finally
    J.Free;
  end;
end;

procedure Cleanup;
var
  I: Integer;
begin
  for I := 0 to 3 do
    DeleteFile(Root + '/src/f' + IntToStr(I) + '.txt');
  RemoveDir(Root + '/src');
  DeleteFile(Root + '/paused.zip');
  DeleteFile(Root + '/cancel-paused.zip');
  RemoveDir(Root);
end;

begin
  Fails := 0;
  Passes := 0;
  if not TzLoadLibrary('') then
  begin
    WriteLn('FAIL setup: the engine library loads: ', TzEngineMissingError);
    Halt(1);
  end;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'tyzip-job-pause-' + IntToStr(GetProcessID);
  ForceDirectories(Root);
  try
    TestPauseResume;
    TestCancelWhilePaused;
  finally
    Cleanup;
  end;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
