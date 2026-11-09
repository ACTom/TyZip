program unit_model_jobmatrix;
{$mode objfpc}{$H+}
{ The nine job kinds through TZJob itself: success, failure and cancel.

  Unit tests elsewhere pin Clone, the rename payload and the cancel flag; this
  walks every job kind the UI can start through the production worker and the
  real engine, so a change to Execute (wrong field read, error swallowed, cancel
  ignored) fails here rather than in the application. Each kind gets:
    - success: the expected result AND something observable on disk/in memory;
    - failure: a payload that cannot work, with a non-OK result;
    - cancel: a cancel request that the engine either honours (TZ7Z_E_CANCEL)
      or cannot see at all (open/list), which must stay a success. }
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

function ZipSettings: TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := 'zip';
  Result.Level := 5;
  Result.ForceUtf8 := True;
end;

procedure PrepareSources;
begin
  WriteText(Root + '/src/a.txt', 'alpha' + LineEnding);
  WriteText(Root + '/src/b.txt', 'beta' + LineEnding);
end;

function Sources: TStringList;
begin
  Result := TStringList.Create;
  Result.Add(Root + '/src/a.txt');
  Result.Add(Root + '/src/b.txt');
end;

{ A pristine archive with the two source files at known indices 0 and 1. }
function MakeZip(const APath: string): Boolean;
var
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  Err: string;
  R: Integer;
begin
  Result := False;
  DeleteFile(APath);
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    Disk.Add(Root + '/src/a.txt');
    Arc.Add('a.txt');
    Disk.Add(Root + '/src/b.txt');
    Arc.Add('b.txt');
    Set1 := TzCollectInputsMapped(Disk, Arc);
    try
      R := TzCreateArchive(APath, ZipSettings, Set1.Recs, Err);
    finally
      TzInputSetFree(Set1);
    end;
    if R <> TZ7Z_OK then
      WriteLn('setup: cannot create ', APath, ': ', Err);
    Result := R = TZ7Z_OK;
  finally
    Arc.Free;
    Disk.Free;
  end;
end;

function EntryNames(const APath: string): string;
var
  A: TTzArchive;
  Err: string;
  I: Integer;
begin
  Result := '';
  A := nil;
  if TzOpenArchive(APath, '', A, Err) <> TZ7Z_OK then Exit('<' + Err + '>');
  try
    for I := 0 to A.Count - 1 do
      Result := Result + A.EntryName(I) + ';';
  finally
    A.Free;
  end;
end;

function RunJob(AJ: TZJob; out AError: string): Integer;
begin
  AJ.Start;
  AJ.WaitFor;
  if not AJ.TakeResult(Result, AError) then
  begin
    Result := -999;
    AError := 'the job reported no result';
  end;
end;

{ --- jkOpen -------------------------------------------------------------- }

procedure TestOpen;
var
  J: TZJob;
  Err: string;
  R: Integer;
begin
  MakeZip(Root + '/open.zip');
  J := TZJob.Create(jkOpen);
  try
    J.Path := Root + '/open.zip';
    J.DisplayName := 'open.zip';
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'open: success (' + Err + ')');
    Check(J.Ctx <> nil, 'open: success hands over a context');
    if J.Ctx <> nil then
      EqInt(Length(J.Ctx.Entries), 2, 'open: the context lists both entries');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkOpen);
  try
    J.Path := Root + '/missing.zip';
    J.DisplayName := 'missing.zip';
    R := RunJob(J, Err);
    Check(R <> TZ7Z_OK, 'open: a missing file fails');
    Check(J.Ctx = nil, 'open: no context for a failure');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkOpen);
  try
    J.Path := Root + '/open.zip';
    J.DisplayName := 'open.zip';
    { Opening walks the entries through the progress sink now, so a cancel
      request does reach the engine and the open reports cancellation. }
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'open: a cancel request stops the entry walk');
  finally
    J.Free;
  end;
end;

{ --- jkList -------------------------------------------------------------- }

function Snapshot: TArchiveEntries;
begin
  SetLength(Result, 2);
  Result[0] := Default(TArchiveEntry);
  Result[0].Name := 'a.txt';
  Result[0].Size := 5;
  Result[0].Index := 0;
  Result[1] := Default(TArchiveEntry);
  Result[1].Name := 'b.txt';
  Result[1].Size := 4;
  Result[1].Index := 1;
end;

procedure TestList;
var
  J: TZJob;
  Entries: TArchiveEntries;
  Err: string;
  R: Integer;
begin
  J := TZJob.Create(jkList);
  try
    J.SetEntries(Snapshot);
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'list: success');
    EqInt(Length(J.Listing), 2, 'list: both rows');
  finally
    J.Free;
  end;

  { An empty snapshot is the closest thing jkList has to a failure: it must
    produce an empty listing, not a crash. }
  J := TZJob.Create(jkList);
  try
    SetLength(Entries, 0);
    J.SetEntries(Entries);
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'list: an empty snapshot is not an error');
    EqInt(Length(J.Listing), 0, 'list: no rows');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkList);
  try
    J.SetEntries(Snapshot);
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'list: no cancellation point, so success stands');
  finally
    J.Free;
  end;
end;

{ --- jkExtract ----------------------------------------------------------- }

procedure TestExtract;
var
  J: TZJob;
  Err, Dest: string;
  R: Integer;
begin
  MakeZip(Root + '/extract.zip');
  Dest := Root + '/dest-extract';
  ForceDirectories(Dest);
  J := TZJob.Create(jkExtract);
  try
    J.Path := Root + '/extract.zip';
    J.Dest := Dest;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'extract: success (' + Err + ')');
    Check(FileExists(Dest + '/a.txt'), 'extract: the first file is there');
    Check(FileExists(Dest + '/b.txt'), 'extract: the second file is there');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkExtract);
  try
    J.Path := Root + '/missing.zip';
    J.Dest := Root + '/dest-extract-missing';
    R := RunJob(J, Err);
    Check(R <> TZ7Z_OK, 'extract: a missing archive fails');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkExtract);
  try
    J.Path := Root + '/extract.zip';
    J.Dest := Root + '/dest-extract-cancel';
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'extract: a cancel reaches the engine');
  finally
    J.Free;
  end;
end;

{ --- jkTest -------------------------------------------------------------- }

procedure TestTest;
var
  J: TZJob;
  Err: string;
  R: Integer;
begin
  MakeZip(Root + '/test.zip');
  J := TZJob.Create(jkTest);
  try
    J.Path := Root + '/test.zip';
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'test: success (' + Err + ')');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkTest);
  try
    J.Path := Root + '/missing.zip';
    R := RunJob(J, Err);
    Check(R <> TZ7Z_OK, 'test: a missing archive fails');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkTest);
  try
    J.Path := Root + '/test.zip';
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'test: a cancel reaches the engine');
  finally
    J.Free;
  end;
end;

{ --- jkExtractOne -------------------------------------------------------- }

procedure TestExtractOne;
var
  J: TZJob;
  Err, OutFile: string;
  R: Integer;
begin
  MakeZip(Root + '/one.zip');
  OutFile := Root + '/one-out.txt';
  DeleteFile(OutFile);
  J := TZJob.Create(jkExtractOne);
  try
    J.Path := Root + '/one.zip';
    J.EntryIndex := 1;
    J.OutFile := OutFile;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'extract one: success (' + Err + ')');
    Check(FileExists(OutFile), 'extract one: the file is written');
  finally
    J.Free;
  end;

  { A negative index is refused before it reaches the engine. }
  J := TZJob.Create(jkExtractOne);
  try
    J.Path := Root + '/one.zip';
    J.EntryIndex := -1;
    J.OutFile := Root + '/one-bad.txt';
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_ARG, 'extract one: a negative index is refused');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkExtractOne);
  try
    J.Path := Root + '/one.zip';
    J.EntryIndex := 999;
    J.OutFile := Root + '/one-ghost.txt';
    R := RunJob(J, Err);
    Check(R <> TZ7Z_OK, 'extract one: an out-of-range index fails');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkExtractOne);
  try
    J.Path := Root + '/one.zip';
    J.EntryIndex := 0;
    J.OutFile := Root + '/one-cancel.txt';
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'extract one: a cancel reaches the engine');
  finally
    J.Free;
  end;
end;

{ --- jkCreate ------------------------------------------------------------ }

procedure TestCreate;
var
  J: TZJob;
  Err, OutPath: string;
  R: Integer;
begin
  OutPath := Root + '/created.zip';
  DeleteFile(OutPath);
  J := TZJob.Create(jkCreate);
  try
    J.Path := OutPath;
    J.Sources := Sources;
    J.Settings := ZipSettings;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'create: success (' + Err + ')');
    Check(FileExists(OutPath), 'create: the archive is written');
  finally
    J.Free;
  end;

  { Nothing to put in it is an argument error, not an empty archive. }
  OutPath := Root + '/created-empty.zip';
  DeleteFile(OutPath);
  J := TZJob.Create(jkCreate);
  try
    J.Path := OutPath;
    J.Sources := TStringList.Create;
    J.Settings := ZipSettings;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_ARG, 'create: no inputs is an argument error');
    Check(not FileExists(OutPath), 'create: no archive is written without inputs');
  finally
    J.Free;
  end;

  OutPath := Root + '/created-cancel.zip';
  DeleteFile(OutPath);
  J := TZJob.Create(jkCreate);
  try
    J.Path := OutPath;
    J.Sources := Sources;
    J.Settings := ZipSettings;
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'create: a cancel reaches the engine');
  finally
    J.Free;
  end;
end;

{ --- jkModify ------------------------------------------------------------ }

procedure TestModify;
var
  J: TZJob;
  Err: string;
  R: Integer;
begin
  MakeZip(Root + '/modify.zip');
  J := TZJob.Create(jkModify);
  try
    J.Path := Root + '/modify.zip';
    J.Settings := ZipSettings;
    { The UI hands the job an empty list for a remove-only update; it never
      leaves Sources nil. }
    J.Sources := TStringList.Create;
    J.RemoveIndices := TLongWordArray([1]);
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'modify: success (' + Err + ')');
    EqInt(Pos('b.txt', EntryNames(Root + '/modify.zip')), 0,
      'modify: the removed entry is gone');
    Check(Pos('a.txt', EntryNames(Root + '/modify.zip')) > 0,
      'modify: the other entry survived');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkModify);
  try
    J.Path := Root + '/missing.zip';
    J.Settings := ZipSettings;
    J.Sources := TStringList.Create;
    J.RemoveIndices := TLongWordArray([0]);
    R := RunJob(J, Err);
    Check(R <> TZ7Z_OK, 'modify: a missing archive fails');
  finally
    J.Free;
  end;

  MakeZip(Root + '/modify-cancel.zip');
  J := TZJob.Create(jkModify);
  try
    J.Path := Root + '/modify-cancel.zip';
    J.Settings := ZipSettings;
    J.Sources := TStringList.Create;
    J.RemoveIndices := TLongWordArray([1]);
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'modify: a cancel reaches the engine');
    Check(Pos('b.txt', EntryNames(Root + '/modify-cancel.zip')) > 0,
      'modify: a cancelled update leaves the archive as it was');
  finally
    J.Free;
  end;
end;

{ --- jkRename ------------------------------------------------------------ }

procedure TestRename;
var
  J: TZJob;
  Err: string;
  R: Integer;
begin
  MakeZip(Root + '/rename.zip');
  J := TZJob.Create(jkRename);
  try
    J.Path := Root + '/rename.zip';
    J.RenameIndex := 1;
    J.RenameTo := 'renamed.txt';
    J.Settings := ZipSettings;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'rename: success (' + Err + ')');
    Check(Pos('renamed.txt', EntryNames(Root + '/rename.zip')) > 0,
      'rename: the new name is stored');
    Check(Pos('b.txt', EntryNames(Root + '/rename.zip')) = 0,
      'rename: the old name is gone');
  finally
    J.Free;
  end;

  MakeZip(Root + '/rename-bad.zip');
  J := TZJob.Create(jkRename);
  try
    J.Path := Root + '/rename-bad.zip';
    J.RenameIndex := -1;
    J.RenameTo := 'never.txt';
    J.Settings := ZipSettings;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_ARG, 'rename: an invalid index is refused');
    Check(Pos('never.txt', EntryNames(Root + '/rename-bad.zip')) = 0,
      'rename: nothing is written for an invalid index');
  finally
    J.Free;
  end;

  MakeZip(Root + '/rename-cancel.zip');
  J := TZJob.Create(jkRename);
  try
    J.Path := Root + '/rename-cancel.zip';
    J.RenameIndex := 1;
    J.RenameTo := 'cancelled.txt';
    J.Settings := ZipSettings;
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'rename: a cancel reaches the engine');
    Check(Pos('cancelled.txt', EntryNames(Root + '/rename-cancel.zip')) = 0,
      'rename: a cancelled rename changes nothing');
  finally
    J.Free;
  end;
end;

{ --- jkConvert ----------------------------------------------------------- }

procedure TestConvert;
var
  J: TZJob;
  Err, Src: string;
  R: Integer;
  S: TCreateSettings;
begin
  Src := Root + '/convert-src.zip';
  MakeZip(Src);
  J := TZJob.Create(jkConvert);
  try
    J.Path := Src;
    J.Dest := Root + '/converted.7z';
    DeleteFile(J.Dest);
    S := Default(TCreateSettings);
    S.FormatName := '7z';
    S.Level := 5;
    J.Settings := S;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_OK, 'convert: success (' + Err + ')');
    Check(FileExists(J.Dest), 'convert: the target is written');
    Check(FileExists(Src), 'convert: the source is untouched');
  finally
    J.Free;
  end;

  J := TZJob.Create(jkConvert);
  try
    J.Path := Root + '/missing.zip';
    J.Dest := Root + '/converted-missing.7z';
    DeleteFile(J.Dest);
    S := Default(TCreateSettings);
    S.FormatName := '7z';
    J.Settings := S;
    R := RunJob(J, Err);
    Check(R <> TZ7Z_OK, 'convert: a missing source fails');
    Check(not FileExists(J.Dest), 'convert: no target for a failed conversion');
  finally
    J.Free;
  end;

  MakeZip(Root + '/convert-cancel.zip');
  J := TZJob.Create(jkConvert);
  try
    J.Path := Root + '/convert-cancel.zip';
    J.Dest := Root + '/converted-cancel.7z';
    DeleteFile(J.Dest);
    S := Default(TCreateSettings);
    S.FormatName := '7z';
    J.Settings := S;
    J.RequestCancel;
    R := RunJob(J, Err);
    EqInt(R, TZ7Z_E_CANCEL, 'convert: a cancel reaches the engine');
    Check(not FileExists(J.Dest), 'convert: a cancelled conversion writes nothing');
  finally
    J.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-jobmatrix-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  PrepareSources;

  TestOpen;
  TestList;
  TestExtract;
  TestTest;
  TestExtractOne;
  TestCreate;
  TestModify;
  TestRename;
  TestConvert;

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
