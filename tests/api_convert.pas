program api_convert;
{$mode objfpc}{$H+}
{$codepage utf8}
{ Converting an archive to another format: extract to a temp tree, pack again.

  Checked against real archives, including a CJK name and a nested folder, and
  the promise that a failed conversion leaves no half-written file behind. }
uses
  SysUtils, Classes, Process, tzip.api, tzip.engine;

var
  Fails, Passes, Skips: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

{ A case the environment could not run at all: neither a pass (which would hide
  the gap) nor a failure (the code under test never ran). }
procedure Skip(const AMsg: string);
begin
  Inc(Skips);
  WriteLn('SKIP ', AMsg);
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
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

function NamesOf(const APath: string): string;
var
  A: TTzArchive;
  Err: string;
  I: Integer;
begin
  Result := '';
  A := nil;
  if TzOpenArchive(APath, '', A, Err) <> TZ7Z_OK then Exit('<' + Err + '>');
  try
    for I := 0 to A.Count - 1 do Result := Result + A.EntryName(I) + ';';
  finally A.Free; end;
end;

function MakeZip(const AName: string): string;
var
  L: TStringList;
begin
  Result := Root + '/' + AName;
  DeleteFile(Result);
  ForceDirectories(Root + '/src/sub');
  L := TStringList.Create;
  try
    L.Add('one');
    L.SaveToFile(Root + '/src/a.txt');
    L.Add('two');
    L.SaveToFile(Root + '/src/sub/中文.txt');
  finally L.Free; end;
  { The archive is written by a Python SCRIPT FILE, not by python3 -c: a CJK
    name passed as a command-line argument is re-encoded by the system before
    Python ever sees it, which would make the fixture mangled and the test would
    then be checking the wrong thing. }
  L := TStringList.Create;
  try
    L.Add('import zipfile, sys, os, codecs');
    L.Add('os.chdir(sys.argv[2])');
    L.Add('z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED)');
    L.Add('z.writestr("a.txt", "one")');
    L.Add('z.writestr("sub/" + "' + '中文' + '" + ".txt", "two")');
    L.Add('z.close()');
    L.SaveToFile(Root + '/mksrc.py');
  finally L.Free; end;
  Run('/usr/bin/python3', [Root + '/mksrc.py', Result, Root + '/src']);
end;

function ConvertSettings(const AFmt: string): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFmt;
  Result.Level := 5;
  Result.ForceUtf8 := True;
end;

procedure TestConvert;
var
  Src, Dst, Err: string;
  R: Integer;
begin
  Src := MakeZip('in.zip');
  Dst := Root + '/out.7z';
  DeleteFile(Dst);
  R := TzConvertArchive(Src, Dst, ConvertSettings('7z'), Err);
  Check(R = TZ7Z_OK, Format('convert zip->7z returned %d (%s)', [R, Err]));
  Check(FileExists(Dst), 'convert: the target exists');
  { The source must still be there: a conversion copies, it does not move. }
  Check(FileExists(Src), 'convert: the source is untouched');

  { Folder rows carry a trailing slash; the engine reports them that way and the
    listing relies on it to recognise a directory. }
  { The source is asserted too, so a failure here says whether the conversion
    broke the name or the fixture did. }
  Check(Pos('sub/中文.txt', NamesOf(Src)) > 0,
    'convert: the source has the CJK name (' + NamesOf(Src) + ')');
  EqStr(NamesOf(Dst), 'a.txt;sub/中文.txt;', 'convert: entries survived');
end;

procedure TestConvertToZip;
var
  Src, Dst, Err: string;
  R: Integer;
begin
  { 7z source, zip target: the other direction. }
  Src := Root + '/in2.7z';
  DeleteFile(Src);
  ForceDirectories(Root + '/src2');
  Run('/bin/sh', ['-c', 'echo hi > ' + Root + '/src2/one.txt']);
  if Run('/usr/bin/env', ['7z', 'a', '-t7z', Src, Root + '/src2/one.txt',
    '-bso0', '-bsp0']) <> 0 then
  begin
    Skip('convert: no 7z on PATH');
    Exit;
  end;
  Dst := Root + '/out2.zip';
  DeleteFile(Dst);
  R := TzConvertArchive(Src, Dst, ConvertSettings('zip'), Err);
  Check(R = TZ7Z_OK, Format('convert 7z->zip returned %d (%s)', [R, Err]));
  Check(Pos('one.txt', NamesOf(Dst)) > 0, 'convert: the entry survived both ways');
end;

procedure TestMissingSource;
var
  Err: string;
  R: Integer;
begin
  R := TzConvertArchive(Root + '/nope.zip', Root + '/x.7z',
    ConvertSettings('7z'), Err);
  Check(R <> TZ7Z_OK, 'missing: a missing source fails');
  Check(Err <> '', 'missing: a reason is given');
  Check(not FileExists(Root + '/x.7z'), 'missing: no output was written');
end;

procedure TestBadSource;
var
  Err: string;
  R: Integer;
  L: TStringList;
  Dst: string;
begin
  { A file that is not an archive must fail without leaving a file where the
    user pointed. }
  L := TStringList.Create;
  try
    L.Add('this is not an archive');
    L.SaveToFile(Root + '/junk.zip');
  finally L.Free; end;
  Dst := Root + '/junk-out.7z';
  DeleteFile(Dst);
  R := TzConvertArchive(Root + '/junk.zip', Dst, ConvertSettings('7z'), Err);
  Check(R <> TZ7Z_OK, 'bad: a non-archive fails');
  Check(not FileExists(Dst), 'bad: no output was written');
end;

procedure TestOverwriteTarget;
var
  Src, Dst, Err: string;
  R: Integer;
  L: TStringList;
begin
  { An archive already at the target is replaced, and the temp name used during
    the write does not survive. }
  Src := MakeZip('in3.zip');
  Dst := Root + '/out3.7z';
  L := TStringList.Create;
  try
    L.Add('old contents');
    L.SaveToFile(Dst);
  finally L.Free; end;
  R := TzConvertArchive(Src, Dst, ConvertSettings('7z'), Err);
  Check(R = TZ7Z_OK, Format('overwrite returned %d (%s)', [R, Err]));
  Check(Pos('a.txt', NamesOf(Dst)) > 0, 'overwrite: the target is the new archive');
  Check(not FileExists(Dst + '.tyzip-convert'), 'overwrite: no temp file is left');
end;

begin
  Fails := 0; Passes := 0; Skips := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-convert-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  TestConvert;
  TestConvertToZip;
  TestMissingSource;
  TestBadSource;
  TestOverwriteTarget;
  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d, SKIPPED %d', [Passes, Fails, Skips]));
  if Fails <> 0 then Halt(1);
end.
