{ The queue of waiting archive jobs, the batch tally, and the password retry.

  TMainForm used to hold all three as loose fields next to the widgets: a job FIFO,
  three integers and an error list for the batch, plus the "clone the job and put
  the new password in" step buried in the completion handler. None of it needs a
  window: it needs to know what runs next, what the batch has done so far, and
  what a retry has to preserve. Keeping it here is what makes "cancel the password
  prompt and the batch still settles" and "a rename retry does not become a
  comment edit" testable.

  Layer: controller. Uses tzip.jobs and the bridge's result codes; no LCL. }
unit tzip.jobcontrol;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tzip.api, tzip.jobs, tzip.jobqueue;

type
  TJobController = class
  private
    FQueue: TJobQueue;
    FBatchTotal: Integer;
    FBatchOK: Integer;
    FBatchFailed: Integer;
    FBatchErrors: TStringList;
  public
    constructor Create;
    destructor Destroy; override;

    { --- the waiting queue --------------------------------------------- }

    { Park a job until the running one finishes. The controller owns it. }
    procedure Enqueue(AJob: TZJob; ATag: Integer; const ATitle, ADetail: string);
    { Start the oldest waiting job. False when there is none. The caller owns the
      returned job. }
    function TakeNext(out AJob: TZJob; out ATag: Integer;
      out ATitle, ADetail: string): Boolean;
    function QueuedCount: Integer;
    { Drop every waiting job (the whole request was cancelled). }
    procedure Clear;

    { --- the batch tally ----------------------------------------------- }

    { Start a new tally. Called when a batch's first item starts from idle. }
    procedure BeginBatch;
    { Record one finished batch item. }
    procedure NoteResult(const ADisplay: string; AResult: Integer;
      const AError: string);
    function HasBatch: Boolean;
    { How many items the current tally covers; the status line reports it. }
    function SummaryCount: Integer;
    function BatchHadFailures: Boolean;
    { The summary dialog's text, or '' when nothing ran. Composed while the tally
      is still readable, so call EndBatch afterwards. }
    function SummaryText: string;
    procedure EndBatch;

    { --- password retry ------------------------------------------------ }

    { A fresh job with every input of AJob and the new password. A finished
      TThread cannot run again, and a hand-picked subset of fields is how a retry
      once ran a different job than the one that failed, so this copies via
      TZJob.Clone and only overrides the password.
      The caller frees AJob and owns the result. }
    function CloneForRetry(AJob: TZJob; const APassword: string): TZJob;
  end;

implementation

uses
  tzip.i18n;

const
  { A batch of 200 broken archives does not need 200 lines in a dialog; the first
    few are what the user acts on. }
  MaxSummaryErrors = 10;

constructor TJobController.Create;
begin
  inherited Create;
  FQueue := TJobQueue.Create;
  FBatchErrors := TStringList.Create;
end;

destructor TJobController.Destroy;
begin
  FQueue.Free;
  FBatchErrors.Free;
  inherited Destroy;
end;

procedure TJobController.Enqueue(AJob: TZJob; ATag: Integer;
  const ATitle, ADetail: string);
begin
  FQueue.Enqueue(AJob, ATag, ATitle, ADetail);
end;

function TJobController.TakeNext(out AJob: TZJob; out ATag: Integer;
  out ATitle, ADetail: string): Boolean;
begin
  AJob := TZJob(FQueue.TakeFirstPayload(ATag, ATitle, ADetail));
  Result := AJob <> nil;
end;

function TJobController.QueuedCount: Integer;
begin
  Result := FQueue.Count;
end;

procedure TJobController.Clear;
begin
  FQueue.Clear;
end;

procedure TJobController.BeginBatch;
begin
  FBatchTotal := 0;
  FBatchOK := 0;
  FBatchFailed := 0;
  FBatchErrors.Clear;
end;

procedure TJobController.NoteResult(const ADisplay: string; AResult: Integer;
  const AError: string);
begin
  Inc(FBatchTotal);
  if AResult = TZ7Z_OK then
    Inc(FBatchOK)
  else
  begin
    Inc(FBatchFailed);
    if AResult = TZ7Z_E_CANCEL then
      FBatchErrors.Add(ADisplay + ': ' + rsStatusCancelled)
    else
      FBatchErrors.Add(ADisplay + ': ' + AError);
  end;
end;

function TJobController.HasBatch: Boolean;
begin
  Result := FBatchTotal > 0;
end;

function TJobController.SummaryCount: Integer;
begin
  Result := FBatchTotal;
end;

function TJobController.BatchHadFailures: Boolean;
begin
  Result := FBatchFailed > 0;
end;

function TJobController.SummaryText: string;
var
  I: Integer;
begin
  Result := '';
  if FBatchTotal = 0 then Exit;
  if FBatchFailed = 0 then
  begin
    Result := Format(rsBatchAllOkFmt, [FBatchTotal]);
    Exit;
  end;
  Result := Format(rsBatchSomeFailedFmt, [FBatchTotal, FBatchOK, FBatchFailed]);
  Result := Result + LineEnding + LineEnding;
  for I := 0 to FBatchErrors.Count - 1 do
  begin
    if I >= MaxSummaryErrors then
    begin
      Result := Result + LineEnding +
        Format(rsBatchMoreFmt, [FBatchErrors.Count - MaxSummaryErrors]);
      Break;
    end;
    Result := Result + FBatchErrors[I] + LineEnding;
  end;
end;

procedure TJobController.EndBatch;
begin
  BeginBatch;
end;

function TJobController.CloneForRetry(AJob: TZJob;
  const APassword: string): TZJob;
begin
  Result := nil;
  if AJob = nil then Exit;
  { Clone copies every input field on purpose (see TZJob.Clone); only the password
    changes, because that is the only thing the retry is about. }
  Result := AJob.Clone;
  Result.Password := APassword;
end;

end.
