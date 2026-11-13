{ Application settings: the record and its INI file.

  Split out of tzip.dialogs and tzip.main, which both had to know the field list:
  the dialog edits it, the form persists and applies it. Keeping the record and
  the file format together means one place decides what a setting is called on
  disk.

  Reading is deliberately forgiving: an unreadable or partial file leaves the
  defaults in place rather than failing, because a corrupt preference file must
  never stop the program from starting. }
unit tzip.settings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, FileUtil, tzip.i18n, tzip.nameenc;

const
  { The range the main form's dividers produce. The INI file is user editable,
    so a width read from it must be clamped before it reaches the layout: a
    negative or absurd value makes the window unusable. }
  SidebarWidthMin = 160;
  SidebarWidthMax = 600;
  PreviewWidthMin = 160;
  PreviewWidthMax = 900;
  { How many recently opened archives the welcome view remembers. }
  MaxRecentArchives = 10;

type
  TAppSettings = record
    ThemeName: string;
    Mode: string;
    Language: string;
    ShowHidden: Boolean;
    ShowSidebar: Boolean;
    ShowPreview: Boolean;
    { Sidebar width in pixels, set by dragging the divider next to it. }
    SidebarWidth: Integer;
    { Preview pane width in pixels, set by dragging its divider. }
    PreviewWidth: Integer;
    FoldersFirst: Boolean;
    ConfirmDelete: Boolean;
    OpenAfterExtract: Boolean;
    DefaultExtractDir: string;
    LastArchiveFormat: string;
    { ZIP entry-name encoding for names without the UTF-8 flag: a
      tzip.nameenc id ('auto' resolves from the interface language). }
    NameEncoding: string;
  end;

{ The values a first run starts from. }
function DefaultSettings: TAppSettings;

{ A stored pane width brought into the range the layout supports. }
function TzClampSidebarWidth(AWidth: Integer): Integer;
function TzClampPreviewWidth(AWidth: Integer): Integer;

{ Write ASettings to APath. Returns False when the file could not be written --
  a read-only home (sandbox, managed Mac) must never turn a theme switch into an
  error dialog, so callers keep their in-memory copy either way. }
function SaveSettingsToFile(const APath: string;
  const ASettings: TAppSettings): Boolean;

{ Read APath over the defaults. A missing or unreadable file yields
  DefaultSettings. }
function LoadSettingsFromFile(const APath: string): TAppSettings;

{ The recently opened archive paths, newest first. Stored in the same INI file
  under [Recent] as Count + Archive0..Archive9.  Kept out of TAppSettings (a
  value record copied around) because this is an owned list, not a scalar. }
function LoadRecentArchives(const APath: string; AList: TStrings): Boolean;
procedure SaveRecentArchives(const APath: string; AList: TStrings);

implementation

function DefaultSettings: TAppSettings;
begin
  Result := Default(TAppSettings);
  Result.ThemeName := 'default';
  Result.Mode := '';
  { Follow the OS language on the first run. A literal 'en' here meant that the
    first time the user pressed Save, the file pinned English and the program
    came back in English on a Chinese system -- while the Settings dialog's
    first entry had always said "System default". }
  Result.Language := LanguageSystem;
  Result.ShowHidden := False;
  Result.ShowSidebar := False;
  Result.ShowPreview := True;
  Result.SidebarWidth := 260;
  Result.PreviewWidth := 320;
  Result.FoldersFirst := True;
  Result.ConfirmDelete := True;
  Result.OpenAfterExtract := False;
  Result.LastArchiveFormat := '7z';
  Result.NameEncoding := NameEncodingDefault;
  Result.DefaultExtractDir := IncludeTrailingPathDelimiter(GetUserDir) + 'Downloads';
end;

function TzClampSidebarWidth(AWidth: Integer): Integer;
begin
  if AWidth < SidebarWidthMin then
    Result := SidebarWidthMin
  else if AWidth > SidebarWidthMax then
    Result := SidebarWidthMax
  else
    Result := AWidth;
end;

function TzClampPreviewWidth(AWidth: Integer): Integer;
begin
  if AWidth < PreviewWidthMin then
    Result := PreviewWidthMin
  else if AWidth > PreviewWidthMax then
    Result := PreviewWidthMax
  else
    Result := AWidth;
end;

function SaveSettingsToFile(const APath: string;
  const ASettings: TAppSettings): Boolean;
var
  Ini: TIniFile;
begin
  Result := False;
  if APath = '' then Exit;
  try
    ForceDirectories(ExtractFileDir(APath));
    Ini := TIniFile.Create(APath);
    try
      Ini.WriteString('UI', 'Theme', ASettings.ThemeName);
      Ini.WriteString('UI', 'Mode', ASettings.Mode);
      Ini.WriteString('UI', 'Language', ASettings.Language);
      Ini.WriteBool('UI', 'ShowHidden', ASettings.ShowHidden);
      Ini.WriteBool('UI', 'ShowSidebar', ASettings.ShowSidebar);
      Ini.WriteBool('UI', 'ShowPreview', ASettings.ShowPreview);
      Ini.WriteInteger('UI', 'SidebarWidth', ASettings.SidebarWidth);
      Ini.WriteInteger('UI', 'PreviewWidth', ASettings.PreviewWidth);
      Ini.WriteBool('UI', 'FoldersFirst', ASettings.FoldersFirst);
      Ini.WriteBool('UI', 'ConfirmDelete', ASettings.ConfirmDelete);
      Ini.WriteBool('UI', 'OpenAfterExtract', ASettings.OpenAfterExtract);
      Ini.WriteString('Paths', 'ExtractDir', ASettings.DefaultExtractDir);
      Ini.WriteString('Archive', 'LastFormat', ASettings.LastArchiveFormat);
      Ini.WriteString('Archive', 'NameEncoding', ASettings.NameEncoding);
      Result := True;
    finally
      Ini.Free;
    end;
  except
    { Keep the caller's in-memory copy; the disk file is best effort. }
    Result := False;
  end;
end;

function LoadRecentArchives(const APath: string; AList: TStrings): Boolean;
var
  Ini: TIniFile;
  Count, I: Integer;
  P: string;
begin
  Result := False;
  if AList = nil then Exit;
  AList.Clear;
  if (APath = '') or (not FileExists(APath)) then Exit;
  try
    Ini := TIniFile.Create(APath);
    try
      Count := Ini.ReadInteger('Recent', 'Count', 0);
      if Count < 0 then Count := 0;
      if Count > MaxRecentArchives then Count := MaxRecentArchives;
      for I := 0 to Count - 1 do
      begin
        P := Ini.ReadString('Recent', 'Archive' + IntToStr(I), '');
        if P <> '' then AList.Add(P);
      end;
      Result := True;
    finally
      Ini.Free;
    end;
  except
    AList.Clear;
  end;
end;

procedure SaveRecentArchives(const APath: string; AList: TStrings);
var
  Ini: TIniFile;
  I, N: Integer;
begin
  if (APath = '') or (AList = nil) then Exit;
  try
    ForceDirectories(ExtractFileDir(APath));
    Ini := TIniFile.Create(APath);
    try
      N := AList.Count;
      if N > MaxRecentArchives then N := MaxRecentArchives;
      Ini.WriteInteger('Recent', 'Count', N);
      for I := 0 to N - 1 do
        Ini.WriteString('Recent', 'Archive' + IntToStr(I), AList[I]);
      { Clear keys a longer previous list left behind. }
      for I := N to MaxRecentArchives - 1 do
        Ini.DeleteKey('Recent', 'Archive' + IntToStr(I));
    finally
      Ini.Free;
    end;
  except
    { Best effort: a read-only home must not break opening an archive. }
  end;
end;

{ A language id from the file: only the ids the Settings dialog offers are
  meaningful, so an empty or hand-edited value falls back to "follow the OS"
  instead of pinning a language that has no catalogue. }
function NormalizeLanguage(const AValue: string): string;
begin
  Result := Trim(AValue);
  if SameText(Result, LanguageSystem) then
    Result := LanguageSystem
  else if SameText(Result, LanguageEnglish) then
    Result := LanguageEnglish
  else if SameText(Result, LanguageChinese) then
    Result := LanguageChinese
  else
    Result := LanguageSystem;
end;

function LoadSettingsFromFile(const APath: string): TAppSettings;
var
  Ini: TIniFile;
begin
  Result := DefaultSettings;
  if (APath = '') or (not FileExists(APath)) then Exit;
  try
    Ini := TIniFile.Create(APath);
    try
      Result.ThemeName := Ini.ReadString('UI', 'Theme', Result.ThemeName);
      Result.Mode := Ini.ReadString('UI', 'Mode', '');
      Result.Language := NormalizeLanguage(
        Ini.ReadString('UI', 'Language', Result.Language));
      Result.ShowHidden := Ini.ReadBool('UI', 'ShowHidden', Result.ShowHidden);
      Result.ShowSidebar := Ini.ReadBool('UI', 'ShowSidebar', Result.ShowSidebar);
      Result.ShowPreview := Ini.ReadBool('UI', 'ShowPreview', Result.ShowPreview);
      Result.SidebarWidth := TzClampSidebarWidth(
        Ini.ReadInteger('UI', 'SidebarWidth', Result.SidebarWidth));
      Result.PreviewWidth := TzClampPreviewWidth(
        Ini.ReadInteger('UI', 'PreviewWidth', Result.PreviewWidth));
      Result.FoldersFirst := Ini.ReadBool('UI', 'FoldersFirst', Result.FoldersFirst);
      Result.ConfirmDelete := Ini.ReadBool('UI', 'ConfirmDelete', Result.ConfirmDelete);
      Result.OpenAfterExtract := Ini.ReadBool('UI', 'OpenAfterExtract', Result.OpenAfterExtract);
      Result.DefaultExtractDir := Ini.ReadString('Paths', 'ExtractDir',
        Result.DefaultExtractDir);
      Result.LastArchiveFormat := Ini.ReadString('Archive', 'LastFormat',
        Result.LastArchiveFormat);
      { A hand-edited or stale id must not reach the engine as a code page:
        TzNameEncodingById turns anything unknown back into auto. }
      Result.NameEncoding := TzNameEncodingById(
        Ini.ReadString('Archive', 'NameEncoding', Result.NameEncoding)).Id;
    finally
      Ini.Free;
    end;
  except
    { A corrupt file must not stop the program from starting. }
    Result := DefaultSettings;
  end;
end;

end.
