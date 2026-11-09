unit tzip.api.errors;
{ What the bridge's error codes mean, and the wording a caller can show.

  The numbers are ABI (tests pin them): the bridge returns a small stable set,
  and this unit owns the policy on top -- is this a password problem? a bad
  argument? -- plus the translated text. The text comes from tzip.i18n so the
  model layer stays free of LCL resources; a caller that can show a better
  message switches on TZErrorClass instead. }

{$mode objfpc}{$H+}

interface

const
  TZ7Z_OK              =  0;
  TZ7Z_E_ARG           = -1;
  TZ7Z_E_MEMORY        = -2;
  TZ7Z_E_OPEN          = -3;
  TZ7Z_E_NOT_ARCHIVE   = -4;
  TZ7Z_E_PASSWORD      = -5;
  TZ7Z_E_FORMAT        = -6;
  TZ7Z_E_UPDATE        = -7;
  TZ7Z_E_EXTRACT       = -8;
  TZ7Z_E_CANCEL        = -9;
  TZ7Z_E_IO            = -10;
  TZ7Z_E_UNSUPPORTED   = -11;

type
  { What a code means to a caller that must choose a user-facing reaction. }
  TZErrorClass = (
    ecOk,
    ecArgument,
    ecMemory,
    ecOpen,
    ecNotArchive,
    ecPassword,
    ecFormat,
    ecUpdate,
    ecExtract,
    ecCancel,
    ecIO,
    ecUnsupported,
    ecUnknown
  );

function TzErrorClassOf(ACode: Integer): TZErrorClass;

{ The translated wording for a category. Use this when the caller only has the
  classification; a caller with the raw code uses TzErrorText, which reports an
  unknown code's number. }
function TzErrorClassText(AClass: TZErrorClass): string;

{ The translated wording for a raw code. Unknown codes keep their number. }
function TzErrorText(ACode: Integer): string;

{ Should the UI ask for the password again after an extraction failed with
  AResult? A data-encrypted 7z reports a wrong password as a data error, not as
  TZ7Z_E_PASSWORD (7-Zip cannot tell it apart from corrupt ciphertext), so a
  data error on an ENCRYPTED entry for which the caller already supplied a
  password is the one case where retrying the password is the right reaction.
  AAlreadyRetried bounds it to one automatic retry: a genuinely damaged archive
  would otherwise ask for a password forever. }
function TzShouldRetryPasswordAfterExtractError(AResult: Integer;
  AEntryEncrypted, APasswordSupplied, AAlreadyRetried: Boolean): Boolean;

implementation

uses
  SysUtils, tzip.i18n;

function TzErrorClassOf(ACode: Integer): TZErrorClass;
begin
  case ACode of
    TZ7Z_OK: Result := ecOk;
    TZ7Z_E_ARG: Result := ecArgument;
    TZ7Z_E_MEMORY: Result := ecMemory;
    TZ7Z_E_OPEN: Result := ecOpen;
    TZ7Z_E_NOT_ARCHIVE: Result := ecNotArchive;
    TZ7Z_E_PASSWORD: Result := ecPassword;
    TZ7Z_E_FORMAT: Result := ecFormat;
    TZ7Z_E_UPDATE: Result := ecUpdate;
    TZ7Z_E_EXTRACT: Result := ecExtract;
    TZ7Z_E_CANCEL: Result := ecCancel;
    TZ7Z_E_IO: Result := ecIO;
    TZ7Z_E_UNSUPPORTED: Result := ecUnsupported;
  else
    Result := ecUnknown;
  end;
end;

function TzErrorClassText(AClass: TZErrorClass): string;
begin
  case AClass of
    ecOk: Result := rsErrOk;
    ecArgument: Result := rsErrArgument;
    ecMemory: Result := rsErrMemory;
    ecOpen: Result := rsErrOpen;
    ecNotArchive: Result := rsErrNotArchive;
    ecPassword: Result := rsErrPassword;
    ecFormat: Result := rsErrFormat;
    ecUpdate: Result := rsErrUpdate;
    ecExtract: Result := rsErrExtract;
    ecCancel: Result := rsErrCancel;
    ecIO: Result := rsErrIO;
    ecUnsupported: Result := rsErrUnsupported;
  else
    { ecUnknown carries no code of its own; TzErrorText fills in the number. }
    Result := Format(rsErrUnknownFmt, [0]);
  end;
end;

function TzErrorText(ACode: Integer): string;
var
  ErrorClass: TZErrorClass;
begin
  ErrorClass := TzErrorClassOf(ACode);
  if ErrorClass = ecUnknown then
    Result := Format(rsErrUnknownFmt, [ACode])
  else
    Result := TzErrorClassText(ErrorClass);
end;

function TzShouldRetryPasswordAfterExtractError(AResult: Integer;
  AEntryEncrypted, APasswordSupplied, AAlreadyRetried: Boolean): Boolean;
begin
  Result := (AResult = TZ7Z_E_EXTRACT) and AEntryEncrypted and
    APasswordSupplied and (not AAlreadyRetried);
end;

end.
