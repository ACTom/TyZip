program unit_main_jobqueue;
{$mode objfpc}{$H+}
{ The waiting-job queue used by tzip.main.

  The bug this pins: the queue used to be a dynamic array of records holding
  strings, shifted with Move() and shrunk with SetLength(). The last slot's
  string was finalized while the shifted copy above still pointed at it, so with
  two or more queued jobs the next dequeue read freed memory. The regression is
  that every label survives every dequeue, in order, for a queue of three and
  after many cycles. }
uses
  SysUtils, Classes, tzip.jobqueue;

type
  { A payload that counts its own freeing, so Clear can be checked. The object
    itself must not be inspected after Free -- reading a field of freed memory is
    undefined, and the heap happily reuses it -- so the count lives in a global. }
  TProbe = class
  public
    destructor Destroy; override;
  end;

var
  Fails, Passes: Integer;
  FreeCount: Integer = 0;

destructor TProbe.Destroy;
begin
  Inc(FreeCount);
  inherited Destroy;
end;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
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

function Dummy: TProbe;
begin
  Result := TProbe.Create;
end;

{ --- order ------------------------------------------------------------- }

procedure TestOrder;
var
  Q: TJobQueue;
  J: TQueuedJob;
begin
  Q := TJobQueue.Create;
  try
    Check(Q.Count = 0, 'order: new queue is empty');
    Check(Q.First = nil, 'order: first of an empty queue is nil');
    Check(Q.TakeFirst = nil, 'order: taking from an empty queue is nil');

    Q.Enqueue(Dummy, 11, 'one', 'detail one');
    Q.Enqueue(Dummy, 22, 'two', 'detail two');
    Q.Enqueue(Dummy, 33, 'three', 'detail three');
    Check(Q.Count = 3, 'order: three queued');
    Check(Q.First.Tag = 11, 'order: first is the oldest');
    Check(Q.Count = 3, 'order: First does not consume');

    J := Q.TakeFirst;
    try
      Check(J.Tag = 11, 'order: oldest comes out first');
    finally J.Free; end;
    Check(Q.Count = 2, 'order: count drops');

    J := Q.TakeFirst;
    try
      Check(J.Tag = 22, 'order: then the second');
    finally J.Free; end;
    J := Q.TakeFirst;
    try
      Check(J.Tag = 33, 'order: then the third');
    finally J.Free; end;
    Check(Q.Count = 0, 'order: drained');
    Check(Q.TakeFirst = nil, 'order: nothing left');
  finally Q.Free; end;
end;

{ --- the use-after-free regression ------------------------------------- }

procedure TestLabelsSurviveDequeue;
var
  Q: TJobQueue;
  J: TQueuedJob;
  I: Integer;
  Want: array[0..2] of string;
  WantDetail: array[0..2] of string;
begin
  Want[0] := 'Extracting the first archive of the batch'; 
  Want[1] := 'Extracting the second archive of the batch';
  Want[2] := 'Extracting the third archive of the batch';
  WantDetail[0] := 'first-archive.7z';
  WantDetail[1] := 'second-archive.7z';
  WantDetail[2] := 'third-archive.7z';

  Q := TJobQueue.Create;
  try
    for I := 0 to 2 do
      Q.Enqueue(Dummy, I, Want[I], WantDetail[I]);

    { Read the LAST item's labels while it is still queued: it is the record the
      old shift finalized first. }
    EqStr(Q.First.Title, Want[0], 'uaf: head labels intact');

    J := Q.TakeFirst;
    try
      EqStr(J.Title, Want[0], 'uaf: taken labels intact');
      EqStr(J.Detail, WantDetail[0], 'uaf: taken detail intact');
    finally J.Free; end;

    { After one shift the remaining items must still carry their own strings.
      Reading them is exactly what the dangling pointers broke. }
    EqStr(Q.First.Title, Want[1], 'uaf: second labels intact after shift');
    EqStr(Q.First.Detail, WantDetail[1], 'uaf: second detail intact after shift');

    J := Q.TakeFirst;
    try
      EqStr(J.Title, Want[1], 'uaf: second is intact after the shift');
      EqStr(J.Detail, WantDetail[1], 'uaf: second detail intact after the shift');
    finally J.Free; end;

    EqStr(Q.First.Title, Want[2], 'uaf: third labels intact after two shifts');
    J := Q.TakeFirst;
    try
      EqStr(J.Title, Want[2], 'uaf: third is intact');
      EqStr(J.Detail, WantDetail[2], 'uaf: third detail intact');
    finally J.Free; end;
  finally Q.Free; end;
end;

{ Three jobs, each dequeued and started in turn -- the shape of a batch. }
procedure TestThreeJobsRunInTurn;
var
  Q: TJobQueue;
  J: TQueuedJob;
  Ran: Integer;
begin
  Ran := 0;
  Q := TJobQueue.Create;
  try
    Q.Enqueue(Dummy, 0, 'first', 'a');
    Q.Enqueue(Dummy, 1, 'second', 'b');
    Q.Enqueue(Dummy, 2, 'third', 'c');
    { A queue of three shifted down three times. }
    while Q.Count > 0 do
    begin
      J := Q.TakeFirst;
      try
        Inc(Ran);
        Check(J.Tag = Ran - 1, Format('batch: job %d in order', [Ran]));
        Check(J.Title <> '', Format('batch: job %d has its title', [Ran]));
      finally J.Free; end;
    end;
    Check(Ran = 3, 'batch: all three ran');
  finally Q.Free; end;
end;

{ --- ownership --------------------------------------------------------- }

procedure TestClearFreesPayloads;
var
  Q: TJobQueue;
  Before: Integer;
begin
  Before := FreeCount;
  Q := TJobQueue.Create;
  try
    Q.Enqueue(Dummy, 0, 'a', '');
    Q.Enqueue(Dummy, 1, 'b', '');
    Q.Clear;
    Check(Q.Count = 0, 'clear: queue empties');
    Check(FreeCount - Before = 2, 'clear: both payloads freed');
    { Clear on an empty queue must not raise, and must not free anything twice. }
    Q.Clear;
    Check(Q.Count = 0, 'clear: second clear is harmless');
    Check(FreeCount - Before = 2, 'clear: second clear frees nothing');
  finally Q.Free; end;
end;

procedure TestDestroyFreesPayloads;
var
  Q: TJobQueue;
  Before: Integer;
begin
  Before := FreeCount;
  Q := TJobQueue.Create;
  Q.Enqueue(Dummy, 0, 'a', '');
  Q.Free;
  Check(FreeCount - Before = 1, 'destroy: a queued payload is freed with the queue');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  TestOrder;
  TestLabelsSurviveDequeue;
  TestThreeJobsRunInTurn;
  TestClearFreesPayloads;
  TestDestroyFreesPayloads;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.