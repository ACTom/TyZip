program unit_model_api;
{$mode objfpc}{$H+}
{ tzip.api's two defensive edges that can be checked without a real archive:

  - the format table arrives as JSON from the bridge. A truncated or corrupt
    table used to raise EJSONParserException out of the startup path; it must
    come back as "no formats known" instead.
  - a file that is not an archive must be reported as NOT_ARCHIVE by its code.
    The old code also accepted any error message containing the word
    "password", which made every unreadable file look like it needed one. }
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

procedure TestFormatJSON;
var
  F: TFormatInfoArray;
begin
  F := TzParseFormatsJSON('[{"name":"7z","ext":"7z","addext":"","update":true},' +
    '{"name":"zip","ext":"zip z01","addext":"","update":false}]');
  EqInt(Length(F), 2, 'formats: two rows');
  if Length(F) = 2 then
  begin
    EqStr(F[0].Name, '7z', 'formats: name');
    EqStr(F[0].Ext, '7z', 'formats: extension');
    Check(F[0].CanUpdate, 'formats: update flag');
    EqStr(F[1].Ext, 'zip z01', 'formats: extension list');
    Check(not F[1].CanUpdate, 'formats: update flag false');
  end;

  { A truncated table is exactly what an interrupted write or an older library
    produces. It must parse to nothing, not raise. }
  F := TzParseFormatsJSON('[{"name":"7z","ext":"7z"');
  EqInt(Length(F), 0, 'formats: truncated JSON is empty');
  F := TzParseFormatsJSON('');
  EqInt(Length(F), 0, 'formats: empty string is empty');
  F := TzParseFormatsJSON('{"name":"7z"}');
  EqInt(Length(F), 0, 'formats: a non-array is empty');
  { Rows that are not objects are skipped rather than trusted. }
  F := TzParseFormatsJSON('[1,"x",{"name":"zip","ext":"zip","addext":"","update":true}]');
  EqInt(Length(F), 3, 'formats: row count is kept');
  if Length(F) = 3 then
  begin
    EqStr(F[0].Name, '', 'formats: a number row is skipped');
    EqStr(F[2].Name, 'zip', 'formats: the object row is kept');
  end;
end;

procedure TestOpenClassification;
var
  A: TTzArchive;
  Err: string;
  R: Integer;
  M: TMemoryStream;
  Buf: array[0..127] of Byte;
  I: Integer;
  L: TStringList;
begin
  { A truncated ZIP: it starts like an archive and then stops. No handler can
    read it, and it is definitely not a password problem. (A plain text file is
    a bad fixture here: 7-Zip's Base64 handler happily opens prose as one entry.) }
  for I := 0 to High(Buf) do
    Buf[I] := Byte((I * 37) and $FF);
  M := TMemoryStream.Create;
  try
    M.WriteBuffer(Buf, SizeOf(Buf));
    M.SaveToFile(Root + '/junk.bin');
  finally
    M.Free;
  end;
  A := nil;
  R := TzOpenArchive(Root + '/junk.bin', '', A, Err);
  EqInt(R, TZ7Z_E_NOT_ARCHIVE, 'open: a corrupt file is not an archive');
  Check(A = nil, 'open: no archive handle for a non-archive');
  Check(Err <> '', 'open: a reason is given');

  { Whatever a text file is detected as, it must never be reported as a missing
    or wrong password: the UI would ask for one that cannot exist. }
  L := TStringList.Create;
  try
    L.Text := 'this is not an archive at all' + LineEnding;
    L.SaveToFile(Root + '/junk.txt');
  finally
    L.Free;
  end;
  A := nil;
  R := TzOpenArchive(Root + '/junk.txt', '', A, Err);
  Check(R <> TZ7Z_E_PASSWORD, 'open: a text file is not a password problem');
  A.Free;

  { A missing file must not be dressed up as a password problem either. }
  A := nil;
  R := TzOpenArchive(Root + '/does-not-exist.7z', '', A, Err);
  Check(R <> TZ7Z_E_PASSWORD, 'open: a missing file is not a password problem');
  Check(A = nil, 'open: no archive handle for a missing file');
end;

{ The other half of the classification: a 7z whose header is encrypted cannot
  be read at all without the right password, and that must arrive as
  TZ7Z_E_PASSWORD -- the api layer no longer reads the message text to guess. }
procedure TestWrongPasswordClassification;
var
  S: TCreateSettings;
  Set1: TZInputSet;
  L: TStringList;
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := 'top secret' + LineEnding;
    L.SaveToFile(Root + '/secret.txt');
    L.Clear;
    L.Add(Root + '/secret.txt');
    S := Default(TCreateSettings);
    S.FormatName := '7z';
    S.Level := 5;
    S.Password := 'right-password';
    S.EncryptNames := True;
    Set1 := TzCollectInputs(L, '');
    try
      R := TzCreateArchive(Root + '/enc.7z', S, Set1.Recs, Err);
    finally
      TzInputSetFree(Set1);
    end;
    Check(R = TZ7Z_OK, 'wrong password: setup (' + Err + ')');
  finally
    L.Free;
  end;

  A := nil;
  R := TzOpenArchive(Root + '/enc.7z', 'wrong-password', A, Err);
  EqInt(R, TZ7Z_E_PASSWORD, 'wrong password: reported as a password problem');
  Check(A = nil, 'wrong password: no archive handle');

  A := nil;
  R := TzOpenArchive(Root + '/enc.7z', 'right-password', A, Err);
  Check(R = TZ7Z_OK, 'wrong password: the right password still opens (' + Err + ')');
  A.Free;
end;

procedure TestFormatByName;
var
  F: TFormatInfo;
begin
  { The cached table is the same one TzLoadFormats returns. }
  Check(Length(TzLoadFormats) > 0, 'formats: the bridge reports at least one');
  F := TzFormatByName('7z');
  EqStr(F.Name, '7z', 'by name: 7z is known');
  F := TzFormatByName('definitely-not-a-format');
  EqStr(F.Name, '', 'by name: an unknown name is empty');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-api-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  TestFormatJSON;
  TestOpenClassification;
  TestWrongPasswordClassification;
  TestFormatByName;

  DeleteFile(Root + '/junk.txt');
  DeleteFile(Root + '/junk.bin');
  DeleteFile(Root + '/secret.txt');
  DeleteFile(Root + '/enc.7z');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
