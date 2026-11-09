program unit_model_cancel;
{$mode objfpc}{$H+}
{ Cancellation and progress, end to end.

  TZ7Z_E_CANCEL did not appear anywhere in the test suite: the bridge returns it
  when the progress sink refuses to continue, and TZJob turns a user's cancel
  request into exactly that refusal. Both are easy to break silently (a sink
  that is never wired up just makes Cancel do nothing), so they are pinned here:
  progress really reports, a refusing sink really stops the operation, and a
  cancelled job really reports TZ7Z_E_CANCEL. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.engine, tzip.jobs;

var
  Fails, Passes: Integer;
  Root: string;

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

type
  { Counts the bridge's progress calls and can refuse to continue. }
  TProbeSink = class(TZ7ZProgressSink)
  public
    Calls: Integer;
    LastDone, LastTotal: QWord;
    { 1 means "refuse on the first call", 0 means "never refuse". }
    FailAtCall: Integer;
    function Tick(Completed, Total: QWord): Boolean; override;
  end;

function TProbeSink.Tick(Completed, Total: QWord): Boolean;
begin
  Inc(Calls);
  LastDone := Completed;
  LastTotal := Total;
  Result := (FailAtCall = 0) or (Calls < FailAtCall);
end;

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally
    L.Free;
  end;
end;

{ Enough files that the bridge reports progress more than once. }
procedure BuildInputs;
var
  I: Integer;
begin
  ForceDirectories(Root + '/in');
  for I := 0 to 119 do
    WriteText(Root + '/in/file' + Format('%.3d', [I]) + '.txt',
      'payload ' + IntToStr(I) + LineEnding + StringOfChar('x', 2000));
end;

function MakeArchive: string;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
begin
  Result := Root + '/progress.zip';
  DeleteFile(Result);
  BuildInputs;
  L := TStringList.Create;
  try
    L.Add(Root + '/in');
    Set1 := TzCollectInputs(L, '');
    try
      S := Default(TCreateSettings);
      S.FormatName := 'zip';
      S.Level := 1;
      if TzCreateArchive(Result, S, Set1.Recs, Err) <> TZ7Z_OK then
      begin
        WriteLn('setup: cannot create the archive: ', Err);
        Result := '';
      end;
    finally
      TzInputSetFree(Set1);
    end;
  finally
    L.Free;
  end;
end;

function IndicesOf(const A: TTzArchive): TLongWordArray;
var
  I: Integer;
begin
  SetLength(Result, A.Count);
  for I := 0 to A.Count - 1 do
    Result[I] := LongWord(I);
end;

{ --- progress really reports -------------------------------------------- }

procedure TestProgressReports;
var
  A: TTzArchive;
  Sink: TProbeSink;
  Err, Dest: string;
  R: Integer;
begin
  A := nil;
  R := TzOpenArchive(Root + '/progress.zip', '', A, Err);
  Check(R = TZ7Z_OK, 'progress: the archive opens (' + Err + ')');
  if A = nil then Exit;
  Sink := TProbeSink.Create;
  try
    Sink.FailAtCall := 0;
    Dest := Root + '/dest-progress';
    ForceDirectories(Dest);
    R := TzExtract(A, IndicesOf(A), Dest, '', Err, Sink);
    Check(R = TZ7Z_OK, 'progress: extraction succeeds (' + Err + ')');
    Check(Sink.Calls > 0, 'progress: the sink is called');
    Check(Sink.LastTotal > 0, 'progress: a total is reported');
  finally
    Sink.Free;
    A.Free;
  end;
end;

{ --- a refusing sink stops the operation -------------------------------- }

procedure TestSinkCancel;
var
  A: TTzArchive;
  Sink: TProbeSink;
  Err, Dest: string;
  R: Integer;
begin
  A := nil;
  R := TzOpenArchive(Root + '/progress.zip', '', A, Err);
  Check(R = TZ7Z_OK, 'cancel: the archive opens (' + Err + ')');
  if A = nil then Exit;
  try
    Sink := TProbeSink.Create;
    try
      Sink.FailAtCall := 1;
      Dest := Root + '/dest-cancel';
      ForceDirectories(Dest);
      R := TzExtract(A, IndicesOf(A), Dest, '', Err, Sink);
      EqInt(R, TZ7Z_E_CANCEL, 'cancel: extraction reports cancellation');
      EqInt(Sink.Calls, 1, 'cancel: the sink was asked once and refused');
    finally
      Sink.Free;
    end;

    Sink := TProbeSink.Create;
    try
      Sink.FailAtCall := 1;
      R := TzTest(A, IndicesOf(A), '', Err, Sink);
      EqInt(R, TZ7Z_E_CANCEL, 'cancel: testing reports cancellation');
    finally
      Sink.Free;
    end;
  finally
    A.Free;
  end;
end;

{ --- TZJob: a cancel request really reaches the engine ------------------ }

procedure TestJobCancel;
var
  J: TZJob;
  Err, Dest: string;
  R: Integer;
begin
  J := TZJob.Create(jkExtract);
  try
    J.Path := Root + '/progress.zip';
    J.Password := '';
    J.Dest := Root + '/dest-job-cancel';
    ForceDirectories(J.Dest);
    { The user presses Cancel before the worker starts: the job's sink must
      refuse on the first progress callback and the engine must return cancel. }
    J.RequestCancel;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'job cancel: a result is reported');
    EqInt(R, TZ7Z_E_CANCEL, 'job cancel: the job reports TZ7Z_E_CANCEL');
  finally
    J.Free;
  end;
end;

{ --- a cancel the engine never saw -------------------------------------- }

procedure TestFinishedListingNotRelabelled;
var
  J: TZJob;
  Entries: TArchiveEntries;
  Err: string;
  R: Integer;
begin
  { jkList has no engine call that could report cancellation. A cancel flag set
    before the worker runs is therefore still set when the job finishes; the
    job must NOT rewrite its successful result to TZ7Z_E_CANCEL, because the
    listing really was produced. This is the regression that made the UI skip
    its refresh for work that had already completed. }
  SetLength(Entries, 2);
  Entries[0].Name := 'a.txt';
  Entries[0].Index := 0;
  Entries[1].Name := 'b.txt';
  Entries[1].Index := 1;
  J := TZJob.Create(jkList);
  try
    J.SetEntries(Entries);
    J.RequestCancel;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'late cancel: a result is reported');
    EqInt(R, TZ7Z_OK, 'late cancel: a finished listing is not relabelled');
  finally
    J.Free;
  end;
end;

{ --- a cancel that arrives after the work is done ----------------------- }

procedure TestJobCancelTooLate;
var
  J: TZJob;
  Err: string;
  R: Integer;
begin
  J := TZJob.Create(jkExtract);
  try
    J.Path := Root + '/progress.zip';
    J.Password := '';
    J.Dest := Root + '/dest-job-late';
    ForceDirectories(J.Dest);
    J.Start;
    J.WaitFor;
    { The work is over; a late request must not rewrite the result. }
    J.RequestCancel;
    Check(J.TakeResult(R, Err), 'late cancel: a result is reported');
    EqInt(R, TZ7Z_OK, 'late cancel: a finished job stays a success');
  finally
    J.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-cancel-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  if MakeArchive = '' then
  begin
    WriteLn('FAIL setup: cannot build the archive');
    Halt(2);
  end;

  TestProgressReports;
  TestSinkCancel;
  TestJobCancel;
  TestFinishedListingNotRelabelled;
  TestJobCancelTooLate;

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
