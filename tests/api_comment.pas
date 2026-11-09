program api_comment;
{$mode objfpc}{$H+}
{$codepage utf8}
{ Archive-level comments through the bridge.

  ZIP stores one; formats that cannot are expected to answer with an empty
  string rather than an error, so the UI never has to special-case them. }
uses
  SysUtils, Classes, Process, tzip.api;

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
  finally
    P.Free;
  end;
end;

procedure TestReadComment;
var
  Z, Comment: string;
  A: TTzArchive;
  Err: string;
  L: TStringList;
begin
  Z := Root + '/with-comment.zip';
  L := TStringList.Create;
  try
    L.Add('x');
    L.SaveToFile(Root + '/a.txt');
  finally L.Free; end;
  Run('/usr/bin/zip', ['-j', '-q', Z, Root + '/a.txt']);
  Check(FileExists(Z), 'setup: the zip exists');

  { The comment is written by a Python one-liner, but the text goes through a
    FILE: passing non-ASCII as a command-line argument lets the system re-encode
    it, and the test then checks a "????" it produced itself rather than the code
    under test. }
  L := TStringList.Create;
  try
    L.Add('这是注释');
    L.SaveToFile(Root + '/comment.txt');
  finally L.Free; end;
  Run('/usr/bin/python3', ['-c',
    'import zipfile,sys;' +
    'z=zipfile.ZipFile(sys.argv[1],"a");' +
    'z.comment=open(sys.argv[2],encoding="utf-8").read().strip().encode("utf-8");' +
    'z.close()', Z, Root + '/comment.txt']);

  A := nil;
  Check(TzOpenArchive(Z, '', A, Err) = TZ7Z_OK, 'open: ' + Err);
  if A <> nil then
  try
    Comment := A.Comment;
    EqStr(Comment, '这是注释', 'read: the comment comes back verbatim');
  finally
    A.Free;
  end;
end;

procedure TestNoComment;
var
  Z, Comment: string;
  A: TTzArchive;
  Err: string;
  L: TStringList;
begin
  Z := Root + '/plain.zip';
  L := TStringList.Create;
  try
    L.Add('y');
    L.SaveToFile(Root + '/b.txt');
  finally L.Free; end;
  Run('/usr/bin/zip', ['-j', '-q', Z, Root + '/b.txt']);

  A := nil;
  Check(TzOpenArchive(Z, '', A, Err) = TZ7Z_OK, 'open plain: ' + Err);
  if A <> nil then
  try
    Comment := A.Comment;
    EqStr(Comment, '', 'read: an archive without a comment answers empty');
  finally
    A.Free;
  end;
end;

{ Write a comment through the modify path and read it back. }
procedure TestWriteComment;
var
  Z, Err: string;
  A: TTzArchive;
  L: TStringList;
  S: TCreateSettings;
  R: Integer;
begin
  Z := Root + '/write.zip';
  DeleteFile(Z);
  L := TStringList.Create;
  try
    L.Add('w');
    L.SaveToFile(Root + '/w.txt');
  finally L.Free; end;
  Run('/usr/bin/zip', ['-j', '-q', Z, Root + '/w.txt']);

  A := nil;
  Check(TzOpenArchive(Z, '', A, Err) = TZ7Z_OK, 'write: opened');
  if A = nil then Exit;
  A.Free;

  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 5;
  S.ForceUtf8 := True;
  R := TzModify(Z, '', S, [], [], Err, nil, '新写入的注释', True);
  Check(R = TZ7Z_OK, Format('write: modify returned %d (%s)', [R, Err]));

  A := nil;
  if TzOpenArchive(Z, '', A, Err) = TZ7Z_OK then
  try
    EqStr(A.Comment, '新写入的注释', 'write: the comment round-trips');
  finally
    A.Free;
  end;

  { An empty comment clears it, and has_comment=false leaves it alone. }
  R := TzModify(Z, '', S, [], [], Err, nil, '', True);
  Check(R = TZ7Z_OK, 'write: clearing returned OK');
  A := nil;
  if TzOpenArchive(Z, '', A, Err) = TZ7Z_OK then
  try
    EqStr(A.Comment, '', 'write: an empty comment clears the stored one');
  finally
    A.Free;
  end;
end;

procedure TestSevenZip;
var
  Z, Comment: string;
  A: TTzArchive;
  Err: string;
  L: TStringList;
begin
  { 7z has an archive-level comment property too; opening one must not fail just
    because the format differs. }
  Z := Root + '/plain.7z';
  L := TStringList.Create;
  try
    L.Add('z');
    L.SaveToFile(Root + '/c.txt');
  finally L.Free; end;
  Run('/usr/bin/env', ['7z', 'a', '-t7z', Z, Root + '/c.txt', '-bso0', '-bsp0']);

  if not FileExists(Z) then
  begin
    Skip('7z: no 7z on PATH');
    Exit;
  end;
  A := nil;
  Check(TzOpenArchive(Z, '', A, Err) = TZ7Z_OK, 'open 7z: ' + Err);
  if A <> nil then
  try
    Comment := A.Comment;
    EqStr(Comment, '', 'read: a 7z without a comment answers empty');
  finally
    A.Free;
  end;
end;

begin
  Fails := 0; Passes := 0; Skips := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-comment-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;
  TestReadComment;
  TestNoComment;
  TestWriteComment;
  TestSevenZip;
  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d, SKIPPED %d', [Passes, Fails, Skips]));
  if Fails <> 0 then Halt(1);
end.
