program unit_model_passwordstore;
{$mode objfpc}{$H+}
{ The keychain password store's contract with the "security" tool.

  The important half cannot be seen through the store's own API: a password must
  never travel in the tool's argument list, where the process table shows it to
  every user, and it must arrive on standard input instead. A stub "security"
  script captures exactly what the real tool would receive.

  The store also has to give up on a keychain call that hangs, or a locked
  keychain freezes the whole application. }
uses
  SysUtils, Classes, BaseUnix, tzip.passwords, tzip.passwordstore;

var
  Fails, Passes: Integer;
  Root, StubRecord, StubPrint, StubHang: string;
  ArgvPath, StdinPath: string;

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

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

{ Writes a shell script and makes it executable. }
procedure WriteScript(const APath, ABody: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := ABody;
    L.SaveToFile(APath);
  finally
    L.Free;
  end;
  if fpChmod(PChar(APath), &755) <> 0 then
    WriteLn('warning: cannot chmod ', APath);
end;

function ScriptBody(const APrint: Boolean): string;
begin
  { One argument per line, so the capture shows exactly what the tool would see. }
  Result := '#!/bin/sh' + LineEnding +
    'printf ' + QuotedStr('%s\n') + ' "$@" > ' + QuotedStr(ArgvPath) + LineEnding +
    'cat > ' + QuotedStr(StdinPath) + LineEnding;
  if APrint then
    Result := Result + 'printf ' + QuotedStr('pw from the keychain\n') + LineEnding;
  Result := Result + 'exit 0' + LineEnding;
end;

procedure ResetCapture;
begin
  DeleteFile(ArgvPath);
  DeleteFile(StdinPath);
end;

function ReadText(const APath: string): string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(APath);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function ArgvLines: TStringList;
begin
  Result := TStringList.Create;
  if FileExists(ArgvPath) then Result.LoadFromFile(ArgvPath);
end;

{ --- what the tool receives ---------------------------------------------- }

procedure TestPutPasswordUsesStdin;
var
  Store: TKeychainPasswordStore;
  Args: TStringList;
  I: Integer;
  Captured: string;
  PasswordInArgv: Boolean;
begin
  ResetCapture;
  Store := TKeychainPasswordStore.Create(StubRecord);
  try
    Store.PutPassword('photos.zip', 's3cret pass');
  finally
    Store.Free;
  end;
  Args := ArgvLines;
  try
    EqInt(Args.Count, 9, 'put: argument count');
    if Args.Count >= 1 then EqStr(Args[0], 'add-generic-password', 'put: command');
    if Args.Count >= 2 then EqStr(Args[1], '-U', 'put: update in place');
    if Args.Count >= 3 then EqStr(Args[2], '-s', 'put: service flag');
    if Args.Count >= 4 then EqStr(Args[3], KeychainService, 'put: service name');
    if Args.Count >= 5 then EqStr(Args[4], '-a', 'put: account flag');
    if Args.Count >= 6 then EqStr(Args[5], 'photos.zip', 'put: account');
    { -w must be last so the tool prompts instead of taking the next argument. }
    if Args.Count >= 9 then
    begin
      EqStr(Args[6], '-T', 'put: trusted app flag');
      EqStr(Args[7], SecurityToolPath, 'put: trusted app path');
      EqStr(Args[8], '-w', 'put: -w is the last argument');
    end;
    PasswordInArgv := False;
    for I := 0 to Args.Count - 1 do
      if Pos('s3cret', Args[I]) > 0 then PasswordInArgv := True;
    Check(not PasswordInArgv, 'put: the password is not in any argument');
  finally
    Args.Free;
  end;
  Captured := ReadText(StdinPath);
  EqStr(Captured, 's3cret pass' + LineEnding, 'put: the password arrives on stdin');
end;

procedure TestGetPassword;
var
  Store: TKeychainPasswordStore;
  Args: TStringList;
begin
  ResetCapture;
  Store := TKeychainPasswordStore.Create(StubPrint);
  try
    EqStr(Store.GetPassword('photos.zip'), 'pw from the keychain',
      'get: the stored password comes back');
  finally
    Store.Free;
  end;
  Args := ArgvLines;
  try
    EqInt(Args.Count, 6, 'get: argument count');
    if Args.Count >= 1 then EqStr(Args[0], 'find-generic-password', 'get: command');
    if Args.Count >= 6 then EqStr(Args[5], '-w', 'get: -w last');
  finally
    Args.Free;
  end;
  EqStr(ReadText(StdinPath), '', 'get: nothing is written to the tool');
end;

procedure TestRemovePassword;
var
  Store: TKeychainPasswordStore;
  Args: TStringList;
begin
  ResetCapture;
  Store := TKeychainPasswordStore.Create(StubRecord);
  try
    Store.RemovePassword('photos.zip');
  finally
    Store.Free;
  end;
  Args := ArgvLines;
  try
    EqInt(Args.Count, 5, 'remove: argument count');
    if Args.Count >= 1 then EqStr(Args[0], 'delete-generic-password', 'remove: command');
    if Args.Count >= 5 then EqStr(Args[4], 'photos.zip', 'remove: account');
  finally
    Args.Free;
  end;
  EqStr(ReadText(StdinPath), '', 'remove: nothing is written to the tool');
end;

procedure TestNothingToDo;
var
  Store: TKeychainPasswordStore;
begin
  ResetCapture;
  Store := TKeychainPasswordStore.Create(StubRecord);
  try
    Store.PutPassword('', 'password');
    Store.PutPassword('photos.zip', '');
    Store.RemovePassword('');
    EqStr(Store.GetPassword(''), '', 'empty: no lookup for an empty key');
  finally
    Store.Free;
  end;
  Check(not FileExists(ArgvPath), 'empty: the tool is not run at all');
end;

procedure TestHangingKeychainTimesOut;
var
  Store: TKeychainPasswordStore;
  Started: QWord;
begin
  Store := TKeychainPasswordStore.Create(StubHang, 200);
  try
    Started := GetTickCount64;
    EqStr(Store.GetPassword('photos.zip'), '',
      'timeout: a hanging keychain answers "nothing remembered"');
    Check(GetTickCount64 - Started < 4000,
      'timeout: the call gives up instead of waiting for the tool');
  finally
    Store.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-pwstore-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  ArgvPath := Root + '/argv.txt';
  StdinPath := Root + '/stdin.txt';
  StubRecord := Root + '/security-record';
  StubPrint := Root + '/security-print';
  StubHang := Root + '/security-hang';
  WriteScript(StubRecord, ScriptBody(False));
  WriteScript(StubPrint, ScriptBody(True));
  WriteScript(StubHang, '#!/bin/sh' + LineEnding + 'exec sleep 5' + LineEnding);

  TestPutPasswordUsesStdin;
  TestGetPassword;
  TestRemovePassword;
  TestNothingToDo;
  TestHangingKeychainTimesOut;

  DeleteFile(ArgvPath);
  DeleteFile(StdinPath);
  DeleteFile(StubRecord);
  DeleteFile(StubPrint);
  DeleteFile(StubHang);
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
