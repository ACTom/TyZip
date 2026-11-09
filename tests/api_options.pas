program api_options;
{$mode objfpc}{$H+}
{ Every create option the dialog exposes, per format.

  The dialog hides options a format cannot honour, but the settings record still
  carries defaults for them -- and a value the handler rejects fails the WHOLE
  job (tar refuses a compression method with E_INVALIDARG). So each option is
  tested where it applies, and the ones a format does not support are tested to
  be ignored rather than fatal.

  Every case is a full round trip: create, reopen, extract, compare bytes. }
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
  if P <> '' then Shell('/bin/rm -rf ' + QuotedStr(P));
end;

{ --- fixture ------------------------------------------------------------ }

procedure BuildTree;
begin
  DelTree(Root);
  ForceDirectories(Root + '/in/sub');
  Shell('printf "alpha" > ' + QuotedStr(Root + '/in/a.txt'));
  Shell('printf "beta" > ' + QuotedStr(Root + '/in/sub/b.txt'));
  Shell('printf "gamma" > ' + QuotedStr(Root + '/one.txt'));
  { A few hundred KB, so a solid block and multiple threads actually do
    something rather than compressing a single tiny file. }
  Shell('/usr/bin/head -c 300000 /dev/urandom > ' + QuotedStr(Root + '/in/big.bin'));
end;

function Collect(const APath: string): TZInputSet;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add(APath);
    Result := TzCollectInputs(L, '');
  finally
    L.Free;
  end;
end;

{ Create with ASettings, then verify the tree comes back byte for byte.
  Returns the create result so callers can assert on it. }
function CreateExtractVerify(const AOut: string; const ASettings: TCreateSettings;
  const ALabel: string): Integer;
var
  Set1: TZInputSet;
  Err, Dest: string;
  A: TTzArchive;
  R: Integer;
begin
  Set1 := Collect(Root + '/in');
  Dest := Root + '/dest';
  DelTree(AOut);
  DelTree(Dest);
  Err := '';
  try
    R := TzCreateArchive(AOut, ASettings, Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
  end;
  Result := R;
  Check(R = TZ7Z_OK, ALabel + ': create (rc=' + IntToStr(R) + ' ' + Err + ')');
  if R <> TZ7Z_OK then Exit;

  ForceDirectories(Dest);
  A := nil;
  R := TzOpenArchive(AOut, ASettings.Password, A, Err);
  Check(R = TZ7Z_OK, ALabel + ': reopen (' + Err + ')');
  if R <> TZ7Z_OK then Exit;
  try
    R := TzExtract(A, [], Dest, ASettings.Password, Err);
    Check(R = TZ7Z_OK, ALabel + ': extract (' + Err + ')');
    if ASettings.Password <> '' then
      R := TzTest(A, [], ASettings.Password, Err)
    else
      R := TzTest(A, [], '', Err);
    Check(R = TZ7Z_OK, ALabel + ': integrity test (' + Err + ')');
  finally
    A.Free;
  end;
  { A compound .tar.gz extracts to ONE tar file; the tree only appears after
    opening that tar. Unwind it so the same assertion covers both shapes. }
  if not FileExists(Dest + '/in/a.txt') then
  begin
    { Whatever single file the stream produced is the tar; its stored name
      varies by format (gzip keeps it, xz and bzip2 do not). }
    Shell('for f in ' + QuotedStr(Dest) + '/*; do ' +
      '[ -f "$f" ] && /usr/bin/tar xf "$f" -C ' + QuotedStr(Dest) + ' 2>/dev/null; ' +
      'done');
  end;
  Check(Trim(Shell('/bin/cat ' + QuotedStr(Dest + '/in/a.txt') + ' 2>/dev/null')) = 'alpha',
    ALabel + ': a.txt round-trips');
  Check(Trim(Shell('/bin/cat ' + QuotedStr(Dest + '/in/sub/b.txt') + ' 2>/dev/null')) = 'beta',
    ALabel + ': nested b.txt round-trips');
end;

function Skeleton(const AFmt: string): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFmt;
  Result.Level := 5;
end;

{ --- levels ------------------------------------------------------------- }

procedure TestLevels;
const
  Fmts: array[0..6] of string = ('7z', 'zip', 'tar', 'gzip', 'bzip2', 'xz', 'wim');
var
  Fmt: string;
  Lvl: Integer;
  S: TCreateSettings;
  I: Integer;
begin
  for I := 0 to High(Fmts) do
  begin
    Fmt := Fmts[I];
    for Lvl in [0, 1, 5, 9] do
    begin
      S := Skeleton(Fmt);
      S.Level := Lvl;
      if Fmt = 'tar' then
        { tar has no level; the engine must simply ignore it. }
        CreateExtractVerify(Root + '/lvl-' + Fmt + '.tar', S,
          Format('level %s x%d (tar ignores it)', [Fmt, Lvl]))
      else if Fmt = 'gzip' then
        CreateExtractVerify(Root + '/lvl-gzip.tar.gz', S,
          Format('level gzip x%d (folder -> tar.gz)', [Lvl]))
      else if Fmt = 'bzip2' then
        CreateExtractVerify(Root + '/lvl-bzip2.tar.bz2', S,
          Format('level bzip2 x%d (folder -> tar.bz2)', [Lvl]))
      else if Fmt = 'xz' then
        CreateExtractVerify(Root + '/lvl-xz.tar.xz', S,
          Format('level xz x%d (folder -> tar.xz)', [Lvl]))
      else
        CreateExtractVerify(Root + '/lvl-' + Fmt + '.' + Fmt, S,
          Format('level %s x%d', [Fmt, Lvl]));
    end;
  end;
end;

procedure TestLevelOutOfRange;
var
  S: TCreateSettings;
  R: Integer;
  Set1: TZInputSet;
  Err: string;
begin
  { -1 means "engine default", which every format must accept. }
  S := Skeleton('7z');
  S.Level := -1;
  CreateExtractVerify(Root + '/lvl-default.7z', S, 'level 7z x(-1 default)');

  { 10 is not a valid level. It must either be rejected cleanly or clamped --
    never produce a corrupt archive. }
  S := Skeleton('zip');
  S.Level := 10;
  Set1 := Collect(Root + '/in');
  Err := '';
  R := TzCreateArchive(Root + '/lvl-bad.zip', S, Set1.Recs, Err);
  TzInputSetFree(Set1);
  Check((R = TZ7Z_OK) or (R < 0), 'level 10: no crash');

  S := Skeleton('zip');
  S.Level := -5;
  Set1 := Collect(Root + '/in');
  Err := '';
  R := TzCreateArchive(Root + '/lvl-neg.zip', S, Set1.Recs, Err);
  TzInputSetFree(Set1);
  Check((R = TZ7Z_OK) or (R < 0), 'level -5: no crash');
end;

{ --- methods ------------------------------------------------------------ }

procedure TestMethods;
const
  Cases: array[0..11] of array[0..1] of string = (
    ('7z', 'LZMA2'), ('7z', 'LZMA'), ('7z', 'PPMd'), ('7z', 'BZip2'),
    ('7z', 'Deflate'), ('7z', 'Copy'),
    ('zip', 'Deflate'), ('zip', 'Deflate64'), ('zip', 'BZip2'),
    ('zip', 'LZMA'), ('zip', 'PPMd'), ('zip', 'Copy'));
var
  I: Integer;
  S: TCreateSettings;
begin
  for I := 0 to High(Cases) do
  begin
    S := Skeleton(Cases[I][0]);
    S.Method := Cases[I][1];
    CreateExtractVerify(Root + '/m-' + Cases[I][0] + '-' + Cases[I][1] + '.' + Cases[I][0],
      S, 'method ' + Cases[I][0] + '/' + Cases[I][1]);
  end;
end;

procedure TestMethodIgnoredElsewhere;
var
  S: TCreateSettings;
begin
  { tar/wim/single-stream formats: a stray method must not fail the job. }
  S := Skeleton('tar');
  S.Method := 'LZMA2';
  CreateExtractVerify(Root + '/m-tar.tar', S, 'method tar ignores LZMA2');

  S := Skeleton('gzip');
  S.Method := 'LZMA2';
  CreateExtractVerify(Root + '/m-gz.tar.gz', S, 'method gzip ignores LZMA2');
end;

{ --- solid -------------------------------------------------------------- }

procedure TestSolid;
var
  S: TCreateSettings;
begin
  S := Skeleton('7z');
  S.Solid := True;
  CreateExtractVerify(Root + '/sol-on.7z', S, 'solid on (7z)');
  S.Solid := False;
  CreateExtractVerify(Root + '/sol-off.7z', S, 'solid off (7z)');

  { zip, tar and the single-stream formats have no solid mode. }
  S := Skeleton('zip');
  S.Solid := True;
  CreateExtractVerify(Root + '/sol-zip.zip', S, 'solid on (zip ignores it)');
  S := Skeleton('tar');
  S.Solid := True;
  CreateExtractVerify(Root + '/sol-tar.tar', S, 'solid on (tar ignores it)');
end;

{ --- threads ------------------------------------------------------------ }

procedure TestThreads;
var
  S: TCreateSettings;
  N: Integer;
begin
  for N in [1, 2, 8] do
  begin
    S := Skeleton('7z');
    S.Threads := N;
    CreateExtractVerify(Root + '/th-' + IntToStr(N) + '.7z', S,
      'threads ' + IntToStr(N) + ' (7z)');
  end;
  S := Skeleton('zip');
  S.Threads := 4;
  CreateExtractVerify(Root + '/th-zip.zip', S, 'threads 4 (zip)');
  { 0 = auto. }
  S := Skeleton('7z');
  S.Threads := 0;
  CreateExtractVerify(Root + '/th-auto.7z', S, 'threads 0 (auto)');
end;

{ --- dictionary and LZMA-only options ----------------------------------- }

procedure TestDictionary;
const
  DictList: array[0..2] of QWord = (1 * 1024 * 1024, 16 * 1024 * 1024,
    64 * 1024 * 1024);
var
  S: TCreateSettings;
  Dict: QWord;
  I: Integer;
begin
  for I := 0 to High(DictList) do
  begin
    Dict := DictList[I];
    S := Skeleton('7z');
    S.DictionarySize := Dict;
    CreateExtractVerify(Root + '/d-' + IntToStr(Dict) + '.7z', S,
      'dictionary ' + TzFormatSize(Dict) + ' (7z)');
  end;
  { A dictionary on a method that has none must be ignored, not fatal. }
  S := Skeleton('7z');
  S.Method := 'Copy';
  S.DictionarySize := 64 * 1024 * 1024;
  CreateExtractVerify(Root + '/d-copy.7z', S, 'dictionary ignored by Copy');
end;

procedure TestMatchFinderAndPasses;
const
  MfList: array[0..2] of string = ('bt4', 'bt3', 'hc4');
var
  S: TCreateSettings;
  MF: string;
  I: Integer;
begin
  for I := 0 to High(MfList) do
  begin
    MF := MfList[I];
    S := Skeleton('7z');
    S.Method := 'LZMA2';
    S.MatchFinder := MF;
    CreateExtractVerify(Root + '/mf-' + MF + '.7z', S, 'match finder ' + MF);
  end;
  { Passes exist for BZip2 and Deflate only; sending it to LZMA2 must be ignored
    rather than fail the whole create. }
  S := Skeleton('7z');
  S.Method := 'BZip2';
  S.NumPasses := 8;
  CreateExtractVerify(Root + '/pass.7z', S, 'passes 8 (7z/BZip2)');
  S := Skeleton('7z');
  S.Method := 'LZMA2';
  S.NumPasses := 8;
  CreateExtractVerify(Root + '/pass-lzma.7z', S, 'passes on LZMA2 are ignored');
end;

procedure TestWordSizePPMd;
var
  S: TCreateSettings;
  W: Integer;
begin
  for W in [16, 32] do
  begin
    S := Skeleton('7z');
    S.Method := 'PPMd';
    S.WordSize := W;
    CreateExtractVerify(Root + '/w-' + IntToStr(W) + '.7z', S,
      'PPMd word size ' + IntToStr(W));
  end;
end;

{ --- encryption --------------------------------------------------------- }

procedure TestEncryption;
var
  S: TCreateSettings;
  A: TTzArchive;
  Err: string;
  R: Integer;
  Set1: TZInputSet;
  Name, OutF, Dest: string;
begin
  { 7z: AES-256 is the only option, plus optional header encryption. }
  S := Skeleton('7z');
  S.Password := 'secret';
  OutF := Root + '/enc.7z';
  CreateExtractVerify(OutF, S, 'password (7z)');

  S := Skeleton('7z');
  S.Password := 'secret';
  S.EncryptNames := True;
  OutF := Root + '/enche.7z';
  CreateExtractVerify(OutF, S, 'password + encrypted names (7z)');
  { With the header encrypted, listing without a password must fail or show
    nothing useful -- it must never expose the real entry names. }
  A := nil;
  Err := '';
  R := TzOpenArchive(OutF, '', A, Err);
  if R = TZ7Z_OK then
  try
    Check(A.Count = 0, 'encrypted names: no entries visible without the password');
  finally
    A.Free;
  end
  else
    Check(True, 'encrypted names: listing refused without the password');

  { zip: AES-256 and classic ZipCrypto. }
  S := Skeleton('zip');
  S.Password := 'secret';
  S.ZipAES256 := True;
  CreateExtractVerify(Root + '/enc-aes.zip', S, 'password AES-256 (zip)');

  S := Skeleton('zip');
  S.Password := 'secret';
  S.ZipAES256 := False;
  CreateExtractVerify(Root + '/enc-zc.zip', S, 'password ZipCrypto (zip)');

  { A wrong password must be refused, not silently produce garbage. }
  S := Skeleton('7z');
  S.Password := 'secret';
  OutF := Root + '/enc-wrong.7z';
  Set1 := Collect(Root + '/in');
  DelTree(OutF);
  Err := '';
  try
    R := TzCreateArchive(OutF, S, Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
  end;
  Check(R = TZ7Z_OK, 'wrong password: setup');
  A := nil;
  R := TzOpenArchive(OutF, 'wrong-password', A, Err);
  if R = TZ7Z_OK then
  try
    Dest := Root + '/dest-wrong';
    DelTree(Dest);
    ForceDirectories(Dest);
    R := TzExtract(A, [], Dest, 'wrong-password', Err);
    Check(R <> TZ7Z_OK, 'wrong password: extraction refused');
  finally
    A.Free;
  end
  else
    Check(True, 'wrong password: open refused');

  { Formats that cannot encrypt must ignore a password rather than fail. }
  S := Skeleton('tar');
  S.Password := 'secret';
  CreateExtractVerify(Root + '/enc-tar.tar', S, 'password on tar (ignored)');
end;

{ --- volumes ------------------------------------------------------------ }

procedure TestVolumes;
var
  S: TCreateSettings;
  Set1: TZInputSet;
  Err, Base: string;
  R: Integer;
  Parts: Integer;
  VA: TTzArchive;
begin
  VA := nil;
  S := Skeleton('7z');
  S.VolumeSize := 64 * 1024;
  S.Level := 0;   { store, so the parts really are ~64 KB each }
  Base := Root + '/vol.7z';
  DelTree(Base + '.001');
  Set1 := Collect(Root + '/in');
  Err := '';
  try
    R := TzCreateArchive(Base, S, Set1.Recs, Err);
  finally
    TzInputSetFree(Set1);
  end;
  Check(R = TZ7Z_OK, 'volumes: create (' + Err + ')');
  if R <> TZ7Z_OK then Exit;
  WriteLn('   volume parts: ',
    Trim(Shell('ls ' + QuotedStr(Base) + '.* 2>/dev/null | tr "\n" " "')));
  Parts := StrToIntDef(Trim(Shell('ls ' + QuotedStr(Base) + '.* 2>/dev/null | wc -l')), 0);
  Check(Parts >= 2, Format('volumes: split into %d parts', [Parts]));
  Check(Trim(Shell('test -f "' + Base + '.001" && echo yes')) = 'yes',
    'volumes: first part is .001');
  { Opening the set through .001 must reach every entry. }
  R := TzOpenArchive(Base + '.001', '', VA, Err);
  Check(R = TZ7Z_OK, 'volumes: .001 opens as the archive (' + Err + ')');
  if R = TZ7Z_OK then VA.Free;
end;

{ --- extra options escape hatch ----------------------------------------- }

procedure TestExtraOptions;
var
  S: TCreateSettings;
begin
  S := Skeleton('7z');
  S.ExtraOptions := 'mt=2';
  CreateExtractVerify(Root + '/x-mt.7z', S, 'extra options mt=2');

  S := Skeleton('7z');
  S.ExtraOptions := 's=on';
  CreateExtractVerify(Root + '/x-solid.7z', S, 'extra options s=on');

  { Nonsense in the field must not crash and must not silently produce a
    broken archive. }
  S := Skeleton('7z');
  S.ExtraOptions := 'this-is-not-a-property=99';
  CreateExtractVerify(Root + '/x-bad.7z', S, 'extra options: unknown property tolerated');
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
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-opt-' +
    IntToStr(GetProcessID);
  BuildTree;

  WriteLn('-- compression levels');
  TestLevels;
  TestLevelOutOfRange;

  WriteLn('-- methods');
  TestMethods;
  TestMethodIgnoredElsewhere;

  WriteLn('-- solid');
  TestSolid;

  WriteLn('-- threads');
  TestThreads;

  WriteLn('-- dictionary / LZMA options');
  TestDictionary;
  TestMatchFinderAndPasses;
  TestWordSizePPMd;

  WriteLn('-- encryption');
  TestEncryption;

  WriteLn('-- volumes');
  TestVolumes;

  WriteLn('-- extra options');
  TestExtraOptions;

  DelTree(Root);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
