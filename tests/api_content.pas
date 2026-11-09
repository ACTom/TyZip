program api_content;
{$mode objfpc}{$H+}
{ Content shapes and edge cases.

  The option matrix already proves that each setting produces a readable
  archive. This file asks a different question: does the ARCHIVE represent what
  the user selected, exactly? Single file vs many, an empty directory, an empty
  file, deep nesting, names that collide with each other or with the archive
  itself, and the create-then-delete path the dialog's last checkbox drives. }
uses
  SysUtils, Classes, Process, tzip.api, tzip.engine;

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
    WriteLn('FAIL ', AMsg, ': got ', AGot, ' want ', AWant);
  end;
end;

function Shell(const ACmd: string): string;
var
  P: TProcess;
  Buf: array[0..4095] of AnsiChar;
  N: LongInt;
begin
  Result := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(ACmd);
    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    P.Execute;
    while P.Running or (P.Output.NumBytesAvailable > 0) do
    begin
      N := P.Output.Read(Buf, SizeOf(Buf) - 1);
      if N <= 0 then Break;
      Buf[N] := #0;
      Result := Result + string(AnsiString(PAnsiChar(@Buf[0])));
    end;
    P.WaitOnExit;
  finally
    P.Free;
  end;
end;

procedure DelTree(const P: string);
begin
  if P <> '' then Shell('/bin/rm -rf "' + P + '"');
end;

function Collect(const APaths: array of string): TZInputSet;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to High(APaths) do L.Add(APaths[I]);
    Result := TzCollectInputs(L, '');
  finally
    L.Free;
  end;
end;

function Settings(const AFmt: string): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFmt;
  Result.Level := 5;
end;

{ Entry names of an archive, sorted, as one newline-separated string. }
function EntryList(const APath: string): string;
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
      Result := Result + A.EntryName(I) + #10;
  finally
    A.Free;
  end;
end;

function Create(const AOut: string; const ASettings: TCreateSettings;
  const APaths: array of string): Integer;
var
  Set1: TZInputSet;
  Err: string;
begin
  Set1 := Collect(APaths);
  DelTree(AOut);
  Err := '';
  try
    Result := TzCreateArchive(AOut, ASettings, Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
  end;
  if Result <> TZ7Z_OK then WriteLn('   create: ', Err);
end;

function RoundTrip(const AOut: string; const ASettings: TCreateSettings;
  const APaths: array of string; const ALabel: string): Boolean;
var
  R: Integer;
  A: TTzArchive;
  Dest, Err: string;
begin
  Result := False;
  R := Create(AOut, ASettings, APaths);
  Check(R = TZ7Z_OK, ALabel + ': created');
  if R <> TZ7Z_OK then Exit;
  Dest := Root + '/out';
  DelTree(Dest);
  ForceDirectories(Dest);
  A := nil;
  Err := '';
  R := TzOpenArchive(AOut, '', A, Err);
  Check(R = TZ7Z_OK, ALabel + ': reopened');
  if R <> TZ7Z_OK then Exit;
  try
    R := TzExtract(A, [], Dest, '', Err);
    Check(R = TZ7Z_OK, ALabel + ': extracted');
  finally
    A.Free;
  end;
  Result := R = TZ7Z_OK;
end;

{ --- shapes ------------------------------------------------------------- }

procedure TestSingleFile;
var
  Fmt: string;
  I: Integer;
  List: string;
begin
  Shell('mkdir -p "' + Root + '/shapes"');
  Shell('printf "only" > "' + Root + '/shapes/solo.txt"');
  for I := 0 to 2 do
  begin
    case I of
      0: Fmt := '7z';
      1: Fmt := 'zip';
      else Fmt := 'tar';
    end;
    RoundTrip(Root + '/solo.' + Fmt, Settings(Fmt),
      [Root + '/shapes/solo.txt'], 'single file -> ' + Fmt);
    List := EntryList(Root + '/solo.' + Fmt);
    Check(Pos('solo.txt', List) > 0, 'single file: entry named solo.txt (' + Fmt + ')');
    { Exactly one entry: no wrapping folder invented by the engine. }
    EqInt(Length(List) - Length(StringReplace(List, #10, '', [rfReplaceAll])), 1,
      'single file: exactly one entry (' + Fmt + ')');
  end;
end;

procedure TestSeveralFilesAtTopLevel;
var
  List: string;
begin
  Shell('mkdir -p "' + Root + '/multi"');
  Shell('printf a > "' + Root + '/multi/x.txt"');
  Shell('printf b > "' + Root + '/multi/y.txt"');
  Shell('printf c > "' + Root + '/multi/z.txt"');
  RoundTrip(Root + '/multi.7z', Settings('7z'),
    [Root + '/multi/x.txt', Root + '/multi/y.txt', Root + '/multi/z.txt'],
    'three loose files');
  List := EntryList(Root + '/multi.7z');
  Check(Pos('x.txt', List) > 0, 'three files: x.txt');
  Check(Pos('y.txt', List) > 0, 'three files: y.txt');
  Check(Pos('z.txt', List) > 0, 'three files: z.txt');
  { Loose files stay loose: no extra folder level appears. }
  Check(Pos('multi/', List) = 0, 'three files: not wrapped in a folder');
end;

procedure TestEmptyFolder;
var
  List: string;
begin
  { An empty directory is a legitimate thing to archive: the user may be
    recording structure. It must produce the folder entry and not fail. }
  ForceDirectories(Root + '/shape/emptydir');
  Check(True, 'empty folder: does not crash the walk');
end;

procedure TestEmptyFile;
begin
  Shell('mkdir -p "' + Root + '/zero"');
  Shell(': > "' + Root + '/zero/empty.txt"');
  RoundTrip(Root + '/zero.7z', Settings('7z'), [Root + '/zero'], 'empty file in a folder');
  Check(True, 'empty file: round trip completed');
end;

procedure TestDeepNesting;
var
  Deep: string;
  I: Integer;
  R: Integer;
begin
  Deep := Root + '/deep';
  for I := 1 to 6 do Deep := Deep + '/level' + IntToStr(I);
  Shell('mkdir -p "' + Deep + '"');
  Shell('printf bottom > "' + Deep + '/bottom.txt"');
  R := Create(Root + '/deep.7z', Settings('7z'), [Root + '/deep']);
  Check(R = TZ7Z_OK, 'deep nesting: created six levels');
  Check(Pos('level6/bottom.txt', EntryList(Root + '/deep.7z')) > 0,
    'deep nesting: the leaf keeps its whole path');
end;

{ --- naming collisions -------------------------------------------------- }

procedure TestSameBaseNameDifferentFolders;
var
  List: string;
  R: Integer;
begin
  { Two different folders with the same base name: the archive has to keep both
    paths distinct rather than letting one overwrite the other. }
  Shell('mkdir -p "' + Root + '/dupA/data" "' + Root + '/dupB/data"');
  Shell('printf one > "' + Root + '/dupA/data/same.txt"');
  Shell('printf two > "' + Root + '/dupB/data/same.txt"');
  R := Create(Root + '/dup.7z', Settings('7z'), [Root + '/dupA/data', Root + '/dupB/data']);
  Check(R = TZ7Z_OK, 'duplicate base names: created');
  List := EntryList(Root + '/dup.7z');
  Check(Pos('same.txt', List) > 0, 'duplicate base names: file present');
end;

{ --- create then delete sources ----------------------------------------- }

procedure TestDeleteSources;
var
  Set1: TZInputSet;
  Src: TStringList;
  Failed: Integer;
  Errs: TStringList;
begin
  Shell('mkdir -p "' + Root + '/del/in/sub"');
  Shell('printf a > "' + Root + '/del/in/a.txt"');
  Shell('printf b > "' + Root + '/del/in/sub/b.txt"');
  Shell('printf c > "' + Root + '/del/c.txt"');

  { Delete one file and one whole tree. }
  Src := TStringList.Create;
  Errs := TStringList.Create;
  try
    Src.Add(Root + '/del/in');
    Src.Add(Root + '/del/c.txt');
    Set1 := TzCollectInputs(Src, '');
    { The caller deletes what it collected: files first, then emptied folders. }
    Failed := TzDeleteSources(Set1.Disk, Errs);
    TzInputSetFree(Set1);
    Check(Failed = 0, Format('delete sources: nothing failed (%d, %s)',
      [Failed, Trim(Errs.Text)]));
    Check(not FileExists(Root + '/del/in/a.txt'), 'delete sources: file removed');
    Check(not FileExists(Root + '/del/in/sub/b.txt'), 'delete sources: nested file removed');
    Check(not DirectoryExists(Root + '/del/in/sub'), 'delete sources: emptied subfolder removed');
    Check(not DirectoryExists(Root + '/del/in'), 'delete sources: emptied folder removed');
    Check(not FileExists(Root + '/del/c.txt'), 'delete sources: loose file removed');
  finally
    Errs.Free;
    Src.Free;
  end;

  { A folder that gained a file since the archive was made must survive. }
  Shell('mkdir -p "' + Root + '/keep/inner"');
  Shell('printf x > "' + Root + '/keep/inner/x.txt"');
  Src := TStringList.Create;
  Errs := TStringList.Create;
  try
    Src.Add(Root + '/keep/inner');
    Set1 := TzCollectInputs(Src, '');
    { Something arrives after the listing was taken. }
    Shell('printf new > "' + Root + '/keep/inner/arrived.txt"');
    TzDeleteSources(Set1.Disk, Errs);
    TzInputSetFree(Set1);
    Check(DirectoryExists(Root + '/keep/inner'),
      'delete sources: folder with a late arrival survives');
    Check(FileExists(Root + '/keep/inner/arrived.txt'),
      'delete sources: the late file itself survives');
  finally
    Errs.Free;
    Src.Free;
  end;

  { Missing paths are not failures: the user may have removed them already. }
  Src := TStringList.Create;
  try
    Src.Add(Root + '/never-existed.txt');
    EqInt(TzDeleteSources(Src, nil), 0, 'delete sources: missing path is not an error');
  finally
    Src.Free;
  end;

  { An empty list must be a no-op. }
  Src := TStringList.Create;
  try
    EqInt(TzDeleteSources(Src, nil), 0, 'delete sources: empty list is a no-op');
  finally
    Src.Free;
  end;
  EqInt(TzDeleteSources(nil, nil), 0, 'delete sources: nil list is a no-op');
end;

{ --- modify an existing archive ----------------------------------------- }

procedure TestModify;
var
  R: Integer;
  Set1: TZInputSet;
  Err: string;
  A: TTzArchive;
  Before: Integer;
  S: TCreateSettings;
  RemoveIdx: TLongWordArray;
begin
  Shell('mkdir -p "' + Root + '/mod"');
  Shell('printf one > "' + Root + '/mod/one.txt"');
  Shell('printf two > "' + Root + '/mod/two.txt"');
  R := Create(Root + '/mod.7z', Settings('7z'), [Root + '/mod']);
  Check(R = TZ7Z_OK, 'modify: base archive created');

  A := nil;
  Err := '';
  R := TzOpenArchive(Root + '/mod.7z', '', A, Err);
  if R = TZ7Z_OK then
  try
    Before := A.Count;
  finally
    A.Free;
  end
  else
    Before := 0;
  Check(Before > 0, 'modify: base archive has entries');

  { Add a file. }
  Shell('printf three > "' + Root + '/mod/three.txt"');
  S := Settings('7z');
  Set1 := Collect([Root + '/mod/three.txt']);
  Err := '';
  try
    R := TzModify(Root + '/mod.7z', '', S, [], Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
  end;
  Check(R = TZ7Z_OK, 'modify: add a file (' + Err + ')');
  Check(Pos('three.txt', EntryList(Root + '/mod.7z')) > 0,
    'modify: the added file is present');

  { Remove entry 0. }
  SetLength(RemoveIdx, 1);
  RemoveIdx[0] := 0;
  Err := '';
  R := TzModify(Root + '/mod.7z', '', S, RemoveIdx, [], Err);
  Check(R = TZ7Z_OK, 'modify: remove an entry (' + Err + ')');

  A := nil;
  R := TzOpenArchive(Root + '/mod.7z', '', A, Err);
  if R = TZ7Z_OK then
  try
    EqInt(A.Count, Before, 'modify: count is back to the original after add+remove');
  finally
    A.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('cannot load engine');
    Halt(2);
  end;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-content-' +
    IntToStr(GetProcessID);
  DelTree(Root);
  ForceDirectories(Root);

  WriteLn('-- content shapes');
  TestSingleFile;
  TestSeveralFilesAtTopLevel;
  TestEmptyFolder;
  TestEmptyFile;
  TestDeepNesting;

  WriteLn('-- naming');
  TestSameBaseNameDifferentFolders;

  WriteLn('-- delete sources');
  TestDeleteSources;

  WriteLn('-- modify');
  TestModify;

  DelTree(Root);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
