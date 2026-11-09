program unit_model_open;
{$mode objfpc}{$H+}
{ Opening an archive through the production entry point, TzOpenContext.

  Two things there are invisible to a pure unit test and easy to break: a
  compound ".tar.gz" is unwrapped into a temporary file, and opening an archive
  that lives INSIDE another archive records that parent. The temporary file must
  belong to the context and disappear with it -- a leak here grows the temp
  directory on every archive the user opens.

  The fixtures are real archives made by the engine, not mocks. }
uses
  SysUtils, Classes, tzip.api, tzip.engine;

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

{ Every "wrap_" file the unwrapper leaves in this process's temp directory. }
function WrapFileCount: Integer;
var
  SR: TSearchRec;
  Mask, Dir: string;
begin
  Result := 0;
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'TyZip-' +
    IntToStr(GetProcessID) + PathDelim;
  Mask := Dir + 'wrap_*';
  if FindFirst(Mask, faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Zip the listed disk files, keeping their names inside the archive. }
function ZipFiles(const ADest: string; const AFiles: array of string;
  const AArcNames: array of string): Boolean;
var
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
  R: Integer;
  I: Integer;
begin
  Result := False;
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    for I := 0 to High(AFiles) do
    begin
      Disk.Add(Root + '/' + AFiles[I]);
      Arc.Add(AArcNames[I]);
    end;
    Set1 := TzCollectInputsMapped(Disk, Arc);
    try
      S := Default(TCreateSettings);
      S.FormatName := 'zip';
      S.Level := 5;
      S.ForceUtf8 := True;
      R := TzCreateArchive(ADest, S, Set1.Recs, Err);
    finally
      TzInputSetFree(Set1);
    end;
    Check(R = TZ7Z_OK, 'setup: zip created (' + Err + ')');
    Result := R = TZ7Z_OK;
  finally
    Arc.Free;
    Disk.Free;
  end;
end;

{ The compound path: a folder becomes a tar, the tar becomes a .tar.gz. }
function MakeTarGz(const ADest: string): Boolean;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
  R: Integer;
begin
  Result := False;
  ForceDirectories(Root + '/src/sub');
  WriteText(Root + '/src/a.txt', 'alpha' + LineEnding);
  WriteText(Root + '/src/sub/b.txt', 'beta' + LineEnding);
  L := TStringList.Create;
  Set1.Disk := nil;
  Set1.Arc := nil;
  try
    L.Add(Root + '/src');
    S := Default(TCreateSettings);
    { The destination extension selects the compound path; the format name is
      the OUTER compression the last step uses. }
    S.FormatName := 'gzip';
    S.Level := 5;
    Set1 := TzCollectInputs(L, '');
    try
      R := TzCreateArchive(ADest, S, Set1.Recs, Err);
    finally
      TzInputSetFree(Set1);
    end;
    Check(R = TZ7Z_OK, 'setup: tar.gz created (' + Err + ')');
    Result := R = TZ7Z_OK;
  finally
    L.Free;
  end;
end;

function EntryNames(const AContext: TArchiveContext): string;
var
  I: Integer;
begin
  Result := '';
  if AContext = nil then Exit;
  for I := 0 to High(AContext.Entries) do
    Result := Result + AContext.Entries[I].Name + ';';
end;

function EntryIndexIn(const AContext: TArchiveContext; const AName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if AContext = nil then Exit;
  for I := 0 to High(AContext.Entries) do
    if SameText(AContext.Entries[I].Name, AName) then Exit(I);
end;

{ --- a plain archive is opened in place ---------------------------------- }

procedure TestPlainArchive;
var
  Ctx: TArchiveContext;
  Err, Path: string;
  R: Integer;
begin
  Path := Root + '/plain.zip';
  DeleteFile(Path);
  WriteText(Root + '/one.txt', 'one' + LineEnding);
  if not ZipFiles(Path, ['one.txt'], ['one.txt']) then Exit;

  Ctx := nil;
  R := TzOpenContext(Path, 'plain.zip', '', nil, False, '', Ctx, Err);
  Check(R = TZ7Z_OK, 'plain: opens (' + Err + ')');
  if Ctx = nil then Exit;
  try
    Check(not Ctx.TemporarySource, 'plain: the source is not temporary');
    EqStr(Ctx.SourcePath, Path, 'plain: the source is the file on disk');
    Check(not Ctx.IsNested, 'plain: not marked nested');
    EqStr(Ctx.DisplayName, 'plain.zip', 'plain: display name kept');
    EqInt(Length(Ctx.Entries), 1, 'plain: one entry');
    Check(Pos('one.txt', EntryNames(Ctx)) > 0, 'plain: the entry is listed');
    { Opening it must not have unwrapped anything. }
    EqInt(WrapFileCount, 0, 'plain: no temporary wrapper file');
  finally
    Ctx.Free;
  end;
end;

{ --- .tar.gz is unwrapped to the tar inside it ---------------------------- }

procedure TestCompoundTarGz;
var
  Ctx: TArchiveContext;
  Err, Path, Wrapped: string;
  R: Integer;
begin
  Path := Root + '/pkg.tar.gz';
  DeleteFile(Path);
  if not MakeTarGz(Path) then Exit;
  Check(FileExists(Path), 'setup: the compound archive exists');

  Ctx := nil;
  R := TzOpenContext(Path, 'pkg.tar.gz', '', nil, False, '', Ctx, Err);
  Check(R = TZ7Z_OK, 'tar.gz: opens (' + Err + ')');
  if Ctx = nil then Exit;
  try
    Check(Ctx.TemporarySource, 'tar.gz: the source is a temporary file');
    Check(not SameText(Ctx.SourcePath, Path),
      'tar.gz: the source is not the compound file itself');
    Check(FileExists(Ctx.SourcePath), 'tar.gz: the temporary source exists');
    Check(Ctx.IsNested, 'tar.gz: the unwrapped context is nested');
    EqStr(Ctx.DisplayName, 'pkg.tar.gz', 'tar.gz: display name kept');
    { The user must see the tar's contents, not one opaque stream row. }
    Check(Length(Ctx.Entries) >= 3, 'tar.gz: entries from the inner tar');
    Check(Pos('src/a.txt', EntryNames(Ctx)) > 0,
      'tar.gz: the tar contents are listed (' + EntryNames(Ctx) + ')');
    Check(Pos('src/sub/b.txt', EntryNames(Ctx)) > 0,
      'tar.gz: the nested folder survived');
    EqInt(WrapFileCount, 1, 'tar.gz: exactly the taken-over temporary file');
    Wrapped := Ctx.SourcePath;
  finally
    Ctx.Free;
  end;

  { The unwrapped file belongs to the context: closing it deletes the file. }
  Check(not FileExists(Wrapped), 'tar.gz: the temporary file is deleted on close');
  EqInt(WrapFileCount, 0, 'tar.gz: no wrapper file is left behind');
  Check(FileExists(Path), 'tar.gz: the compound file itself is untouched');
end;

{ --- an archive inside another archive ----------------------------------- }

procedure TestNested;
var
  Outer, Inner: TArchiveContext;
  Err, OuterPath, InnerPath, Tmp: string;
  R, InnerIndex: Integer;
begin
  OuterPath := Root + '/outer.zip';
  InnerPath := Root + '/inner.tar.gz';
  DeleteFile(OuterPath);
  DeleteFile(InnerPath);
  if not MakeTarGz(InnerPath) then Exit;
  WriteText(Root + '/placeholder.txt', 'placeholder' + LineEnding);
  if not ZipFiles(OuterPath, ['inner.tar.gz', 'placeholder.txt'],
    ['inner.tar.gz', 'placeholder.txt']) then Exit;

  Outer := nil;
  R := TzOpenContext(OuterPath, 'outer.zip', '', nil, False, '', Outer, Err);
  Check(R = TZ7Z_OK, 'nested: the outer archive opens (' + Err + ')');
  if Outer = nil then Exit;

  Inner := nil;
  try
    InnerIndex := EntryIndexIn(Outer, 'inner.tar.gz');
    Check(InnerIndex >= 0, 'nested: the inner archive is an entry');
    if InnerIndex < 0 then Exit;

    { What the UI does when the user double-clicks the nested entry: extract it
      to a private file, then open that file as a child of the outer context. }
    Tmp := Root + '/extracted-inner.tar.gz';
    DeleteFile(Tmp);
    R := TzExtractOne(Outer.Archive, InnerIndex, Tmp, '', Err);
    Check(R = TZ7Z_OK, 'nested: the inner archive extracts (' + Err + ')');

    R := TzOpenContext(Tmp, 'inner.tar.gz', '', Outer, True, OuterPath, Inner, Err);
    Check(R = TZ7Z_OK, 'nested: the inner archive opens (' + Err + ')');
    if Inner <> nil then
    begin
      Check(Inner.IsNested, 'nested: the context knows it is nested');
      Check(Inner.Parent = Outer, 'nested: the parent context is recorded');
      EqStr(Inner.DisplayName, 'inner.tar.gz', 'nested: display name kept');
      { The nested file is itself a .tar.gz wrapper, so it owns a temp copy. }
      Check(Inner.TemporarySource, 'nested: the .tar.gz source is temporary');
      Check(Pos('src/a.txt', EntryNames(Inner)) > 0,
        'nested: the inner tar contents are listed (' + EntryNames(Inner) + ')');
      Inner.Free;
      Inner := nil;
      EqInt(WrapFileCount, 0, 'nested: closing the child releases its temp copy');
    end;
  finally
    Inner.Free;
    Outer.Free;
    if FileExists(Tmp) then DeleteFile(Tmp);
  end;
end;

{ --- an archive holding one archive-like document is NOT unwrapped --------- }

procedure TestSingleArchiveEntryIsNotUnwrapped;
var
  Ctx: TArchiveContext;
  Err, OuterPath, InnerPath: string;
  R: Integer;
begin
  { A real ZIP payload under the name book.xlsx: xlsx is a ZIP container in the
    format table, so the old wrapper rule unwrapped the outer archive into the
    document's internals -- the user saw Excel's structure and could not go
    back. An archive proper must always be shown as itself (ticket 39). }
  WriteText(Root + '/payload.txt', 'payload' + LineEnding);
  InnerPath := Root + '/payload.zip';
  DeleteFile(InnerPath);
  if not ZipFiles(InnerPath, ['payload.txt'], ['payload.txt']) then Exit;

  OuterPath := Root + '/only-xlsx.zip';
  DeleteFile(OuterPath);
  if not ZipFiles(OuterPath, ['payload.zip'], ['book.xlsx']) then Exit;

  Ctx := nil;
  R := TzOpenContext(OuterPath, 'only-xlsx.zip', '', nil, False, '', Ctx, Err);
  Check(R = TZ7Z_OK, 'only-xlsx: opens (' + Err + ')');
  if Ctx = nil then Exit;
  try
    Check(not Ctx.TemporarySource, 'only-xlsx: not unwrapped into a temp file');
    EqStr(Ctx.SourcePath, OuterPath, 'only-xlsx: source is the outer archive');
    EqInt(Length(Ctx.Entries), 1, 'only-xlsx: one entry');
    Check(Pos('book.xlsx', EntryNames(Ctx)) > 0,
      'only-xlsx: the document is listed (' + EntryNames(Ctx) + ')');
  finally
    Ctx.Free;
  end;
  EqInt(WrapFileCount, 0, 'only-xlsx: no wrapper temp file is left behind');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-open-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  TestPlainArchive;
  TestCompoundTarGz;
  TestNested;
  TestSingleArchiveEntryIsNotUnwrapped;

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
