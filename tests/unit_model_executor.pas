program unit_model_executor;
{$mode objfpc}{$H+}
{ TZJob's execution seam: every job kind asks its executor for the work, and the
  worker's own state machine (result, error, cancel) is what wraps the answer.

  A fake executor records which kind's method was called and returns a canned
  code, so a wrong dispatch, a swallowed error or a broken "cancel after the
  work finished" rule fails here without needing an archive. The real engine
  behaviour is covered by unit_model_jobmatrix. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.engine, tzip.jobs;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant]));
  end;
end;

type
  { Records which method Execute asked for and answers with a canned code. }
  TRecordingExecutor = class(TZJobExecutor)
  public
    Calls: Integer;
    CallName: string;
    RetCode: Integer;
    RetError: string;
    function RecordCall(const AName: string): Integer;
    function OpenJob(AJob: TZJob; out AError: string): Integer; override;
    function ListJob(AJob: TZJob; out AError: string): Integer; override;
    function ExtractJob(AJob: TZJob; out AError: string): Integer; override;
    function TestJob(AJob: TZJob; out AError: string): Integer; override;
    function ExtractOneJob(AJob: TZJob; out AError: string): Integer; override;
    function CreateJob(AJob: TZJob; out AError: string): Integer; override;
    function ConvertJob(AJob: TZJob; out AError: string): Integer; override;
    function RenameJob(AJob: TZJob; out AError: string): Integer; override;
    function ModifyJob(AJob: TZJob; out AError: string): Integer; override;
    function SearchJob(AJob: TZJob; out AError: string): Integer; override;
  end;

  { Proves the worker still turns an unexpected exception into a failed job. }
  TRaisingExecutor = class(TZJobExecutor)
  public
    function OpenJob(AJob: TZJob; out AError: string): Integer; override;
  end;

function TRecordingExecutor.RecordCall(const AName: string): Integer;
begin
  Inc(Calls);
  CallName := AName;
  Result := RetCode;
end;

function TRecordingExecutor.OpenJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('open');
  AError := RetError;
end;

function TRecordingExecutor.ListJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('list');
  AError := RetError;
end;

function TRecordingExecutor.ExtractJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('extract');
  AError := RetError;
end;

function TRecordingExecutor.TestJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('test');
  AError := RetError;
end;

function TRecordingExecutor.ExtractOneJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('extract-one');
  AError := RetError;
end;

function TRecordingExecutor.CreateJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('create');
  AError := RetError;
end;

function TRecordingExecutor.ConvertJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('convert');
  AError := RetError;
end;

function TRecordingExecutor.RenameJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('rename');
  AError := RetError;
end;

function TRecordingExecutor.ModifyJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('modify');
  AError := RetError;
end;

function TRecordingExecutor.SearchJob(AJob: TZJob; out AError: string): Integer;
begin
  Result := RecordCall('search');
  AError := RetError;
end;

function TRaisingExecutor.OpenJob(AJob: TZJob; out AError: string): Integer;
begin
  raise Exception.Create('executor exploded');
end;

function RunJob(AKind: TZJobKind; AExecutor: TZJobExecutor;
  out AError: string): Integer;
var
  J: TZJob;
begin
  J := TZJob.Create(AKind);
  try
    J.Executor := AExecutor;
    J.Start;
    J.WaitFor;
    if not J.TakeResult(Result, AError) then
    begin
      Result := -999;
      AError := 'no result';
    end;
  finally
    J.Free;
  end;
end;

{ --- every kind reaches its own executor method ------------------------- }

procedure TestDispatch;
const
  Kinds: array[0..9] of TZJobKind = (jkOpen, jkList, jkExtract, jkTest,
    jkExtractOne, jkCreate, jkConvert, jkRename, jkModify, jkSearch);
  Names: array[0..9] of string = ('open', 'list', 'extract', 'test',
    'extract-one', 'create', 'convert', 'rename', 'modify', 'search');
var
  I: Integer;
  Fake: TRecordingExecutor;
  Err: string;
  R: Integer;
begin
  for I := 0 to High(Kinds) do
  begin
    Fake := TRecordingExecutor.Create;
    try
      Fake.RetCode := TZ7Z_OK;
      R := RunJob(Kinds[I], Fake, Err);
      EqInt(R, TZ7Z_OK, Format('dispatch %s: success code', [Names[I]]));
      EqInt(Fake.Calls, 1, Format('dispatch %s: one executor call', [Names[I]]));
      EqStr(Fake.CallName, Names[I],
        Format('dispatch %s: the matching executor method', [Names[I]]));
    finally
      Fake.Free;
    end;
  end;
end;

{ --- the executor's answer is what the job reports ---------------------- }

procedure TestResultPropagation;
var
  Fake: TRecordingExecutor;
  Err: string;
  R: Integer;
begin
  Fake := TRecordingExecutor.Create;
  try
    Fake.RetCode := TZ7Z_E_UPDATE;
    Fake.RetError := 'update failed';
    R := RunJob(jkModify, Fake, Err);
    EqInt(R, TZ7Z_E_UPDATE, 'propagate: the error code is kept');
    EqStr(Err, 'update failed', 'propagate: the error text is kept');
  finally
    Fake.Free;
  end;
end;

{ --- an executor exception becomes a failed job ------------------------- }

procedure TestExecutorException;
var
  Raising: TRaisingExecutor;
  Err: string;
  R: Integer;
begin
  Raising := TRaisingExecutor.Create;
  try
    R := RunJob(jkOpen, Raising, Err);
    EqInt(R, TZ7Z_E_EXTRACT, 'exception: reported as a failed job');
    Check(Pos('executor exploded', Err) > 0, 'exception: the message is kept');
  finally
    Raising.Free;
  end;
end;

{ --- cancel bookkeeping stays in the worker ----------------------------- }

procedure TestCancelAfterFinish;
var
  J: TZJob;
  Fake: TRecordingExecutor;
  Err: string;
  R: Integer;
begin
  Fake := TRecordingExecutor.Create;
  J := TZJob.Create(jkExtract);
  try
    J.Executor := Fake;
    Fake.RetCode := TZ7Z_OK;
    J.Start;
    J.WaitFor;
    { The work finished; a late cancel flag must not rewrite the result. }
    J.RequestCancel;
    Check(J.TakeResult(R, Err), 'cancel: a result is reported');
    EqInt(R, TZ7Z_OK, 'cancel: a finished job is not relabelled');
  finally
    J.Free;
    Fake.Free;
  end;
end;

{ --- without an injection the real executor is still wired ------------- }

procedure TestDefaultExecutor;
var
  J: TZJob;
  Entries: TArchiveEntries;
  Err: string;
  R: Integer;
begin
  SetLength(Entries, 2);
  Entries[0] := Default(TArchiveEntry);
  Entries[0].Name := 'a.txt';
  Entries[0].Index := 0;
  Entries[1] := Default(TArchiveEntry);
  Entries[1].Name := 'b.txt';
  Entries[1].Index := 1;
  J := TZJob.Create(jkList);
  try
    J.SetEntries(Entries);
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'default: a result is reported');
    EqInt(R, TZ7Z_OK, 'default: the real listing is produced');
    EqInt(Length(J.Listing), 2, 'default: both entries listed');
  finally
    J.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  TestDispatch;
  TestResultPropagation;
  TestExecutorException;
  TestCancelAfterFinish;
  TestDefaultExecutor;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
