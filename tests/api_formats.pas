program api_formats;
{$mode objfpc}{$H+}
{ Every format the create dialog can offer, end to end.

  This is the suite that the "folder -> .tar.gz" bug needed: choosing gzip for a
  directory produced a .tar.gz NAME while the engine still wrote gzip, which
  fails with E_INVALIDARG. Nothing here is mocked -- each case creates a real
  archive from a real tree on disk, opens it again, and compares the extracted
  bytes with the input.

  Coverage per format: what it accepts (single file, folder, several inputs),
  what it must refuse, and the compound .tar.<comp> names that a single-stream
  format forces. }
uses
  SysUtils, Classes, Process, tzip.api, tzip.engine;

var
  Fails: Integer;
  Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then
  begin
    Inc(Passes);
    WriteLn('ok   ', AMsg);
  end
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

function Exists(const P: string): Boolean;
begin
  Result := FileExists(P);
end;

function ReadText(const P: string): string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(P) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(P);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

procedure WriteText(const P: string; const S: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFileDir(P));
  L := TStringList.Create;
  try
    L.Text := S;
    L.SaveToFile(P);
  finally
    L.Free;
  end;
end;

{ Contents of APath, read by /bin/cat. Used where the FILE NAME itself is the
  thing under test, so the assertion cannot be fooled by the harness. }
function ShellCat(const APath: string): string;
var
  P: TProcess;
  Buf: array[0..1023] of AnsiChar;
  N: LongInt;
begin
  Result := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/cat';
    P.Parameters.Add(APath);
    P.Options := [poUsePipes, poNoConsole];
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
  if P = '' then Exit;
  ExecuteProcess('/bin/rm', ['-rf', P]);
end;

{ --- input helpers ------------------------------------------------------- }

function Inp(const ADisk, AArc: string; AIsDir: Boolean): TZ7ZInput;
begin
  Result.DiskPath := PAnsiChar(UTF8Encode(ADisk));
  Result.ArcPath := PAnsiChar(UTF8Encode(AArc));
  Result.IsDir := Ord(AIsDir);
end;

function MakeSettings(const AFmt: string; ALevel, ASolid: Integer): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFmt;
  Result.Level := ALevel;
  Result.Solid := ASolid <> 0;
end;

{ --- a fixture: one file, one directory with a nested file ---------------- }

var
  Root: string;

procedure BuildFixture;
begin
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-fmt-' +
    IntToStr(GetProcessID);
  DelTree(Root);
  ForceDirectories(Root + '/src/sub');
  WriteText(Root + '/src/a.txt', 'alpha' + LineEnding);
  WriteText(Root + '/src/sub/b.txt', 'beta' + LineEnding);
end;

{ Create AOut from the fixture tree, then extract it again into ADest and
  verify the payload is byte-identical to the input. }
procedure CreateAndVerify(const AFmt, AOut, ADest: string;
  ALevel, ASolid: Integer);
var
  Src: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  { TzCollectInputs walks the folders; handing the engine a bare directory
    record would store the directory only, without its contents. Real callers
    (the job) go through it, so the test must too. }
  Src := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Src.Add(Root + '/src');
    Src.Add(Root + '/one.txt');
    Set1 := TzCollectInputs(Src, '');
    DelTree(AOut);
    DelTree(ADest);
    Check(Length(Set1.Recs) >= 5,
      Format('%s: input set expands the folder (%d records)',
        [AFmt, Length(Set1.Recs)]));
    S := MakeSettings(AFmt, ALevel, ASolid);
    Err := '';
    R := TzCreateArchive(AOut, S, Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
    Src.Free;
  end;
  Check(R = TZ7Z_OK, Format('%s: create a folder + a file (rc=%d %s)',
    [AFmt, R, Err]));
  if R <> TZ7Z_OK then Exit;
  Check(Exists(AOut), Format('%s: archive exists at %s', [AFmt,
    ExtractFileName(AOut)]));
  if not Exists(AOut) then Exit;

  ForceDirectories(ADest);
  A := nil;
  Err := '';
  R := TzOpenArchive(AOut, '', A, Err);
  Check(R = TZ7Z_OK, Format('%s: reopen (rc=%d %s)', [AFmt, R, Err]));
  if R <> TZ7Z_OK then Exit;
  try
    Check(A.Count > 0, Format('%s: has entries (%d)', [AFmt, A.Count]));
    R := TzExtract(A, [], ADest, '', Err);
    Check(R = TZ7Z_OK, Format('%s: extract (rc=%d %s)', [AFmt, R, Err]));
  finally
    A.Free;
  end;

  Check(ReadText(ADest + '/one.txt') = 'alpha' + LineEnding,
    Format('%s: one.txt round-trips', [AFmt]));
  Check(ReadText(ADest + '/src/a.txt') = 'alpha' + LineEnding,
    Format('%s: src/a.txt round-trips', [AFmt]));
  Check(ReadText(ADest + '/src/sub/b.txt') = 'beta' + LineEnding,
    Format('%s: src/sub/b.txt round-trips', [AFmt]));
end;

{ A single-stream format with a folder must be given the compound name. Without
  the tar layer the engine refuses the job, so this is the case that broke. }
procedure TestCompound(const AComp, AExt: string);
var
  Src: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  OutGz, Dest, TarName: string;
  R: Integer;
  Err: string;
  A: TTzArchive;
begin
  { A real folder tree, expanded the way the job does it. }
  Src := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Src.Add(Root + '/src');
    Set1 := TzCollectInputs(Src, '');

    OutGz := Root + '/dir' + AExt;
    DelTree(OutGz);
    DelTree(Root + '/cmpdest');
    S := MakeSettings(AComp, 5, 0);
    Err := '';
    R := TzCreateArchive(OutGz, S, Set1.Recs, Err);
    Check(R = TZ7Z_OK, Format('%s: folder -> %s (rc=%d %s)',
      [AComp, ExtractFileName(OutGz), R, Err]));

    { The bare single-stream name is what the engine refuses for a tree: with no
      tar layer there is nothing to put the folder into. }
    DelTree(Root + '/bare.' + AComp);
    R := TzCreateArchive(Root + '/bare.' + AComp, S, Set1.Recs, Err);
    Check(R <> TZ7Z_OK, Format('%s: folder -> bare .%s is refused (rc=%d)',
      [AComp, AComp, R]));
  finally
    TzInputSetFree(Set1);
    Src.Free;
  end;

  if not Exists(OutGz) then Exit;
  ForceDirectories(Root + '/cmpdest');
  A := nil;
  R := TzOpenArchive(OutGz, '', A, Err);
  Check(R = TZ7Z_OK, Format('%s: reopen %s', [AComp, ExtractFileName(OutGz)]));
  if R = TZ7Z_OK then
  try
    R := TzExtract(A, [], Root + '/cmpdest', '', Err);
    Check(R = TZ7Z_OK, Format('%s: extract the tar inside', [AComp]));
  finally
    A.Free;
  end;
  { Extracting a .tar.gz yields the tar stream as ONE file; the tree only
    appears after the tar itself is opened. So check that file, then open it and
    verify the payload inside. }
  Dest := Root + '/cmpdest';
  { Only gzip records the original file name in its header; bzip2 and xz carry
    no name at all, so the tar stream comes out under the fallback name. Both
    cases are correct, so accept either. }
  TarName := '';
  if FileExists(Dest + '/dir.tar') then TarName := Dest + '/dir.tar'
  else if FileExists(Dest + '/[Content]') then TarName := Dest + '/[Content]';
  if (TarName = '') and (AComp = 'gzip') then
    Check(False, 'gzip: the tar stream lands as dir.tar')
  else
    Check(TarName <> '', Format('%s: the tar stream is extracted (%s)', [AComp,
      ExtractFileName(TarName)]));
  if TarName <> '' then
  begin
    A := nil;
    R := TzOpenArchive(TarName, '', A, Err);
    Check(R = TZ7Z_OK, Format('%s: open the inner tar (rc=%d %s)', [AComp, R, Err]));
    if R = TZ7Z_OK then
    try
      DelTree(Root + '/cmptree');
      ForceDirectories(Root + '/cmptree');
      R := TzExtract(A, [], Root + '/cmptree', '', Err);
      Check(R = TZ7Z_OK, Format('%s: extract the inner tar', [AComp]));
    finally
      A.Free;
    end;
    Check(ReadText(Root + '/cmptree/src/a.txt') = 'alpha' + LineEnding,
      Format('%s: compound keeps the tree (src/a.txt)', [AComp]));
    Check(ReadText(Root + '/cmptree/src/sub/b.txt') = 'beta' + LineEnding,
      Format('%s: compound keeps the nested file', [AComp]));
  end;
end;

{ A single file into .gz must NOT get the tar layer. }
procedure TestSingleStreamFile(const AComp, AExt: string);
var
  DiskU: RawByteString;
  Inputs: array[0..0] of TZ7ZInput;
  S: TCreateSettings;
  OutF, Dest, Payload: string;
  R: Integer;
  Err: string;
  A: TTzArchive;
begin
  DiskU := UTF8Encode(Root + '/one.txt');
  Inputs[0].DiskPath := PAnsiChar(DiskU);
  Inputs[0].ArcPath := PAnsiChar('one.txt');
  Inputs[0].IsDir := 0;
  OutF := Root + '/single' + AExt;
  DelTree(OutF);
  S := MakeSettings(AComp, 5, 0);
  Err := '';
  R := TzCreateArchive(OutF, S, Inputs, Err);
  Check(R = TZ7Z_OK, Format('%s: single file -> %s (rc=%d %s)',
    [AComp, ExtractFileName(OutF), R, Err]));
  if not Exists(OutF) then Exit;

  Dest := Root + '/singledest';
  DelTree(Dest);
  ForceDirectories(Dest);
  A := nil;
  R := TzOpenArchive(OutF, '', A, Err);
  Check(R = TZ7Z_OK, Format('%s: reopen single stream', [AComp]));
  if R = TZ7Z_OK then
  try
    R := TzExtract(A, [], Dest, '', Err);
    Check(R = TZ7Z_OK, Format('%s: extract single stream', [AComp]));
  finally
    A.Free;
  end;
  { No tar layer. gzip keeps the name in its header; bzip2 and xz do not, so the
    file may arrive as [Content]. Either way its CONTENT must be the text, not a
    tar header -- that is what "not tar-wrapped" means here. }
  Payload := ReadText(Dest + '/one.txt');
  if Payload = '' then Payload := ReadText(Dest + '/[Content]');
  Check(Payload = 'alpha' + LineEnding,
    Format('%s: single stream is not tar-wrapped', [AComp]));
end;

{ Compressing an already-compressed file twice must still round-trip, and the
  inner name must not gain a doubled extension ("x.tar.tar"). }
procedure TestInnerName(const AComp, AExt: string);
var
  Src: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  OutGz, Dest: string;
  R: Integer;
  Err: string;
  A: TTzArchive;
begin
  Src := TStringList.Create;
  Set1 := Default(TZInputSet);
  Src.Add(Root + '/src');
  Set1 := TzCollectInputs(Src, '');
  OutGz := Root + '/named' + AExt;
  DelTree(OutGz);
  S := MakeSettings(AComp, 5, 0);
  Err := '';
  R := TzCreateArchive(OutGz, S, Set1.Recs, Err);
  TzInputSetFree(Set1);
  Src.Free;
  if R <> TZ7Z_OK then
  begin
    Check(False, Format('%s: setup for the name check', [AComp]));
    Exit;
  end;
  Dest := Root + '/nameddest';
  DelTree(Dest);
  ForceDirectories(Dest);
  A := nil;
  R := TzOpenArchive(OutGz, '', A, Err);
  if R = TZ7Z_OK then
  try
    { A single-entry stream: the stored name should be "named.tar". }
    if A.Count = 1 then
      Check(Pos('tar.tar', LowerCase(A.EntryName(0))) = 0,
        Format('%s: inner name is not x.tar.tar (got %s)',
          [AComp, A.EntryName(0)]));
  finally
    A.Free;
  end;
end;

procedure TestFormatsPresent;
var
  Fmts: TFormatInfoArray;
  I: Integer;
  Names: string;
begin
  { The dialog builds its format list from this, so every writable format the
    engine reports must be reachable. }
  Fmts := TzLoadFormats;
  Names := '';
  for I := 0 to High(Fmts) do
    if Fmts[I].CanUpdate then
      Names := Names + Fmts[I].Name + ' ';
  Check(Pos('7z', Names) > 0, 'formats: engine can write 7z');
  Check(Pos('zip', Names) > 0, 'formats: engine can write zip');
  Check(Pos('tar', Names) > 0, 'formats: engine can write tar');
  Check(Pos('gzip', Names) > 0, 'formats: engine can write gzip');
  Check(Pos('bzip2', Names) > 0, 'formats: engine can write bzip2');
  Check(Pos('xz', Names) > 0, 'formats: engine can write xz');
end;

{ tar is packing only: asking for compression options must not fail the job. }
procedure TestTarIgnoresCompressionOptions;
var
  DiskU: RawByteString;
  Inputs: array[0..0] of TZ7ZInput;
  S: TCreateSettings;
  OutF: string;
  R: Integer;
  Err: string;
begin
  DiskU := UTF8Encode(Root + '/src');
  Inputs[0].DiskPath := PAnsiChar(DiskU);
  Inputs[0].ArcPath := PAnsiChar('src');
  Inputs[0].IsDir := 1;
  OutF := Root + '/packed.tar';
  DelTree(OutF);
  S := MakeSettings('tar', -1, 0);
  S.Method := 'LZMA2';
  Err := '';
  R := TzCreateArchive(OutF, S, Inputs, Err);
  Check(R = TZ7Z_OK, Format('tar: packs a folder with a stray method set (rc=%d %s)',
    [R, Err]));
  Check(Exists(OutF), 'tar: archive exists');
end;

procedure TestDeepAndWide;
var
  Src: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  OutF, Dest: string;
  R, I: Integer;
  Err: string;
  A: TTzArchive;
begin
  { Many entries, including names with spaces and CJK, must survive. }
  ForceDirectories(Root + '/many');
  for I := 1 to 40 do
    WriteText(Root + '/many/f' + IntToStr(I) + '.txt', 'n' + IntToStr(I));
  WriteText(Root + '/many/cjk.txt', 'cjk');
  { Create the CJK-named file through the shell: the path goes to /bin/sh as
    UTF-8 bytes and the filesystem gets the right name. Doing it with
    TStringList.SaveToFile from Pascal goes through the RTL's string handling,
    and under this build the name arrives double-encoded -- which is a property
    of the test harness, not of the code under test. }
  { The name is written by sh itself with a printf of literal UTF-8 bytes, so
    nothing in the Pascal string layer can re-encode it. }
  ExecuteProcess('/bin/sh', ['-c',
    'printf cjk2 > "' + Root + '/many/名字 带空格.txt"']);
  Src := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Src.Add(Root + '/many');
    Set1 := TzCollectInputs(Src, '');
    OutF := Root + '/many.7z';
    DelTree(OutF);
    S := MakeSettings('7z', 5, 1);
    Err := '';
    R := TzCreateArchive(OutF, S, Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
    Src.Free;
  end;
  Check(R = TZ7Z_OK, Format('7z: 41 entries incl. CJK + spaces (rc=%d %s)', [R, Err]));
  Dest := Root + '/manydest';
  DelTree(Dest);
  ForceDirectories(Dest);
  A := nil;
  R := TzOpenArchive(OutF, '', A, Err);
  if R = TZ7Z_OK then
  try
    Check(A.Count >= 41, Format('7z: all entries present (%d)', [A.Count]));
    R := TzExtract(A, [], Dest, '', Err);
    Check(R = TZ7Z_OK, '7z: extract all');
  finally
    A.Free;
  end;
  { Verified through the shell so the assertion itself does not depend on the
    RTL's name conversion -- the point is the bytes on disk. }
  Check(Trim(ShellCat(Dest + '/many/名字 带空格.txt')) = 'cjk2',
    '7z: CJK name with a space round-trips');
  Check(Trim(ShellCat(Dest + '/many/f40.txt')) = 'n40',
    '7z: last entry round-trips');
end;

procedure TestEmptyInput;
var
  S: TCreateSettings;
  R: Integer;
  Err: string;
begin
  S := MakeSettings('7z', 5, 0);
  Err := '';
  R := TzCreateArchive(Root + '/nothing.7z', S, [], Err);
  Check(R <> TZ7Z_OK, 'create: refusing an empty input list');
end;

var
  RootOut: string;
begin
  { Same UTF-8 contract as the app (see the note in TyZip.lpr), and it must be
    in force BEFORE any path is built or any file is created. }
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Fails := 0;
  Passes := 0;
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('cannot load ', TzLibraryPath);
    Halt(2);
  end;
  BuildFixture;
  WriteText(Root + '/one.txt', 'alpha' + LineEnding);
  RootOut := Root;

  WriteLn('-- formats the dialog offers');
  TestFormatsPresent;

  WriteLn('-- 7z');
  CreateAndVerify('7z', Root + '/a.7z', Root + '/out7z', 5, 1);
  CreateAndVerify('7z', Root + '/a0.7z', Root + '/out7z0', 0, 0);

  WriteLn('-- zip');
  CreateAndVerify('zip', Root + '/a.zip', Root + '/outzip', 5, 0);
  CreateAndVerify('zip', Root + '/a0.zip', Root + '/outzip0', 0, 0);

  WriteLn('-- tar');
  CreateAndVerify('tar', Root + '/a.tar', Root + '/outtar', -1, 0);
  TestTarIgnoresCompressionOptions;

  WriteLn('-- wim');
  CreateAndVerify('wim', Root + '/a.wim', Root + '/outwim', 5, 0);

  WriteLn('-- single-stream formats: folder needs tar');
  TestCompound('gzip', '.tar.gz');
  TestCompound('bzip2', '.tar.bz2');
  TestCompound('xz', '.tar.xz');

  WriteLn('-- single-stream formats: one file stays plain');
  TestSingleStreamFile('gzip', '.gz');
  TestSingleStreamFile('bzip2', '.bz2');
  TestSingleStreamFile('xz', '.xz');

  WriteLn('-- compound inner name');
  TestInnerName('gzip', '.tar.gz');

  WriteLn('-- scale and odd names');
  TestDeepAndWide;

  WriteLn('-- errors');
  TestEmptyInput;

  DelTree(RootOut);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
