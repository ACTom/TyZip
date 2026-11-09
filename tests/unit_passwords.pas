program unit_passwords;
{$mode objfpc}{$H+}
{ Remembered archive passwords.

  The rules worth pinning: the key is the file name so an archive keeps its
  password after being moved; an empty password forgets rather than saving a
  blank one; and a store that raises must not stop the user. }
uses
  SysUtils, Classes, tzip.passwords;

var
  Fails, Passes: Integer;

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

type
  { A store that always raises, to prove the wrappers do not propagate. }
  TBrokenStore = class(TPasswordStore)
  public
    function GetPassword(const AKey: string): string; override;
    procedure PutPassword(const AKey, APassword: string); override;
    procedure RemovePassword(const AKey: string); override;
    procedure ListKeys(ANames: TStrings); override;
  end;

function TBrokenStore.GetPassword(const AKey: string): string;
begin
  raise Exception.Create('no keychain');
end;

procedure TBrokenStore.PutPassword(const AKey, APassword: string);
begin
  raise Exception.Create('no keychain');
end;

procedure TBrokenStore.RemovePassword(const AKey: string);
begin
  raise Exception.Create('no keychain');
end;

procedure TBrokenStore.ListKeys(ANames: TStrings);
begin
  raise Exception.Create('no keychain');
end;

procedure TestKey;
begin
  EqStr(PasswordKey('/a/b/photos.zip'), 'photos.zip', 'key: file name only');
  EqStr(PasswordKey('/other/place/photos.zip'), 'photos.zip', 'key: path does not matter');
  EqStr(PasswordKey('/a/PHOTOS.ZIP'), 'photos.zip', 'key: lowercased');
  EqStr(PasswordKey(''), '', 'key: empty');
  EqStr(PasswordKey('/a/b/'), '', 'key: directory only');
end;

procedure TestMemoryStore;
var
  S: TMemoryPasswordStore;
  N: TStringList;
begin
  S := TMemoryPasswordStore.Create;
  try
    EqStr(S.GetPassword('x.zip'), '', 'store: nothing remembered yet');
    S.PutPassword('x.zip', 'secret');
    EqStr(S.GetPassword('x.zip'), 'secret', 'store: remembered');
    { Case-insensitive, matching PasswordKey's normalisation. }
    EqStr(S.GetPassword('X.ZIP'), 'secret', 'store: lookup ignores case');
    S.PutPassword('x.zip', 'newer');
    EqStr(S.GetPassword('x.zip'), 'newer', 'store: replaced');
    S.RemovePassword('x.zip');
    EqStr(S.GetPassword('x.zip'), '', 'store: removed');
    N := TStringList.Create;
    try
      S.ListKeys(N);
      Check(N.Count = 0, 'store: empty after removal');
    finally N.Free; end;
  finally S.Free; end;
end;

procedure TestWrappers;
var
  S: TMemoryPasswordStore;
  B: TBrokenStore;
begin
  S := TMemoryPasswordStore.Create;
  try
    RememberPassword(S, '/a/secret.7z', 'pw1');
    EqStr(RememberedPassword(S, '/a/secret.7z'), 'pw1', 'wrap: remembered');
    { Moving the archive keeps the password: same file name, different path. }
    EqStr(RememberedPassword(S, '/elsewhere/secret.7z'), 'pw1', 'wrap: survives a move');

    { An empty password removes the entry instead of storing a blank. }
    RememberPassword(S, '/a/secret.7z', '');
    EqStr(RememberedPassword(S, '/a/secret.7z'), '', 'wrap: empty forgets');

    RememberPassword(S, '/a/secret.7z', 'pw2');
    ForgetPassword(S, '/a/secret.7z');
    EqStr(RememberedPassword(S, '/a/secret.7z'), '', 'wrap: forget works');
    { Forgetting twice is not an error. }
    ForgetPassword(S, '/a/secret.7z');
    Check(True, 'wrap: forget is idempotent');
  finally S.Free; end;

  { A store that raises must not take the caller down with it. }
  B := TBrokenStore.Create;
  try
    EqStr(RememberedPassword(B, '/a/x.zip'), '', 'broken: get returns empty');
    RememberPassword(B, '/a/x.zip', 'pw');
    Check(True, 'broken: remember does not raise');
    ForgetPassword(B, '/a/x.zip');
    Check(True, 'broken: forget does not raise');
  finally B.Free; end;

  { A nil store is simply "nothing remembered", not a crash. }
  EqStr(RememberedPassword(nil, '/a/x.zip'), '', 'nil: returns empty');
  RememberPassword(nil, '/a/x.zip', 'pw');
  ForgetPassword(nil, '/a/x.zip');
  Check(True, 'nil: calls are no-ops');
end;

begin
  Fails := 0; Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  TestKey;
  TestMemoryStore;
  TestWrappers;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
