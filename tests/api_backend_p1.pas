program api_backend_p1;
{$mode objfpc}{$H+}
{$codepage utf8}
{ Regression tests for the P1 defects in backend/tz7z.cpp (ticket 09).

  Covered here:

  * an archive opened with its password falls back to that password when the
    caller passes "" instead of treating "" as the password,
  * a CRC error on an encrypted archive is reported as an extraction error, not
    rewritten to "wrong password" (which made the UI ask for the password
    forever),
  * a failed multi-volume create leaves no orphan .001/.002 parts behind,
  * a failed rewrite (write/flush failure) leaves the previous archive intact,
  * an input list with a NULL path is an argument error, not a silently smaller
    archive,
  * tar symbolic and hard links are recreated as links instead of regular files
    that contain the link target. }

uses
  BaseUnix, SysUtils, Classes, DynLibs, Process, tzip.api;

var
  Fails, Passes: Integer;
  Root: string;
  SavedLimit: TRLimit;
  HaveSavedLimit: Boolean;

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

function ReadAllText(const APath: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(APath);
    Result := L.Text;
  finally L.Free; end;
end;

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally L.Free; end;
end;

procedure WriteBlob(const APath: string; const AData: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    if Length(AData) > 0 then
      F.WriteBuffer(AData[1], Length(AData));
  finally F.Free; end;
end;

function Run(const AExe: string; const AArgs: array of string): Integer;
var
  P: TProcess;
  I: Integer;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := AExe;
    for I := 0 to High(AArgs) do P.Parameters.Add(AArgs[I]);
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus;
  finally P.Free; end;
end;

{ The file-size rlimit is a deterministic way to make a write fail without
  filling the disk. SIGXFSZ is ignored so the failure comes back as EFBIG. }
procedure SetFileSizeLimit(ALimit: QWord);
var
  Rl: TRLimit;
begin
  if not HaveSavedLimit then
  begin
    if fpGetRLimit(RLIMIT_FSIZE, @SavedLimit) <> 0 then
      Exit;
    HaveSavedLimit := True;
  end;
  Rl := SavedLimit;
  Rl.rlim_cur := ALimit;
  fpSetRLimit(RLIMIT_FSIZE, @Rl);
end;

procedure RestoreFileSizeLimit;
begin
  if HaveSavedLimit then
    fpSetRLimit(RLIMIT_FSIZE, @SavedLimit);
end;

type
  TInput = record
    DiskU: RawByteString;
    ArcU: RawByteString;
    Rec: TZ7ZInput;
  end;

procedure SetInput(var AInput: TInput; const ADisk, AArc: string; AIsDir: Boolean);
begin
  AInput.DiskU := UTF8Encode(ADisk);
  AInput.ArcU := UTF8Encode(AArc);
  AInput.Rec.DiskPath := PAnsiChar(AInput.DiskU);
  AInput.Rec.ArcPath := PAnsiChar(AInput.ArcU);
  AInput.Rec.IsDir := Ord(AIsDir);
end;

function ExtractEntryText(const APath, APassword, AOutDir: string;
  out AText: string; out AErr: string): Boolean;
var
  A: TTzArchive;
  R: Integer;
begin
  Result := False;
  AText := '';
  A := nil;
  R := TzOpenArchive(APath, APassword, A, AErr);
  if R <> TZ7Z_OK then
    Exit;
  try
    ForceDirectories(AOutDir);
    R := TzExtract(A, [], AOutDir, APassword, AErr);
    if R <> TZ7Z_OK then
      Exit;
  finally
    A.Free;
  end;
  if not FileExists(AOutDir + '/payload.txt') then
  begin
    AErr := 'payload.txt was not extracted';
    Exit;
  end;
  AText := ReadAllText(AOutDir + '/payload.txt');
  Result := True;
end;

function CreateZip(const APath, AContent, APassword: string; AAES: Boolean;
  out AErr: string): Integer;
var
  Inp: TInput;
  S: TCreateSettings;
begin
  WriteText(Root + '/payload-src.txt', AContent);
  SetInput(Inp, Root + '/payload-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 0;
  S.Method := 'Deflate';
  S.ForceUtf8 := True;
  S.Password := APassword;
  S.ZipAES256 := AAES;
  Result := TzCreate(APath, S, [Inp.Rec], AErr);
end;

{ --- P1: password fallback --------------------------------------------- }

procedure TestPasswordFallback;
var
  Inp: TInput;
  S: TCreateSettings;
  R: Integer;
  Err, Z, Text, Dest: string;
  A: TTzArchive;
  Count: Integer;
begin
  Z := Root + '/enc-fallback.7z';
  Dest := Root + '/enc-fallback-out';
  WriteText(Root + '/enc-src.txt', 'encrypted-payload');
  SetInput(Inp, Root + '/enc-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 5;
  S.Password := 'secret';
  R := TzCreate(Z, S, [Inp.Rec], Err);
  Check(R = TZ7Z_OK, 'password fallback: setup encrypted archive (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;

  A := nil;
  R := TzOpenArchive(Z, 'secret', A, Err);
  Check(R = TZ7Z_OK, 'password fallback: opened with the password (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;
  try
    { The caller passes "" when it has no new password to offer; the archive's
      own password must be used, not the empty string. }
    R := TzTest(A, [], '', Err);
    Check(R = TZ7Z_OK, Format('password fallback: test with "" uses the archive password (%d, %s)', [R, Err]));
    R := TzExtract(A, [], Dest, '', Err);
    Check(R = TZ7Z_OK, Format('password fallback: extract with "" uses the archive password (%d, %s)', [R, Err]));
    R := TzTest(A, [], 'wrong', Err);
    Check(R <> TZ7Z_OK, 'password fallback: a wrong password is still refused');
  finally
    A.Free;
  end;
  if FileExists(Dest + '/payload.txt') then
    EqStr(Trim(ReadAllText(Dest + '/payload.txt')), 'encrypted-payload',
      'password fallback: the payload is correct')
  else
    Check(False, 'password fallback: the payload was extracted');
  { Keep the compiler honest about the unused variable. }
  Count := 0;
  if Count <> 0 then WriteLn(Count);
end;

{ --- P1: CRC error is not a password error ----------------------------- }

procedure CorruptFirstZipPayloadByte(const APath: string);
var
  F: TFileStream;
  Data: TBytes;
  I, NameLen, ExtraLen, DataStart: Integer;
begin
  F := TFileStream.Create(APath, fmOpenReadWrite);
  try
    SetLength(Data, F.Size);
    if Length(Data) > 0 then
      F.ReadBuffer(Data[0], Length(Data));
    I := 0;
    while I + 30 <= Length(Data) do
    begin
      if (Data[I] = $50) and (Data[I + 1] = $4B) and
         (Data[I + 2] = $03) and (Data[I + 3] = $04) then
      begin
        NameLen := Data[I + 26] or (Data[I + 27] shl 8);
        ExtraLen := Data[I + 28] or (Data[I + 29] shl 8);
        DataStart := I + 30 + NameLen + ExtraLen;
        { Skip the 12-byte ZipCrypto header: corrupting that would look like a
          wrong password. The bit after it must surface as a CRC error. }
        if DataStart + 12 + 3 < Length(Data) then
          Data[DataStart + 12 + 3] := Data[DataStart + 12 + 3] xor $FF;
        Break;
      end;
      Inc(I);
    end;
    F.Position := 0;
    F.WriteBuffer(Data[0], Length(Data));
  finally F.Free; end;
end;

procedure TestCrcErrorIsNotPassword;
var
  R: Integer;
  Err, Z: string;
  A: TTzArchive;
begin
  Z := Root + '/crc.zip';
  R := CreateZip(Z, 'crc-payload-0123456789', 'secret', False, Err);
  Check(R = TZ7Z_OK, 'CRC error: setup encrypted zip (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;
  CorruptFirstZipPayloadByte(Z);

  A := nil;
  R := TzOpenArchive(Z, 'secret', A, Err);
  Check(R = TZ7Z_OK, 'CRC error: the header is still readable (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;
  try
    R := TzTest(A, [], 'secret', Err);
    Check(R = TZ7Z_E_EXTRACT,
      Format('CRC error: reported as an extraction error, not a password error (%d, %s)', [R, Err]));
  finally
    A.Free;
  end;
end;

{ --- P1: failed multi-volume create leaves no parts -------------------- }

function CountGlob(const APattern: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(APattern, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure TestSplitFailureLeavesNoParts;
var
  Inp: TInput;
  S: TCreateSettings;
  R: Integer;
  Err, Base: string;
begin
  Base := Root + '/split-fail.7z';
  WriteBlob(Root + '/split-big.bin', StringOfChar('x', 220 * 1024));
  SetInput(Inp, Root + '/split-big.bin', 'big.bin', False);
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 0;
  S.VolumeSize := 64 * 1024;
  { Let the first volume land, then fail while the second is being written. }
  SetFileSizeLimit(50 * 1024);
  try
    R := TzCreate(Base, S, [Inp.Rec], Err);
  finally
    RestoreFileSizeLimit;
  end;
  Check(R <> TZ7Z_OK, Format('split failure: the create failed (%d, %s)', [R, Err]));
  Check(CountGlob(Base + '.*') = 0,
    Format('split failure: no .001/.002 parts are left behind (%d found)',
      [CountGlob(Base + '.*')]));
  Check(not FileExists(Base), 'split failure: no base archive is left behind');
end;

{ --- P1: a failed rewrite keeps the old archive ------------------------ }

procedure TestFailedRewriteKeepsArchive;
var
  Inp: TInput;
  S: TCreateSettings;
  R: Integer;
  Err, Z, Text, Dest: string;
  SizeBefore: Int64;
  F: TFileStream;
begin
  Z := Root + '/rewrite.tar';
  Dest := Root + '/rewrite-out';
  WriteText(Root + '/rewrite-src.txt', 'tar-original-payload');
  SetInput(Inp, Root + '/rewrite-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := 'tar';
  S.Level := 0;
  R := TzCreate(Z, S, [Inp.Rec], Err);
  Check(R = TZ7Z_OK, 'failed rewrite: setup tar (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;
  F := TFileStream.Create(Z, fmOpenRead);
  try
    SizeBefore := F.Size;
  finally F.Free; end;
  Check(SizeBefore > 1000, 'failed rewrite: the setup tar is larger than the limit');

  S := Default(TCreateSettings);
  S.FormatName := 'tar';
  S.Level := -1;
  { Below the archive size: every write reaches the stdio buffer, the failure
    only shows up when the stream is flushed and closed. The old code renamed
    the truncated temporary file over the archive anyway. }
  SetFileSizeLimit(1000);
  try
    R := TzModify(Z, '', S, [], [], Err);
  finally
    RestoreFileSizeLimit;
  end;
  Check(R <> TZ7Z_OK,
    Format('failed rewrite: the failed modify is reported (%d, %s)', [R, Err]));
  Check(ExtractEntryText(Z, '', Dest, Text, Err),
    'failed rewrite: the original archive still extracts (' + Err + ')');
  EqStr(Trim(Text), 'tar-original-payload', 'failed rewrite: the original payload is intact');
end;

{ --- P1: NULL input path is an error, not a smaller archive ------------ }

type
  TCreateFn = function(ArchivePath: PAnsiChar; Options: PZ7ZCreateOptions;
    Inputs: PZ7ZInput; Count: LongWord; Progress: Pointer; User: Pointer;
    Err: PAnsiChar; ErrCap: LongInt): LongInt; cdecl;

procedure TestNullInputIsRejected;
var
  H: TLibHandle;
  CreateFn: TCreateFn;
  Opt: TZ7ZCreateOptions;
  Inputs: array[0..1] of TZ7ZInput;
  Disk1, Arc1, Fmt: RawByteString;
  Err: array[0..1023] of AnsiChar;
  R: Integer;
  OutF, ErrS: string;
begin
  OutF := Root + '/null-input.zip';
  DeleteFile(OutF);
  H := LoadLibrary(TzLibraryPath);
  if H = NilHandle then
  begin
    Check(False, 'NULL input: cannot reopen the engine library');
    Exit;
  end;
  CreateFn := TCreateFn(GetProcedureAddress(H, 'tz7z_create'));
  if not Assigned(CreateFn) then
  begin
    Check(False, 'NULL input: tz7z_create is not exported');
    Exit;
  end;

  { Deliberately call the C ABI: tzip.api always passes two non-NULL pointers,
    so this branch (and its silent skip) is only reachable from C. }
  WriteText(Root + '/null-input-src.txt', 'null-input');
  FillChar(Opt, SizeOf(Opt), 0);
  Fmt := 'zip';
  Opt.FormatName := PAnsiChar(Fmt);
  Opt.Level := 5;
  Disk1 := UTF8Encode(Root + '/null-input-src.txt');
  Arc1 := 'payload.txt';
  Inputs[0].DiskPath := PAnsiChar(Disk1);
  Inputs[0].ArcPath := PAnsiChar(Arc1);
  Inputs[0].IsDir := 0;
  Inputs[1].DiskPath := PAnsiChar(Disk1);
  Inputs[1].ArcPath := nil;
  Inputs[1].IsDir := 0;

  FillChar(Err, SizeOf(Err), 0);
  R := CreateFn(PAnsiChar(OutF), @Opt, @Inputs[0], 2, nil, nil, @Err[0], SizeOf(Err));
  ErrS := string(AnsiString(PAnsiChar(@Err[0])));
  Check(R = TZ7Z_E_ARG,
    Format('NULL input: rejected with an argument error (%d, %s)', [R, ErrS]));
  Check(not FileExists(OutF), 'NULL input: no archive is written for a rejected input list');
end;

{ --- P1: tar links ------------------------------------------------------ }

procedure TestTarLinks;
var
  SrcDir, Z, Dest: string;
  St: stat;
  Target: array[0..1023] of AnsiChar;
  R, N: Integer;
  Err: string;
  A: TTzArchive;
begin
  SrcDir := Root + '/link-src';
  ForceDirectories(SrcDir);
  WriteText(SrcDir + '/payload.txt', 'symlink-payload');
  DeleteFile(SrcDir + '/link');
  if fpSymlink(PChar('payload.txt'), PChar(SrcDir + '/link')) <> 0 then
  begin
    Check(False, 'tar links: cannot create the setup symlink');
    Exit;
  end;
  if Run('/bin/ln', [SrcDir + '/payload.txt', SrcDir + '/hard']) <> 0 then
    Check(False, 'tar links: setup hard link failed');
  Z := Root + '/links.tar';
  Dest := Root + '/links-out';
  if Run('/usr/bin/tar', ['-cf', Z, '-C', SrcDir, 'payload.txt', 'link', 'hard']) <> 0 then
  begin
    Check(False, 'tar links: setup tar failed');
    Exit;
  end;

  A := nil;
  R := TzOpenArchive(Z, '', A, Err);
  Check(R = TZ7Z_OK, 'tar links: the tar opens (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;
  try
    ForceDirectories(Dest);
    R := TzExtract(A, [], Dest, '', Err);
    Check(R = TZ7Z_OK, 'tar links: extraction succeeds (' + Err + ')');
  finally
    A.Free;
  end;

  N := fpLstat(Dest + '/link', St);
  Check((N = 0) and ((St.st_mode and S_IFMT) = S_IFLNK),
    Format('tar links: the symbolic link is a link, not a regular file (stat=%d mode=%x)',
      [N, St.st_mode]));
  if N = 0 then
  begin
    FillChar(Target, SizeOf(Target), 0);
    N := fpReadLink(PChar(Dest + '/link'), @Target[0], SizeOf(Target) - 1);
    Check((N > 0) and (string(Target) = 'payload.txt'),
      Format('tar links: the link target is preserved [%s]', [string(Target)]));
  end;
  N := fpLstat(Dest + '/hard', St);
  Check((N = 0) and ((St.st_mode and S_IFMT) = S_IFREG) and (St.st_nlink >= 2),
    Format('tar links: the hard link shares its inode (stat=%d mode=%x nlink=%d)',
      [N, St.st_mode, St.st_nlink]));
  Check(FileExists(Dest + '/payload.txt'),
    'tar links: the regular entry is still extracted');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-backend-p1-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  { Without this a write over the rlimit kills the process instead of failing. }
  fpSignal(SIGXFSZ, SignalHandler(SIG_IGN));
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  WriteLn('-- password fallback');
  TestPasswordFallback;
  WriteLn('-- CRC error is not a password error');
  TestCrcErrorIsNotPassword;
  WriteLn('-- failed split create leaves no parts');
  TestSplitFailureLeavesNoParts;
  WriteLn('-- failed rewrite keeps the archive');
  TestFailedRewriteKeepsArchive;
  WriteLn('-- NULL input path');
  TestNullInputIsRejected;
  WriteLn('-- tar links');
  TestTarLinks;

  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
