program unit_model_errors;
{$mode objfpc}{$H+}
{ The bridge's error codes and what they MEAN.

  The codes are ABI (their numbers are checked here); the class is the policy a
  caller switches on -- "ask for a password", "the file is not an archive" --
  without matching English words. The text is only a fallback for callers that
  cannot translate. }
uses
  SysUtils, tzip.api, tzip.api.errors;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
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

procedure TestCodeValues;
begin
  { These numbers cross the C ABI; changing one silently would break every
    caller that stored an error code. }
  EqInt(TZ7Z_OK, 0, 'codes: OK');
  EqInt(TZ7Z_E_ARG, -1, 'codes: argument');
  EqInt(TZ7Z_E_MEMORY, -2, 'codes: memory');
  EqInt(TZ7Z_E_OPEN, -3, 'codes: open');
  EqInt(TZ7Z_E_NOT_ARCHIVE, -4, 'codes: not an archive');
  EqInt(TZ7Z_E_PASSWORD, -5, 'codes: password');
  EqInt(TZ7Z_E_FORMAT, -6, 'codes: format');
  EqInt(TZ7Z_E_UPDATE, -7, 'codes: update');
  EqInt(TZ7Z_E_EXTRACT, -8, 'codes: extract');
  EqInt(TZ7Z_E_CANCEL, -9, 'codes: cancel');
  EqInt(TZ7Z_E_IO, -10, 'codes: io');
  EqInt(TZ7Z_E_UNSUPPORTED, -11, 'codes: unsupported');
  { ABI v3 added tz7z_extract_one_prefix, v4 the progress sink, v5
    tz7z_set_name_codepage, v6 tz7z_entry_name_is_legacy; the struct layouts
    stayed at v2. }
  EqInt(TZ7Z_ABI_VERSION, 6, 'abi: revision the loader requires');
end;

procedure TestClassification;
begin
  Check(TzErrorClassOf(TZ7Z_OK) = ecOk, 'class: OK');
  Check(TzErrorClassOf(TZ7Z_E_ARG) = ecArgument, 'class: argument');
  Check(TzErrorClassOf(TZ7Z_E_MEMORY) = ecMemory, 'class: memory');
  Check(TzErrorClassOf(TZ7Z_E_OPEN) = ecOpen, 'class: open');
  Check(TzErrorClassOf(TZ7Z_E_NOT_ARCHIVE) = ecNotArchive, 'class: not archive');
  Check(TzErrorClassOf(TZ7Z_E_PASSWORD) = ecPassword, 'class: password');
  Check(TzErrorClassOf(TZ7Z_E_FORMAT) = ecFormat, 'class: format');
  Check(TzErrorClassOf(TZ7Z_E_UPDATE) = ecUpdate, 'class: update');
  Check(TzErrorClassOf(TZ7Z_E_EXTRACT) = ecExtract, 'class: extract');
  Check(TzErrorClassOf(TZ7Z_E_CANCEL) = ecCancel, 'class: cancel');
  Check(TzErrorClassOf(TZ7Z_E_IO) = ecIO, 'class: io');
  Check(TzErrorClassOf(TZ7Z_E_UNSUPPORTED) = ecUnsupported, 'class: unsupported');
  { A code from a newer library must not be mistaken for something it is not. }
  Check(TzErrorClassOf(-99) = ecUnknown, 'class: unknown code');
  Check(TzErrorClassOf(1) = ecUnknown, 'class: positive unknown');
end;

procedure TestFallbackText;
var
  Code: Integer;
begin
  { Wording is translated, so the test never looks for English: every known
    code has SOME text, the categories read differently, an unknown code keeps
    its number, and the category text agrees with the code text. }
  for Code := TZ7Z_E_UNSUPPORTED to TZ7Z_OK do
    Check(TzErrorText(Code) <> '', Format('text: code %d has text', [Code]));
  Check(TzErrorText(TZ7Z_E_PASSWORD) <> TzErrorText(TZ7Z_OK),
    'text: different codes read differently');
  Check(TzErrorText(TZ7Z_E_NOT_ARCHIVE) <> TzErrorText(TZ7Z_E_PASSWORD),
    'text: distinct codes get distinct text');
  Check(Pos('-99', TzErrorText(-99)) > 0,
    'text: an unknown code reports its number');
  for Code := TZ7Z_E_UNSUPPORTED to TZ7Z_OK do
    Check(TzErrorClassText(TzErrorClassOf(Code)) = TzErrorText(Code),
      Format('text: class and code agree for %d', [Code]));
end;

{ The UI may only turn an extraction failure into a password retry where the
  error can actually mean a wrong password. 7z reports a wrong password on a
  data-encrypted entry as a data error, so the one case is: encrypted entry, a
  password was supplied, E_EXTRACT, and this request has not already spent its
  one automatic retry (ticket 34). }
procedure TestExtractRetryDecision;
begin
  Check(TzShouldRetryPasswordAfterExtractError(TZ7Z_E_EXTRACT, True, True, False),
    'retry decision: encrypted entry + supplied password can retry');
  Check(not TzShouldRetryPasswordAfterExtractError(TZ7Z_E_EXTRACT, True, True, True),
    'retry decision: only one automatic retry');
  Check(not TzShouldRetryPasswordAfterExtractError(TZ7Z_E_EXTRACT, True, False, False),
    'retry decision: no password is the E_PASSWORD path, not this one');
  Check(not TzShouldRetryPasswordAfterExtractError(TZ7Z_E_EXTRACT, False, True, False),
    'retry decision: a plaintext entry data error is corruption');
  Check(not TzShouldRetryPasswordAfterExtractError(TZ7Z_E_PASSWORD, True, True, False),
    'retry decision: E_PASSWORD already has its own retry');
  Check(not TzShouldRetryPasswordAfterExtractError(TZ7Z_E_IO, True, True, False),
    'retry decision: an IO failure is not a password problem');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  TestCodeValues;
  TestClassification;
  TestFallbackText;
  TestExtractRetryDecision;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
