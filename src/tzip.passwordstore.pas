{ Remembered passwords, kept in the macOS keychain.

  The shell tool is used rather than the Security framework directly: it is the
  same store, it needs no C bindings, and its exit status tells us plainly
  whether the call worked. A keychain that is locked or that the user refuses
  simply makes these calls fail, which tzip.passwords already treats as "nothing
  remembered".

  Every entry is filed under our own service name so the keychain UI shows the
  user what put it there, and so uninstalling means deleting one service.

  A password never appears in the tool's argument list: "security" prompts for
  it and reads the prompt from its standard input, where this unit writes the
  password. Arguments are visible to every other user of the machine through
  the process table. }
unit tzip.passwordstore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, tzip.passwords;

const
  { Shown in Keychain Access next to each entry. }
  KeychainService = 'TyZip Archive Password';

  { The tool Apple ships for keychain access. A test can point a store at a stub
    instead, which is how the argument and stdin contract is checked. }
  SecurityToolPath = '/usr/bin/security';

  { A keychain that is locked or waiting for a system dialog must not freeze the
    application: a call that has not finished by then counts as failed and the
    user types the password, as when nothing is remembered. }
  KeychainTimeoutMs = 10000;

type
  TKeychainPasswordStore = class(TPasswordStore)
  private
    FExecutable: string;
    FTimeoutMs: Cardinal;
    { AStdin is written to the tool's standard input before it is allowed to
      finish; '' writes nothing. }
    function Run(const AArgs: array of string; const AStdin: RawByteString;
      out AOut: string): Boolean;
    function AccountFor(const AKey: string): string;
  public
    constructor Create(const AExecutable: string = SecurityToolPath;
      ATimeoutMs: Cardinal = KeychainTimeoutMs);
    function GetPassword(const AKey: string): string; override;
    procedure PutPassword(const AKey, APassword: string); override;
    procedure RemovePassword(const AKey: string); override;
    procedure ListKeys(ANames: TStrings); override;
  end;

{ The store the app uses. Never nil: when the keychain cannot be reached the
  entries simply come back empty, and the user types the password as before. }
function TzPasswordStore: TPasswordStore;

implementation

var
  GStore: TPasswordStore = nil;

function TKeychainPasswordStore.AccountFor(const AKey: string): string;
begin
  Result := AKey;
end;

constructor TKeychainPasswordStore.Create(const AExecutable: string;
  ATimeoutMs: Cardinal);
begin
  inherited Create;
  FExecutable := AExecutable;
  FTimeoutMs := ATimeoutMs;
end;

function TKeychainPasswordStore.Run(const AArgs: array of string;
  const AStdin: RawByteString; out AOut: string): Boolean;
var
  P: TProcess;
  L: TStringList;
  Data: TMemoryStream;
  I: Integer;
begin
  Result := False;
  AOut := '';
  L := TStringList.Create;
  Data := TMemoryStream.Create;
  P := TProcess.Create(nil);
  try
    P.Executable := FExecutable;
    for I := 0 to High(AArgs) do P.Parameters.Add(AArgs[I]);
    P.Options := [poUsePipes, poStderrToOutPut];
    try
      P.Execute;
    except
      Exit;
    end;
    { The password for "add" arrives here, on standard input, so it never shows
      up in the process list where any other user of the machine could read it. }
    if AStdin <> '' then P.Input.WriteBuffer(AStdin[1], Length(AStdin));
    P.CloseInput;
    { A locked keychain can wait on the user for an unbounded time; the timeout
      turns that into "nothing remembered" instead of a frozen window. }
    if not P.WaitOnExit(FTimeoutMs) then
    begin
      P.Terminate(1);
      Exit;
    end;
    Data.CopyFrom(P.Output, 0);
    Data.Position := 0;
    L.LoadFromStream(Data);
    AOut := L.Text;
    Result := P.ExitStatus = 0;
  finally
    P.Free;
    Data.Free;
    L.Free;
  end;
end;

function TKeychainPasswordStore.GetPassword(const AKey: string): string;
var
  Out_: string;
begin
  Result := '';
  if AKey = '' then Exit;
  if Run(['find-generic-password', '-s', KeychainService, '-a', AccountFor(AKey),
    '-w'], '', Out_) then
    Result := Trim(Out_);
end;

procedure TKeychainPasswordStore.PutPassword(const AKey, APassword: string);
var
  Ignored: string;
begin
  if (AKey = '') or (APassword = '') then Exit;
  { "-U" replaces an existing entry in place instead of failing on it, which
    keeps the entry's own metadata and avoids a duplicate for the same archive.
    "-w" must be the LAST argument: with no value after it the tool prompts, and
    the prompt reads the password from the standard input written by Run. } 
  Run(['add-generic-password', '-U', '-s', KeychainService,
    '-a', AccountFor(AKey), '-T', SecurityToolPath, '-w'],
    RawByteString(APassword) + RawByteString(LineEnding), Ignored);
end;

procedure TKeychainPasswordStore.RemovePassword(const AKey: string);
var
  Ignored: string;
begin
  if AKey = '' then Exit;
  Run(['delete-generic-password', '-s', KeychainService,
    '-a', AccountFor(AKey)], '', Ignored);
end;

procedure TKeychainPasswordStore.ListKeys(ANames: TStrings);
var
  Out_, Line, Acct: string;
  Lines: TStringList;
  I, P: Integer;
begin
  if ANames = nil then Exit;
  if not Run(['dump-keychain'], '', Out_) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Out_;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      { Each entry's attributes print as:  "acct"<blob>="photos.zip" }
      if Pos('"acct"', Line) = 0 then Continue;
      P := Pos('="', Line);
      if P = 0 then Continue;
      Acct := Copy(Line, P + 2, Length(Line));
      if (Acct <> '') and (Acct[Length(Acct)] = '"') then
        Delete(Acct, Length(Acct), 1);
      { Only ours: another service's entries are none of our business. }
      if Pos(KeychainService, Lines[I]) > 0 then
        ANames.Add(Acct);
    end;
  finally
    Lines.Free;
  end;
end;

function TzPasswordStore: TPasswordStore;
begin
  if GStore = nil then GStore := TKeychainPasswordStore.Create;
  Result := GStore;
end;

end.
