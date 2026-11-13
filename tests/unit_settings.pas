program unit_settings;
{$mode objfpc}{$H+}
{ Settings: the record, its defaults, and its INI round trip.

  Worth testing because a preference file is the one piece of user state TyZip
  owns. A field that fails to round-trip is silently reset on every launch, and a
  corrupt file that throws would stop the program from starting at all. }
uses
  SysUtils, Classes, IniFiles, tzip.i18n, tzip.settings;

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

procedure EqBool(AGot, AWant: Boolean; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %s want %s',
      [AMsg, BoolToStr(AGot, True), BoolToStr(AWant, True)]));
  end;
end;

{ --- defaults ----------------------------------------------------------- }

procedure TestDefaults;
var
  S: TAppSettings;
begin
  S := DefaultSettings;
  { Every field must have a usable value: a first run shows a themed window
    with the sidebar hidden, the preview open and confirmation on. }
  EqStr(S.ThemeName, 'default', 'default: theme');
  EqStr(S.Mode, '', 'default: mode is unset');
  { First run follows the OS; pinning a language here is what made the first
    Save write "en" into the file on a Chinese system. }
  EqStr(S.Language, LanguageSystem, 'default: language follows the system');
  EqBool(S.ShowHidden, False, 'default: hidden files off');
  EqBool(S.ShowSidebar, False, 'default: sidebar off');
  EqBool(S.ShowPreview, True, 'default: preview on');
  EqInt(S.SidebarWidth, 260, 'default: sidebar width');
  EqInt(S.PreviewWidth, 320, 'default: preview width');
  EqBool(S.FoldersFirst, True, 'default: folders first');
  EqBool(S.ConfirmDelete, True, 'default: confirm delete');
  EqBool(S.OpenAfterExtract, False, 'default: do not open after extract');
  EqStr(S.LastArchiveFormat, '7z', 'default: archive format');
  EqStr(S.NameEncoding, 'auto', 'default: ZIP name encoding follows language');
  Check(Pos('Downloads', S.DefaultExtractDir) > 0,
    'default: extract dir is Downloads');
end;

{ --- round trip --------------------------------------------------------- }

procedure TestRoundTrip;
var
  S, Back: TAppSettings;
  Path: string;
begin
  Path := Root + '/roundtrip.ini';
  DeleteFile(Path);

  S := DefaultSettings;
  { Every field changed from its default, so a field that is not written (or not
    read back) shows up as a failure rather than matching by luck. }
  S.ThemeName := 'nord';
  S.Mode := 'dark';
  S.Language := 'zh_CN';
  S.ShowHidden := True;
  S.ShowSidebar := True;
  S.ShowPreview := False;
  S.SidebarWidth := 333;
  S.PreviewWidth := 444;
  S.FoldersFirst := False;
  S.ConfirmDelete := False;
  S.OpenAfterExtract := True;
  S.DefaultExtractDir := '/tmp/out';
  S.LastArchiveFormat := 'zip';
  S.NameEncoding := 'gbk';

  Check(SaveSettingsToFile(Path, S), 'roundtrip: saved');
  Check(FileExists(Path), 'roundtrip: file exists');

  Back := LoadSettingsFromFile(Path);
  EqStr(Back.ThemeName, 'nord', 'roundtrip: theme');
  EqStr(Back.Mode, 'dark', 'roundtrip: mode');
  EqStr(Back.Language, 'zh_CN', 'roundtrip: language');
  EqBool(Back.ShowHidden, True, 'roundtrip: show hidden');
  EqBool(Back.ShowSidebar, True, 'roundtrip: show sidebar');
  EqBool(Back.ShowPreview, False, 'roundtrip: show preview');
  EqInt(Back.SidebarWidth, 333, 'roundtrip: sidebar width');
  EqInt(Back.PreviewWidth, 444, 'roundtrip: preview width');
  EqBool(Back.FoldersFirst, False, 'roundtrip: folders first');
  EqBool(Back.ConfirmDelete, False, 'roundtrip: confirm delete');
  EqBool(Back.OpenAfterExtract, True, 'roundtrip: open after extract');
  EqStr(Back.DefaultExtractDir, '/tmp/out', 'roundtrip: extract dir');
  EqStr(Back.LastArchiveFormat, 'zip', 'roundtrip: archive format');
  EqStr(Back.NameEncoding, 'gbk', 'roundtrip: ZIP name encoding');
end;

procedure TestNameEncodingNormalization;
var
  Ini: TIniFile;
  S: TAppSettings;
  Path: string;

  procedure Expect(const AStored, AWant, AMsg: string);
  begin
    Path := Root + '/nameenc.ini';
    DeleteFile(Path);
    Ini := TIniFile.Create(Path);
    try
      Ini.WriteString('Archive', 'NameEncoding', AStored);
    finally Ini.Free; end;
    S := LoadSettingsFromFile(Path);
    EqStr(S.NameEncoding, AWant, AMsg);
  end;

begin
  { The INI file is user editable, and the id is also persisted across
    versions; only the ids the settings dialog offers are meaningful. }
  Expect('gbk', 'gbk', 'name encoding: a known id is kept');
  Expect('GBK', 'gbk', 'name encoding: id matching ignores case');
  Expect('', 'auto', 'name encoding: empty falls back to auto');
  Expect('klingon', 'auto', 'name encoding: unknown falls back to auto');
end;

{ --- missing and damaged files ------------------------------------------ }

{ --- language ids ------------------------------------------------------- }

procedure TestLanguageNormalization;
var
  Ini: TIniFile;
  S: TAppSettings;
  Path: string;

  procedure Expect(const AStored, AWant, AMsg: string);
  begin
    Path := Root + '/lang.ini';
    DeleteFile(Path);
    Ini := TIniFile.Create(Path);
    try
      Ini.WriteString('UI', 'Language', AStored);
    finally Ini.Free; end;
    S := LoadSettingsFromFile(Path);
    EqStr(S.Language, AWant, AMsg);
  end;

begin
  Expect('', LanguageSystem, 'language: empty follows the system');
  Expect('system', LanguageSystem, 'language: system is kept');
  Expect('en', LanguageEnglish, 'language: english is kept');
  Expect('EN', LanguageEnglish, 'language: id matching ignores case');
  Expect('zh_CN', LanguageChinese, 'language: chinese is kept');
  { A hand-edited or corrupt id would otherwise pin a language with no
    catalogue; "follow the OS" is the safe interpretation. }
  Expect('klingon', LanguageSystem, 'language: unknown falls back to system');
end;

{ --- pane widths -------------------------------------------------------- }

procedure TestWidthClamp;
var
  Ini: TIniFile;
  S: TAppSettings;
  Path: string;
begin
  { The INI file is user editable; a damaged or hand-edited width must not make
    the window unusable. }
  Path := Root + '/widths.ini';
  DeleteFile(Path);
  Ini := TIniFile.Create(Path);
  try
    Ini.WriteInteger('UI', 'SidebarWidth', -40);
    Ini.WriteInteger('UI', 'PreviewWidth', 100000);
  finally
    Ini.Free;
  end;
  S := LoadSettingsFromFile(Path);
  EqInt(S.SidebarWidth, 160, 'width: a negative sidebar is clamped');
  EqInt(S.PreviewWidth, 900, 'width: an absurd preview is clamped');
  EqInt(TzClampSidebarWidth(260), 260, 'width: an in-range sidebar is kept');
  EqInt(TzClampSidebarWidth(1000), 600, 'width: a too-wide sidebar is capped');
  EqInt(TzClampPreviewWidth(500), 500, 'width: an in-range preview is kept');
  EqInt(TzClampPreviewWidth(10), 160, 'width: a too-narrow preview is raised');
end;

procedure TestMissingFile;
var
  S: TAppSettings;
begin
  { A first run has no file at all. }
  S := LoadSettingsFromFile(Root + '/does-not-exist.ini');
  EqStr(S.ThemeName, 'default', 'missing: falls back to defaults');
  EqBool(S.ShowPreview, True, 'missing: default preview');
  { An empty path must not fault either. }
  S := LoadSettingsFromFile('');
  EqStr(S.ThemeName, 'default', 'missing: empty path gives defaults');
end;

procedure TestPartialFile;
var
  Ini: TIniFile;
  S: TAppSettings;
  Path: string;
begin
  { A file with only some keys: the rest keep their defaults rather than
    becoming zero. This is what happens after an upgrade adds a setting. }
  Path := Root + '/partial.ini';
  DeleteFile(Path);
  Ini := TIniFile.Create(Path);
  try
    Ini.WriteString('UI', 'Theme', 'solarized');
  finally Ini.Free; end;

  S := LoadSettingsFromFile(Path);
  EqStr(S.ThemeName, 'solarized', 'partial: the key that is there');
  EqStr(S.Mode, '', 'partial: absent mode keeps its default');
  EqBool(S.ConfirmDelete, True, 'partial: absent bool keeps its default');
  EqInt(S.SidebarWidth, 260, 'partial: absent int keeps its default');
end;

procedure TestGarbageFile;
var
  L: TStringList;
  S: TAppSettings;
  Path: string;
begin
  { A corrupt file must never stop the program from starting. }
  Path := Root + '/garbage.ini';
  L := TStringList.Create;
  try
    L.Text := 'this is not an ini file' + LineEnding + #0#1#2#3;
    L.SaveToFile(Path);
  finally L.Free; end;
  S := LoadSettingsFromFile(Path);
  EqStr(S.ThemeName, 'default', 'garbage: falls back to defaults');
end;

procedure TestRecentArchives;
var
  L, Back: TStringList;
  Path: string;
  I: Integer;
begin
  Path := Root + '/recent.ini';
  L := TStringList.Create;
  Back := TStringList.Create;
  try
    L.Add('/tmp/a.zip');
    L.Add('/tmp/b.7z');
    SaveRecentArchives(Path, L);
    Check(LoadRecentArchives(Path, Back), 'recent: load reports success');
    EqInt(Back.Count, 2, 'recent: count');
    EqStr(Back[0], '/tmp/a.zip', 'recent: newest first');
    EqStr(Back[1], '/tmp/b.7z', 'recent: second');
    { The welcome list is capped, and a longer old file must not leak keys. }
    L.Clear;
    for I := 0 to 14 do
      L.Add('/tmp/' + IntToStr(I) + '.zip');
    SaveRecentArchives(Path, L);
    LoadRecentArchives(Path, Back);
    EqInt(Back.Count, MaxRecentArchives, 'recent: capped');
    Check(not LoadRecentArchives(Root + '/missing-recent.ini', Back),
      'recent: missing file reports false');
    EqInt(Back.Count, 0, 'recent: missing file clears the list');
  finally
    L.Free;
    Back.Free;
  end;
  if FileExists(Path) then DeleteFile(Path);
end;

procedure TestUnwritablePath;
var
  S: TAppSettings;
begin
  { A read-only home must not raise: the caller keeps its in-memory copy. }
  S := DefaultSettings;
  Check(not SaveSettingsToFile('/proc/definitely-not-writable/x.ini', S),
    'unwritable: save reports failure instead of raising');
  Check(not SaveSettingsToFile('', S), 'unwritable: empty path reports failure');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-settings-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);

  TestDefaults;
  TestRoundTrip;
  TestNameEncodingNormalization;
  TestLanguageNormalization;
  TestWidthClamp;
  TestMissingFile;
  TestPartialFile;
  TestGarbageFile;
  TestUnwritablePath;
  TestRecentArchives;

  if FileExists(Root + '/roundtrip.ini') then DeleteFile(Root + '/roundtrip.ini');
  if FileExists(Root + '/partial.ini') then DeleteFile(Root + '/partial.ini');
  if FileExists(Root + '/garbage.ini') then DeleteFile(Root + '/garbage.ini');
  if FileExists(Root + '/lang.ini') then DeleteFile(Root + '/lang.ini');
  if FileExists(Root + '/widths.ini') then DeleteFile(Root + '/widths.ini');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
