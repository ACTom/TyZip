unit tzip.i18n;

{ Central UI strings and language selection state.

  English strings are the resource defaults.  A translation lives in a compiled
  .mo file (source in languages/tzip.zh_CN.po) next to the executable or
  in Contents/Resources/languages.  Installing it is the LCL's job and lives in
  tzip.i18n.lcl, so this unit stays usable from headless code and tests. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, IniFiles, FileUtil;

resourcestring
  { application / shell }
  rsAppName = 'TyZip';
  rsReady = 'Ready';
  rsFileMenu = 'File';
  rsEditMenu = 'Edit';
  rsGoMenu = 'Go';
  rsViewMenu = 'View';
  rsToolsMenu = 'Tools';
  rsHelpMenu = 'Help';
  rsMenuNew = 'New Archive…';
  rsMenuOpen = 'Open Archive…';
  rsMenuClose = 'Close Archive';
  rsMenuExtract = 'Extract…';
  rsMenuTest = 'Test Archive';
  rsMenuInfo = 'Archive Information';
  rsMenuExit = 'Exit';
  rsMenuSelectAll = 'Select All';
  rsMenuDelete = 'Delete';
  rsMenuAddFiles = 'Add Files…';
  rsMenuAddFolder = 'Add Folder…';
  rsMenuBack = 'Back';
  rsMenuForward = 'Forward';
  rsMenuUp = 'Enclosing Folder';
  rsMenuRefresh = 'Refresh';
  rsMenuShowHidden = 'Show Hidden Files';
  rsMenuSidebar = 'Sidebar';
  rsMenuPreview = 'Preview Pane';
  rsMenuSettings = 'Settings…';
  rsMenuLanguage = 'Language';
  rsMenuTheme = 'Theme';
  rsMenuAppearance = 'Appearance';
  rsMenuAbout = 'About TyZip';
  rsToolNew = 'New';
  rsToolOpen = 'Open';
  rsToolExtract = 'Extract';
  rsToolTest = 'Test';
  rsToolAdd = 'Add';
  rsToolDelete = 'Delete';
  rsToolConvert = 'Convert';
  rsToolInfo = 'Info';
  rsFilterHint = 'Filter by name…';
  rsPreviewTitle = 'Preview';
  rsPreviewShowHint = 'Show preview pane';
  rsPreviewHideHint = 'Hide preview pane';
  rsPreviewNoSelection = 'Select a file to preview';
  rsPreviewLoadingFmt = 'Loading preview of %s…';
  rsPreviewTruncated = '… preview truncated';
  rsPreviewNoPreviewFmt = 'No preview available for %s';
  rsPreviewTooLargeFmt = '%s is too large to preview';
  rsPreviewLoadErrorFmt = 'Cannot preview %s';
  rsPreviewWrap = 'Wrap';
  rsPreviewWrapHint = 'Wrap long lines';
  { The preview's language picker: its hint, and the "no highlighting" entry. }
  rsPreviewSyntaxHint = 'Syntax highlighting language';
  { Image viewer. }
  rsZoomFit = 'Fit';
  rsPreviewLoading = 'Loading…';
  rsPreviewLanguageNone = 'None';
  rsCtxExtract = 'Extract Selected…';
  rsCtxExtractAllTo = 'Extract All to…';
  rsCtxExtractAllHere = 'Extract All Here';
  rsCtxExtractEachToFolder = 'Extract Each to Its Own Folder';
  rsCtxTestAll = 'Test All Archives';
  rsCtxAddSelectedFmt = 'Add %d Items to Archive…';
  rsCtxRename = 'Rename…';
  rsCtxOpen = 'Open';
  rsCtxOpenWith = 'Open With';
  rsCtxOpenWithOther = 'Other…';
  rsCtxOpenAsArchive = 'Open as Archive';
  rsCtxExtractHere = 'Extract Here';
  rsCtxReveal = 'Show in Finder';
  rsCtxCopyPath = 'Copy Path';
  rsTypeFolder = 'Folder';
  rsTypeFile = 'File';
  rsStatusItemsFmt = '%d items  ·  %d selected  ·  %s';
  rsStatusArchiveFmt = '%s  ·  %d items  ·  %d selected  ·  %s  ·  %s';
  rsStatusEncrypted = 'encrypted';
  rsStatusCreatedFmt = 'Created %s';
  rsStatusExtractedFmt = 'Extracted %d item(s) to %s';
  rsStatusDeletedFmt = 'Deleted %d entries.';
  rsStatusAddedFmt = 'Added %d entries.';
  rsStatusFolderAdded = 'Folder added.';
  rsStatusCancelled = 'Operation cancelled.';
  rsStatusArchiveSuffixFmt = '%s — %s (%s)';
  rsStatusLoadingFolderFmt = 'Loading folder %s…';
  rsStatusUpdated = 'Archive updated.';
  rsBusyStillWorking = 'Still working — please wait…';
  { Empty-window hint on a plain launch: the folder view no longer opens by
    itself, so the window says what it wants. }
  rsStartupHint = 'Open or drop an archive';
  { The welcome screen's two buttons: choose an archive file, or a folder to
    browse in the file manager. }
  rsStartupBrowseFiles = 'Browse Files…';
  rsStartupBrowseFolder = 'Browse Folder…';
  rsStartupChooseFolder = 'Choose a folder to browse';
  rsRecentArchives = 'Recently opened';
  { Busy-overlay headings. The detail line below each one names the file. }
  rsBusyOpening = 'Opening archive — please wait…';
  rsBusyReading = 'Reading archive contents';
  rsBusySearching = 'Searching archive';
  rsBusyExtracting = 'Extracting';
  rsBusyTesting = 'Testing archive';
  rsBusyCreating = 'Creating archive';
  rsBusyUpdating = 'Updating archive';
  rsBusyUnpacking = 'Unpacking';
  rsColName = 'Name';
  rsColSize = 'Size';
  rsColPacked = 'Packed';
  rsColRatio = 'Ratio';
  rsColModified = 'Modified';
  rsColCreated = 'Created';
  rsColAccessed = 'Accessed';
  rsColAttributes = 'Attributes';
  rsColCRC = 'CRC';
  rsColMethod = 'Method';
  rsColEncrypted = 'Encrypted';
  rsColFolder = 'Folder';
  rsColType = 'Type';

  { dialogs }
  rsDlgPassword = 'Password';
  rsPasswordForFmt = 'Password for %s';
  { The prompt after an encrypted 7z entry failed to decode with the password
    the user just supplied. 7-Zip cannot distinguish a wrong password from
    corrupt ciphertext, so the wording says "wrong" without claiming certainty
    in the error box that follows a second failure. }
  rsPasswordWrongForFmt = 'Wrong password for %s. Try again:';
  rsDlgShowPassword = 'Show password';
  rsDlgOK = 'OK';
  rsDlgCancel = 'Cancel';
  rsDlgSave = 'Save';
  rsDlgChoose = 'Choose…';
  rsDlgExtract = 'Extract';
  rsDlgSearch = 'Find in Archive';
  rsMenuFind = 'Find in Archive…';
  rsMenuExtractAllSelected = 'Extract All Selected…';
  rsMenuClearSearch = 'Clear Search';
  rsDlgSearchQuery = 'Find:';
  rsDlgSearchWhere = 'Search in:';
  rsDlgSearchNames = 'Names';
  rsDlgSearchContent = 'Contents';
  rsDlgSearchBoth = 'Names and contents';
  rsDlgSearchMode = 'Match:';
  rsDlgSearchSubstring = 'Contains';
  rsDlgSearchWildcard = 'Wildcard (* and ?)';
  rsDlgSearchRegex = 'Regular expression';
  rsDlgSearchCase = 'Match case';
  rsStatusSearchNone = 'No matches found.';
  rsStatusSearchFmt = 'Found %d matches.';
  rsErrRenameFolderUnsupported = 'Folders cannot be renamed in place yet.';
  rsStatusRenamedFmt = 'Renamed to %s.';
  rsDlgComment = 'Archive Comment';
  rsDlgIconCache = 'Icon cache';
  rsDlgIconCacheNone = 'not in use';
  rsDlgIconCacheSizeFmt = '%s in %d files';
  rsDlgIconCacheClearedFmt = 'Removed %d cached icons.';
  rsDlgClearIconCache = 'Clear Icon Cache';
  rsErrNoArchivesSelected = 'No archives were selected.';
  rsBatchAllOkFmt = 'All %d archives were processed successfully.';
  rsBatchSomeFailedFmt = '%d archives processed: %d succeeded, %d failed.';
  rsBatchMoreFmt = '…and %d more.';
  rsStatusBatchDoneFmt = 'Batch finished: %d archives.';
  rsCtxCreateArchive = 'Add to Archive…';
  rsCtxCreateHereFmt = 'Add to %s';
  rsCtxCreateEach = 'Add Each to a Separate Archive';
  rsCtxConvert = 'Convert to Another Format…';
  rsStatusBatchSkippedFmt = '%d item(s) skipped: not an archive.';
  rsDlgConvertTitle = 'Convert Archive';
  rsErrConvertSameFile = 'The converted archive needs a different name from the original.';
  rsErrNoConvertTarget = 'There is no other format this archive can be converted to.';
  rsErrConvertFailed = 'The conversion failed:';
  rsStatusConvertedFmt = 'Converted to %s.';
  rsBusyConverting = 'Converting…';
  rsMenuConvert = 'Convert to Another Format…';
  rsStatusCommentSaved = 'Archive comment saved.';
  rsDlgCommentPrompt = 'Comment stored in the archive:';
  rsDlgClose = 'Close';
  rsMenuComment = 'Archive Comment…';
  rsConfirmWriteBackFmt = '"%s" was changed. Write the new version back into the archive?';
  rsStatusWrittenBackFmt = 'Updated %s in the archive.';
  rsDlgRename = 'Rename Entry';
  rsDlgRenamePrompt = 'New name:';
  rsDlgPreset = 'Preset:';
  rsDlgPresetNone = '(none)';
  rsErrPresetSlotsFull = 'There is no room for another preset. Delete one first.';
  rsDlgSavePreset = 'Save as preset…';
  rsDlgPresetName = 'Name for this preset:';
  rsDlgPresetSavedFmt = 'Preset "%s" saved.';
  rsDlgQuickDest = 'Where:';
  rsDlgSmartFolder = 'Extract into a folder named after the archive';
  rsDlgOnConflict = 'If a file exists:';
  rsDlgConflictOverwrite = 'Overwrite';
  rsDlgConflictSkip = 'Skip';
  rsDlgConflictRename = 'Keep both';
  rsDlgDeleteArchiveAfter = 'Delete the archive after extracting';
  rsDlgExtractTitle = 'Extract';
  rsDlgExtractToFmt = 'Extract %d item(s) to:';
  rsDlgPasswordOptional = 'Password (leave empty if the archive is not encrypted):';
  rsDlgOpenAfter = 'Open destination folder when finished';
  rsDlgChooseDest = 'Choose a destination folder';
  rsDlgNewArchive = 'New Archive';
  rsDlgArchivePath = 'Archive path:';
  rsDlgFormat = 'Format:';
  rsDlgLevel = 'Compression level:';
  rsDlgMethod = 'Method:';
  rsDlgThreads = 'Threads:';
  { Create-archive dialog, tabbed layout. These live here rather than in
    tzip.dialogs so the .po packs can translate them; a resourcestring declared
    in a unit outside the translation scan stays English forever. }
  { Dialog labels that used to live in tzip.dialogs: a resourcestring outside
    the translation scan is never translated, which is why the level names and
    method names stayed English. }
  rsDlgSaveAs = 'Save archive as';
  rsDlgLevelStore = 'Store';
  rsDlgLevelFastest = 'Fastest';
  rsDlgLevelFast = 'Fast';
  rsDlgLevelNormal = 'Normal';
  rsDlgLevelMaximum = 'Maximum';
  rsDlgLevelUltra = 'Ultra';
  rsDlgMethodDefault = 'Default';
  rsDlgInfoCountsFmt = '%d  (%d files, %d folders)';
  rsDlgTabGeneral = 'General';
  rsDlgTabEncrypt = 'Encryption';
  rsDlgTabAdvanced = 'Advanced';
  rsDlgTabOptions = 'Options';
  rsDlgDeleteAfter = 'Delete source files after archiving';
  rsStatusDeleteSomeFailedFmt = 'Archive created; %d source item(s) could not be deleted';
  rsDlgPassword2 = 'Confirm password:';
  rsDlgAES256 = 'AES-256 encryption (zip)';
  rsDlgCodepage = 'Name encoding:';
  rsDlgCpAuto = 'Auto (UTF-8)';
  rsDlgCpUtf8 = 'UTF-8';
  rsDlgCpGbk = 'GBK (Chinese Windows)';
  rsDlgCpGb18030 = 'GB18030';
  rsDlgCpShiftJis = 'Shift-JIS (Japanese)';
  rsDlgCpLatin1 = 'Latin-1 (Western)';
  rsDlgEncryptNote = 'Encryption is available for 7z and zip only.';
  rsDlgCpNote = 'Affects non-ASCII entry names. Tools on other systems must use the same one.';
  rsDlgDictSize = 'Dictionary:';
  rsDlgMatchFinder = 'Match finder:';
  rsDlgWordSize = 'Word size:';
  rsDlgPasses = 'Passes:';
  rsDlgThreadsAuto = '(0 = all cores)';
  rsDlgMemEstimateFmt = 'Estimated RAM needed: %s (this machine has %s)';
  rsDlgMemNeedFmt = 'Estimated RAM needed: %s';
  rsDlgMemTooMuchFmt = 'Warning: this needs %s of RAM, but only %s is installed';
  rsDlgExtraLabel = 'Extra parameters:';
  rsDlgExtraHint = 'Leave this empty unless you know exactly what to put here.' +
    LineEnding + 'Advanced 7-Zip switches only; the fields above already cover the common ones.';
  rsDlgPasswordLabel = 'Password:';
  rsDlgSolid = 'Solid block';
  rsDlgEncryptNames = 'Encrypt file names (7z)';
  rsDlgSplitVolume = 'Split volume:';
  rsDlgSingleFile = 'Single file';
  rsDlgSettings = 'Settings';
  rsDlgTheme = 'Theme:';
  rsDlgMode = 'Appearance:';
  rsDlgSystemDefault = 'System default';
  rsDlgLight = 'Light';
  rsDlgDark = 'Dark';
  rsDlgLanguage = 'Language:';
  rsDlgLanguageRestart = 'Language changes take effect after TyZip is restarted.';
  rsDlgShowHidden = 'Show hidden files';
  rsDlgFoldersFirst = 'Folders first';
  rsDlgConfirmDelete = 'Confirm before deleting archive entries';
  rsDlgOpenAfterExtract = 'Open destination after extraction';
  rsDlgDefaultExtractDir = 'Default extraction folder:';
  rsDlgChooseDefaultExtract = 'Choose default extraction folder';
  rsDlgArchiveInfo = 'Archive Information';
  { The version comes from the bundle (see tzip.platform.TzAppVersion): one %
    placeholder, filled by the About box, so no source file names a version. }
  rsDlgAboutText = 'TyZip %s' + LineEnding + LineEnding +
    'A TyControls archive manager for macOS.' + LineEnding +
    'Archive engine: official 7-Zip 26.03 dynamic library' + LineEnding +
    'Built with Lazarus / Free Pascal.';
  rsDlgExtracting = 'Extracting';
  rsDlgCancelling = 'Cancelling…';
  rsDlgPause = 'Pause';
  rsDlgResume = 'Resume';
  rsDlgPaused = 'Paused';
  rsDlgPhaseOpen = 'Opening';
  rsDlgPhaseExtract = 'Extracting';
  rsDlgPhaseCreate = 'Compressing';
  rsDlgPhaseTest = 'Testing';
  rsDlgPhaseCurrentFmt = '%s · %s';
  rsDlgProgressFmt = '%s / %s  (%d%%)';
  { Opening has no byte total until the index exists; it counts entries. }
  rsDlgProgressItemsFmt = '%d / %d items  (%d%%)';
  rsDlgElapsedFmt = 'Elapsed %s';
  rsDlgRemainingFmt = 'Remaining %s';
  rsDlgRemainingUnknown = 'Remaining —';
  rsDlgTotalSizeFmt = 'Total %s';
  rsDlgSpeedFmt = 'Speed %s/s';
  rsDlgItemsTotalFmt = 'Entries %d';
  rsDlgItemsRateFmt = 'Speed %d items/s';
  rsDlgFilesFmt = 'Files %d / %d';
  rsDlgPackedFmt = 'Compressed %s';
  rsDlgPackedRatioFmt = 'Compressed %s (%d%%)';
  rsDlgCurrentFileFmt = 'Current %s';

  { errors }
  rsErrEngineMissing = 'The TyZip engine library (libtz7z.dylib) could not be loaded.' + LineEnding +
    'Build the backend first, or set TYZIP_LIB to its full path.';
  rsErrFolderNotFoundFmt = 'Folder not found: %s';
  rsErrCannotOpenArchive = 'Cannot open archive:';
  rsErrCannotExtractNested = 'Cannot extract nested archive:';
  rsErrNoAppForFile = 'No application is associated with:';
  rsDlgChooseApp = 'Choose an Application';
  { Filter syntax: <description>|<pattern>|<description>|<pattern>... }
  rsAppBundleFilter = 'Applications (*.app)|*.app|All files|*';
  rsErrSelectFilesFirst = 'Select one or more files or folders first.';
  rsErrNothingToCompress = 'Nothing to compress.';
  rsErrReplaceFmt = 'A file named %s already exists. Replace it?';
  rsErrCreateFailed = 'Could not create the archive:';
  rsErrExtractionFailed = 'Extraction failed:';
  { 7-Zip cannot distinguish a wrong password from corrupt data, so both the
    test command and a failed encrypted extraction use this honest wording. }
  rsErrArchiveDamagedOrWrongPassword = 'The archive is damaged or the password is wrong:';
  rsErrUpdateFailed = 'Could not update the archive:';
  rsErrReopenFailed = 'Could not reopen the archive:';
  rsErrNestedReadOnly = 'This is a nested archive inside another archive. Open the outer archive to modify it.';
  rsErrSplitArchiveReadOnly = 'This archive is split across several volumes and cannot be modified in place. Extract it first, then create a new archive.';
  rsErrFormatNoUpdate = 'This archive format cannot be updated.';
  { Removing the archive after a successful extraction failed. }
  rsErrDeleteArchiveFmt = 'The archive could not be deleted: %s';
  { Every selected entry was skipped by the destination conflict policy. }
  rsStatusNothingToExtract = 'Nothing was extracted: every selected item already exists in the destination.';
  { Generic engine error classes: the model layer maps an ABI error code to one
    of these, so the wording lives in the translation catalogs, not in C++. }
  rsErrOk = 'OK';
  rsErrArgument = 'Invalid argument.';
  rsErrMemory = 'Out of memory.';
  rsErrOpen = 'Cannot open the archive.';
  rsErrNotArchive = 'This file is not a supported archive.';
  rsErrPassword = 'The password is wrong or missing.';
  rsErrFormat = 'Unsupported archive format.';
  rsErrUpdate = 'Updating the archive failed.';
  rsErrExtract = 'Extracting the archive failed.';
  rsErrCancel = 'Operation cancelled.';
  rsErrIO = 'File I/O error.';
  rsErrUnsupported = 'Operation not supported.';
  rsErrUnknownFmt = 'Unknown error (%d).';
  { Finder Services return these as their progress sentence. }
  rsSvcCompressingFmt = 'Compressing %d item(s)…';
  rsSvcCompressing = 'Compressing…';
  rsSvcExtractingFmt = 'Extracting %d archive(s)…';
  rsSvcExtracting = 'Extracting…';
  rsErrSelectDelete = 'Select one or more entries to delete.';
  rsErrArchiveOnlyInFiles = 'Open a Finder folder first. Creating an archive from entries inside another archive is not supported yet.';
  rsInfoTestDoneFmt = 'Test complete. %d item(s) verified.';
  rsConfirmDeleteFmt = 'Delete %d selected entr(ies) from the archive?';
  rsOpenArchiveTitle = 'Open Archive';
  rsAddFilesTitle = 'Add Files to Archive';
  { Externally opened paths that cannot be shown as an archive. }
  rsErrUnsupportedFormatFmt = '"%s" is not a format TyZip can open.';
  rsErrFileNotFoundFmt = '"%s" no longer exists.';
  { Dropping files onto an open archive. }
  rsDropAddConfirmFmt = 'Add %d item(s) to "%s"?'#13#10#13#10'%s';
  rsDropAddMoreFmt = '… and %d more';
  rsDropConflictFmt =
    'These files already exist in the archive:'#13#10#13#10'%s'#13#10#13#10 +
    'Replace them, or skip the ones that already exist?';
  rsAddFolderTitle = 'Add Folder to Archive';
  rsArchiveFilter = 'Archives (*.7z;*.zip;*.rar;*.tar;*.gz;*.tgz;*.bz2;*.xz;*.dmg)|*.7z;*.zip;*.rar;*.tar;*.gz;*.tgz;*.bz2;*.xz;*.dmg;*.cab;*.iso|All files (*.*)|*.*';
  rsAllFilesFilter = 'All files (*.*)|*.*';
  rsInfoName = 'Name:';
  rsInfoSource = 'Source:';
  rsInfoFormat = 'Format:';
  rsInfoEntries = 'Entries:';
  rsInfoUnpacked = 'Unpacked size:';
  rsInfoPacked = 'Packed size:';
  rsInfoRatio = 'Ratio:';
  rsInfoEncrypted = 'Encrypted:';
  rsInfoCanUpdate = 'Can update:';
  rsInfoNested = 'Nested:';
  rsInfoOpenedFrom = 'Opened from:';
  rsInfoChain = 'Archive chain:';
  rsYes = 'yes';
  rsNo = 'no';

const
  { Language IDs stored in TyZip.ini.  'system' means the OS locale. }
  LanguageSystem = 'system';
  LanguageEnglish = 'en';
  LanguageChinese = 'zh_CN';

{ Locate the languages/ directory for a development build or an .app bundle. }
function TzLanguagesDir: string;
{ ~/.config/TyZip/ -- settings, icon cache. Deliberately NOT derived from the
  application name, which a language pack can translate (see the body). }
function TzConfigDir: string;
{ Read the configured language from TyZip.ini. }
function TzConfiguredLanguage: string;
{ Installing the pack needs the LCL and lives in tzip.i18n.lcl. }
{ Language ids offered in Settings. }
procedure TzLanguageChoices(ANames, AIds: TStrings);

implementation

{ The settings and icon-cache folder. FPC builds GetAppConfigDir from the
  application NAME, and that name comes from rsAppName -- which a .po pack can
  translate. A pack that translated "TyZip" therefore moved the whole settings
  folder to a translated name (a Chinese build once stored everything under
  ".../.config/确认/"), and switching language moved it again. The folder is
  derived from a fixed literal here so it never depends on a translation. }
function TzConfigDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetUserDir) + '.config/TyZip/';
end;

{ One-time move of the folder a translated app name created. Nothing is deleted:
  the old folder keeps whatever could not be moved, so a failed move is visible
  rather than silent. }
procedure MigrateLegacyConfigDir;
var
  Legacy: string;
begin
  { The name a Chinese pack produced before the app name was pinned. Only that
    one is known to have shipped; anything else is left alone. }
  Legacy := IncludeTrailingPathDelimiter(GetUserDir) + '.config/' + #$E7#$A1#$AE#$E8#$AE#$A4 + PathDelim;
  if not DirectoryExists(Legacy) then Exit;
  if FileExists(Legacy + 'TyZip.ini') and not FileExists(TzConfigDir + 'TyZip.ini') then
  begin
    if not DirectoryExists(TzConfigDir) then
      if not ForceDirectories(TzConfigDir) then Exit;
    CopyFile(Legacy + 'TyZip.ini', TzConfigDir + 'TyZip.ini');
  end;
  if DirectoryExists(Legacy + 'iconcache') and
     not DirectoryExists(TzConfigDir + 'iconcache') then
  begin
    if not DirectoryExists(TzConfigDir) then
      if not ForceDirectories(TzConfigDir) then Exit;
    { The cache is rebuildable, so a best-effort copy is enough. }
    RenameFile(Legacy + 'iconcache', TzConfigDir + 'iconcache');
  end;
end;

function ConfigIniPath: string;
begin
  Result := TzConfigDir + 'TyZip.ini';
end;

var
  GMigrated: Boolean = False;

function TzConfiguredLanguage: string;
var
  Ini: TIniFile;
begin
  if not GMigrated then
  begin
    GMigrated := True;
    MigrateLegacyConfigDir;
  end;
  { Default to the SYSTEM language, not to English. A first run used to pin
    English no matter what the OS was set to, while the Settings dialog already
    offered "System default" as the first choice -- the default simply did not
    match it. LanguageSystem flows into SetDefaultLang(''), which is LCL asking
    the OS. }
  Result := LanguageSystem;
  if not FileExists(ConfigIniPath) then Exit;
  Ini := TIniFile.Create(ConfigIniPath);
  try
    Result := Ini.ReadString('UI', 'Language', LanguageSystem);
  finally
    Ini.Free;
  end;
  if Result = '' then Result := LanguageSystem;
end;

function TzLanguagesDir: string;
var
  Dir: string;
  I: Integer;
begin
  Result := '';
  Dir := ExtractFilePath(ExpandFileName(ParamStr(0)));
  for I := 1 to 6 do
  begin
    if DirectoryExists(Dir + 'languages') then
      Exit(IncludeTrailingPathDelimiter(Dir + 'languages'));
    if DirectoryExists(Dir + 'Resources' + PathDelim + 'languages') then
      Exit(IncludeTrailingPathDelimiter(Dir + 'Resources' + PathDelim + 'languages'));
    if DirectoryExists(Dir + '..' + PathDelim + 'Resources' + PathDelim + 'languages') then
      Exit(IncludeTrailingPathDelimiter(Dir + '..' + PathDelim + 'Resources' + PathDelim + 'languages'));
    if DirectoryExists(Dir + '..' + PathDelim + 'languages') then
      Exit(IncludeTrailingPathDelimiter(Dir + '..' + PathDelim + 'languages'));
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    if Dir = '' then Break;
  end;
  if DirectoryExists('languages') then
    Result := IncludeTrailingPathDelimiter(ExpandFileName('languages'));
end;

procedure TzLanguageChoices(ANames, AIds: TStrings);
begin
  if ANames = nil then Exit;
  ANames.Clear;
  ANames.Add(rsDlgSystemDefault);
  ANames.Add('English');
  ANames.Add('简体中文');
  if AIds <> nil then
  begin
    AIds.Clear; AIds.Add(LanguageSystem); AIds.Add(LanguageEnglish); AIds.Add(LanguageChinese);
  end;
end;

end.
