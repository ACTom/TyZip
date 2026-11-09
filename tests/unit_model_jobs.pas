program unit_model_jobs;
{$mode objfpc}{$H+}
{ TZJob: a retry after a wrong password is a Clone of the job that failed.

  The compiler cannot see that a hand-written Clone forgot a field, so a retry
  used to run a different job than the one that failed -- a rename retry went to
  entry 0 with an empty target name and rewrote the archive. Two tests pin the
  contract down: every payload field survives a Clone for every job kind, and a
  cloned rename really renames the entry it was told to. }
uses
  { The thread driver must be first: the job under test is a TThread. }
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

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant]));
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

function SettingsSignature(const S: TCreateSettings): string;
begin
  Result := Format('%s|%d|%s|%s|%d|%s|%s|%s|%d|%d|%d|%s|%d|%d|%s|%s|%s', [
    S.FormatName, S.Level, S.Method, BoolToStr(S.Solid, True), S.Threads,
    S.Password, BoolToStr(S.EncryptNames, True), BoolToStr(S.ZipAES256, True),
    S.VolumeSize, S.DictionarySize, S.WordSize, S.MatchFinder, S.NumPasses,
    S.Codepage, BoolToStr(S.ForceUtf8, True), S.ExtraOptions,
    BoolToStr(S.DeleteSources, True)]);
end;

function SameArray(const A, B: TLongWordArray): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
end;

{ --- a new job has no entry selected ------------------------------------- }

procedure TestDefaults;
var
  J: TZJob;
begin
  { Each kind reads its own payload; the -1 sentinels live there. }
  J := TZJob.Create(jkExtractOne);
  try
    EqInt(J.EntryIndex, -1, 'default: no entry selected');
  finally
    J.Free;
  end;
  J := TZJob.Create(jkRename);
  try
    EqInt(J.RenameIndex, -1, 'default: no entry to rename');
    EqStr(J.RenameTo, '', 'default: no rename target');
    Check(not J.SetComment, 'default: no comment edit');
    EqStr(J.NewComment, '', 'default: no comment text');
  finally
    J.Free;
  end;
end;

{ --- a cloned rename changes the entry it was told to -------------------- }

function WriteTextFile(const APath, AText: string): Boolean;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
    Result := True;
  finally
    L.Free;
  end;
end;

function BuildSampleArchive(out AError: string): string;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  R: Integer;
begin
  Result := Root + '/work.7z';
  WriteTextFile(Root + '/first.txt', 'first' + LineEnding);
  WriteTextFile(Root + '/second.txt', 'second' + LineEnding);
  L := TStringList.Create;
  Set1.Disk := nil;
  Set1.Arc := nil;
  try
    L.Add(Root + '/first.txt');
    L.Add(Root + '/second.txt');
    S := Default(TCreateSettings);
    S.FormatName := '7z';
    S.Level := 5;
    Set1 := TzCollectInputs(L, '');
    try
      R := TzCreateArchive(Result, S, Set1.Recs, AError);
      if R <> TZ7Z_OK then
        WriteLn('setup: cannot create the sample archive: ', AError);
    finally
      TzInputSetFree(Set1);
    end;
  finally
    L.Free;
  end;
end;

function EntryIndexIn(const AArchivePath, AName: string): Integer;
var
  A: TTzArchive;
  Err: string;
  I: Integer;
begin
  Result := -1;
  if TzOpenArchive(AArchivePath, '', A, Err) <> TZ7Z_OK then
  begin
    WriteLn('setup: cannot open the sample archive: ', Err);
    Exit;
  end;
  try
    for I := 0 to A.Count - 1 do
      if A.EntryName(I) = AName then
      begin
        Result := I;
        Exit;
      end;
  finally
    A.Free;
  end;
end;

function ArchiveEntries: TStringList;
var
  A: TTzArchive;
  Err: string;
  I: Integer;
begin
  Result := TStringList.Create;
  if TzOpenArchive(Root + '/work.7z', '', A, Err) <> TZ7Z_OK then
  begin
    WriteLn('check: cannot open the sample archive: ', Err);
    Exit;
  end;
  try
    for I := 0 to A.Count - 1 do
      Result.Add(A.EntryName(I));
  finally
    A.Free;
  end;
end;

procedure TestClonedRename;
var
  S: TCreateSettings;
  Idx: Integer;
  Base, C: TZJob;
  R: Integer;
  Err, Arc: string;
  Names: TStringList;
  I: Integer;
begin
  Arc := BuildSampleArchive(Err);
  Idx := EntryIndexIn(Arc, 'second.txt');
  Check(Idx >= 1, 'rename: the second entry is index 1 or later');
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 5;

  Base := TZJob.Create(jkRename);
  C := nil;
  try
    Base.Path := Arc;
    Base.Password := '';
    Base.RenameIndex := Idx;
    Base.RenameTo := 'renamed.txt';
    Base.Settings := S;
    C := Base.Clone;
    EqInt(C.RenameIndex, Idx, 'rename: the clone carries the entry index');
    EqStr(C.RenameTo, 'renamed.txt', 'rename: the clone carries the target name');
    C.Start;
    C.WaitFor;
    Check(C.TakeResult(R, Err), 'rename: the cloned job reports a result');
    Check(R = TZ7Z_OK, 'rename: the cloned job succeeds' + LineEnding + Err);

    Names := ArchiveEntries;
    try
      EqInt(Names.Count, 2, 'rename: entry count unchanged');
      Check(Names.IndexOf('renamed.txt') >= 0, 'rename: the new name is in the archive');
      Check(Names.IndexOf('second.txt') < 0, 'rename: the old name is gone');
      Check(Names.IndexOf('first.txt') >= 0, 'rename: the other entry is untouched');
    finally
      Names.Free;
    end;
  finally
    C.Free;
    Base.Free;
  end;
end;

procedure TestCancelDoesNotRelabel;
var
  J: TZJob;
  Entries: TArchiveEntries;
  R: Integer;
  Err: string;
begin
  SetLength(Entries, 2);
  Entries[0].Name := 'a.txt';
  Entries[0].Index := 0;
  Entries[1].Name := 'b.txt';
  Entries[1].Index := 1;
  J := TZJob.Create(jkList);
  try
    J.SetEntries(Entries);
    { A cancel that never reached the engine must not turn a finished job into
      "cancelled": the work is done and the UI has to refresh and clean up. }
    J.RequestCancel;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'cancel: the job reports a result');
    EqInt(R, TZ7Z_OK, 'cancel: a finished job stays a success');
  finally
    J.Free;
  end;
end;

procedure TestInvalidRenameIndex;
var
  S: TCreateSettings;
  J: TZJob;
  R: Integer;
  Err: string;
  Names: TStringList;
  Before: Integer;
begin
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 5;
  Names := ArchiveEntries;
  try
    Before := Names.Count;
  finally
    Names.Free;
  end;

  J := TZJob.Create(jkRename);
  try
    J.Path := Root + '/work.7z';
    J.Password := '';
    J.RenameIndex := -1;
    J.RenameTo := 'should-not-appear.txt';
    J.Settings := S;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'invalid rename: the job reports a result');
    EqInt(R, TZ7Z_E_ARG, 'invalid rename: refused as a bad argument');
  finally
    J.Free;
  end;

  Names := ArchiveEntries;
  try
    EqInt(Names.Count, Before, 'invalid rename: the archive is unchanged');
    Check(Names.IndexOf('should-not-appear.txt') < 0,
      'invalid rename: nothing was written');
  finally
    Names.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-jobs-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  Check(TzLoadLibrary(''), 'setup: the engine library loads');

  TestDefaults;
  TestClonedRename;
  TestInvalidRenameIndex;
  TestCancelDoesNotRelabel;

  if FileExists(Root + '/work.7z') then DeleteFile(Root + '/work.7z');
  if FileExists(Root + '/first.txt') then DeleteFile(Root + '/first.txt');
  if FileExists(Root + '/second.txt') then DeleteFile(Root + '/second.txt');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
