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
  Zip := Root + '/read-nocp.zip';
  Check(MakeZip(Zip, 'gbk') = TZ7Z_OK, 'read no codepage: fixture');
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

{ --- rewriting keeps the archive's name encoding ----------------------- }

function RawZipEntriesScript: string;
begin
  Result := Root + '/make-raw-zip-entries.py';
  if not FileExists(Result) then
    Shell('cat > "' + Result + '" <<''PY''' + LineEnding +
      'import struct, sys, zlib' + LineEnding +
      'path = sys.argv[1]' + LineEnding +
      'host = int(sys.argv[2])' + LineEnding +
      'pairs = sys.argv[3:]' + LineEnding +
      'data = b"payload"' + LineEnding +
      'crc = zlib.crc32(data) & 0xffffffff' + LineEnding +
      'made = (host << 8) | 20' + LineEnding +
      'body = b""' + LineEnding +
      'central = b""' + LineEnding +
      'offset = 0' + LineEnding +
      'for p in pairs:' + LineEnding +
      '    hx, fl = p.split(":")' + LineEnding +
      '    name = bytes.fromhex(hx)' + LineEnding +
      '    flags = int(fl)' + LineEnding +
      '    lfh = struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, flags, 0, 0, 0, crc, len(data), len(data), len(name), 0) + name' + LineEnding +
      '    cdh = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, made, 20, flags, 0, 0, 0, crc, len(data), len(data), len(name), 0, 0, 0, 0, 0, offset) + name' + LineEnding +
      '    body += lfh + data' + LineEnding +
      '    central += cdh' + LineEnding +
      '    offset += len(lfh) + len(data)' + LineEnding +
      'eocd = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, len(pairs), len(pairs), len(central), len(body), 0)' + LineEnding +
      'open(path, "wb").write(body + central + eocd)' + LineEnding +
      'PY');
end;

{ A multi-entry ZIP with exact name bytes/flags per entry. Each element of
  AEntries is "<namehex>:<flags>". }
function MakeRawZipEntries(const APath: string;
  const AEntries: array of string; AHostOS: Word): Boolean;
var
  Cmd: string;
  I: Integer;
begin
  DelTree(APath);
  Cmd := '/usr/bin/python3 ' + QuotedStr(RawZipEntriesScript) + ' ' +
    QuotedStr(APath) + ' ' + IntToStr(AHostOS);
  for I := 0 to High(AEntries) do
    Cmd := Cmd + ' ' + QuotedStr(AEntries[I]);
  Shell(Cmd);
  Result := FileExists(APath);
end;

function EntriesProbeScript: string;
begin
  Result := Root + '/probe-entries.py';
  if not FileExists(Result) then
    Shell('cat > "' + Result + '" <<''PY''' + LineEnding +
      'import struct, sys' + LineEnding +
      'd = open(sys.argv[1], "rb").read()' + LineEnding +
      'i = 0' + LineEnding +
      'while True:' + LineEnding +
      '    i = d.find(b"PK\x01\x02", i)' + LineEnding +
      '    if i < 0:' + LineEnding +
      '        break' + LineEnding +
      '    f = struct.unpack("<H", d[i+8:i+10])[0]' + LineEnding +
      '    n = struct.unpack("<H", d[i+28:i+30])[0]' + LineEnding +
      '    print("%d %s" % (f, d[i+46:i+46+n].hex()))' + LineEnding +
      '    i += 4' + LineEnding +
      'PY');
end;

{ One "<flag> <namehex>" line per central-directory entry, in archive order. }
function ProbeEntries(const AZip: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Text := Trim(Shell('/usr/bin/python3 ' +
    QuotedStr(EntriesProbeScript) + ' ' + QuotedStr(AZip)));
end;

function OpenContextAt(const AZip: string; ANameCodepage: LongWord;
  out ACtx: TArchiveContext; out AErr: string): Integer;
begin
  ACtx := nil;
  AErr := '';
  Result := TzOpenContext(AZip, ExtractFileName(AZip), '', nil, False, AZip,
    ACtx, AErr, nil, ANameCodepage);
end;

{ The settings an update starts from, before the archive's encoding is applied:
  keep each entry's method (-1) and write UTF-8 unless the detector says
  otherwise. }
function BaseModifySettings: TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := 'zip';
  Result.Level := -1;
  Result.ForceUtf8 := True;
end;

function OneInputMapped(const ADisk, AArc: string): TZInputSet;
var
  Disk, Arc: TStringList;
begin
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    Disk.Add(ADisk);
    Arc.Add(AArc);
    Result := TzCollectInputsMapped(Disk, Arc);
  finally
    Arc.Free;
    Disk.Free;
  end;
end;

function OneInput(const ADisk: string): TZInputSet;
var
  Source: TStringList;
begin
  Source := TStringList.Create;
  try
    Source.Add(ADisk);
    Result := TzCollectInputs(Source, '');
  finally
    Source.Free;
  end;
end;

procedure TestUpdateKeepsGbk;
var
  Zip, Err: string;
  Ctx: TArchiveContext;
  S: TCreateSettings;
  Set1: TZInputSet;
  Entries: TStringList;
  R: Integer;
begin
  Zip := Root + '/update-gbk.zip';
  Check(MakeZip(Zip, 'gbk') = TZ7Z_OK, 'update gbk: fixture');

  R := OpenContextAt(Zip, 936, Ctx, Err);
  Check(R = TZ7Z_OK, 'update gbk: opened (' + Err + ')');
  if R <> TZ7Z_OK then Exit;
  try
    S := BaseModifySettings;
    TzUpdateSettingsForContext(Ctx, S);
    Check(S.Codepage = 936, Format('update gbk: writes code page 936 (%d)', [S.Codepage]));
    Check(not S.ForceUtf8, 'update gbk: does not force utf8 names');
  finally
    Ctx.Free;
  end;

  { Adding a file must not re-encode the existing entry. }
  Shell('printf "x" > "' + Root + '/added.txt"');
  Set1 := OneInputMapped(Root + '/added.txt', '新增.txt');
  try
    Err := '';
    R := TzModify(Zip, '', S, [], Set1.Recs, Err);
    Check(R = TZ7Z_OK, Format('update gbk: add returned %d (%s)', [R, Err]));
  finally
    TzInputSetFree(Set1);
  end;
  Entries := ProbeEntries(Zip);
  try
    Check(Entries.Count = 2, Format('update gbk: two entries after add (%d)', [Entries.Count]));
    if Entries.Count = 2 then
    begin
      EqStr(Entries[0], '0 ' + PyEncodedHex(NAME, 'gbk'),
        'update gbk: the existing name bytes are unchanged');
      EqStr(Entries[1], '0 ' + PyEncodedHex('新增.txt', 'gbk'),
        'update gbk: the added chinese name is written in the code page');
    end;
  finally
    Entries.Free;
  end;

  { Deleting the other entry also leaves the surviving bytes alone. }
  R := OpenContextAt(Zip, 936, Ctx, Err);
  Check(R = TZ7Z_OK, 'update gbk: reopened for delete');
  if R <> TZ7Z_OK then Exit;
  try
    S := BaseModifySettings;
    TzUpdateSettingsForContext(Ctx, S);
  finally
    Ctx.Free;
  end;
  Err := '';
  R := TzModify(Zip, '', S, [LongWord(0)], [], Err);
  Check(R = TZ7Z_OK, Format('update gbk: delete returned %d (%s)', [R, Err]));
  Entries := ProbeEntries(Zip);
  try
    Check(Entries.Count = 1, Format('update gbk: one entry after delete (%d)', [Entries.Count]));
    if Entries.Count = 1 then
      EqStr(Entries[0], '0 ' + PyEncodedHex('新增.txt', 'gbk'),
        'update gbk: the remaining name bytes are unchanged');
  finally
    Entries.Free;
  end;
end;

procedure TestUpdateKeepsUtf8;
var
  Zip, Err: string;
  Ctx: TArchiveContext;
  S: TCreateSettings;
  Set1: TZInputSet;
  Entries: TStringList;
  R: Integer;
begin
  Zip := Root + '/update-utf8.zip';
  { A FAT host with a flagged UTF-8 name AND an ASCII name. The ASCII entry used
    to make detection answer "legacy" (an ASCII name decodes the same everywhere,
    so it carries no encoding), and the next edit then re-encoded the flagged
    Chinese name and dropped its flag. }
  Check(MakeRawZipEntries(Zip,
    [HexOf(UTF8Encode(NAME)) + ':' + IntToStr($800),
     HexOf(UTF8Encode('plain.txt')) + ':0'], 0),
    'update utf8: fixture written');
  R := OpenContextAt(Zip, 936, Ctx, Err);
  Check(R = TZ7Z_OK, 'update utf8: opened');
  if R <> TZ7Z_OK then Exit;
  try
    Check(TzArchiveNameEncoding(Ctx.Archive) = 0,
      'update utf8: detected as utf8; ascii names do not make it legacy');
    S := BaseModifySettings;
    TzUpdateSettingsForContext(Ctx, S);
    Check(S.Codepage = 65001, Format('update utf8: reads with 65001 (%d)', [S.Codepage]));
    Check(S.ForceUtf8, 'update utf8: keeps utf8 names');
  finally
    Ctx.Free;
  end;
  Shell('printf "x" > "' + Root + '/added2.txt"');
  Set1 := OneInputMapped(Root + '/added2.txt', '新增.txt');
  try
    Err := '';
    R := TzModify(Zip, '', S, [], Set1.Recs, Err);
    Check(R = TZ7Z_OK, Format('update utf8: add returned %d (%s)', [R, Err]));
  finally
    TzInputSetFree(Set1);
  end;
  Entries := ProbeEntries(Zip);
  try
    Check(Entries.Count = 3, Format('update utf8: three entries (%d)', [Entries.Count]));
    if Entries.Count = 3 then
    begin
      EqStr(Entries[0], IntToStr($800) + ' ' + HexOf(UTF8Encode(NAME)),
        'update utf8: the flagged name keeps its bytes and flag');
      EqStr(Entries[1], '0 ' + HexOf(UTF8Encode('plain.txt')),
        'update utf8: the ascii name keeps its bytes and flag');
      EqStr(Entries[2], IntToStr($800) + ' ' + HexOf(UTF8Encode('新增.txt')),
        'update utf8: the added chinese name is written as utf8');
    end;
  finally
    Entries.Free;
  end;
end;

procedure TestRenameFallsBack;
var
  Zip, Tmp, Err: string;
  Ctx: TArchiveContext;
  S: TCreateSettings;
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  Entries: TStringList;
  R: Integer;
begin
  Zip := Root + '/rename-gbk.zip';
  Check(MakeRawZipEntries(Zip,
    [PyEncodedHex(NAME, 'gbk') + ':0',
     PyEncodedHex('另一个.txt', 'gbk') + ':0'], 0),
    'rename: fixture written');
  Tmp := Root + '/rename-src.bin';
  R := OpenContextAt(Zip, 936, Ctx, Err);
  Check(R = TZ7Z_OK, 'rename: opened');
  if R <> TZ7Z_OK then Exit;
  try
    S := BaseModifySettings;
    TzUpdateSettingsForContext(Ctx, S);
    Check(TzExtractOne(Ctx.Archive, 0, Tmp, '', Err) = TZ7Z_OK,
      'rename: entry extracted (' + Err + ')');
  finally
    Ctx.Free;
  end;

  { The emoji cannot be written in GBK: that entry must fall back to UTF-8. }
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Disk.Add(Tmp);
    Arc.Add(EMOJI_NAME);
    Set1 := TzCollectInputsMapped(Disk, Arc);
    Err := '';
    R := TzModify(Zip, '', S, [LongWord(0)], Set1.Recs, Err);
    Check(R = TZ7Z_OK, Format('rename: modify returned %d (%s)', [R, Err]));
  finally
    TzInputSetFree(Set1);
    Disk.Free;
    Arc.Free;
  end;
  Entries := ProbeEntries(Zip);
  try
    Check(Entries.Count = 2, Format('rename: two entries, one was replaced (%d)', [Entries.Count]));
    if Entries.Count = 2 then
    begin
      { The untouched entry keeps its legacy bytes; only the new name falls back
        to UTF-8 because GBK cannot represent it. }
      EqStr(Entries[0], '0 ' + PyEncodedHex('另一个.txt', 'gbk'),
        'rename: the other entry stays in the code page');
      Check(Pos(IntToStr($800) + ' ', Entries[1]) = 1,
        'rename: an unrepresentable name falls back to utf8 (' + Entries[1] + ')');
      EqStr(Copy(Entries[1], 6, MaxInt), PyEncodedHex(EMOJI_NAME, 'utf-8'),
        'rename: the fallback name is the right utf8 name');
    end;
  finally
    Entries.Free;
  end;
end;

procedure TestMixed;
var
  Zip, Err: string;
  Ctx: TArchiveContext;
  S: TCreateSettings;
  Set1: TZInputSet;
  Entries: TStringList;
  R: Integer;
begin
  Zip := Root + '/mixed.zip';
  Check(MakeRawZipEntries(Zip,
    [HexOf(UTF8Encode(EMOJI_NAME)) + ':' + IntToStr($800),
     PyEncodedHex(NAME, 'gbk') + ':0'], 0), 'mixed: fixture written');
  R := OpenContextAt(Zip, 936, Ctx, Err);
  Check(R = TZ7Z_OK, 'mixed: opened (' + Err + ')');
  if R <> TZ7Z_OK then Exit;
  try
    { Mixed: the safe choice is the legacy code page for writing, with the
      per-entry UTF-8 fallback keeping the unrepresentable emoji name. }
    Check(TzArchiveNameEncoding(Ctx.Archive) = 936,
      'mixed: detection picks the legacy code page');
    S := BaseModifySettings;
    TzUpdateSettingsForContext(Ctx, S);
    Check(S.Codepage = 936, 'mixed: writes code page 936');
    Check(not S.ForceUtf8, 'mixed: does not force utf8 names');
  finally
    Ctx.Free;
  end;
  Shell('printf "x" > "' + Root + '/mixed-added.txt"');
  Set1 := OneInputMapped(Root + '/mixed-added.txt', '新增.txt');
  try
    Err := '';
    R := TzModify(Zip, '', S, [], Set1.Recs, Err);
    Check(R = TZ7Z_OK, Format('mixed: modify returned %d (%s)', [R, Err]));
  finally
    TzInputSetFree(Set1);
  end;
  Entries := ProbeEntries(Zip);
  try
    Check(Entries.Count = 3, Format('mixed: three entries (%d)', [Entries.Count]));
    if Entries.Count = 3 then
    begin
      EqStr(Entries[0], IntToStr($800) + ' ' + HexOf(UTF8Encode(EMOJI_NAME)),
        'mixed: the utf8 entry keeps its bytes and flag');
      EqStr(Entries[1], '0 ' + PyEncodedHex(NAME, 'gbk'),
        'mixed: the gbk entry keeps its bytes and flag');
      EqStr(Entries[2], '0 ' + PyEncodedHex('新增.txt', 'gbk'),
        'mixed: the added chinese name is written in the code page');
    end;
  finally
    Entries.Free;
  end;
end;

procedure TestConvertHonoursCodePage;
var
  Src, Dst, Err: string;
  S: TCreateSettings;
  Entries: TStringList;
  R: Integer;
begin
  Src := Root + '/convert-src.zip';
  Check(MakeZip(Src, 'utf8') = TZ7Z_OK, 'convert: source fixture');

  { The conversion dialog's own codepage choice must reach the writer instead of
    being overridden with "always UTF-8". }
  Dst := Root + '/convert-gbk.zip';
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := -1;
  S.Codepage := 936;
  S.ForceUtf8 := False;
  Err := '';
  R := TzConvertArchive(Src, Dst, S, Err);
  Check(R = TZ7Z_OK, Format('convert: gbk conversion returned %d (%s)', [R, Err]));
  Entries := ProbeEntries(Dst);
  try
    Check(Entries.Count = 1, 'convert: gbk target has one entry');
    if Entries.Count = 1 then
      EqStr(Entries[0], '0 ' + PyEncodedHex(NAME, 'gbk'),
        'convert: the target names are written in the chosen code page');
  finally
    Entries.Free;
  end;

  Dst := Root + '/convert-utf8.zip';
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := -1;
  S.Codepage := 65001;
  S.ForceUtf8 := True;
  Err := '';
  R := TzConvertArchive(Src, Dst, S, Err);
  Check(R = TZ7Z_OK, Format('convert: utf8 conversion returned %d (%s)', [R, Err]));
  Entries := ProbeEntries(Dst);
  try
    EqStr(Entries[0], IntToStr($800) + ' ' + HexOf(UTF8Encode(NAME)),
      'convert: an utf8 target keeps the flag');
  finally
    Entries.Free;
  end;
end;

{ One non-East-Asian code page end to end: write and read back. The iconv
  table must actually know it; an unknown code page falls back to bytes and the
  name comes back mojibake. }
procedure TestCyrillicCodePage;
var
  Zip, CyrName, Err, Name: string;
  S: TCreateSettings;
  Source: TStringList;
  Set1: TZInputSet;
  Entries: TStringList;
  R: Integer;
begin
  CyrName := 'Привет.txt';
  Shell('printf "x" > "' + Root + '/' + CyrName + '"');
  Zip := Root + '/write-cp1251.zip';
  Source := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Source.Add(Root + '/' + CyrName);
    Set1 := TzCollectInputs(Source, '');
    S := Default(TCreateSettings);
    S.FormatName := 'zip';
    S.Level := 5;
    S.Codepage := 1251;
    DelTree(Zip);
    Err := '';
    R := TzCreateArchive(Zip, S, Set1.Recs, Err);
    Check(R = TZ7Z_OK, Format('cp1251: created (%d %s)', [R, Err]));
  finally
    TzInputSetFree(Set1);
    Source.Free;
  end;

  Entries := ProbeEntries(Zip);
  try
    Check(Entries.Count = 1, 'cp1251: one entry');
    if Entries.Count = 1 then
      EqStr(Entries[0], '0 ' + PyEncodedHex(CyrName, 'cp1251'),
        'cp1251: the raw name bytes are windows-1251');
  finally
    Entries.Free;
  end;

  R := RawOpenName(Zip, 1251, Name);
  Check(R = TZ7Z_OK, 'cp1251: reopened');
  EqStr(Name, CyrName, 'cp1251: the name is read back through the code page');
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
  TestCyrillicCodePage;

  WriteLn('-- read decodes legacy names');
  TestReadGbk;
  TestUtf8NoFlag;
  TestFlaggedUnaffected;
  TestNoCodepage;
  TestEncryptedZip;

  WriteLn('-- rewriting keeps the name encoding');
  TestUpdateKeepsGbk;
  TestUpdateKeepsUtf8;
  TestRenameFallsBack;
  TestMixed;
  TestConvertHonoursCodePage;

  WriteLn('-- other formats keep CJK names');
  TestOtherFormatsCJK;

  DelTree(Root);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
