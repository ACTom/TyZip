program unit_main_commands;
{$mode objfpc}{$H+}
{ Archive command construction: the settings and jobs the Do* commands build.

  Pinned here: the modify rewrite keeps the archive's format/method/protection and
  forces UTF-8 names; the create defaults are level 5 and solid; a job carries
  exactly the inputs the command was given (sources and indices copied, not
  aliased); the batch destination gets its trailing separator; and the per-archive
  folder rule stays the historical one until someone decides to change it. }
uses
  { TZJob is a TThread. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, tzip.api, tzip.engine, tzip.extract, tzip.jobs, tzip.commands;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

procedure EqInt(const AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

{ --- settings ----------------------------------------------------------- }

procedure TestModifySettings;
var
  S: TCreateSettings;
begin
  S := TzModifySettings('zip', 'pw', True);
  EqStr(S.FormatName, 'zip', 'modify: format kept');
  EqInt(S.Level, -1, 'modify: keeps each entry compression method');
  Check(S.Solid, 'modify: solid');
  EqStr(S.Password, 'pw', 'modify: password carried');
  Check(S.EncryptNames, 'modify: encrypted names carried');
  Check(S.ForceUtf8, 'modify: UTF-8 names forced');
  Check(not S.DeleteSources, 'modify: never deletes sources');

  S := TzModifySettings('7z', '', False);
  EqStr(S.Password, '', 'modify: no password stays empty');
  Check(not S.EncryptNames, 'modify: unprotected stays unprotected');
end;

procedure TestCreateSettings;
var
  S: TCreateSettings;
begin
  S := TzCreateSettingsFor('7z');
  EqStr(S.FormatName, '7z', 'create: format set');
  EqInt(S.Level, 5, 'create: default level');
  Check(S.Solid, 'create: solid');
  Check(S.ForceUtf8, 'create: UTF-8 names');
  Check(not S.DeleteSources, 'create: sources kept unless asked');
end;

{ --- jobs --------------------------------------------------------------- }

procedure TestModifyJob;
var
  S: TCreateSettings;
  J: TZJob;
  Src: TStringList;
begin
  S := TzModifySettings('zip', 'pw', False);
  { No sources: the field stays nil, which every caller that has none relies on. }
  J := TzNewModifyJob('/a.zip', 'a.zip', 'pw', S, nil);
  try
    Check(J.Kind = jkModify, 'modify job: kind');
    EqStr(J.Path, '/a.zip', 'modify job: path');
    EqStr(J.DisplayName, 'a.zip', 'modify job: display name');
    EqStr(J.Password, 'pw', 'modify job: password');
    EqStr(J.Settings.FormatName, 'zip', 'modify job: settings');
    Check(J.Sources = nil, 'modify job: no sources means none');
  finally J.Free; end;

  Src := TStringList.Create;
  try
    Src.Add('/tmp/x');
    Src.Add('/tmp/y');
    J := TzNewModifyJob('/a.zip', 'a.zip', '', S, Src);
    try
      Check(J.Sources <> nil, 'modify job: sources copied');
      EqInt(J.Sources.Count, 2, 'modify job: both sources');
      Src.Add('/tmp/z');
      EqInt(J.Sources.Count, 2, 'modify job: the copy does not alias the caller list');
    finally J.Free; end;
  finally Src.Free; end;
end;

procedure TestRenameJob;
var
  S: TCreateSettings;
  J: TZJob;
begin
  S := TzModifySettings('zip', '', False);
  J := TzNewRenameJob('/a.zip', 'a.zip', '', S, 7, 'old.txt', 'new.txt');
  try
    Check(J.Kind = jkRename, 'rename job: kind');
    EqInt(J.RenameIndex, 7, 'rename job: entry index');
    EqStr(J.RenameFrom, 'old.txt', 'rename job: old name');
    EqStr(J.RenameTo, 'new.txt', 'rename job: new name');
    EqStr(J.Settings.FormatName, 'zip', 'rename job: settings');
  finally J.Free; end;
end;

procedure TestExtractJobs;
var
  J: TZJob;
  Idx: TLongWordArray;
begin
  SetLength(Idx, 2);
  Idx[0] := 1;
  Idx[1] := 4;
  J := TzNewExtractJob('/a.zip', 'a.zip', 'pw', '/out/', Idx);
  try
    Check(J.Kind = jkExtract, 'extract job: kind');
    EqStr(J.Dest, '/out/', 'extract job: destination');
    EqInt(Length(J.Indices), 2, 'extract job: both indices');
    Idx[0] := 9;
    Check(J.Indices[0] = 1, 'extract job: indices are copied, not aliased');
  finally J.Free; end;

  J := TzNewBatchExtractJob('/a.zip', '/out', 'pw');
  try
    Check(J.Kind = jkExtract, 'batch extract: kind');
    EqStr(J.Dest, IncludeTrailingPathDelimiter('/out'), 'batch extract: trailing separator');
    EqInt(Length(J.Indices), 0, 'batch extract: whole archive');
    EqStr(J.DisplayName, 'a.zip', 'batch extract: display name from the path');
  finally J.Free; end;

  J := TzNewBatchExtractJob('/a.zip', '', '');
  try
    EqStr(J.Dest, '', 'batch extract: no destination stays empty');
  finally J.Free; end;

  { Smart extraction: unwraps the archive through its context and, when the plan
    strips a root folder, asks the job to stage and commit the tree. }
  SetLength(Idx, 2);
  Idx[0] := 3;
  Idx[1] := 4;
  J := TzNewSmartExtractJob('/a.tar.gz', 'a.tar.gz', '', '/out', 'photos', Idx);
  try
    Check(J.Kind = jkExtract, 'smart extract: kind');
    EqStr(J.Dest, '/out', 'smart extract: destination');
    EqStr(J.StripRoot, 'photos', 'smart extract: strip root');
    Check(J.Unwrap, 'smart extract: unwraps the wrapper');
    EqInt(Length(J.Indices), 2, 'smart extract: both indices');
    Idx[0] := 9;
    Check(J.Indices[0] = 3, 'smart extract: indices are copied, not aliased');
  finally J.Free; end;
end;

procedure TestTestJobs;
var
  J: TZJob;
  Idx: TLongWordArray;
begin
  SetLength(Idx, 1);
  Idx[0] := 3;
  J := TzNewTestJob('/a.zip', 'a.zip', '', Idx);
  try
    Check(J.Kind = jkTest, 'test job: kind');
    EqInt(Length(J.Indices), 1, 'test job: the selected entries');
  finally J.Free; end;

  J := TzNewBatchTestJob('/b.zip', 'pw');
  try
    Check(J.Kind = jkTest, 'batch test: kind');
    EqStr(J.DisplayName, 'b.zip', 'batch test: display name');
    EqInt(Length(J.Indices), 0, 'batch test: whole archive');
  finally J.Free; end;
end;

{ --- destinations and status ------------------------------------------- }

procedure TestOwnFolderDest;
begin
  EqStr(TzOwnFolderDest('/tmp/photos.zip'), '/tmp/photos', 'own folder: simple');
  EqStr(TzOwnFolderDest('/tmp/photos.tar.gz'), '/tmp/photos',
    'own folder: a whole compression chain is dropped');
  EqStr(TzOwnFolderDest('/tmp/data.tar.bz2'), '/tmp/data', 'own folder: bz2');
  EqStr(TzOwnFolderDest('/tmp/data.tar.xz'), '/tmp/data', 'own folder: xz');
  EqStr(TzOwnFolderDest('/tmp/data.tar.zst'), '/tmp/data', 'own folder: zst');
  { The historical rule does not know .lzma, so it only drops .tar here. This is
    pinned so that switching to SmartFolderName is a deliberate change later. }
  EqStr(TzOwnFolderDest('/tmp/data.tar.lzma'), '/tmp/data.tar',
    'own folder: the historical .lzma result');
  EqStr(TzOwnFolderDest('/tmp/noext'), '/tmp/noext', 'own folder: no extension');
end;

procedure TestExternalOpenKind;
var
  Archive: string;
begin
  Archive := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'tyzip-external-open-test.zip';
  FileClose(FileCreate(Archive));
  try
    Check(TzExternalOpenKind(Archive, True) = eokOpenInNewInstance,
      'external open: another archive gets its own window');
  finally
    DeleteFile(Archive);
  end;
  Check(TzExternalOpenKind('/tmp/does-not-exist-tyzip.zip', True) = eokOpenHere,
    'external open: a missing archive opens here (and reports the error)');
  Check(TzExternalOpenKind('/tmp', True) = eokOpenHere,
    'external open: a folder opens here');
  Check(TzExternalOpenKind('/tmp/plain.txt', True) = eokAddToArchive,
    'external open: a plain file still adds to the open archive');
  Check(TzExternalOpenKind('/tmp/second.zip', False) = eokOpenHere,
    'external open: no archive open, archive opens here');
  Check(TzExternalOpenKind('/tmp/plain.txt', False) = eokOpenHere,
    'external open: no archive open, plain file opens here');
end;

procedure TestBatchSkipStatus;
begin
  EqStr(TzBatchSkipStatus(0), '', 'skip status: nothing skipped, no text');
  Check(TzBatchSkipStatus(3) <> '', 'skip status: skipped files get a message');
end;

begin
  Fails := 0; Passes := 0;
  TestModifySettings;
  TestCreateSettings;
  TestModifyJob;
  TestRenameJob;
  TestExtractJobs;
  TestTestJobs;
  TestOwnFolderDest;
  TestBatchSkipStatus;
  TestExternalOpenKind;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
