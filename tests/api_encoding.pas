program api_encoding;
{$mode objfpc}{$H+}
{$codepage utf8}
{ ZIP entry-name encoding.

  A ZIP stores non-ASCII names either as bytes in the local ANSI code page (no
  UTF-8 flag) or as UTF-8 (flag 0x0800). A Windows tool writes the ANSI form, a
  Linux tool writes the UTF-8 form, and each misreads the other -- which is what
  turned into mojibake for users in both directions.

  The fixtures carry raw name bytes on purpose: python writes and reads the
  exact bytes of the ZIP header, so the assertions are about what the engine
  really does, not about what one of our own tools happens to decode. }
uses
  SysUtils, Classes, Process, tzip.api, tzip.engine;

const
  NAME = '中文名称.txt';
  EMOJI_NAME = '😀名称.txt';

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

function HexOf(const S: RawByteString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    Result := Result + LowerCase(IntToHex(Ord(S[I]), 2));
end;

function HexToRaw(const AHex: string): RawByteString;
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, Length(AHex) div 2);
  for I := 1 to Length(Result) do
    Result[I] := AnsiChar(StrToIntDef('$' + Copy(AHex, (I - 1) * 2 + 1, 2), 0));
end;

{ The bytes python produces when it encodes AName in ACodec ('gbk', 'cp932',
  ...). The fixture header and the create path are both checked against this,
  so neither side can silently agree on the wrong bytes. }
function PyEncodedHex(const AName, ACodec: string): string;
var
  Script: string;
begin
  Script := 'import sys;print(sys.argv[1].encode(sys.argv[2]).hex())';
  Result := Trim(Shell('/usr/bin/python3 -c ' + QuotedStr(Script) + ' ' +
    QuotedStr(AName) + ' ' + QuotedStr(ACodec)));
end;

function RawZipScript: string;
begin
  Result := Root + '/make-raw-zip.py';
  if not FileExists(Result) then
    Shell('cat > "' + Result + '" <<''PY''' + LineEnding +
      'import struct, sys, zlib' + LineEnding +
      'path = sys.argv[1]' + LineEnding +
      'name = bytes.fromhex(sys.argv[2])' + LineEnding +
      'host = int(sys.argv[3])' + LineEnding +
      'flags = int(sys.argv[4])' + LineEnding +
      'data = b"payload"' + LineEnding +
      'crc = zlib.crc32(data) & 0xffffffff' + LineEnding +
      'made = (host << 8) | 20' + LineEnding +
      'lfh = struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, flags, 0, 0, 0, crc,' +
      ' len(data), len(data), len(name), 0) + name' + LineEnding +
      'cdh = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, made, 20, flags,' +
      ' 0, 0, 0, crc, len(data), len(data), len(name), 0, 0, 0, 0, 0, 0) + name' +
      LineEnding +
      'eocd = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 1, 1, len(cdh),' +
      ' len(lfh) + len(data), 0)' + LineEnding +
      'open(path, "wb").write(lfh + data + cdh + eocd)' + LineEnding +
      'PY');
end;

{ A one-entry ZIP whose raw name bytes, UTF-8 flag and made-by host are exactly
  what the test chooses. AHostOS: 0 = MS-DOS, 3 = Unix. }
function MakeRawZip(const APath: string; const ARawName: RawByteString;
  AHostOS: Word; AFlags: Word): Boolean;
begin
  DelTree(APath);
  Shell('/usr/bin/python3 ' + QuotedStr(RawZipScript) + ' ' +
    QuotedStr(APath) + ' ' + HexOf(ARawName) + ' ' +
    IntToStr(AHostOS) + ' ' + IntToStr(AFlags));
  Result := FileExists(APath);
end;

{ The UTF-8 flag and the raw name bytes of a ZIP's first entry. }
procedure ProbeZip(const AZip: string; out AFlags: LongInt; out AHex: string);
var
  Script, OutS: string;
  L: TStringList;
begin
  AFlags := -1;
  AHex := '';
  Script := 'import struct,sys;d=open(sys.argv[1],"rb").read();' +
    'i=d.find(b"PK\x03\x04");f=struct.unpack("<H",d[i+6:i+8])[0];' +
    'n=struct.unpack("<H",d[i+26:i+28])[0];' +
    'print("%d %s" % (f, d[i+30:i+30+n].hex()))';
  OutS := Trim(Shell('/usr/bin/python3 -c ' + QuotedStr(Script) + ' ' +
    QuotedStr(AZip)));
  L := TStringList.Create;
  try
    L.Delimiter := ' ';
    L.StrictDelimiter := True;
    L.DelimitedText := OutS;
    if L.Count >= 2 then
    begin
      AFlags := StrToIntDef(L[0], -1);
      AHex := L[1];
    end;
  finally
    L.Free;
  end;
end;

{ Create one ZIP with a CJK entry name through the public create path. }
function MakeZip(const AOut, ACodePage: string): Integer;
var
  Settings: TCreateSettings;
  Source: TStringList;
  Set1: TZInputSet;
  Err: string;
begin
  { The file is created by sh so its on-disk name is exactly the UTF-8 bytes. }
  Shell('printf "payload" > "' + Root + '/' + NAME + '"');
  Source := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Source.Add(Root + '/' + NAME);
    Set1 := TzCollectInputs(Source, '');
    Check(Length(Set1.Recs) = 1, 'source collected for ' + ACodePage);
    Settings := Default(TCreateSettings);
    Settings.FormatName := 'zip';
    Settings.Level := 5;
    if ACodePage = 'gbk' then Settings.Codepage := 936
    else if ACodePage = 'gb18030' then Settings.Codepage := 54936
    else if ACodePage = 'shiftjis' then Settings.Codepage := 932
    else if ACodePage = 'utf8' then
    begin
      Settings.Codepage := 65001;
      Settings.ForceUtf8 := True;
    end
    else Settings.Codepage := 0;
    DelTree(AOut);
    Err := '';
    Result := TzCreateArchive(AOut, Settings, Set1.Recs, Err);
    if Result <> TZ7Z_OK then
      WriteLn('   create error: ', Err);
  finally
    TzInputSetFree(Set1);
    Source.Free;
  end;
end;

{ The create side: the selected code page must reach the raw header bytes. }
procedure TestWriteCodePage(const AName, ACodec: string;
  AExpectUtf8Flag: Boolean);
var
  Zip: string;
  Flags: LongInt;
  Hex, Want: string;
  R: Integer;
begin
  Zip := Root + '/write-' + AName + '.zip';
  R := MakeZip(Zip, AName);
  Check(R = TZ7Z_OK, 'write ' + AName + ': created');
  if R <> TZ7Z_OK then Exit;

  ProbeZip(Zip, Flags, Hex);
  Check(Flags >= 0, 'write ' + AName + ': could probe the zip');
  Check((Flags and $800 <> 0) = AExpectUtf8Flag,
    Format('write %s: UTF-8 flag is %s (%d)',
      [AName, BoolToStr(AExpectUtf8Flag, True), Flags]));
  Want := PyEncodedHex(NAME, ACodec);
  Check(Hex = Want,
    Format('write %s: raw name bytes are %s, want %s', [AName, Hex, Want]));
  Check(Shell('/usr/bin/unzip -l "' + Zip + '" >/dev/null 2>&1; echo $?').Trim = '0',
    'write ' + AName + ': unzip accepts the file');
end;

{ Open a raw fixture and return the first entry name. }
function RawOpenName(const AZip: string; ANameCodepage: LongWord;
  out AName: string): Integer;
var
  A: TTzArchive;
  Err: string;
begin
  AName := '';
  A := nil;
  Err := '';
  Result := TzOpenArchive(AZip, '', A, Err, nil, ANameCodepage);
  if Result <> TZ7Z_OK then
  begin
    WriteLn('   raw open: ', Err);
    Exit;
  end;
  try
    if A.Count >= 1 then AName := A.EntryName(0);
  finally
    A.Free;
  end;
end;

procedure TestReadRaw(const AZip: string; ACodepage: LongWord;
  const AWant, AMsg: string);
var
  Name: string;
  R: Integer;
begin
  R := RawOpenName(AZip, ACodepage, Name);
  Check(R = TZ7Z_OK, AMsg + ': opened');
  if R = TZ7Z_OK then
    EqStr(Name, AWant, AMsg + ': name');
end;

procedure TestReadGbk;
var
  Zip, Dest, Listing: string;
  Flags: LongInt;
  Hex: string;
  R: Integer;
  A: TTzArchive;
  Err: string;
begin
  Zip := Root + '/read-gbk.zip';
  { The fixture header carries the same bytes the writer check expects. }
  Hex := PyEncodedHex(NAME, 'gbk');
  Check(MakeRawZip(Zip, HexToRaw(Hex), 0, 0), 'read gbk: fixture written');
  ProbeZip(Zip, Flags, Hex);
  EqStr(Hex, PyEncodedHex(NAME, 'gbk'),
    'read gbk: the fixture header carries gbk bytes');
  TestReadRaw(Zip, 936, NAME, 'read gbk: cp936');

  { Extraction must put the decoded name on disk. }
  A := nil;
  Err := '';
  Dest := Root + '/out-gbk';
  DelTree(Dest);
  R := TzOpenArchive(Zip, '', A, Err, nil, 936);
  if R = TZ7Z_OK then
  try
    R := TzExtract(A, [], Dest, '', Err);
    Check(R = TZ7Z_OK, 'read gbk: extracted (' + Err + ')');
  finally
    A.Free;
  end
  else
    Check(False, 'read gbk: reopen for extract');
  Listing := Trim(Shell('/bin/ls -1 "' + Dest + '"'));
  EqStr(Listing, NAME, 'read gbk: extracted file name');
end;

procedure TestUtf8NoFlag;
var
  Zip: string;
begin
  Zip := Root + '/read-utf8-noflag.zip';
  { Unix made-by (3) and no flag: mac/Linux tools write this. }
  Check(MakeRawZip(Zip, UTF8Encode(NAME), 3, 0),
    'read utf8 no flag: fixture written');
  TestReadRaw(Zip, 936, NAME, 'read utf8 no flag: cp936 still decodes utf8');
end;

procedure TestFlaggedUnaffected;
var
  Zip: string;
begin
  Zip := Root + '/read-flagged.zip';
  Check(MakeRawZip(Zip, UTF8Encode(EMOJI_NAME), 0, $800),
    'read flagged: fixture written');
  TestReadRaw(Zip, 936, EMOJI_NAME, 'read flagged: cp936 does not touch it');
  TestReadRaw(Zip, 0, EMOJI_NAME, 'read flagged: engine default does not touch it');
end;

procedure TestNoCodepage;
var
  Zip: string;
  Name: string;
  R: Integer;
begin
  Zip := Root + '/read-gbk.zip';
  R := RawOpenName(Zip, 0, Name);
  Check(R = TZ7Z_OK, 'read no codepage: opened');
  Check(Name <> '', 'read no codepage: the name is still non-empty');
end;

procedure TestEncryptedZip;
var
  Source: TStringList;
  Set1: TZInputSet;
  Settings: TCreateSettings;
  OutF, Err: string;
  R: Integer;
  A: TTzArchive;
begin
  Shell('printf "secret" > "' + Root + '/' + NAME + '"');
  OutF := Root + '/enc-pw.zip';
  DelTree(OutF);
  Source := TStringList.Create;
  Set1 := Default(TZInputSet);
  A := nil;
  try
    Source.Add(Root + '/' + NAME);
    Set1 := TzCollectInputs(Source, '');
    Settings := Default(TCreateSettings);
    Settings.FormatName := 'zip';
    Settings.Level := 5;
    Settings.Password := 'pw';
    Err := '';
    R := TzCreateArchive(OutF, Settings, Set1.Recs, Err);
    Check(R = TZ7Z_OK, 'encrypted: created (' + Err + ')');
    if R <> TZ7Z_OK then Exit;
    R := TzOpenArchive(OutF, 'pw', A, Err, nil, 936);
    Check(R = TZ7Z_OK, 'encrypted: opened with a password and cp936');
    if R = TZ7Z_OK then
      EqStr(A.EntryName(0), NAME, 'encrypted: name decoded');
  finally
    A.Free;
    TzInputSetFree(Set1);
    Source.Free;
  end;
end;

{ The non-ZIP formats store names in their own way; a CJK name must survive. }
procedure TestOtherFormatsCJK;
const
  Fmts: array[0..3] of string = ('7z', 'tar', 'zip', 'wim');
var
  Source: TStringList;
  Set1: TZInputSet;
  Settings: TCreateSettings;
  OutF, Dest, Err: string;
  R: Integer;
  A: TTzArchive;
  I: Integer;
  Found: Boolean;
begin
  for I := 0 to High(Fmts) do
  begin
    Shell('mkdir -p "' + Root + '/cjk' + Fmts[I] + '"');
    Shell('printf "v" > "' + Root + '/cjk' + Fmts[I] + '/中文名字.txt"');
    Source := TStringList.Create;
    Set1 := Default(TZInputSet);
    OutF := Root + '/cjk-' + Fmts[I] + '.' + Fmts[I];
    Dest := Root + '/cjkout-' + Fmts[I];
    A := nil;
    try
      Source.Add(Root + '/cjk' + Fmts[I]);
      Set1 := TzCollectInputs(Source, '');
      Settings := Default(TCreateSettings);
      Settings.FormatName := Fmts[I];
      Settings.Level := 5;
      DelTree(OutF);
      DelTree(Dest);
      Err := '';
      R := TzCreateArchive(OutF, Settings, Set1.Recs, Err);
      Check(R = TZ7Z_OK, Fmts[I] + ': CJK name created (' + Err + ')');
      if R <> TZ7Z_OK then Continue;

      { A codepage on a non-ZIP is "apply where relevant": it must not change
        the names these formats already store as Unicode/UTF-8. }
      R := TzOpenArchive(OutF, '', A, Err, nil, 936);
      Check(R = TZ7Z_OK, Fmts[I] + ': CJK archive reopened with cp936');
      if R <> TZ7Z_OK then Continue;
      try
        Found := False;
        for R := 0 to A.Count - 1 do
          if Pos('中文名字', A.EntryName(R)) > 0 then Found := True;
        Check(Found, Fmts[I] + ': CJK name preserved in the listing');
        R := TzExtract(A, [], Dest, '', Err);
        Check(R = TZ7Z_OK, Fmts[I] + ': CJK archive extracted (' + Err + ')');
      finally
        A.Free;
        A := nil;
      end;
      Check(Trim(Shell('/bin/cat "' + Dest + '/cjk' + Fmts[I] + '/中文名字.txt" 2>/dev/null')) = 'v',
        Fmts[I] + ': CJK file extracted under the right name');
    finally
      A.Free;
      TzInputSetFree(Set1);
      Source.Free;
    end;
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

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-enc-' +
    IntToStr(GetProcessID);
  DelTree(Root);
  ForceDirectories(Root);

  WriteLn('-- create writes the chosen code page');
  TestWriteCodePage('gbk', 'gbk', False);
  TestWriteCodePage('gb18030', 'gb18030', False);
  TestWriteCodePage('shiftjis', 'cp932', False);
  TestWriteCodePage('utf8', 'utf-8', True);

  WriteLn('-- read decodes legacy names');
  TestReadGbk;
  TestUtf8NoFlag;
  TestFlaggedUnaffected;
  TestNoCodepage;
  TestEncryptedZip;

  WriteLn('-- other formats keep CJK names');
  TestOtherFormatsCJK;

  DelTree(Root);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
