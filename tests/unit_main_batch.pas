program unit_main_batch;
{$mode objfpc}{$H+}
{ The batch extraction state machine: one archive at a time, list -> resolve ->
  extract, cancel stops the chain, and the skip/rename/failure numbers the summary
  is built from.

  Pure data on purpose: no window, no current archive context, no job machinery. }
uses
  SysUtils, Classes, tzip.engine, tzip.extract, tzip.batch;

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

function TempDir(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + AName;
  if DirectoryExists(Result) then
    RemoveDir(Result);
  ForceDirectories(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

procedure WriteTextFile(const APath, AText: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then
      F.WriteBuffer(Pointer(AText)^, Length(AText));
  finally
    F.Free;
  end;
end;

function TwoArchives: TStringList;
begin
  Result := TStringList.Create;
  Result.Add('/tmp/a.zip');
  Result.Add('/tmp/b.7z');
end;

function OneEntry(const AName: string; AIsDir: Boolean): TExtractEntry;
begin
  Result := Default(TExtractEntry);
  Result.Name := AName;
  Result.IsDir := AIsDir;
end;

{ --- construction ------------------------------------------------------- }

procedure TestConstruction;
var
  L: TStringList;
  R: TBatchRun;
begin
  L := TStringList.Create;
  try
    L.Add('/tmp/a.zip');
    L.Add('/tmp/notes.txt');   { not an archive }
    L.Add('/tmp/b.7z');
    R := TBatchRun.Create(L, '/tmp/out', ecOverwrite);
    try
      EqInt(R.Count, 3, 'construct: one item per input');
      EqInt(R.SkippedNonArchiveCount, 1, 'construct: a non-archive is skipped');
      EqInt(Ord(R[1].Stage), Ord(bsSkipped), 'construct: skipped item stage');
      EqInt(R.DoneCount, 0, 'construct: nothing done yet');
      Check(not R.AllFinished, 'construct: a run with pending items is not finished');
    finally R.Free; end;
  finally L.Free; end;
end;

{ --- one archive at a time ---------------------------------------------- }

procedure TestSequentialChain;
var
  L: TStringList;
  R: TBatchRun;
  Idx: Integer;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
begin
  L := TwoArchives;
  try
    R := TBatchRun.Create(L, '', ecOverwrite);
    try
      Idx := R.StartNext;
      EqInt(Idx, 0, 'chain: first archive');
      EqInt(Ord(R[0].Stage), Ord(bsListing), 'chain: listing stage');
      { While it is in flight, no second chain may start. }
      EqInt(R.StartNext, -1, 'chain: refuses a parallel archive');
      Check(not R.CanStartNext, 'chain: cannot start while listing');

      R.NoteListed(0, 2);
      SetLength(Entries, 2);
      Entries[0] := OneEntry('one.txt', False);
      Entries[1] := OneEntry('dir', True);
      SetLength(Indices, 2);
      Indices[0] := 10;
      Indices[1] := 11;
      Check(R.Resolve(0, Entries, Indices), 'chain: resolve has entries to extract');
      EqInt(Ord(R[0].Stage), Ord(bsExtracting), 'chain: extracting stage');
      EqInt(R[0].KeptCount, 2, 'chain: both entries kept');
      EqInt(R[0].SkippedCount, 0, 'chain: nothing skipped');
      EqInt(R.CurrentIndices[0], 10, 'chain: first index');
      EqInt(R.CurrentIndices[1], 11, 'chain: second index');
      EqInt(R.StartNext, -1, 'chain: still refuses while extracting');

      R.NoteExtracted(0, 0, '');
      EqInt(Ord(R[0].Stage), Ord(bsDone), 'chain: done stage');
      EqInt(R.DoneCount, 1, 'chain: one done');
      Idx := R.StartNext;
      EqInt(Idx, 1, 'chain: next archive after the first finished');
      R.NoteListingFailed(1, 'boom');
      EqInt(Ord(R[1].Stage), Ord(bsFailed), 'chain: listing failure is a failed item');
      EqInt(R.FailedCount, 1, 'chain: one failed');
      { A failed archive is a finished step, not a pending one. }
      Check(R.AllFinished, 'chain: nothing pending after the failure');
    finally R.Free; end;
  finally L.Free; end;
end;

{ --- cancel ------------------------------------------------------------- }

procedure TestStop;
var
  L: TStringList;
  R: TBatchRun;
begin
  L := TwoArchives;
  try
    R := TBatchRun.Create(L, '', ecOverwrite);
    try
      EqInt(R.StartNext, 0, 'stop: first archive started');
      R.RequestStop;
      Check(not R.CanStartNext, 'stop: no new archive after the request');
      { The one in flight is allowed to finish. }
      R.NoteListingFailed(0, 'cancelled');
      EqInt(R.StartNext, -1, 'stop: second archive never starts');
      EqInt(Ord(R[1].Stage), Ord(bsPending), 'stop: second stays pending');
      Check(not R.AllFinished, 'stop: pending item means not finished');
    finally R.Free; end;
  finally L.Free; end;
end;

{ --- conflicts ---------------------------------------------------------- }

procedure TestSkipConflict;
var
  L: TStringList;
  R: TBatchRun;
  Dir: string;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
begin
  Dir := TempDir('tz-batch-skip');
  L := TStringList.Create;
  try
    L.Add('/tmp/a.zip');
    R := TBatchRun.Create(L, Dir, ecSkip);
    try
      EqInt(R.StartNext, 0, 'skip: listing started');
      R.NoteListed(0, 2);
      { Existing file that the archive would replace. }
      WriteTextFile(Dir + 'dup.txt', 'old');
      SetLength(Entries, 2);
      Entries[0] := OneEntry('dup.txt', False);
      Entries[1] := OneEntry('new.txt', False);
      SetLength(Indices, 2);
      Indices[0] := 3;
      Indices[1] := 4;
      Check(R.Resolve(0, Entries, Indices), 'skip: the new entry is still extracted');
      EqInt(R[0].KeptCount, 1, 'skip: existing entry kept out');
      EqInt(R[0].SkippedCount, 1, 'skip: one entry skipped');
      EqInt(R[0].RenamedCount, 0, 'skip: nothing renamed');
      EqInt(Length(R.CurrentIndices), 1, 'skip: only one index requested');
      EqInt(R.CurrentIndices[0], 4, 'skip: the new entry index');
      EqInt(R.SkippedEntryCount, 1, 'skip: run counts the skipped entry');
    finally R.Free; end;
  finally L.Free; end;
end;

procedure TestRenameConflict;
var
  L: TStringList;
  R: TBatchRun;
  Dir: string;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
begin
  Dir := TempDir('tz-batch-rename');
  L := TStringList.Create;
  try
    L.Add('/tmp/a.zip');
    R := TBatchRun.Create(L, Dir, ecRename);
    try
      EqInt(R.StartNext, 0, 'rename: listing started');
      R.NoteListed(0, 1);
      WriteTextFile(Dir + 'dup.txt', 'old');
      SetLength(Entries, 1);
      Entries[0] := OneEntry('dup.txt', False);
      SetLength(Indices, 1);
      Indices[0] := 7;
      Check(R.Resolve(0, Entries, Indices), 'rename: entry is still extracted');
      EqInt(R[0].KeptCount, 1, 'rename: entry kept');
      EqInt(R[0].RenamedCount, 1, 'rename: existing file moved aside');
      Check(not FileExists(Dir + 'dup.txt'),
        'rename: the existing file moved aside so the new one can take the name');
      EqInt(R.RenamedEntryCount, 1, 'rename: run counts the rename');
    finally R.Free; end;
  finally L.Free; end;
end;

procedure TestAllSkippedIsDone;
var
  L: TStringList;
  R: TBatchRun;
  Dir: string;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
begin
  Dir := TempDir('tz-batch-allskip');
  L := TStringList.Create;
  try
    L.Add('/tmp/a.zip');
    R := TBatchRun.Create(L, Dir, ecSkip);
    try
      EqInt(R.StartNext, 0, 'allskip: listing started');
      R.NoteListed(0, 1);
      WriteTextFile(Dir + 'only.txt', 'old');
      SetLength(Entries, 1);
      Entries[0] := OneEntry('only.txt', False);
      SetLength(Indices, 1);
      Indices[0] := 9;
      Check(not R.Resolve(0, Entries, Indices),
        'allskip: nothing to extract means no job');
      EqInt(Ord(R[0].Stage), Ord(bsDone),
        'allskip: skipping everything is a successful archive, not a failure');
      EqInt(R.DoneCount, 1, 'allskip: counted as done');
      Check(R.AllFinished, 'allskip: run finished without extracting');
    finally R.Free; end;
  finally L.Free; end;
end;

procedure TestCancelItem;
var
  L: TStringList;
  R: TBatchRun;
begin
  L := TwoArchives;
  try
    R := TBatchRun.Create(L, '', ecOverwrite);
    try
      EqInt(R.StartNext, 0, 'cancel: first archive in flight');
      R.NoteCancelled(0);
      EqInt(Ord(R[0].Stage), Ord(bsCancelled), 'cancel: item is cancelled, not failed');
      EqInt(R.CancelledCount, 1, 'cancel: counted separately');
      EqInt(R.FailedCount, 0, 'cancel: not counted as a failure');
      Check(not R.CanStartNext, 'cancel: the chain stops');
      EqInt(R.StartNext, -1, 'cancel: no later archive starts');
      EqInt(Ord(R[1].Stage), Ord(bsPending), 'cancel: second stays pending');
      Check(not R.AllFinished, 'cancel: a pending archive means the run is not finished');
    finally R.Free; end;
  finally L.Free; end;
end;

procedure TestWrongStageIgnored;
var
  L: TStringList;
  R: TBatchRun;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
begin
  L := TStringList.Create;
  try
    L.Add('/tmp/a.zip');
    R := TBatchRun.Create(L, '', ecOverwrite);
    try
      SetLength(Entries, 1);
      Entries[0] := OneEntry('x.txt', False);
      SetLength(Indices, 1);
      { Resolving before the listing was noted must not move the item. }
      Check(not R.Resolve(0, Entries, Indices), 'stage: resolve before listing is refused');
      EqInt(Ord(R[0].Stage), Ord(bsPending), 'stage: item stays pending');
      { Extracting without resolving is refused too. }
      R.StartNext;
      R.NoteExtracted(0, 0, '');
      EqInt(Ord(R[0].Stage), Ord(bsListing), 'stage: extract note before extracting is ignored');
    finally R.Free; end;
  finally L.Free; end;
end;

begin
  Fails := 0; Passes := 0;
  TestConstruction;
  TestSequentialChain;
  TestStop;
  TestSkipConflict;
  TestRenameConflict;
  TestAllSkippedIsDone;
  TestCancelItem;
  TestWrongStageIgnored;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
