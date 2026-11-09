program unit_model_encrypted;
{$mode objfpc}{$H+}
{ Encryption negatives: a password-protected archive must REFUSE to hand over
  its contents without the password and with a wrong one.

  The existing encryption tests prove the positive half (with the right password
  the data comes back). They only glanced at the negative half, so a regression
  that let zip AES or ZipCrypto extraction "succeed" with an empty password would
  have gone unnoticed. Each case here is create -> open -> extract with the
  wrong/no password, with a positive control so a test that fails everything
  cannot pass by accident. }
uses
  SysUtils, Classes, tzip.api, tzip.engine;

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

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally
    L.Free;
  end;
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
    Result := Trim(L.Text);
  finally
    L.Free;
  end;
end;

function MakeEncrypted(const APath, AFmt: string; AEncryptNames, AZipAES256: Boolean): Boolean;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
  R: Integer;
begin
  Result := False;
  DeleteFile(APath);
  WriteText(Root + '/payload.txt', 'secret payload' + LineEnding);
  L := TStringList.Create;
  Set1.Disk := nil;
  Set1.Arc := nil;
  try
    L.Add(Root + '/payload.txt');
    S := Default(TCreateSettings);
    S.FormatName := AFmt;
    S.Level := 5;
    S.Password := 'right-password';
    S.EncryptNames := AEncryptNames;
    S.ZipAES256 := AZipAES256;
    Set1 := TzCollectInputs(L, '');
    try
      R := TzCreateArchive(APath, S, Set1.Recs, Err);
    finally
      TzInputSetFree(Set1);
    end;
    Check(R = TZ7Z_OK, 'setup: ' + AFmt + ' archive created (' + Err + ')');
    Result := R = TZ7Z_OK;
  finally
    L.Free;
  end;
end;

function ExtractTo(const APath, APassword, ADest: string;
  out AError: string): Integer;
var
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  AError := '';
  A := nil;
  Result := TzOpenArchive(APath, '', A, Err);
  if Result <> TZ7Z_OK then
  begin
    AError := Err;
    Exit;
  end;
  try
    ForceDirectories(ADest);
    Result := TzExtract(A, [], ADest, APassword, Err);
    AError := Err;
  finally
    A.Free;
  end;
end;

{ The positive control: the same archive does open with the right password. }
procedure PositiveControl(const APath, ADest, ALabel: string);
var
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  A := nil;
  R := TzOpenArchive(APath, 'right-password', A, Err);
  Check(R = TZ7Z_OK, ALabel + ': the right password opens (' + Err + ')');
  if A = nil then Exit;
  try
    R := TzExtract(A, [], ADest, 'right-password', Err);
    Check(R = TZ7Z_OK, ALabel + ': the right password extracts (' + Err + ')');
    EqStr(ReadText(ADest + '/payload.txt'), 'secret payload',
      ALabel + ': the payload is readable with the right password');
  finally
    A.Free;
  end;
end;

{ 7z with an encrypted header: opening is what needs the password. }
procedure TestEncryptedHeader(const APath: string);
var
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  A := nil;
  R := TzOpenArchive(APath, '', A, Err);
  EqInt(R, TZ7Z_E_PASSWORD, '7z header: opening without a password is refused');
  Check(A = nil, '7z header: no handle without the password');
  A := nil;
  R := TzOpenArchive(APath, 'wrong-password', A, Err);
  EqInt(R, TZ7Z_E_PASSWORD, '7z header: opening with a wrong password is refused');
  A.Free;
  PositiveControl(APath, Root + '/dest-head-right', '7z header');
end;

procedure NegativeCases(const APath, ALabel: string);
var
  Dest, Err: string;
  R: Integer;
begin
  { No password at all: extraction must fail and must say the password is the
    problem, which is what makes the UI ask for one. }
  Dest := Root + '/dest-' + ALabel + '-none';
  R := ExtractTo(APath, '', Dest, Err);
  Check(R <> TZ7Z_OK, ALabel + ': no password cannot extract (' + Err + ')');
  EqInt(R, TZ7Z_E_PASSWORD, ALabel + ': no password reports a password problem');

  { Wrong password: still refused, and never with the plaintext. }
  Dest := Root + '/dest-' + ALabel + '-wrong';
  R := ExtractTo(APath, 'wrong-password', Dest, Err);
  Check(R <> TZ7Z_OK, ALabel + ': a wrong password cannot extract (' + Err + ')');
  Check((R = TZ7Z_E_PASSWORD) or (R = TZ7Z_E_EXTRACT),
    Format('%s: a wrong password is a password/data error, got %d', [ALabel, R]));
  Check(Pos('secret payload', ReadText(Dest + '/payload.txt')) = 0,
    ALabel + ': no plaintext is left behind by a failed extraction');

  { The positive control: a test where everything fails would otherwise pass. }
  PositiveControl(APath, Root + '/dest-' + ALabel + '-right', ALabel);
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-enc-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  { ZIP: the header is readable, so opening without a password succeeds; the
    data is what is protected. Both ZIP encryption flavours are checked. }
  if MakeEncrypted(Root + '/aes.zip', 'zip', False, True) then
    NegativeCases(Root + '/aes.zip', 'aes-zip');
  if MakeEncrypted(Root + '/zc.zip', 'zip', False, False) then
    NegativeCases(Root + '/zc.zip', 'zipcrypto-zip');

  { 7z with a readable header: same shape as the ZIP cases. }
  if MakeEncrypted(Root + '/data.7z', '7z', False, False) then
    NegativeCases(Root + '/data.7z', '7z-data');

  { 7z with an ENCRYPTED header: even opening needs the password. }
  if MakeEncrypted(Root + '/head.7z', '7z', True, False) then
    TestEncryptedHeader(Root + '/head.7z');

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
