{ The archive commands: what job a command means, and what it is called.

  The window's Do* methods mix three things: building the request (which job, with
  which inputs), asking the user (dialogs, confirmations) and reporting the
  outcome (status bar, error dialog). This unit takes the first one. Given plain
  parameters it produces the TCreateSettings or the TZJob the command needs -- no
  dialog, no status bar, no preview teardown -- so the construction can be tested
  without a window.

  Layer: controller. Uses tzip.jobs and tzip.extract; no LCL. }

unit tzip.commands;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tzip.api, tzip.engine, tzip.extract, tzip.jobs;

{ What an OS "open this file" request means while a window may already show an
  archive. A folder or another archive is something to OPEN; reading the second
  as "add it to the archive on screen" popped the add-confirmation dialog when
  the user double-clicked a second archive in Finder (ticket 44). Only a plain
  non-archive file keeps the old "add it to the current archive" meaning. }
type
  TExternalOpenKind = (eokOpenHere, eokOpenInNewInstance, eokAddToArchive);

function TzExternalOpenKind(const APath: string;
  AArchiveOpen: Boolean): TExternalOpenKind;

{ The settings a MODIFY rewrite uses: keep the archive's format, compression
  method (Level = -1) and protection, and force UTF-8 names. A ZIP rewrite
  without ForceUtf8 re-encodes every name in the local code page, so every
  rewrite path shares this constructor instead of repeating six assignments. }
function TzModifySettings(const AFormatName, APassword: string;
  AEncryptNames: Boolean): TCreateSettings;

{ The settings a CREATE uses by default: level 5, solid, UTF-8 names. }
function TzCreateSettingsFor(const AFormatName: string): TCreateSettings;

{ A jkModify job with its inputs filled. ASources is copied when given, so the
  caller keeps ownership of its list. }
function TzNewModifyJob(const APath, ADisplayName, APassword: string;
  const ASettings: TCreateSettings; const ASources: TStrings = nil): TZJob;

{ A jkRename job: rewrite AEntryName of the archive as ATarget. }
function TzNewRenameJob(const APath, ADisplayName, APassword: string;
  const ASettings: TCreateSettings; AEntryIndex: Integer;
  const AEntryName, ATarget: string): TZJob;

{ Extract AIndices (empty means "the whole archive" to the engine). }
function TzNewExtractJob(const APath, ADisplayName, APassword, ADest: string;
  const AIndices: TLongWordArray): TZJob;

{ One archive of a batch extraction: whole archive, ADest gets a trailing
  separator so the engine writes inside it. }
function TzNewBatchExtractJob(const APath, ADest, APassword: string): TZJob;

{ Test AIndices, or a whole archive for batch testing. }
function TzNewTestJob(const APath, ADisplayName, APassword: string;
  const AIndices: TLongWordArray): TZJob;
function TzNewBatchTestJob(const APath, APassword: string): TZJob;

{ "Extract each archive into a folder named after it, beside the archive":
  the destination only, without the trailing separator the job adds.

  The extension rule is deliberately the one this window has always used for this
  command (strip .gz/.bz2/.xz/.zst, then one more extension), NOT
  tzip.extract.SmartFolderName: the two disagree for ".tar.lzma", and adopting
  that is a user-visible decision of its own. }
function TzOwnFolderDest(const AArchivePath: string): string;

{ The status line for a batch that skipped files which are not archives; '' when
  nothing was skipped. }
function TzBatchSkipStatus(ASkipped: Integer): string;

implementation

uses
  tzip.i18n;

function TzExternalOpenKind(const APath: string;
  AArchiveOpen: Boolean): TExternalOpenKind;
begin
  if AArchiveOpen then
  begin
    if TzIsArchiveName(APath) then
    begin
      if FileExists(APath) then Exit(eokOpenInNewInstance);
      Exit(eokOpenHere);
    end;
    if not DirectoryExists(APath) then Exit(eokAddToArchive);
  end;
  Result := eokOpenHere;
end;

function TzModifySettings(const AFormatName, APassword: string;
  AEncryptNames: Boolean): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFormatName;
  { -1 asks the engine to keep each entry's current method instead of
    recompressing the whole archive. }
  Result.Level := -1;
  Result.Solid := True;
  Result.Password := APassword;
  Result.EncryptNames := AEncryptNames;
  Result.ForceUtf8 := True;
end;

function TzCreateSettingsFor(const AFormatName: string): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFormatName;
  Result.Level := 5;
  Result.Solid := True;
  Result.ForceUtf8 := True;
  Result.DeleteSources := False;
end;

function TzNewModifyJob(const APath, ADisplayName, APassword: string;
  const ASettings: TCreateSettings; const ASources: TStrings): TZJob;
begin
  Result := TZJob.Create(jkModify);
  Result.Path := APath;
  Result.DisplayName := ADisplayName;
  Result.Password := APassword;
  Result.Settings := ASettings;
  if ASources <> nil then
  begin
    Result.Sources := TStringList.Create;
    Result.Sources.Assign(ASources);
  end;
end;

function TzNewRenameJob(const APath, ADisplayName, APassword: string;
  const ASettings: TCreateSettings; AEntryIndex: Integer;
  const AEntryName, ATarget: string): TZJob;
begin
  Result := TZJob.Create(jkRename);
  Result.Path := APath;
  Result.DisplayName := ADisplayName;
  Result.Password := APassword;
  Result.Settings := ASettings;
  Result.RenameIndex := AEntryIndex;
  Result.RenameFrom := AEntryName;
  Result.RenameTo := ATarget;
end;

function TzNewExtractJob(const APath, ADisplayName, APassword, ADest: string;
  const AIndices: TLongWordArray): TZJob;
begin
  Result := TZJob.Create(jkExtract);
  Result.Path := APath;
  Result.DisplayName := ADisplayName;
  Result.Password := APassword;
  Result.Dest := ADest;
  Result.Indices := Copy(AIndices);
end;

function TzNewBatchExtractJob(const APath, ADest, APassword: string): TZJob;
begin
  Result := TZJob.Create(jkExtract);
  Result.Path := APath;
  Result.DisplayName := ExtractFileName(APath);
  Result.Password := APassword;
  if ADest <> '' then
    Result.Dest := IncludeTrailingPathDelimiter(ADest)
  else
    Result.Dest := '';
  { No index list: a batch operation works on whole archives. }
  Result.Indices := nil;
end;

function TzNewTestJob(const APath, ADisplayName, APassword: string;
  const AIndices: TLongWordArray): TZJob;
begin
  Result := TZJob.Create(jkTest);
  Result.Path := APath;
  Result.DisplayName := ADisplayName;
  Result.Password := APassword;
  Result.Indices := Copy(AIndices);
end;

function TzNewBatchTestJob(const APath, APassword: string): TZJob;
begin
  Result := TZJob.Create(jkTest);
  Result.Path := APath;
  Result.DisplayName := ExtractFileName(APath);
  Result.Password := APassword;
  Result.Indices := nil;
end;

function TzOwnFolderDest(const AArchivePath: string): string;
var
  Stem: string;
begin
  Stem := ExtractFileName(AArchivePath);
  if SameText(ExtractFileExt(Stem), '.gz') or SameText(ExtractFileExt(Stem), '.bz2')
     or SameText(ExtractFileExt(Stem), '.xz') or SameText(ExtractFileExt(Stem), '.zst') then
    Stem := ChangeFileExt(Stem, '');
  Stem := ChangeFileExt(Stem, '');
  if Stem = '' then Stem := 'Extracted';
  Result := IncludeTrailingPathDelimiter(
    ExcludeTrailingPathDelimiter(ExtractFileDir(AArchivePath))) + Stem;
end;

function TzBatchSkipStatus(ASkipped: Integer): string;
begin
  Result := '';
  if ASkipped > 0 then
    Result := Format(rsStatusBatchSkippedFmt, [ASkipped]);
end;

end.
