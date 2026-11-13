unit tzip.createopts;
{ The values behind TyZip's create-archive and settings dialogs, without the LCL.

  tzip.dialogs used to own a second copy of knowledge the engine already has:
  which formats can be written, what extension each one wants, and when a
  single-stream format needs the ".tar" layer. That copy drifted from the
  engine's own table, and because it lived inside a TTyDialog no test could see
  the drift. Everything here is a plain function over plain records so
  tests/unit_dialogs_opts.pas can assert exactly what the dialog will show.

  The format table is passed in as a TFormatInfoArray (the dialog passes
  TzLoadFormats) instead of being read here, so these functions are callable
  without a loaded bridge and the engine stays the source of truth for names,
  extensions and writability. Only capability flags -- which options a format
  handler accepts -- are stated here, because the bridge does not expose them. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tzip.api, tzip.settings, tzip.nameenc;

type
  { What a writable format can actually be told to do. The dialog shows only the
    controls named here and hides the rest instead of greying them out. Known is
    false for a format the engine can write but this table does not describe; the
    dialog then offers none of these options rather than guessing, and never adds
    a compound extension the engine cannot write. }
  TFormatCaps = record
    Known: Boolean;
    HasMethod: Boolean;      { selectable compression method }
    HasLevel: Boolean;       { compression level }
    HasSolid: Boolean;       { solid blocks }
    HasEncrypt: Boolean;     { password support }
    HasEncryptNames: Boolean;
    HasAES: Boolean;         { zip: AES-256 instead of ZipCrypto }
    HasCodePage: Boolean;    { zip: entry-name code page }
    HasVolume: Boolean;      { multi-volume split }
    HasDictionary: Boolean;
    HasWordSize: Boolean;
    SingleStream: Boolean;   { gz/bz2/xz: one stream, no directory tree }
  end;

const
  { Create formats in the order users reach for them, not alphabetically: 7z and
    zip are what nearly every archive is. Formats the engine can write but this
    list does not name follow, in engine order. }
  CreateFormatOrder: array[0..6] of string =
    ('7z', 'zip', 'tar', 'gzip', 'bzip2', 'xz', 'wim');

  { Compression levels behind the Level combo, in combo order. 7-Zip names them
    Store, Fastest, Fast, Normal, Maximum, Ultra. }
  CreateLevels: array[0..5] of Integer = (0, 1, 3, 5, 7, 9);

  { Name-encoding choices behind the Codepage combo, in combo order. 0 is "let
    the engine decide"; 28591 is the Windows number for ISO-8859-1. }

  CodepageAuto = LongWord(0);
  CodepageUtf8 = LongWord(65001);

  { Split-volume choices behind the Volume combo, with the labels shown for them.
    Values and labels live together on purpose: they used to be a label list in
    the dialog and a value list elsewhere, and a short value array read past its
    end when 16 GB or 50 GB was chosen. }
  CreateVolumeSizes: array[0..6] of QWord = (0,
    100 * QWord(1024) * 1024, 700 * QWord(1024) * 1024,
    QWord(1024) * 1024 * 1024, 4 * QWord(1024) * 1024 * 1024,
    16 * QWord(1024) * 1024 * 1024, 50 * QWord(1024) * 1024 * 1024);
  CreateVolumeLabels: array[0..6] of string = ('',
    '100 MB', '700 MB', '1 GB', '4 GB', '16 GB', '50 GB');

  { Dictionary sizes offered for LZMA/LZMA2, in MB. 64 MB is a good default on a
    modern machine; the first entries exist for small files where a large
    dictionary only wastes memory. }
  CreateDictSizes: array[0..10] of Integer =
    (1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024);

{ The capability flags for AFormat. Known is false when the format is not in the
  table; the caller must then leave the format's options alone. }
function TzFormatCaps(const AFormat: string): TFormatCaps;

{ The write extension of AFormat as the engine's own format table reports it:
  its first listed extension, lowercase, with the dot. '' when the format is not
  writable or the engine does not know it. }
function TzPreferredCreateExt(const AFormat: string;
  const AFormats: TFormatInfoArray): string;

{ The compound ".tar.<ext>" name a single-stream format needs for a tree or for
  several files. Derived from the engine's own add-extension list ("this handler
  can add .tar"), so a format that gains tar support in the engine needs no
  change here. '' when the format is not a known single-stream format or the
  engine offers no tar layer for it. }
function TzCompoundCreateExt(const AFormat: string;
  const AFormats: TFormatInfoArray): string;

{ The extension the create dialog should give AFormat for ASourceCount inputs. }
function TzCreateExtForSources(const AFormat: string; ASourceCount: Integer;
  const AFormats: TFormatInfoArray): string;

{ APath with its extension rewritten for AFormat. An extension that already
  matches is kept, including case. For a single-stream format an existing
  ".tar.<ext>" name is kept as the user typed it; for any other format it is
  replaced whole ("photo.tar.gz" becomes "photo.zip", not "photo.tar.zip"). }
function TzArchiveNameForCreate(const APath, AFormat: string;
  ASourceCount: Integer; const AFormats: TFormatInfoArray): string;

{ The default archive NAME for a create from ASources: a single source keeps
  its own name; several sources are named after the folder they share, not after
  whichever file happens to be first (ticket 42). }
function TzDefaultArchiveName(ASources: TStrings; const AFormat: string;
  const AFormats: TFormatInfoArray): string;

{ True when AExt is one of the compound tar extension suffixes. }
function TzIsCompoundTarExt(const AExt: string): Boolean;

{ Level combo index for a stored compression level, -1 when ALevel < 0 ("no
  level") or nothing can be shown. Stored presets may hold levels the combo does
  not offer (2, 4, ...); the nearest offered level is used so such a preset still
  applies instead of being silently ignored. }
function TzLevelComboIndex(ALevel: Integer): Integer;
{ Compression level behind level combo index AIndex; -1 when out of range. }
function TzLevelValue(AIndex: Integer): Integer;

{ Codepage combo index for a stored code page, -1 when the combo cannot show it. }
function TzCodepageComboIndex(ACodepage: LongWord): Integer;
{ Code page behind codepage combo index AIndex; CodepageAuto when out of range. }
function TzCodepageValue(AIndex: Integer): LongWord;

{ Volume combo index for a stored volume size, -1 when no size matches. }
function TzVolumeComboIndex(ASize: QWord): Integer;
{ Volume size behind volume combo index AIndex; 0 ("single file") out of range. }
function TzVolumeValue(AIndex: Integer): QWord;

{ Dictionary size in bytes behind dictionary combo index AIndex; 0 out of range. }
function TzDictPresetBytes(AIndex: Integer): QWord;
{ Dictionary size text shown in the combo ("64 MB", "1 GB"); '' out of range. }
function TzDictPresetText(AIndex: Integer): string;
{ Dictionary combo index for a stored size in bytes, -1 when no entry matches. }
function TzDictComboIndex(ASize: QWord): Integer;

{ ABase with the fields the settings dialog edits taken from AEdited. The pane
  widths, their visibility and the last-used archive format are owned by the main
  form (dragged dividers, View menu, create dialog), so saving the settings page
  must not reset them to the record defaults. Widths are clamped here as well, so
  a value loaded from a damaged INI file cannot be written back out of range. }
function TzApplyDialogSettings(const ABase, AEdited: TAppSettings): TAppSettings;

implementation

const
  { Capability table. One entry per format the engine reports as writable.
    Anything absent is deliberately unknown: the dialog then shows no options
    for it and never invents a compound extension. }
  CreateCaps: array[0..6] of TFormatCaps = (
    (Known: True; HasMethod: True; HasLevel: True; HasSolid: True;
     HasEncrypt: True; HasEncryptNames: True; HasAES: False;
     HasCodePage: False; HasVolume: True; HasDictionary: True;
     HasWordSize: True; SingleStream: False),                      { 7z }
    (Known: True; HasMethod: True; HasLevel: True; HasSolid: False;
     HasEncrypt: True; HasEncryptNames: False; HasAES: True;
     HasCodePage: True; HasVolume: True; HasDictionary: True;
     HasWordSize: True; SingleStream: False),                      { zip }
    (Known: True; HasMethod: False; HasLevel: False; HasSolid: False;
     HasEncrypt: False; HasEncryptNames: False; HasAES: False;
     HasCodePage: False; HasVolume: False; HasDictionary: False;
     HasWordSize: False; SingleStream: False),                     { tar }
    (Known: True; HasMethod: False; HasLevel: True; HasSolid: False;
     HasEncrypt: False; HasEncryptNames: False; HasAES: False;
     HasCodePage: False; HasVolume: False; HasDictionary: False;
     HasWordSize: False; SingleStream: True),                      { gzip }
    (Known: True; HasMethod: False; HasLevel: True; HasSolid: False;
     HasEncrypt: False; HasEncryptNames: False; HasAES: False;
     HasCodePage: False; HasVolume: False; HasDictionary: False;
     HasWordSize: False; SingleStream: True),                      { bzip2 }
    (Known: True; HasMethod: False; HasLevel: True; HasSolid: False;
     HasEncrypt: False; HasEncryptNames: False; HasAES: False;
     HasCodePage: False; HasVolume: False; HasDictionary: False;
     HasWordSize: False; SingleStream: True),                      { xz }
    (Known: True; HasMethod: True; HasLevel: True; HasSolid: False;
     HasEncrypt: False; HasEncryptNames: False; HasAES: False;
     HasCodePage: False; HasVolume: False; HasDictionary: False;
     HasWordSize: False; SingleStream: False)                      { wim }
  );

  { Compressor names repeat in the engine's Ext list ("gz gzip tgz"); the
    conventional write extension is the first one.
    The compound suffixes are the three the engine's create path unwraps. }
  CompoundTarExts: array[0..2] of string = ('.tar.gz', '.tar.bz2', '.tar.xz');

function TzFormatCaps(const AFormat: string): TFormatCaps;
var
  I: Integer;
begin
  for I := 0 to High(CreateCaps) do
    if SameText(AFormat, CreateFormatOrder[I]) then Exit(CreateCaps[I]);
  Result := Default(TFormatCaps);
end;

function FindFormat(const AFormat: string; const AFormats: TFormatInfoArray;
  out AInfo: TFormatInfo): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AFormats) do
    if SameText(AFormats[I].Name, AFormat) then
    begin
      AInfo := AFormats[I];
      Exit(True);
    end;
  Result := False;
end;

function FirstExtToken(const AExt: string): string;
var
  S: string;
  P: Integer;
begin
  S := Trim(AExt);
  P := Pos(' ', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  S := LowerCase(S);
  if (S <> '') and (S[1] = '.') then Delete(S, 1, 1);
  Result := S;
end;

{ True when AList contains AToken as one space-separated entry. }
function ExtListHas(const AList, AToken: string): Boolean;
var
  S, Item: string;
  I, Start: Integer;
begin
  S := LowerCase(Trim(AList));
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and (S[I] = ' ') do Inc(I);
    Start := I;
    while (I <= Length(S)) and (S[I] <> ' ') do Inc(I);
    Item := Copy(S, Start, I - Start);
    if Item = AToken then Exit(True);
  end;
  Result := False;
end;

function TzPreferredCreateExt(const AFormat: string;
  const AFormats: TFormatInfoArray): string;
var
  F: TFormatInfo;
  Ext: string;
begin
  Result := '';
  if not FindFormat(AFormat, AFormats, F) then Exit;
  if not F.CanUpdate then Exit;
  Ext := FirstExtToken(F.Ext);
  if Ext = '' then Exit;
  Result := '.' + Ext;
end;

function TzCompoundCreateExt(const AFormat: string;
  const AFormats: TFormatInfoArray): string;
var
  F: TFormatInfo;
  Ext: string;
begin
  Result := '';
  { A compound name is only safe for a format the table describes as
    single-stream AND whose handler says it can add a tar. An unknown writable
    format gets neither: the engine's create path would not unwrap a name it
    does not know. }
  if not TzFormatCaps(AFormat).SingleStream then Exit;
  if not FindFormat(AFormat, AFormats, F) then Exit;
  if not F.CanUpdate then Exit;
  Ext := FirstExtToken(F.Ext);
  if Ext = '' then Exit;
  if not ExtListHas(F.AddExt, '.tar') then Exit;
  Result := '.tar.' + Ext;
end;

function TzCreateExtForSources(const AFormat: string; ASourceCount: Integer;
  const AFormats: TFormatInfoArray): string;
var
  Compound: string;
begin
  Result := TzPreferredCreateExt(AFormat, AFormats);
  if Result = '' then Exit;
  if TzFormatCaps(AFormat).SingleStream and (ASourceCount <> 1) then
  begin
    Compound := TzCompoundCreateExt(AFormat, AFormats);
    if Compound <> '' then Result := Compound;
  end;
end;

{ True when APath is ADir itself or lives under it. }
function TzPathIsUnder(const ADir, APath: string): Boolean;
begin
  if ADir = PathDelim then Exit(True);
  Result := (ADir = APath) or
    (Copy(APath, 1, Length(ADir) + 1) = IncludeTrailingPathDelimiter(ADir));
end;

function TzDefaultArchiveName(ASources: TStrings; const AFormat: string;
  const AFormats: TFormatInfoArray): string;
var
  I: Integer;
  Parent, Common, FirstDir, Stem, Ext: string;
begin
  Result := '';
  if (ASources = nil) or (ASources.Count = 0) then Exit;
  { One source keeps its own name, extension rewritten for the format. }
  if ASources.Count = 1 then
    Exit(ExtractFileName(
      TzArchiveNameForCreate(ASources[0], AFormat, 1, AFormats)));

  { Several sources: name the archive after the folder they share, not after
    whichever file happened to be first (ticket 42). }
  FirstDir := ExcludeTrailingPathDelimiter(
    ExtractFileDir(ExcludeTrailingPathDelimiter(ASources[0])));
  Common := FirstDir;
  for I := 1 to ASources.Count - 1 do
  begin
    Parent := ExcludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(ASources[I])));
    while (Common <> '') and (Common <> PathDelim) and
          (not TzPathIsUnder(Common, Parent)) do
      Common := ExcludeTrailingPathDelimiter(ExtractFileDir(Common));
  end;
  if Common = PathDelim then Common := '';
  if Common = '' then Common := FirstDir;
  Stem := ExtractFileName(ExcludeTrailingPathDelimiter(Common));
  if Stem = '' then
    Stem := ChangeFileExt(
      ExtractFileName(ExcludeTrailingPathDelimiter(ASources[0])), '');
  Ext := TzCreateExtForSources(AFormat, ASources.Count, AFormats);
  Result := Stem + Ext;
end;

function TzIsCompoundTarExt(const AExt: string): Boolean;
var
  Ext: string;
  I: Integer;
begin
  Ext := LowerCase(AExt);
  for I := 0 to High(CompoundTarExts) do
    if Ext = CompoundTarExts[I] then Exit(True);
  Result := False;
end;

{ The extension of AName as the dialog should compare it: the compound
  ".tar.gz"-style suffix when there is one, else the ordinary last extension.
  ExtractFileExt alone sees only ".gz" in "photo.tar.gz", which is why a compound
  name could not be replaced or recognised. Lowercase, with the dot. }
function TzEffectiveExt(const AName: string): string;
var
  L: string;
  I, Len: Integer;
begin
  L := LowerCase(AName);
  for I := 0 to High(CompoundTarExts) do
  begin
    Len := Length(CompoundTarExts[I]);
    if (Length(L) > Len) and
       (Copy(L, Length(L) - Len + 1, Len) = CompoundTarExts[I]) then
      Exit(CompoundTarExts[I]);
  end;
  Result := LowerCase(ExtractFileExt(L));
end;

function TzArchiveNameForCreate(const APath, AFormat: string;
  ASourceCount: Integer; const AFormats: TFormatInfoArray): string;
var
  P, Dir, Name, Base, Ext, Want: string;
begin
  P := Trim(APath);
  Result := P;
  if P = '' then Exit;
  Want := TzCreateExtForSources(AFormat, ASourceCount, AFormats);
  if Want = '' then Exit;

  Dir := ExtractFileDir(P);
  Name := ExtractFileName(P);
  Ext := TzEffectiveExt(Name);
  if Ext = Want then Exit;
  { A user-typed compound name for a single-stream format is already what the
    engine will write; do not fight over which compressor is named. }
  if TzFormatCaps(AFormat).SingleStream and TzIsCompoundTarExt(Ext) then Exit;

  { Replace the whole suffix, so ".tar.gz" does not survive as ".tar.zip". }
  if TzIsCompoundTarExt(Ext) then
    Base := Copy(Name, 1, Length(Name) - Length(Ext))
  else
    Base := ChangeFileExt(Name, '');
  if Base = '' then Exit;

  if Dir <> '' then
    Result := IncludeTrailingPathDelimiter(Dir) + Base + Want
  else
    Result := Base + Want;
end;

function TzLevelValue(AIndex: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex > High(CreateLevels)) then
    Result := -1
  else
    Result := CreateLevels[AIndex];
end;

function TzLevelComboIndex(ALevel: Integer): Integer;
var
  I, Diff, BestDiff: Integer;
begin
  Result := -1;
  if ALevel < 0 then Exit;
  if ALevel >= CreateLevels[High(CreateLevels)] then
    Exit(High(CreateLevels));
  BestDiff := MaxInt;
  for I := 0 to High(CreateLevels) do
  begin
    Diff := Abs(CreateLevels[I] - ALevel);
    if Diff < BestDiff then
    begin
      BestDiff := Diff;
      Result := I;
    end;
  end;
end;

function TzCodepageValue(AIndex: Integer): LongWord;
begin
  if (AIndex < 0) or (AIndex > High(NameEncodings)) then
    Result := CodepageAuto
  else
    Result := NameEncodings[AIndex].Codepage;
end;

function TzCodepageComboIndex(ACodepage: LongWord): Integer;
begin
  Result := TzNameEncodingIndexByCodepage(ACodepage);
end;

function TzVolumeValue(AIndex: Integer): QWord;
begin
  if (AIndex < 0) or (AIndex > High(CreateVolumeSizes)) then
    Result := 0
  else
    Result := CreateVolumeSizes[AIndex];
end;

function TzVolumeComboIndex(ASize: QWord): Integer;
var
  I: Integer;
begin
  for I := 0 to High(CreateVolumeSizes) do
    if CreateVolumeSizes[I] = ASize then Exit(I);
  Result := -1;
end;

function TzDictPresetBytes(AIndex: Integer): QWord;
begin
  if (AIndex < 0) or (AIndex > High(CreateDictSizes)) then
    Result := 0
  else
    Result := QWord(CreateDictSizes[AIndex]) * 1024 * 1024;
end;

function TzDictPresetText(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex > High(CreateDictSizes)) then
    Result := ''
  else if CreateDictSizes[AIndex] >= 1024 then
    Result := IntToStr(CreateDictSizes[AIndex] div 1024) + ' GB'
  else
    Result := IntToStr(CreateDictSizes[AIndex]) + ' MB';
end;

function TzDictComboIndex(ASize: QWord): Integer;
var
  I: Integer;
begin
  for I := 0 to High(CreateDictSizes) do
    if TzDictPresetBytes(I) = ASize then Exit(I);
  Result := -1;
end;

function TzApplyDialogSettings(const ABase, AEdited: TAppSettings): TAppSettings;
begin
  Result := ABase;
  { Every field the settings dialog has a control for. }
  Result.ThemeName := AEdited.ThemeName;
  Result.Mode := AEdited.Mode;
  Result.Language := AEdited.Language;
  Result.ShowHidden := AEdited.ShowHidden;
  Result.FoldersFirst := AEdited.FoldersFirst;
  Result.ConfirmDelete := AEdited.ConfirmDelete;
  Result.OpenAfterExtract := AEdited.OpenAfterExtract;
  Result.DefaultExtractDir := AEdited.DefaultExtractDir;
  Result.NameEncoding := AEdited.NameEncoding;
  { ShowSidebar/ShowPreview, the two pane widths and LastArchiveFormat are not
    edited here: they belong to the main form, and copying AEdited wholesale used
    to zero the widths on every save. The clamp keeps a value loaded from a
    damaged preferences file from being written back out of range; the bounds and
    the functions live in tzip.settings, which this unit already uses. }
  Result.SidebarWidth := TzClampSidebarWidth(Result.SidebarWidth);
  Result.PreviewWidth := TzClampPreviewWidth(Result.PreviewWidth);
end;

end.
