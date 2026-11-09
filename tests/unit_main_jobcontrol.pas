program unit_main_jobcontrol;
{$mode objfpc}{$H+}
{ The job controller: waiting queue, batch tally and password retry.

  Pinned here: jobs leave in arrival order, a cancel drops the queue, the batch
  counts what ran (including cancels) and composes one summary, and a retry keeps
  every input the failed job had. }
uses
  { TZJob is a TThread; creating one needs a thread driver. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, tzip.api, tzip.engine, tzip.jobs, tzip.jobcontrol;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqInt(const AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

function NewJob(AKind: TZJobKind): TZJob;
begin
  Result := TZJob.Create(AKind);
  Result.Path := '/tmp/a.zip';
  Result.DisplayName := 'a.zip';
end;

{ --- queue -------------------------------------------------------------- }

procedure TestQueue;
var
  C: TJobController;
  J: TZJob;
  Tag: Integer;
  Title, Detail: string;
begin
  C := TJobController.Create;
  try
    Check(not C.TakeNext(J, Tag, Title, Detail), 'queue: empty controller has no next job');
    EqInt(C.QueuedCount, 0, 'queue: empty count');

    C.Enqueue(NewJob(jkExtract), 11, 'one', 'first.zip');
    C.Enqueue(NewJob(jkTest), 22, 'two', 'second.zip');
    EqInt(C.QueuedCount, 2, 'queue: two waiting');

    Check(C.TakeNext(J, Tag, Title, Detail), 'queue: takes a job');
    try
      EqInt(Tag, 11, 'queue: FIFO tag');
      EqStr(Title, 'one', 'queue: title travels with the job');
      EqStr(Detail, 'first.zip', 'queue: detail travels with the job');
      Check(J.Kind = jkExtract, 'queue: the job keeps its kind');
    finally J.Free; end;

    Check(C.TakeNext(J, Tag, Title, Detail), 'queue: second job');
    try
      EqInt(Tag, 22, 'queue: FIFO order kept');
    finally J.Free; end;
    Check(not C.TakeNext(J, Tag, Title, Detail), 'queue: drained');

    { Cancel drops everything still waiting. }
    C.Enqueue(NewJob(jkExtract), 1, 'a', '');
    C.Enqueue(NewJob(jkExtract), 2, 'b', '');
    C.Clear;
    EqInt(C.QueuedCount, 0, 'queue: clear drops the queue');
    Check(not C.TakeNext(J, Tag, Title, Detail), 'queue: nothing after clear');
  finally C.Free; end;
end;

{ --- batch -------------------------------------------------------------- }

procedure TestBatch;
var
  C: TJobController;
  Msg: string;
begin
  C := TJobController.Create;
  try
    Check(not C.HasBatch, 'batch: a new controller has no batch');
    EqStr(C.SummaryText, '', 'batch: no summary before anything ran');

    C.BeginBatch;
    C.NoteResult('a.zip', TZ7Z_OK, '');
    C.NoteResult('b.zip', TZ7Z_OK, '');
    Check(C.HasBatch, 'batch: two results make a batch');
    Check(not C.BatchHadFailures, 'batch: no failures');
    Msg := C.SummaryText;
    Check(Pos('2', Msg) > 0, 'batch: the all-ok summary counts both');

    { A failure and a cancel both count as "not ok" and are listed with a name. }
    C.NoteResult('c.zip', TZ7Z_E_EXTRACT, 'broken');
    C.NoteResult('d.zip', TZ7Z_E_CANCEL, '');
    Check(C.BatchHadFailures, 'batch: failures are reported');
    Msg := C.SummaryText;
    Check(Pos('c.zip', Msg) > 0, 'batch: the failing archive is named');
    Check(Pos('d.zip', Msg) > 0, 'batch: a cancelled archive is named');

    { The tally ends and a new one starts clean. }
    C.EndBatch;
    Check(not C.HasBatch, 'batch: end clears the tally');
    EqStr(C.SummaryText, '', 'batch: no summary after the end');

    { The error list is capped, but says how many were left out. }
    C.BeginBatch;
    C.NoteResult('ok.zip', TZ7Z_OK, '');
    C.NoteResult('e1.zip', TZ7Z_E_EXTRACT, 'bad');
    C.NoteResult('e2.zip', TZ7Z_E_EXTRACT, 'bad');
    C.NoteResult('e3.zip', TZ7Z_E_EXTRACT, 'bad');
    Msg := C.SummaryText;
    Check(Pos('e1.zip', Msg) > 0, 'batch: first failure listed');

    { A cancelled batch item is recorded even when nothing else failed. }
    C.EndBatch;
    C.BeginBatch;
    C.NoteResult('only.zip', TZ7Z_E_CANCEL, '');
    Check(C.BatchHadFailures, 'batch: one cancel is a failed batch run');
    Check(Pos('only.zip', C.SummaryText) > 0, 'batch: the cancelled item is named');
  finally C.Free; end;
end;

{ --- password retry ----------------------------------------------------- }

procedure TestRetry;
var
  C: TJobController;
  Original, Retry: TZJob;
begin
  C := TJobController.Create;
  try
    Original := NewJob(jkRename);
    Original.Password := 'old';
    Original.RenameIndex := 7;
    Original.RenameTo := 'new name.txt';
    Original.NewComment := 'note';
    Original.SetComment := True;
    Original.Indices := TLongWordArray([3, 4]);
    Original.Dest := '/out';
    Original.ArcPrefix := 'docs';
    Original.Sources := TStringList.Create;
    Original.Sources.Add('/tmp/x');

    Retry := C.CloneForRetry(Original, 'new');
    try
      Check(Retry <> nil, 'retry: a clone is produced');
      Check(Retry <> Original, 'retry: the clone is a different object');
      EqStr(Retry.Password, 'new', 'retry: the new password is set');
      EqStr(Original.Password, 'old', 'retry: the failed job is untouched');
      { A hand-picked copy is how a rename retry once rewrote the wrong entry:
        every input has to survive. }
      EqInt(Retry.RenameIndex, 7, 'retry: the rename target survives');
      EqStr(Retry.RenameTo, 'new name.txt', 'retry: the new name survives');
      EqStr(Retry.NewComment, 'note', 'retry: the comment survives');
      Check(Retry.SetComment, 'retry: the set-comment flag survives');
      EqInt(Length(Retry.Indices), 2, 'retry: the index list survives');
      EqStr(Retry.Dest, '/out', 'retry: the destination survives');
      EqStr(Retry.ArcPrefix, 'docs', 'retry: the archive prefix survives');
      Check((Retry.Sources <> nil) and (Retry.Sources.Count = 1),
        'retry: the source list is copied');
    finally
      Retry.Free;
      Original.Free;
    end;

    Check(C.CloneForRetry(nil, 'x') = nil, 'retry: no job, no clone');
  finally C.Free; end;
end;

begin
  Fails := 0; Passes := 0;
  TestQueue;
  TestBatch;
  TestRetry;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
