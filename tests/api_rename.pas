program api_rename;
{$mode objfpc}{$H+}
{ Renaming an entry through the engine: extract, re-add under the new path,
  remove the old one.

  This is the real thing, not a mock: it creates a zip, renames one entry with
  the same calls the job uses, and checks the archive afterwards. }
uses
  SysUtils, Classes, Process, tzip.api, tzip.engine;

var
  Fails, Passes: Integer;
  Root: string;

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

function MakeZip(const AName: string; const AFiles: array of string): string;
var
  I: Integer;
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
  R: Integer;
  P: TStringList;
begin
  Result := Root + '/' + AName;
  DeleteFile(Result);
  for I := 0 to High(AFiles) do
  begin
    ForceDirectories(ExtractFileDir(Root + '/' + AFiles[I]));
    P := TStringList.Create;
    try
      P.Add('content of ' + AFiles[I]);
      P.SaveToFile(Root + '/' + AFiles[I]);
    finally
      P.Free;
    end;
  end;
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    for I := 0 to High(AFiles) do Disk.Add(Root + '/' + AFiles[I]);
    Set1 := TzCollectInputsMapped(Disk, Arc);
    { The archive names come from the file names, so a Unicode file name must
      survive this step; check before blaming the rename. }
    if Length(AFiles) > 0 then
      Check(Set1.Arc[0] = AFiles[0], 'setup: archive name matches (' + Set1.Arc[0] + ')');
    try
      S := Default(TCreateSettings);
      S.FormatName := 'zip';
      S.Level := 5;
      { ZIP stores names in a local code page unless told otherwise, so without
        this a CJK name is written as Latin-1 bytes and cannot be renamed later. }
      S.ForceUtf8 := True;
      R := TzCreate(Result, S, Set1.Recs, Err);
      Check(R = TZ7Z_OK, 'create: ' + Err);
    finally
      TzInputSetFree(Set1);
    end;
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
  if TzOpenArchive(APath, '', A, Err) <> TZ7Z_OK then Exit;
  try
    for I := 0 to A.Count - 1 do
      Result := Result + A.EntryName(I) + ';';
  finally
    A.Free;
  end;
end;

{ The same three steps the rename job performs. }
function RenameEntry(const APath, AFrom, ATo: string): Integer;
var
  A: TTzArchive;
  Err, Tmp: string;
  Idx, I: Integer;
  Disk, Arc: TStringList;
  Set2: TZInputSet;
  Rem: TLongWordArray;
  S: TCreateSettings;
begin
  Result := -1;
  A := nil;
  Result := TzOpenArchive(APath, '', A, Err);
  if Result <> TZ7Z_OK then Exit;
  try
    Idx := -1;
    for I := 0 to A.Count - 1 do
      if SameText(A.EntryName(I), AFrom) then
      begin
        Idx := I;
        Break;
      end;
    if Idx < 0 then Exit(TZ7Z_E_ARG);
    Tmp := Root + '/.tmp-extract';
    DeleteFile(Tmp);
    Result := TzExtractOne(A, LongWord(Idx), Tmp, '', Err, nil);
    if Result <> TZ7Z_OK then Exit;
  finally
    A.Free;
  end;
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    Disk.Add(Tmp);
    Arc.Add(ATo);
    Set2 := TzCollectInputsMapped(Disk, Arc);
    try
      S := Default(TCreateSettings);
      S.FormatName := 'zip';
      S.Level := 5;
      S.ForceUtf8 := True;
      Rem := TLongWordArray([LongWord(Idx)]);
      Result := TzModify(APath, '', S, Rem, Set2.Recs, Err, nil);
    finally
      TzInputSetFree(Set2);
    end;
  finally
    Arc.Free;
    Disk.Free;
  end;
  DeleteFile(Tmp);
end;

procedure TestRename;
var
  Z: string;
  R: Integer;
  Names: string;
begin
  Z := MakeZip('r1.zip', ['a.txt', 'b.txt']);
  Check(Pos('a.txt', EntryNames(Z)) > 0, 'setup: a.txt is there');

  R := RenameEntry(Z, 'a.txt', 'renamed.txt');
  Check(R = TZ7Z_OK, Format('rename: engine returned %d', [R]));
  Names := EntryNames(Z);
  Check(Pos('renamed.txt', Names) > 0, 'rename: new name is present');
  Check(Pos('a.txt;', Names) = 0, 'rename: old name is gone');
  Check(Pos('b.txt', Names) > 0, 'rename: the other entry survived');
end;

procedure TestRenameIntoFolder;
var
  Z: string;
  Names: string;
begin
  Z := MakeZip('r2.zip', ['c.txt']);
  Check(RenameEntry(Z, 'c.txt', 'sub/c.txt') = TZ7Z_OK, 'move: renamed');
  Names := EntryNames(Z);
  Check(Pos('sub/c.txt', Names) > 0, 'move: landed in the folder (' + Names + ')');
  { "c.txt;" would also be found inside "sub/c.txt", so the check is that no
    entry is still called exactly "c.txt". }
  Check(Pos(';c.txt;', ';' + Names) = 0, 'move: the old path is gone (' + Names + ')');
end;

procedure TestRenameUnicode;
var
  Z: string;
  Names: string;
begin
  { The whole rename path must carry UTF-8 names through unchanged. }
  Z := MakeZip('r3.zip', ['原始.txt']);
  Check(Pos('原始.txt', EntryNames(Z)) > 0, 'unicode: setup [' + EntryNames(Z) + ']');
  { The rename is only meaningful on a correctly stored name, so the setup is
    asserted exactly rather than by substring. }
  Check(EntryNames(Z) = '原始.txt;', 'unicode: setup is exact');
  { Three CJK characters are 9 bytes in UTF-8, plus ".txt" -- 13. Pinning it
    catches a source file saved in another encoding before it reaches the engine. }
  Check(Length(RawByteString('改名后.txt')) = 13, 'unicode: the literal is UTF-8');
  Check(RenameEntry(Z, '原始.txt', '改名后.txt') = TZ7Z_OK,
    'unicode: renamed (before: ' + EntryNames(Z) + ')');
  Names := EntryNames(Z);
  Check(Pos('改名后.txt', Names) > 0, 'unicode: the new name survived (' + Names + ')');
  { The whole point: it must come back as the same 13 bytes, not as mojibake. }
  Check(Names = '改名后.txt;', 'unicode: the stored name is exact (' + Names + ')');
  Check(Pos('原始.txt', Names) = 0, 'unicode: the old name is gone (' + Names + ')');
end;

begin
  Fails := 0; Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-rename-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  { The library is found next to the executable, as every other engine test
    does; without this the engine is not loaded and every call returns E_OPEN. }
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  TestRename;
  TestRenameIntoFolder;
  TestRenameUnicode;
  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
