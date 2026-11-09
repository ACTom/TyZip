{ One batch extraction run: where each archive is in the chain
  list entries -> resolve conflicts -> extract, and what the run has counted.

  This is deliberately pure: it knows nothing about the window, the current archive
  context or the job machinery. The window owns one TBatchRun per run, feeds it the
  listing of each archive, asks it to resolve the conflicts for that archive, then
  starts the extraction the run hands back. Keeping it out here means the step rules
  (one archive at a time, cancel stops the chain, skip/rename/failure counts) are
  testable without a UI or an engine.

  The rule for re-entry is structural: while an item is listing or extracting,
  StartNext answers -1, so a second batch can never grow a parallel chain. }

unit tzip.batch;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tzip.engine, tzip.extract;

type
  TBatchStage = (
    bsPending,     { not started }
    bsListing,     { its entry list is being fetched }
    bsExtracting,  { conflicts resolved; extraction queued or running }
    bsDone,        { extraction succeeded (or there was nothing left to write) }
    bsFailed,      { listing or extraction failed }
    bsCancelled,   { the user cancelled while this archive was in flight }
    bsSkipped      { not an archive: never started }
  );

  TBatchItem = record
    Path: string;
    Stage: TBatchStage;
    EntryCount: Integer;
    KeptCount: Integer;      { entries the extraction will write }
    SkippedCount: Integer;   { entries the conflict policy leaves alone }
    RenamedCount: Integer;   { existing files moved aside by "keep both" }
    Error: string;
  end;

  TBatchRun = class
  private
    FItems: array of TBatchItem;
    FDest: string;
    FConflict: TExtractConflict;
    FIndex: Integer;          { the item that is listing/extracting, -1 = none }
    FStopRequested: Boolean;
    FIndices: TLongWordArray; { entry indices for the active extraction }
    function GetItem(AIndex: Integer): TBatchItem;
    function GetCount: Integer;
    function GetDoneCount: Integer;
    function GetFailedCount: Integer;
    function GetCancelledCount: Integer;
    function GetSkippedNonArchiveCount: Integer;
    function GetSkippedEntryCount: Integer;
    function GetRenamedEntryCount: Integer;
  public
    constructor Create(const AArchives: TStrings; const ADest: string;
      AConflict: TExtractConflict);

    { The archive whose entries should be listed next, or -1 when the chain is
      stopped, finished, or an archive is already in flight. }
    function StartNext: Integer;
    { The listing for AIndex arrived with AEntryCount entries. }
    procedure NoteListed(AIndex, AEntryCount: Integer);
    { Resolve AIndex's conflicts against the destination. AEntries are the
      archive's entries and AIndices their engine indices, in the same order.
      Answers True when there is something to extract. }
    function Resolve(AIndex: Integer; const AEntries: TExtractEntryArray;
      const AIndices: TLongWordArray): Boolean;
    procedure NoteExtracted(AIndex, AResult: Integer; const AError: string);
    procedure NoteListingFailed(AIndex: Integer; const AError: string);
    { The user cancelled while AIndex was listing/extracting: it is not a failure
      and not finished work, and no later archive starts. }
    procedure NoteCancelled(AIndex: Integer);
    { Stop after the archive in flight finishes: no new one is started. }
    procedure RequestStop;

    function CanStartNext: Boolean;
    function AllFinished: Boolean;
    function CurrentIndices: TLongWordArray;
    function ActiveItem: Integer;

    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TBatchItem read GetItem; default;
    property DoneCount: Integer read GetDoneCount;
    property FailedCount: Integer read GetFailedCount;
    property CancelledCount: Integer read GetCancelledCount;
    property SkippedNonArchiveCount: Integer read GetSkippedNonArchiveCount;
    property SkippedEntryCount: Integer read GetSkippedEntryCount;
    property RenamedEntryCount: Integer read GetRenamedEntryCount;
    property Destination: string read FDest;
    property Conflict: TExtractConflict read FConflict;
  end;

implementation

constructor TBatchRun.Create(const AArchives: TStrings; const ADest: string;
  AConflict: TExtractConflict);
var
  I: Integer;
begin
  inherited Create;
  FDest := ADest;
  FConflict := AConflict;
  FIndex := -1;
  FStopRequested := False;
  if AArchives = nil then Exit;
  SetLength(FItems, AArchives.Count);
  for I := 0 to AArchives.Count - 1 do
  begin
    FItems[I] := Default(TBatchItem);
    FItems[I].Path := AArchives[I];
    if TzIsArchiveName(AArchives[I]) then
      FItems[I].Stage := bsPending
    else
    begin
      FItems[I].Stage := bsSkipped;
      FItems[I].Error := 'not an archive';
    end;
  end;
end;

function TBatchRun.GetItem(AIndex: Integer): TBatchItem;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    Result := Default(TBatchItem)
  else
    Result := FItems[AIndex];
end;

function TBatchRun.GetCount: Integer;
begin
  Result := Length(FItems);
end;

function TBatchRun.GetDoneCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    if FItems[I].Stage = bsDone then Inc(Result);
end;

function TBatchRun.GetFailedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    if FItems[I].Stage = bsFailed then Inc(Result);
end;

function TBatchRun.GetCancelledCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    if FItems[I].Stage = bsCancelled then Inc(Result);
end;

function TBatchRun.GetSkippedNonArchiveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    if FItems[I].Stage = bsSkipped then Inc(Result);
end;

function TBatchRun.GetSkippedEntryCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    Inc(Result, FItems[I].SkippedCount);
end;

function TBatchRun.GetRenamedEntryCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    Inc(Result, FItems[I].RenamedCount);
end;

function TBatchRun.ActiveItem: Integer;
begin
  if (FIndex >= 0) and (FIndex <= High(FItems)) and
     (FItems[FIndex].Stage in [bsListing, bsExtracting]) then
    Result := FIndex
  else
    Result := -1;
end;

function TBatchRun.CanStartNext: Boolean;
begin
  Result := (not FStopRequested) and (ActiveItem < 0);
end;

function TBatchRun.StartNext: Integer;
var
  I: Integer;
begin
  Result := -1;
  { One archive at a time, and never past a stop request. }
  if not CanStartNext then Exit;
  for I := 0 to High(FItems) do
    if FItems[I].Stage = bsPending then
    begin
      FIndex := I;
      FItems[I].Stage := bsListing;
      Exit(I);
    end;
end;

procedure TBatchRun.NoteListed(AIndex, AEntryCount: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  if FItems[AIndex].Stage <> bsListing then Exit;
  FItems[AIndex].EntryCount := AEntryCount;
end;

function TBatchRun.Resolve(AIndex: Integer; const AEntries: TExtractEntryArray;
  const AIndices: TLongWordArray): Boolean;
var
  Keep: TExtractEntryKeep;
  Collisions, I, N: Integer;
  Kept, Skipped: Integer;
begin
  Result := False;
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  if FItems[AIndex].Stage <> bsListing then Exit;
  { Ticket 04's entry-level semantics: skip by not requesting the entry, rename by
    moving aside only the existing file that entry would replace. Files elsewhere
    in the destination are never touched. }
  Collisions := ResolveExtractConflicts(FDest, AEntries, FConflict, Keep);
  Kept := 0;
  Skipped := 0;
  N := 0;
  SetLength(FIndices, Length(AIndices));
  for I := 0 to High(AEntries) do
  begin
    if (I > High(Keep)) or Keep[I] then
    begin
      if I <= High(AIndices) then
      begin
        FIndices[N] := AIndices[I];
        Inc(N);
      end;
      Inc(Kept);
    end
    else
      Inc(Skipped);
  end;
  SetLength(FIndices, N);
  FItems[AIndex].KeptCount := Kept;
  FItems[AIndex].SkippedCount := Skipped;
  if FConflict = ecRename then
    { Of the collisions, the ones that were kept are the ones moved aside. }
    FItems[AIndex].RenamedCount := Collisions - Skipped
  else
    FItems[AIndex].RenamedCount := 0;
  if Kept = 0 then
  begin
    { Everything was skipped: there is nothing to extract, and that is a
      successful outcome for this archive, not a failure. }
    FItems[AIndex].Stage := bsDone;
    SetLength(FIndices, 0);
    Exit(False);
  end;
  FItems[AIndex].Stage := bsExtracting;
  Result := True;
end;

procedure TBatchRun.NoteExtracted(AIndex, AResult: Integer; const AError: string);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  if FItems[AIndex].Stage <> bsExtracting then Exit;
  if AResult = 0 then
    FItems[AIndex].Stage := bsDone
  else
  begin
    FItems[AIndex].Stage := bsFailed;
    FItems[AIndex].Error := AError;
  end;
  if FIndex = AIndex then FIndex := -1;
end;

procedure TBatchRun.NoteListingFailed(AIndex: Integer; const AError: string);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  if FItems[AIndex].Stage <> bsListing then Exit;
  FItems[AIndex].Stage := bsFailed;
  FItems[AIndex].Error := AError;
  if FIndex = AIndex then FIndex := -1;
end;

procedure TBatchRun.NoteCancelled(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  if not (FItems[AIndex].Stage in [bsListing, bsExtracting]) then Exit;
  FItems[AIndex].Stage := bsCancelled;
  if FIndex = AIndex then FIndex := -1;
  { Cancelling one archive cancels the chain: the remaining archives must not
    start behind the user's back. }
  FStopRequested := True;
end;

procedure TBatchRun.RequestStop;
begin
  FStopRequested := True;
end;

function TBatchRun.AllFinished: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to High(FItems) do
    if FItems[I].Stage in [bsPending, bsListing, bsExtracting] then
      Exit(False);
end;

function TBatchRun.CurrentIndices: TLongWordArray;
begin
  Result := Copy(FIndices);
end;

end.
