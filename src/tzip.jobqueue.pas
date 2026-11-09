{ Jobs waiting for the one that is running to finish.

  The window runs one archive operation at a time. Everything else the user asks
  for meanwhile is parked here, in arrival order, and started when the running
  job lands. That is what makes "select twenty archives, extract them all" a
  sequence instead of one extraction and nineteen refusals.

  The queue is a class rather than an array of records for a reason that cost a
  crash: a waiting job carries its title and detail strings, and shifting such a
  record with Move() or shrinking the array with SetLength() does not maintain
  the reference counts. Moving the array left the shifted strings sharing their
  reference count with the finalized last slot, so with two or more queued jobs
  the second StartNextQueued read freed memory. }
unit tzip.jobqueue;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { One waiting job: an opaque payload owned by the queue, a caller-defined tag
    (the main form stores a TZJobPurpose there) and the two lines the overlay
    shows. }
  TQueuedJob = class
  private
    FPayload: TObject;
    FTag: Integer;
    FTitle: string;
    FDetail: string;
  public
    destructor Destroy; override;
    { Hand the payload over: the item no longer owns it. Used when the caller
      takes a job out to run it. }
    function Detach: TObject;
    property Payload: TObject read FPayload;
    property Tag: Integer read FTag;
    property Title: string read FTitle;
    property Detail: string read FDetail;
  end;

  { First in, first out. Owns the items and their payloads. }
  TJobQueue = class
  private
    FItems: TList;
  public
    constructor Create;
    destructor Destroy; override;
    { Append a job. The queue takes ownership of APayload. }
    function Enqueue(APayload: TObject; ATag: Integer;
      const ATitle, ADetail: string): TQueuedJob;
    function Count: Integer;
    { The oldest job still queued, or nil. The queue keeps ownership. }
    function First: TQueuedJob;
    { Remove the oldest job and hand it over: the CALLER owns the result and must
      free it (which frees the payload). nil when the queue is empty. }
    function TakeFirst: TQueuedJob;
    { Remove the oldest job, hand its PAYLOAD to the caller and free the item.
      nil when the queue is empty; the caller owns the payload. }
    function TakeFirstPayload(out ATag: Integer;
      out ATitle, ADetail: string): TObject;
    { Free every waiting job, payloads included, and leave the queue empty. }
    procedure Clear;
  end;

implementation

{ TQueuedJob }

destructor TQueuedJob.Destroy;
begin
  FPayload.Free;
  inherited Destroy;
end;

function TQueuedJob.Detach: TObject;
begin
  Result := FPayload;
  FPayload := nil;
end;

{ TJobQueue }

constructor TJobQueue.Create;
begin
  inherited Create;
  FItems := TList.Create;
end;

destructor TJobQueue.Destroy;
begin
  Clear;
  FItems.Free;
  inherited Destroy;
end;

function TJobQueue.Enqueue(APayload: TObject; ATag: Integer;
  const ATitle, ADetail: string): TQueuedJob;
begin
  Result := TQueuedJob.Create;
  Result.FPayload := APayload;
  Result.FTag := ATag;
  Result.FTitle := ATitle;
  Result.FDetail := ADetail;
  FItems.Add(Result);
end;

function TJobQueue.Count: Integer;
begin
  Result := FItems.Count;
end;

function TJobQueue.First: TQueuedJob;
begin
  if FItems.Count = 0 then Exit(nil);
  Result := TQueuedJob(FItems[0]);
end;

function TJobQueue.TakeFirst: TQueuedJob;
begin
  Result := nil;
  if FItems.Count = 0 then Exit;
  Result := TQueuedJob(FItems[0]);
  { Deleting the entry does not touch the string fields of the object: the item
    itself lives on and stays valid for the caller. This is the whole point of
    the class. }
  FItems.Delete(0);
end;

function TJobQueue.TakeFirstPayload(out ATag: Integer;
  out ATitle, ADetail: string): TObject;
var
  Item: TQueuedJob;
begin
  Result := nil;
  ATag := 0;
  ATitle := '';
  ADetail := '';
  Item := TakeFirst;
  if Item = nil then Exit;
  try
    Result := Item.Detach;
    ATag := Item.Tag;
    ATitle := Item.Title;
    ADetail := Item.Detail;
  finally
    Item.Free;
  end;
end;

procedure TJobQueue.Clear;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TObject(FItems[I]).Free;
  FItems.Clear;
end;

end.
