{ Remembered archive passwords.

  Up to the macOS keychain: this unit only decides WHICH password belongs to an
  archive and keeps them in order. Keychain storage is injected as a callback so
  this file stays free of platform calls and can be tested.

  The list is keyed by the archive's file name, not its full path: the same
  archive is opened from Finder, from a shell and after being moved, and a
  password remembered for one of those should work for all of them. The cost is
  that two different archives with the same name and the same password share an
  entry, which is the same tradeoff every password manager makes. }
unit tzip.passwords;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Where a remembered password is actually stored. The caller supplies one; the
    app uses the keychain, a test uses a string list. }
  TPasswordStore = class
  public
    { Nil when nothing is remembered for this key. }
    function GetPassword(const AKey: string): string; virtual; abstract;
    procedure PutPassword(const AKey, APassword: string); virtual; abstract;
    procedure RemovePassword(const AKey: string); virtual; abstract;
    { The keys currently held, in whatever order the store reports. }
    procedure ListKeys(ANames: TStrings); virtual; abstract;
  end;

  { In-memory store. Used by tests, and by the app when the platform keychain is
    unavailable so a session still works without ever touching disk. }
  TMemoryPasswordStore = class(TPasswordStore)
  private
    FKeys: TStringList;
    { Parallel to FKeys: the password for the key at the same index. }
    FValues: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function GetPassword(const AKey: string): string; override;
    procedure PutPassword(const AKey, APassword: string); override;
    procedure RemovePassword(const AKey: string); override;
    procedure ListKeys(ANames: TStrings); override;
  end;

{ The key a password is filed under: the archive's file name, lowercased, so a
  case-insensitive filesystem does not produce two entries for one archive. }
function PasswordKey(const AArchivePath: string): string;

{ The password to try when nothing is typed: the one remembered for this
  archive, or ''. }
function RememberedPassword(AStore: TPasswordStore;
  const AArchivePath: string): string;

{ Store APassword for the archive. An empty password removes the entry rather
  than saving a blank one. }
procedure RememberPassword(AStore: TPasswordStore;
  const AArchivePath, APassword: string);

{ Remove the entry. Safe when there is none. }
procedure ForgetPassword(AStore: TPasswordStore; const AArchivePath: string);

implementation

constructor TMemoryPasswordStore.Create;
begin
  inherited Create;
  FKeys := TStringList.Create;
  FKeys.CaseSensitive := False;
  FKeys.Sorted := True;
  { Sorted with no duplicates keeps IndexOf a binary search. The password is
    kept in a second list at the same index rather than after an '=', so a
    password containing '=' survives the trip. }
  FKeys.Duplicates := dupIgnore;
  FValues := TStringList.Create;
end;

destructor TMemoryPasswordStore.Destroy;
begin
  FValues.Free;
  FKeys.Free;
  inherited Destroy;
end;

function TMemoryPasswordStore.GetPassword(const AKey: string): string;
var
  I: Integer;
begin
  Result := '';
  if AKey = '' then Exit;
  I := FKeys.IndexOf(AKey);
  if (I >= 0) and (I < FValues.Count) then Result := FValues[I];
end;

procedure TMemoryPasswordStore.PutPassword(const AKey, APassword: string);
var
  I: Integer;
begin
  if AKey = '' then Exit;
  I := FKeys.IndexOf(AKey);
  if I >= 0 then
  begin
    FValues[I] := APassword;
    Exit;
  end;
  FKeys.Add(AKey);
  { A sorted Add may insert rather than append, so the index is looked up again
    and the value list is grown to the same length before the write. }
  I := FKeys.IndexOf(AKey);
  while FValues.Count < FKeys.Count do FValues.Add('');
  if I >= 0 then FValues[I] := APassword;
end;

procedure TMemoryPasswordStore.RemovePassword(const AKey: string);
var
  I: Integer;
begin
  if AKey = '' then Exit;
  I := FKeys.IndexOf(AKey);
  if I >= 0 then
  begin
    FKeys.Delete(I);
    if I < FValues.Count then FValues.Delete(I);
  end;
end;

procedure TMemoryPasswordStore.ListKeys(ANames: TStrings);
var
  I: Integer;
begin
  if ANames = nil then Exit;
  for I := 0 to FKeys.Count - 1 do
    ANames.Add(FKeys[I]);
end;

function PasswordKey(const AArchivePath: string): string;
begin
  Result := LowerCase(ExtractFileName(AArchivePath));
end;

function RememberedPassword(AStore: TPasswordStore;
  const AArchivePath: string): string;
var
  K: string;
begin
  Result := '';
  if AStore = nil then Exit;
  K := PasswordKey(AArchivePath);
  if K = '' then Exit;
  try
    Result := AStore.GetPassword(K);
  except
    { A keychain that refuses to answer must not stop the user opening their
      archive: they can still type the password. }
    Result := '';
  end;
end;

procedure RememberPassword(AStore: TPasswordStore;
  const AArchivePath, APassword: string);
var
  K: string;
begin
  if AStore = nil then Exit;
  K := PasswordKey(AArchivePath);
  if K = '' then Exit;
  try
    if APassword = '' then
      AStore.RemovePassword(K)
    else
      AStore.PutPassword(K, APassword);
  except
    { Losing a remember request is not worth an error dialog. }
  end;
end;

procedure ForgetPassword(AStore: TPasswordStore; const AArchivePath: string);
var
  K: string;
begin
  if AStore = nil then Exit;
  K := PasswordKey(AArchivePath);
  if K = '' then Exit;
  try
    AStore.RemovePassword(K);
  except
  end;
end;

end.
