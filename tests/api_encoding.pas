program api_encoding;
{$mode objfpc}{$H+}
{ ZIP entry-name encoding.

  This is the Windows/Linux interop problem in one file. A ZIP stores non-ASCII
  names either as bytes in the local ANSI code page (no UTF-8 flag) or as UTF-8
  (flag 0x0800 set). A Windows tool writes the ANSI form, a Linux tool writes the
  UTF-8 form, and each misreads the other -- which is what turned into mojibake
  for users in both directions.

  Covered here: every code page the dialog offers, the UTF-8 flag that results,
  reading the archive back, and the non-ZIP formats whose names must survive a
  round trip regardless. }
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
  if P <> '' then Shell('/bin/rm -rf "' + P + '"');
end;

function MakeUTF8File(const APath, AContent: string): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  FS := nil;
  try
    ForceDirectories(ExtractFileDir(APath));
    FS := TFileStream.Create(APath, fmCreate);
    if AContent <> '' then FS.WriteBuffer(AContent[1], Length(AContent));
    Result := True;
  except
    Result := False;
  end;
  FS.Free;
end;

{ Create one ZIP holding a single CJK-named entry, with the given code page. }
function MakeZip(const AOut, ACodepage: string): Integer;
var
  Settings: TCreateSettings;
  Source: TStringList;
  Set1: TZInputSet;
  Err: string;
begin
  { The file is created by sh so its on-disk name is exactly the UTF-8 bytes. }
  Shell('printf "payload" > "' + Root + '/中文名称.txt"');
  Source := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Source.Add(Root + '/中文名称.txt');
    Set1 := TzCollectInputs(Source, '');
    Check(Length(Set1.Recs) = 1, 'source collected for ' + ACodepage);
    Settings := Default(TCreateSettings);
    Settings.FormatName := 'zip';
    Settings.Level := 5;
    if ACodepage = 'gbk' then Settings.Codepage := 936
    else if ACodepage = 'gb18030' then Settings.Codepage := 54936
    else if ACodepage = 'shiftjis' then Settings.Codepage := 932
    else if ACodepage = 'utf8' then
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

{ Read the UTF-8 flag of the first local file header directly from the bytes.
  python's zipfile is used because it exposes the flag and the raw name without
  guessing. }
{ Read the UTF-8 flag, or the entry name, straight out of the ZIP with python3:
  it exposes the raw flag bits without guessing an encoding. }
function ZipProbe(const AZip, AWhat: string): string;
var
  Script, Cmd: string;
begin
  if AWhat = 'flag' then
    Script := 'import zipfile,sys;print(zipfile.ZipFile(sys.argv[1]).infolist()[0].flag_bits)'
  else
    Script := 'import zipfile,sys;print(zipfile.ZipFile(sys.argv[1]).infolist()[0].filename)';
  Cmd := '/usr/bin/python3 -c ' + QuotedStr(Script) + ' ' + QuotedStr(AZip) + ' 2>/dev/null';
  Result := Trim(Shell(Cmd));
end;

procedure TestCodePage(const AName: string; AExpectUtf8Flag: Boolean);
var
  Zip, Flag, Name: string;
  R: Integer;
  A: TTzArchive;
  Err: string;
begin
  Zip := Root + '/enc-' + AName + '.zip';
  R := MakeZip(Zip, AName);
  Check(R = TZ7Z_OK, 'encoding ' + AName + ': created');

  Flag := ZipProbe(Zip, 'flag');
  if Flag = '' then
  begin
    Check(False, 'encoding ' + AName + ': could not read the ZIP flag');
    Exit;
  end;
  { Bit 0x0800 is "name is UTF-8". }
  Check((StrToIntDef(Flag, 0) and $800 <> 0) = AExpectUtf8Flag,
    Format('encoding %s: UTF-8 flag is %s (flag bits %s)',
      [AName, BoolToStr(AExpectUtf8Flag, True), Flag]));

  { Our own reader must show a usable name whatever encoding was chosen. }
  A := nil;
  Err := '';
  R := TzOpenArchive(Zip, '', A, Err);
  Check(R = TZ7Z_OK, 'encoding ' + AName + ': reopened');
  if R = TZ7Z_OK then
  try
    Check(A.Count >= 1, 'encoding ' + AName + ': has an entry');
    if A.Count >= 1 then
    begin
      Name := A.EntryName(0);
      Check(Name <> '', 'encoding ' + AName + ': entry has a name');
      Check(Pos(#$FFFD, Name) = 0,
        'encoding ' + AName + ': name has no replacement characters');
    end;
  finally
    A.Free;
  end;
  { The ZIP must still be a valid archive for independent tools. }
  Check(Shell('/usr/bin/unzip -l "' + Zip + '" >/dev/null 2>&1; echo $?').Trim = '0',
    'encoding ' + AName + ': unzip accepts the file');
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

      A := nil;
      R := TzOpenArchive(OutF, '', A, Err);
      Check(R = TZ7Z_OK, Fmts[I] + ': CJK archive reopened');
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
      end;
      Check(Trim(Shell('/bin/cat "' + Dest + '/cjk' + Fmts[I] + '/中文名字.txt" 2>/dev/null')) = 'v',
        Fmts[I] + ': CJK file extracted under the right name');
    finally
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

  WriteLn('-- ZIP code pages');
  { With no code page requested the engine writes UTF-8 and sets the flag, which
    is what modern tools produce and what the dialog calls "Auto (UTF-8)". }
  TestCodePage('auto', True);
  TestCodePage('gbk', False);
  TestCodePage('gb18030', False);
  TestCodePage('shiftjis', False);
  TestCodePage('utf8', True);

  WriteLn('-- other formats keep CJK names');
  TestOtherFormatsCJK;

  DelTree(Root);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
