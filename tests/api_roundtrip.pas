program api_roundtrip;
{$mode objfpc}{$H+}
uses SysUtils, Classes, DateUtils, tzip.api, tzip.engine;

var
  Fails: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then WriteLn('ok   ', AMsg)
  else begin WriteLn('FAIL ', AMsg); Inc(Fails); end;
end;

function MakeInput(const ADisk, AArc: string; AIsDir: Boolean): TZ7ZInput;
begin
  Result.DiskPath := PAnsiChar(UTF8Encode(ADisk));
  Result.ArcPath := PAnsiChar(UTF8Encode(AArc));
  Result.IsDir := Ord(AIsDir);
end;

var
  Root, Src, A7, AZ, OutDir, Err, Pw, Inner, InnerOut: string;
  S: TCreateSettings;
  Inputs: array of TZ7ZInput;
  DiskU, ArcU: array of RawByteString;
  A: TTzArchive;
  C: TArchiveContext;
  L: TListing;
  Ind: TLongWordArray;
  R: Integer;
  I: Integer;
  U: RawByteString;
  FS: TFileStream;
  Buf: array[0..1023] of Byte;

  procedure AddFile(const Rel: string; const Data: string);
  var T: TStringList;
  begin
    T := TStringList.Create;
    try T.Text := Data; T.SaveToFile(IncludeTrailingPathDelimiter(Src) + Rel); finally T.Free; end;
  end;

  function AllIndices(Ctx: TArchiveContext): TLongWordArray;
  begin Result := TzAllIndices(Ctx); end;

begin
  Fails := 0;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-api-' + IntToStr(GetProcessID);
  Src := Root + '/src';
  ForceDirectories(Src + '/sub');
  AddFile('a.txt', 'alpha' + LineEnding);
  AddFile('sub/b.txt', 'bravo' + LineEnding);
  AddFile('sub/c.bin', StringOfChar('x', 3000000));
  A7 := Root + '/test.7z';
  AZ := Root + '/test.zip';
  OutDir := Root + '/out';
  if not TzLoadLibrary(ParamStr(0)) then begin WriteLn('no lib'); Halt(2); end;

  SetLength(Inputs, 4);
  SetLength(DiskU, 4); SetLength(ArcU, 4);
  DiskU[0] := UTF8Encode(Src); ArcU[0] := UTF8Encode('src');
  DiskU[1] := UTF8Encode(Src + '/a.txt'); ArcU[1] := UTF8Encode('src/a.txt');
  DiskU[2] := UTF8Encode(Src + '/sub/b.txt'); ArcU[2] := UTF8Encode('src/sub/b.txt');
  DiskU[3] := UTF8Encode(Src + '/sub/c.bin'); ArcU[3] := UTF8Encode('src/sub/c.bin');
  for I := 0 to 3 do
  begin
    Inputs[I].DiskPath := PAnsiChar(DiskU[I]);
    Inputs[I].ArcPath := PAnsiChar(ArcU[I]);
    Inputs[I].IsDir := Ord(I = 0);
  end;

  S := Default(TCreateSettings);
  S.FormatName := '7z'; S.Level := 5; S.Method := 'LZMA2'; S.Solid := True; S.Threads := 0;
  R := TzCreate(A7, S, Inputs, Err);
  Check(R = 0, 'create 7z: ' + Err);
  S.Password := 'secret'; S.EncryptNames := True;
  R := TzCreate(Root + '/enc.7z', S, Inputs, Err);
  Check(R = 0, 'create encrypted 7z: ' + Err);
  S := Default(TCreateSettings);
  S.FormatName := 'zip'; S.Level := 5; S.Method := 'Deflate'; S.Password := 'zippw'; S.ZipAES256 := True;
  R := TzCreate(AZ, S, Inputs, Err);
  Check(R = 0, 'create zip: ' + Err);

  R := TzOpenArchive(A7, '', A, Err);
  Check(R = 0, 'open 7z');
  if R = 0 then
  begin
    Check(A.Count = 4, '7z entry count');
    Ind := TzAllIndices(nil);
    R := TzTest(A, Ind, '', Err);
    Check(R = 0, 'empty indices means all');
    R := TzExtract(A, Ind, OutDir, '', Err);
    WriteLn('extract R=', R, ' err=', Err);
    Check(R = 0, 'extract 7z: ' + Err);
    Check(FileExists(OutDir + '/src/a.txt'), 'extracted a.txt');
    Check(FileExists(OutDir + '/src/sub/c.bin'), 'extracted c.bin');
    A.Free;
  end;

  R := TzOpenArchive(Root + '/enc.7z', '', A, Err);
  Check(R = TZ7Z_E_PASSWORD, 'encrypted header asks password');
  R := TzOpenArchive(Root + '/enc.7z', 'secret', A, Err);
  Check(R = 0, 'open encrypted with password');
  if R = 0 then
  begin
    R := TzTest(A, TzAllIndices(nil), 'secret', Err);
    Check(R = 0, 'test encrypted');
    R := TzExtract(A, TzAllIndices(nil), Root + '/encout', 'wrong', Err);
    WriteLn('wrongpw R=', R, ' err=', Err);
    { A 7z with a readable header reports a wrong data password as a data/CRC
      error, not as kWrongPassword.  The bridge must no longer rewrite that to
      TZ7Z_E_PASSWORD: that rewrite made every corrupt entry in an encrypted
      archive look like a password problem and the UI asked for the password
      forever (ticket 09).  The password is still rejected -- the extraction
      fails -- it just keeps its honest error code. }
    Check(R <> TZ7Z_OK, 'wrong password rejected');
    R := TzExtract(A, TzAllIndices(nil), Root + '/encout', 'secret', Err);
    Check(R = 0, 'extract encrypted');
    A.Free;
  end;

  R := TzOpenArchive(AZ, 'zippw', A, Err);
  Check(R = 0, 'open zip aes');
  if R = 0 then
  begin
    R := TzTest(A, TzAllIndices(nil), 'zippw', Err);
    Check(R = 0, 'test zip aes');
    R := TzExtract(A, TzAllIndices(nil), Root + '/zipout', 'zippw', Err);
    Check(R = 0, 'extract zip aes: ' + Err);
    A.Free;
  end;

  { Modify: add a file and remove one }
  SetLength(Inputs, 1); SetLength(DiskU, 1); SetLength(ArcU, 1);
  DiskU[0] := UTF8Encode(Src + '/a.txt'); ArcU[0] := UTF8Encode('added.txt');
  Inputs[0].DiskPath := PAnsiChar(DiskU[0]); Inputs[0].ArcPath := PAnsiChar(ArcU[0]); Inputs[0].IsDir := 0;
  S := Default(TCreateSettings); S.FormatName := '7z'; S.Level := -1; S.Solid := True;
  R := TzModify(A7, '', S, [], Inputs, Err);
  Check(R = 0, 'modify add: ' + Err);
  R := TzOpenArchive(A7, '', A, Err);
  Check((R = 0) and (A.Count = 5), 'add gave 5 entries');
  if R = 0 then
  begin
    SetLength(Ind, 1); Ind[0] := 0;
    R := TzModify(A7, '', S, Ind, [], Err);
    Check(R = 0, 'modify delete: ' + Err);
    A.Free;
  end;
  R := TzOpenArchive(A7, '', A, Err);
  Check((R = 0) and (A.Count = 4), 'delete gave 4 entries');
  if R = 0 then A.Free;

  { Zip update }
  AddFile('zipadd.txt', 'zulu' + LineEnding);
  DiskU[0] := UTF8Encode(Src + '/zipadd.txt'); ArcU[0] := UTF8Encode('zipadd.txt');
  Inputs[0].DiskPath := PAnsiChar(DiskU[0]); Inputs[0].ArcPath := PAnsiChar(ArcU[0]); Inputs[0].IsDir := 0;
  S := Default(TCreateSettings); S.FormatName := 'zip'; S.Level := -1; S.Password := 'zippw'; S.ZipAES256 := True;
  R := TzModify(AZ, 'zippw', S, [], Inputs, Err);
  Check(R = 0, 'modify zip add: ' + Err);
  R := TzOpenArchive(AZ, 'zippw', A, Err);
  Check((R = 0) and (A.Count = 5), 'zip add gave 5 entries');
  if R = 0 then A.Free;

  { Split volumes }
  DiskU[0] := UTF8Encode(Src + '/sub/c.bin'); ArcU[0] := UTF8Encode('c.bin');
  Inputs[0].DiskPath := PAnsiChar(DiskU[0]); Inputs[0].ArcPath := PAnsiChar(ArcU[0]); Inputs[0].IsDir := 0;
  S := Default(TCreateSettings); S.FormatName := '7z'; S.Level := 0; S.VolumeSize := 1024*1024;
  R := TzCreate(Root + '/vol.7z', S, Inputs, Err);
  Check(R = 0, 'create split 7z: ' + Err);
  Check(FileExists(Root + '/vol.7z.001'), 'split .001 exists');
  R := TzOpenArchive(Root + '/vol.7z.001', '', A, Err);
  Check(R = 0, 'open split 7z: ' + Err);
  if R = 0 then
  begin
    Check(A.Count = 1, 'split entry count');
    R := TzExtract(A, TzAllIndices(nil), Root + '/volout', '', Err);
    Check(R = 0, 'extract split: ' + Err);
    A.Free;
  end;

  { Nested archive: extract the inner archive as one file, then reopen it. }
  AddFile('inner.txt', 'nested' + LineEnding);
  SetLength(Inputs, 1); SetLength(DiskU, 1); SetLength(ArcU, 1);
  DiskU[0] := UTF8Encode(Src + '/inner.txt'); ArcU[0] := UTF8Encode('inner.txt');
  Inputs[0].DiskPath := PAnsiChar(DiskU[0]); Inputs[0].ArcPath := PAnsiChar(ArcU[0]); Inputs[0].IsDir := 0;
  S := Default(TCreateSettings); S.FormatName := '7z'; S.Level := 5;
  R := TzCreate(Root + '/inner.7z', S, Inputs, Err);
  Check(R = 0, 'create inner 7z: ' + Err);
  DiskU[0] := UTF8Encode(Root + '/inner.7z'); ArcU[0] := UTF8Encode('inner.7z');
  Inputs[0].DiskPath := PAnsiChar(DiskU[0]); Inputs[0].ArcPath := PAnsiChar(ArcU[0]); Inputs[0].IsDir := 0;
  R := TzCreate(Root + '/outer.7z', S, Inputs, Err);
  Check(R = 0, 'create outer 7z: ' + Err);
  R := TzOpenArchive(Root + '/outer.7z', '', A, Err);
  Check(R = 0, 'open outer 7z');
  if R = 0 then
  begin
    R := TzExtractOne(A, 0, Root + '/inner-extracted.7z', '', Err);
    Check(R = 0, 'extract inner: ' + Err);
    A.Free;
    R := TzOpenArchive(Root + '/inner-extracted.7z', '', A, Err);
    Check((R = 0) and (A.Count = 1), 'reopen inner');
    if R = 0 then A.Free;
  end;

  WriteLn('FAILS=', Fails);
  if Fails > 0 then Halt(1);
end.
