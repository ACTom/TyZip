unit tzip.dialogs;
{ Modal dialogs used by TyZip.

  Every dialog here is a TTyDialog: the themed title bar and the bottom button bar
  come from TyControls, and the content lives inside an alClient TTyPanel.  No LCL
  native dialog or message box is used. The values behind the controls -- format
  capabilities, extensions, the combo tables and the settings merge -- live in
  tzip.createopts so they can be tested without a window. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, LCLType, Dialogs, ExtCtrls,
  tyControls.Controller, tyControls.BuiltinThemes, tyControls.Form,
  tyControls.Panel, tyControls.TyLabel, tyControls.Edit,
  tyControls.ComboBox, tyControls.CheckBox, tyControls.SpinEdit,
  tyControls.Memo,
  tyControls.PageControl, tyControls.TabSheet,
  tzip.platform,
  tyControls.Dialogs, tyControls.Dialogs.SelectPath,
  tyControls.Dialogs.FileDialog,
  tzip.i18n, tzip.api, tzip.engine,
  tzip.ui.dialogkit, tzip.ui.scrollguard, tzip.settings, tzip.extract, tzip.presets, tzip.search,
  tzip.ui.icons, tzip.createopts;

type

  { Every TyZip dialog is a Cocoa form too: keep its native scroll view from
    shifting the dialog content on a wheel tick (see tzip.ui.scrollguard). }
  TZipDialog = class(TTyDialog)
  private
    FScrollGuardTimer: TTimer;
    procedure ScrollGuardTick(Sender: TObject);
  protected
    procedure DoShow; override;
    procedure DoHide; override;
  public
    destructor Destroy; override;
  end;

  { Password prompt. }
  TPasswordForm = class(TZipDialog)
  private
    FEdit: TTyEdit;
    FShow: TTyCheckBox;
    procedure ShowChange(Sender: TObject);
    function GetPassword: string;
  public
    constructor Create(AOwner: TComponent; const APrompt, APassword: string); reintroduce;
    property Password: string read GetPassword;
  end;


  { A single-line text prompt. The widgetsets' own InputQuery is an LCL native
    dialog, and this program does not use those: every dialog is a TTyDialog so
    it inherits the theme. }
  TTextPromptForm = class(TZipDialog)
  private
    FEdit: TTyEdit;
  public
    constructor Create(AOwner: TComponent; const ACaption, APrompt,
      ADefault: string); reintroduce;
    function Text: string;
  end;

  { Edit the archive's own comment (not an entry's). }
  TCommentDialogForm = class(TZipDialog)
  private
    FMemo: TTyMemo;
  public
    constructor Create(AOwner: TComponent; const AComment: string;
      AReadOnly: Boolean); reintroduce;
    function Comment: string;
  end;

  { Archive search dialog: the query, where to look, how to match. }
  TSearchDialogForm = class(TZipDialog)
  private
    FQuery: TTyEdit;
    FScope: TTyComboBox;
    FMode: TTyComboBox;
    FCase: TTyCheckBox;
    function GetOptions: TSearchOptions;
  public
    constructor Create(AOwner: TComponent; const AOptions: TSearchOptions); reintroduce;
    property Options: TSearchOptions read GetOptions;
  end;

  { What the extract dialog collects. Destination resolution and conflict
    naming happen in tzip.extract; this only gathers the choices. }
  TExtractDialogForm = class(TZipDialog)
  private
    FDest: TTyEdit;
    FPw: TTyEdit;
    FOpenAfter: TTyCheckBox;
    FDeleteAfter: TTyCheckBox;
    FSmartFolder: TTyCheckBox;
    FSmartExtract: TTyCheckBox;
    FPartial: Boolean;
    FConflict: TTyComboBox;
    FQuick: TTyComboBox;
    procedure BrowseClick(Sender: TObject);
    procedure QuickChange(Sender: TObject);
    procedure ModeChange(Sender: TObject);
    function GetOptions: TExtractOptions;
  public
    constructor Create(AOwner: TComponent;
      ACount: Integer; const ADefaultDest: string;
      ANeedsPassword, APartial: Boolean); reintroduce;
    property Options: TExtractOptions read GetOptions;
  end;

  { The create-archive dialog, laid out like WinRAR's: the settings that nearly
    everyone touches live on the first tab, and the rest sit behind tabs that only
    interested users open. Which controls appear at all depends on the format --
    a gzip stream has no solid mode or AES, tar has no compression at all -- so
    unavailable options are hidden rather than shown greyed out. }
  TNewArchiveDialog = class(TZipDialog)
  private
    { Presets are loaded once and applied by the combo at the top of the dialog.
      Empty means the feature is off (no settings file yet). }
    FPresets: TArchivePresetArray;
    FPreset: TTyComboBox;
    FPath: TTyEdit;
    FFormat: TTyComboBox;
    FMethod: TTyComboBox;
    FLevel: TTyComboBox;
    FThreads: TTySpinEdit;
    FSolid: TTyCheckBox;
    FDict: TTyComboBox;
    FWordSize: TTyComboBox;
    FMatchFinder: TTyComboBox;
    FPasses: TTySpinEdit;
    FMemLabel: TTyLabel;
    FVolume: TTyComboBox;
    FPassword: TTyEdit;
    FPassword2: TTyEdit;
    FShowPassword: TTyCheckBox;
    FAES: TTyCheckBox;
    FEncryptNames: TTyCheckBox;
    FCodepage: TTyComboBox;
    FDeleteAfter: TTyCheckBox;
    FExtra: TTyEdit;
    FSourceCount: Integer;
    FLblDict: TTyLabel;
    FLblWord: TTyLabel;
    FLblMatch: TTyLabel;
    FLblPasses: TTyLabel;
    FLblMethod: TTyLabel;
    FLblLevel: TTyLabel;
    FLblVolume: TTyLabel;
    FLblCodepage: TTyLabel;
    FLblCpNote: TTyLabel;
    FLblThreads: TTyLabel;
    FLblThreadsAuto: TTyLabel;
    FChkSolid: TTyCheckBox;
    procedure BrowseClick(Sender: TObject);
    procedure FormatChange(Sender: TObject);
    procedure PasswordChange(Sender: TObject);
    procedure ShowPasswordChange(Sender: TObject);
    procedure MethodChange(Sender: TObject);
    procedure UpdateFormatControls;
    procedure UpdateMemoryLabel;
    function GetPath: string;
    function CurrentFormat: string;
    procedure ApplyFormatSuffix;
    procedure PresetChange(Sender: TObject);
    procedure RefreshPresetCombo;
    procedure SavePresetClick(Sender: TObject);
  public
    { Push a settings record into every control. Public because conversion uses
      it to carry the source archive's level and format into the dialog.
      APassword is separate on purpose: presets never store one, but a
      conversion must not silently drop an archive's protection. }
    procedure ApplyPreset(const APreset: TArchivePreset;
      const APassword: string = '');
    constructor Create(AOwner: TComponent; ASourceCount: Integer;
      const ADefaultPath, ADefaultFormat: string); reintroduce;
    property ArchivePath: string read GetPath;
    function Settings: TCreateSettings;
  end;

  TSettingsForm = class(TZipDialog)
  private
    { The record the dialog was opened with. The dialog only edits a subset of
      it; GetSettings merges that subset back onto this so fields the main form
      owns (pane widths and visibility, last archive format) survive a save. }
    FBase: TAppSettings;
    FTheme: TTyComboBox;
    FMode: TTyComboBox;
    FLanguage: TTyComboBox;
    FLanguageIds: TStringList;
    FHidden: TTyCheckBox;
    FFoldersFirst: TTyCheckBox;
    FConfirm: TTyCheckBox;
    FOpenAfter: TTyCheckBox;
    FExtractDir: TTyEdit;
    { Icon cache maintenance: the size is shown next to the button so a user can
      see what clearing it would reclaim. }
    FCacheLabel: TTyLabel;
    FCacheDir: string;
    procedure BrowseClick(Sender: TObject);
    procedure ClearCacheClick(Sender: TObject);
    procedure UpdateCacheLabel;
  public
    constructor Create(AOwner: TComponent; const ASettings: TAppSettings;
      const AIconCacheDir: string); reintroduce;
    destructor Destroy; override;
    function GetSettings: TAppSettings;
  end;

function AskPassword(AOwner: TForm; const APrompt: string; var APassword: string): Boolean;

function ShowExtractDialog(AOwner: TForm;
  ACount: Integer; const ADefaultDest: string; ANeedsPassword, APartial: Boolean;
  out AOptions: TExtractOptions): Boolean;

{ The Finder smart service has no conflict policy of its own: when files from
  the archive already exist in the destination, ask once for that archive.
  ecAsk means the user cancelled the whole batch. }
function ShowSmartConflictDialog(AOwner: TForm;
  const AArchiveName, ADest: string): TExtractConflict;

{ The create dialog. ASeed may carry settings the caller wants pre-filled --
  conversion uses it to keep the source archive's password and level, which the
  user would otherwise have to retype for every conversion. }
function ShowNewArchiveDialog(AOwner: TForm; ASourceCount: Integer;
  const ADefaultPath, ADefaultFormat: string;
  out APath: string; out ASettings: TCreateSettings;
  const ASeed: TCreateSettings; AConverting: Boolean): Boolean;
function ShowSettingsDialog(AOwner: TForm; const ASettings: TAppSettings;
  const AIconCacheDir: string; out ANew: TAppSettings): Boolean;
procedure ShowArchiveInfo(AOwner: TForm; ACtx: TArchiveContext);

{ Edit an archive comment. False when cancelled. AReadOnly shows it but offers
  no way to change it, for archives that cannot store one. }
function ShowCommentDialog(AOwner: TForm; const AComment: string;
  AReadOnly: Boolean; out ANewComment: string): Boolean;

{ Fill AOptions from the user. False when cancelled. }
function ShowSearchDialog(AOwner: TForm; var AOptions: TSearchOptions): Boolean;

{ Ask for one line of text. False when the user cancelled. }
function PromptForText(AOwner: TComponent; const ACaption, APrompt,
  ADefault: string; out AText: string): Boolean;

implementation

procedure TZipDialog.ScrollGuardTick(Sender: TObject);
begin
  TzGuardFormScroll(Self);
end;

procedure TZipDialog.DoShow;
begin
  inherited DoShow;
  TzGuardFormScroll(Self);
  if FScrollGuardTimer = nil then
  begin
    FScrollGuardTimer := TTimer.Create(Self);
    FScrollGuardTimer.Interval := 100;
    FScrollGuardTimer.OnTimer := @ScrollGuardTick;
  end;
  FScrollGuardTimer.Enabled := True;
end;

procedure TZipDialog.DoHide;
begin
  if FScrollGuardTimer <> nil then FScrollGuardTimer.Enabled := False;
  inherited DoHide;
end;

destructor TZipDialog.Destroy;
begin
  TzUnguardFormScroll(Self);
  FScrollGuardTimer.Free;
  inherited Destroy;
end;

function ShowCommentDialog(AOwner: TForm; const AComment: string;
  AReadOnly: Boolean; out ANewComment: string): Boolean;
var
  D: TCommentDialogForm;
begin
  ANewComment := AComment;
  D := TCommentDialogForm.Create(AOwner, AComment, AReadOnly);
  try
    Result := D.ShowModal = mrOk;
    if Result then ANewComment := D.Comment;
  finally
    D.Free;
  end;
end;



{ ---------------------------------------------------------------------------
  Password
  --------------------------------------------------------------------------- }

constructor TPasswordForm.Create(AOwner: TComponent; const APrompt, APassword: string);
var
  Body: TTyPanel;
  Pad, CW: Integer;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := rsDlgPassword;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(360);

  Body := NewBody(Self);
  NewLabel(Body, APrompt, Pad, Pad, CW, Px(40)).WordWrap := True;
  FEdit := NewEdit(Body, Pad, Pad + Px(48), CW, Px(cEditH));
  FEdit.PasswordChar := '*';
  FEdit.Text := APassword;
  FShow := NewCheckBox(Body, rsDlgShowPassword, Pad, Pad + Px(84),
    Px(220), Px(cCheckH));
  FShow.OnChange := @ShowChange;

  AddButton(rsDlgOK, mrOk, True, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Pad + Px(108));

  ActiveControl := FEdit;
  FEdit.SelectAll;
end;

procedure TPasswordForm.ShowChange(Sender: TObject);
begin
  if FShow.Checked then FEdit.PasswordChar := '' else FEdit.PasswordChar := '*';
end;

function TPasswordForm.GetPassword: string;
begin
  Result := FEdit.Text;
end;

function AskPassword(AOwner: TForm; const APrompt: string; var APassword: string): Boolean;
var
  D: TPasswordForm;
begin
  D := TPasswordForm.Create(AOwner, APrompt, APassword);
  try
    Result := D.ShowModal = mrOk;
    if Result then APassword := D.Password;
  finally
    D.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Comment
  --------------------------------------------------------------------------- }

constructor TCommentDialogForm.Create(AOwner: TComponent;
  const AComment: string; AReadOnly: Boolean);
var
  Body: TTyPanel;
  Pad, CW: Integer;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := rsDlgComment;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(460);
  Body := NewBody(Self);
  NewLabel(Body, rsDlgCommentPrompt, Pad, Pad, CW, Px(cLabelH));
  FMemo := TTyMemo.Create(Self);
  FMemo.Parent := Body;
  FMemo.Left := Pad;
  FMemo.Top := Pad + Px(22);
  FMemo.Width := CW;
  FMemo.Height := Px(180);
  FMemo.Text := AComment;
  FMemo.ReadOnly := AReadOnly;
  if AReadOnly then
    AddButton(rsDlgClose, mrOk, True, False)
  else
  begin
    AddButton(rsDlgOK, mrOk, True, False);
    AddButton(rsDlgCancel, mrCancel, False, True);
  end;
  AutoSizeToContent(CW, Pad + Px(22) + Px(180) + Px(16));
  if not AReadOnly then ActiveControl := FMemo;
end;

function TCommentDialogForm.Comment: string;
begin
  Result := FMemo.Text;
end;

{ ---------------------------------------------------------------------------
  Search and prompts
  --------------------------------------------------------------------------- }

constructor TSearchDialogForm.Create(AOwner: TComponent;
  const AOptions: TSearchOptions);
var
  Body: TTyPanel;
  Pad, CW, Y: Integer;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := rsDlgSearch;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(420);

  Body := NewBody(Self);
  NewLabel(Body, rsDlgSearchQuery, Pad, Pad, CW, Px(cLabelH));
  FQuery := NewEdit(Body, Pad, Pad + Px(22), CW, Px(cEditH));
  FQuery.Text := AOptions.Query;
  Y := Pad + Px(62);

  NewLabel(Body, rsDlgSearchWhere, Pad, Y, Px(110), Px(cLabelH));
  FScope := NewCombo(Body, Pad + Px(110), Y - Px(4), Px(200), Px(cComboH));
  FScope.Items.Add(rsDlgSearchNames);
  FScope.Items.Add(rsDlgSearchContent);
  FScope.Items.Add(rsDlgSearchBoth);
  case AOptions.Scope of
    ssContent: FScope.ItemIndex := 1;
    ssBoth: FScope.ItemIndex := 2;
  else
    FScope.ItemIndex := 0;
  end;
  Y := Y + Px(36);

  NewLabel(Body, rsDlgSearchMode, Pad, Y, Px(110), Px(cLabelH));
  FMode := NewCombo(Body, Pad + Px(110), Y - Px(4), Px(200), Px(cComboH));
  FMode.Items.Add(rsDlgSearchSubstring);
  FMode.Items.Add(rsDlgSearchWildcard);
  FMode.Items.Add(rsDlgSearchRegex);
  case AOptions.Mode of
    smWildcard: FMode.ItemIndex := 1;
    smRegex: FMode.ItemIndex := 2;
  else
    FMode.ItemIndex := 0;
  end;
  Y := Y + Px(38);

  FCase := NewCheckBox(Body, rsDlgSearchCase, Pad, Y, Px(200), Px(cCheckH));
  FCase.Checked := AOptions.CaseSensitive;
  Y := Y + Px(cCheckH);

  AddButton(rsDlgSearch, mrOk, True, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Y + Px(8));
  ActiveControl := FQuery;
end;

function TSearchDialogForm.GetOptions: TSearchOptions;
begin
  Result := Default(TSearchOptions);
  Result.Query := Trim(FQuery.Text);
  case FScope.ItemIndex of
    1: Result.Scope := ssContent;
    2: Result.Scope := ssBoth;
  else
    Result.Scope := ssName;
  end;
  case FMode.ItemIndex of
    1: Result.Mode := smWildcard;
    2: Result.Mode := smRegex;
  else
    Result.Mode := smSubstring;
  end;
  Result.CaseSensitive := FCase.Checked;
  { The default limit from the search unit, not a zero meaning "no limit". }
  Result.MaxContentBytes := DefaultSearchOptions('').MaxContentBytes;
end;

constructor TTextPromptForm.Create(AOwner: TComponent; const ACaption, APrompt,
  ADefault: string);
var
  Body: TTyPanel;
  Pad, CW: Integer;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := ACaption;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(360);
  Body := NewBody(Self);
  NewLabel(Body, APrompt, Pad, Pad, CW, Px(cLabelH));
  FEdit := NewEdit(Body, Pad, Pad + Px(24), CW, Px(cEditH));
  FEdit.Text := ADefault;
  AddButton(rsDlgOK, mrOk, True, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Pad + Px(24) + Px(cEditH) + Px(16));
  ActiveControl := FEdit;
end;

function TTextPromptForm.Text: string;
begin
  Result := FEdit.Text;
end;

function ShowSearchDialog(AOwner: TForm; var AOptions: TSearchOptions): Boolean;
var
  D: TSearchDialogForm;
begin
  Result := False;
  D := TSearchDialogForm.Create(AOwner, AOptions);
  try
    if D.ShowModal <> mrOk then Exit;
    AOptions := D.Options;
    Result := True;
  finally
    D.Free;
  end;
end;

function PromptForText(AOwner: TComponent; const ACaption, APrompt,
  ADefault: string; out AText: string): Boolean;
var
  D: TTextPromptForm;
begin
  AText := '';
  D := TTextPromptForm.Create(AOwner, ACaption, APrompt, ADefault);
  try
    Result := D.ShowModal = mrOk;
    if Result then AText := D.Text;
  finally
    D.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Extract
  --------------------------------------------------------------------------- }

constructor TExtractDialogForm.Create(AOwner: TComponent;
  ACount: Integer; const ADefaultDest: string; ANeedsPassword, APartial: Boolean);
var
  Body: TTyPanel;
  Pad, CW, Y: Integer;
  I: Integer;
  Labels: TStringArray;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := rsDlgExtractTitle;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(520);

  Body := NewBody(Self);
  NewLabel(Body, Format(rsDlgExtractToFmt, [ACount]), Pad, Pad, CW, Px(cLabelH));
  Y := Pad + Px(28);

  { Shortcut destinations first: they are the common case, and choosing one
    fills the path field below rather than replacing it. }
  Labels := QuickDestinationLabels;
  NewLabel(Body, rsDlgQuickDest, Pad, Y, Px(110), Px(cLabelH));
  FQuick := NewCombo(Body, Pad + Px(110), Y - Px(4), Px(200), Px(cComboH));
  FQuick.Items.Add(rsDlgChooseDest);
  for I := 0 to High(Labels) do FQuick.Items.Add(Labels[I]);
  FQuick.ItemIndex := 0;
  FQuick.OnChange := @QuickChange;
  Y := Y + Px(36);

  FDest := NewEdit(Body, Pad, Y, Px(420), Px(cEditH));
  FDest.Text := ADefaultDest;
  NewBodyButton(Body, rsDlgChoose, Pad + Px(428), Y - Px(1),
    Px(92), Px(cBodyBtnH), @BrowseClick);
  Y := Y + Px(40);

  { Two layout modes on one row, mutually exclusive: smart extraction decides
    the nesting itself, a named folder always adds one. A partial selection
    cannot be laid out by structure, so the smart box is disabled there. }
  FPartial := APartial;
  FSmartExtract := NewCheckBox(Body, rsDlgSmartExtract, Pad, Y, Px(150),
    Px(cCheckH));
  FSmartExtract.Checked := False;
  FSmartExtract.Enabled := not APartial;
  if APartial then
  begin
    FSmartExtract.Hint := rsDlgSmartExtractPartialHint;
    FSmartExtract.ShowHint := True;
  end;
  FSmartExtract.OnChange := @ModeChange;
  FSmartFolder := NewCheckBox(Body, rsDlgSmartFolder, Pad + Px(160), Y,
    Px(360), Px(cCheckH));
  FSmartFolder.Checked := False;
  FSmartFolder.OnChange := @ModeChange;
  Y := Y + Px(30);

  NewLabel(Body, rsDlgOnConflict, Pad, Y + Px(4), Px(110), Px(cLabelH));
  FConflict := NewCombo(Body, Pad + Px(110), Y, Px(240), Px(cComboH));
  { The dialog can only promise a policy it can apply before the engine starts,
    and the engine cannot stop and ask per file, so "ask" is not offered here:
    the user is answering that question right now. }
  FConflict.Items.Add(rsDlgConflictOverwrite);
  FConflict.Items.Add(rsDlgConflictSkip);
  FConflict.Items.Add(rsDlgConflictRename);
  FConflict.ItemIndex := 2;
  Y := Y + Px(40);

  FDeleteAfter := NewCheckBox(Body, rsDlgDeleteArchiveAfter, Pad, Y,
    Px(460), Px(cCheckH));
  Y := Y + Px(30);
  FOpenAfter := NewCheckBox(Body, rsDlgOpenAfter, Pad, Y, Px(420), Px(cCheckH));
  Y := Y + Px(cCheckH);

  if ANeedsPassword then
  begin
    Inc(Y, Px(12));
    NewLabel(Body, rsDlgPasswordOptional, Pad, Y, CW, Px(cLabelH));
    FPw := NewEdit(Body, Pad, Y + Px(24), CW, Px(cEditH));
    FPw.PasswordChar := '*';
    Inc(Y, Px(60));
  end;

  AddButton(rsDlgExtract, mrOk, True, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Y + Px(8));

  ActiveControl := FDest;
end;

procedure TExtractDialogForm.BrowseClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := FDest.Text;
  if TySelectDirectory(rsDlgChooseDest, '', Dir) then FDest.Text := Dir;
end;

procedure TExtractDialogForm.QuickChange(Sender: TObject);
var
  Dests: TStringArray;
begin
  if FQuick.ItemIndex <= 0 then Exit;
  Dests := QuickDestinations;
  if FQuick.ItemIndex - 1 > High(Dests) then Exit;
  { An empty entry means "beside the archive". The dialog is not told where the
    archive lives, so it leaves the field empty and the caller resolves that
    choice against the archive it is processing. }
  FDest.Text := Dests[FQuick.ItemIndex - 1];
end;

procedure TExtractDialogForm.ModeChange(Sender: TObject);
begin
  { The two layout choices are alternatives, not switches that add up. }
  FSmartFolder.Enabled := not FSmartExtract.Checked;
  FSmartExtract.Enabled := (not FPartial) and (not FSmartFolder.Checked);
end;

function TExtractDialogForm.GetOptions: TExtractOptions;
begin
  Result := Default(TExtractOptions);
  Result.Destination := FDest.Text;
  TzResolveExtractModes(FSmartExtract.Checked, FSmartFolder.Checked, FPartial,
    Result.SmartExtract, Result.SmartFolder);
  case FConflict.ItemIndex of
    0: Result.Conflict := ecOverwrite;
    1: Result.Conflict := ecSkip;
  else
    Result.Conflict := ecRename;
  end;
  Result.DeleteArchiveAfter := FDeleteAfter.Checked;
  Result.OpenAfter := FOpenAfter.Checked;
  if FPw <> nil then Result.Password := FPw.Text;
end;

function ShowExtractDialog(AOwner: TForm;
  ACount: Integer; const ADefaultDest: string; ANeedsPassword, APartial: Boolean;
  out AOptions: TExtractOptions): Boolean;
var
  D: TExtractDialogForm;
begin
  AOptions := Default(TExtractOptions);
  D := TExtractDialogForm.Create(AOwner, ACount, ADefaultDest, ANeedsPassword,
    APartial);
  try
    Result := D.ShowModal = mrOk;
    if Result then AOptions := D.Options;
  finally D.Free; end;
end;

{ One archive of the Finder smart service has files that already exist in its
  destination. The answer applies to that whole archive. }
type
  TSmartConflictForm = class(TZipDialog)
  public
    constructor Create(AOwner: TComponent;
      const AArchiveName, ADest: string); reintroduce;
  end;

constructor TSmartConflictForm.Create(AOwner: TComponent;
  const AArchiveName, ADest: string);
var
  Body: TTyPanel;
  Pad, CW: Integer;
begin
  inherited CreateNew(AOwner);
  AutoScroll := False;
  Caption := rsDlgSmartConflictTitle;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(420);
  Body := NewBody(Self);
  NewLabel(Body, Format(rsDlgSmartConflictFmt, [AArchiveName, ADest]), Pad, Pad,
    CW, Px(cLabelH) * 2);
  AddButton(rsDlgConflictOverwrite, mrYes, True, False);
  AddButton(rsDlgConflictRename, mrNo, False, False);
  AddButton(rsDlgConflictSkip, mrIgnore, False, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Pad + Px(cLabelH) * 2 + Px(16));
end;

function ShowSmartConflictDialog(AOwner: TForm;
  const AArchiveName, ADest: string): TExtractConflict;
var
  D: TSmartConflictForm;
begin
  { ecAsk is the "stop the whole batch" answer. }
  Result := ecAsk;
  D := TSmartConflictForm.Create(AOwner, AArchiveName, ADest);
  try
    case D.ShowModal of
      mrYes: Result := ecOverwrite;
      mrNo: Result := ecRename;
      mrIgnore: Result := ecSkip;
    end;
  finally
    D.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  New archive
  --------------------------------------------------------------------------- }

const
  { Memory estimate for LZMA/LZMA2: the encoder keeps roughly ten match buffers
    of dictionary size. Used only for the advisory label. }
  DictBlockFactor = 10.5;

{ Installed physical memory. Used only to warn about an over-large dictionary;
  0 when the platform cannot be asked, in which case no warning is shown. }
function GetPhysicalMemory: QWord;
begin
  Result := TzPhysicalMemory;
end;

{ A page of the tab control. Every page is a transparent ghost panel filling its
  sheet; this sequence used to be spelled out once per tab. The caller places its
  rows inside Result. }
function NewTabPage(ATabs: TTyPageControl; const ATitle: string): TTyPanel;
var
  Sheet: TTyTabSheet;
begin
  Sheet := ATabs.AddPage(ATitle);
  Result := TTyPanel.Create(Sheet);
  Result.Parent := Sheet;
  Result.Align := alClient;
  Result.Caption := '';
  Result.StyleClass := 'ghost';
end;

constructor TNewArchiveDialog.Create(AOwner: TComponent; ASourceCount: Integer;
  const ADefaultPath, ADefaultFormat: string);
var
  Body, Page: TTyPanel;
  Tabs: TTyPageControl;
  Pad, CW, Y: Integer;
  G: TFormatInfo;
  Pref: string;
  I: Integer;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := rsDlgNewArchive;
  Position := poMainFormCenter;
  FSourceCount := ASourceCount;
  Pad := Px(cPad);
  CW := Px(500);

  Body := NewBody(Self);

  { Presets first: choosing one fills the controls below, so it has to be read
    before them. The row is always present; with nothing saved it offers only
    "Save current settings as a preset", which is how a user creates the first.

    Y is the running offset down the page. It is a SEPARATE variable from Pad:
    the first version advanced Pad itself, so every control below -- and the tab
    control's width -- was placed against a margin of 52 instead of 16, which
    shifted the whole page right and pushed its right edge out of the window. }
  Y := Pad;
  NewLabel(Body, rsDlgPreset, Pad, Y, Px(80), Px(cLabelH));
  FPreset := NewCombo(Body, Pad + Px(80), Y - Px(4), Px(200), Px(cComboH));
  FPreset.OnChange := @PresetChange;
  NewBodyButton(Body, rsDlgSavePreset, Pad + Px(288), Y - Px(5),
    Px(150), Px(cBodyBtnH), @SavePresetClick);
  FPresets := LoadPresetsFromApp;
  RefreshPresetCombo;
  Y := Y + Px(36);

  { The archive name and format sit ABOVE the tabs, as in WinRAR: they decide
    which of the tab's controls are meaningful at all. }
  NewLabel(Body, rsDlgArchivePath, Pad, Y, CW, Px(cLabelH));
  FPath := NewEdit(Body, Pad, Y + Px(22), CW - Px(96), Px(cEditH));
  FPath.Text := ADefaultPath;
  NewBodyButton(Body, rsDlgChoose, Pad + CW - Px(88), Y + Px(21),
    Px(88), Px(cBodyBtnH), @BrowseClick);
  NewLabel(Body, rsDlgFormat, Pad, Y + Px(60), Px(120), Px(cLabelH));
  FFormat := NewCombo(Body, Pad + Px(96), Y + Px(56), Px(180), Px(cComboH));
  { Order by how often the format is actually chosen, not alphabetically: 7z and
    zip are what nearly every archive is, and burying them between "bzip2" and
    "gzip" in an alphabetical list makes the common case the slow one. Anything
    the engine can write but this list does not name is appended afterwards. }
  for Pref in CreateFormatOrder do
    for G in TzLoadFormats do
      if G.CanUpdate and SameText(G.Name, Pref) then
        FFormat.Items.Add(G.Name);
  for G in TzLoadFormats do
    if G.CanUpdate and (FFormat.Items.IndexOf(G.Name) < 0) then
      FFormat.Items.Add(G.Name);

  Tabs := TTyPageControl.Create(Body);
  Tabs.Parent := Body;
  Tabs.Left := Pad;
  Tabs.Top := Y + Px(96);
  { ClientWidth is CW + 32 (see AutoSizeToContent), and the tabs start at Pad, so
    the width has to leave that same margin on the right: at full CW the control
    ran past the window edge and its right side was clipped. }
  Tabs.Width := CW - Pad;
  Tabs.Height := Px(300);

  { ---------------- tab 1: 常规 ----------------
    Ordered by how often the option is used, and with the always-present ones
    first: every format can delete its sources, so that sits at the top instead
    of leaving a single lonely checkbox at the bottom of an otherwise empty page
    (which is all an .xz archive would show). }
  Page := NewTabPage(Tabs, rsDlgTabGeneral);
  Y := Pad;

  FDeleteAfter := NewCheckBox(Page, rsDlgDeleteAfter, Pad, Y, Px(280), Px(cCheckH));
  Y := Y + Px(34);

  FLblLevel := NewLabel(Page, rsDlgLevel, Pad, Y, Px(110), Px(cLabelH));
  FLevel := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(160), Px(cComboH));
  FLevel.Items.Add(rsDlgLevelStore);
  FLevel.Items.Add(rsDlgLevelFastest);
  FLevel.Items.Add(rsDlgLevelFast);
  FLevel.Items.Add(rsDlgLevelNormal);
  FLevel.Items.Add(rsDlgLevelMaximum);
  FLevel.Items.Add(rsDlgLevelUltra);
  FLevel.ItemIndex := 3;
  { One label per entry in the shared level table; the two must stay in step or
    Settings() reads the wrong level for the chosen row. }
  Assert(FLevel.Items.Count = Length(CreateLevels),
    'level choices and CreateLevels[] disagree');
  FLevel.OnChange := @MethodChange;
  Y := Y + Px(36);

  FLblMethod := NewLabel(Page, rsDlgMethod, Pad, Y, Px(110), Px(cLabelH));
  FMethod := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(160), Px(cComboH));
  FMethod.OnChange := @MethodChange;
  Y := Y + Px(36);

  FChkSolid := NewCheckBox(Page, rsDlgSolid, Pad, Y, Px(200), Px(cCheckH));
  FChkSolid.Checked := True;
  FSolid := FChkSolid;
  Y := Y + Px(34);

  FLblVolume := NewLabel(Page, rsDlgSplitVolume, Pad, Y, Px(110), Px(cLabelH));
  FVolume := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(160), Px(cComboH));
  for I := 0 to High(CreateVolumeLabels) do
    if I = 0 then FVolume.Items.Add(rsDlgSingleFile)
    else FVolume.Items.Add(CreateVolumeLabels[I]);
  FVolume.ItemIndex := 0;
  { Values and labels come from one table, so a short value array can no longer
    read past its end at create time. }
  Assert(FVolume.Items.Count = Length(CreateVolumeSizes),
    'volume choices and CreateVolumeSizes[] disagree');
  Y := Y + Px(36);

  { ZIP entry-name encoding belongs on the general page, not under encryption:
    it is about how NAMES are stored, and it matters whether or not a password
    is set. Reading order groups it with the other "what goes in the file"
    choices above it. }
  FLblCodepage := NewLabel(Page, rsDlgCodepage, Pad, Y, Px(110), Px(cLabelH));
  FCodepage := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(240), Px(cComboH));
  FCodepage.Items.Add(rsDlgCpAuto);
  FCodepage.Items.Add(rsDlgCpUtf8);
  FCodepage.Items.Add(rsDlgCpGbk);
  FCodepage.Items.Add(rsDlgCpGb18030);
  FCodepage.Items.Add(rsDlgCpShiftJis);
  FCodepage.Items.Add(rsDlgCpLatin1);
  Assert(FCodepage.Items.Count = Length(CreateCodepages),
    'codepage choices and CreateCodepages[] disagree');

  FCodepage.ItemIndex := 0;
  Y := Y + Px(30);
  FLblCpNote := NewLabel(Page, rsDlgCpNote, Pad, Y, CW - Px(2 * cPad), Px(cLabelH));

  { ---------------- tab 2: 加密 ---------------- }
  Page := NewTabPage(Tabs, rsDlgTabEncrypt);
  Y := Pad;
  NewLabel(Page, rsDlgPasswordLabel, Pad, Y, Px(110), Px(cLabelH));
  FPassword := NewEdit(Page, Pad + Px(110), Y - Px(4), Px(200), Px(cEditH));
  FPassword.PasswordChar := '*';
  FPassword.OnChange := @PasswordChange;
  Y := Y + Px(36);
  NewLabel(Page, rsDlgPassword2, Pad, Y, Px(110), Px(cLabelH));
  FPassword2 := NewEdit(Page, Pad + Px(110), Y - Px(4), Px(200), Px(cEditH));
  FPassword2.PasswordChar := '*';
  FPassword2.OnChange := @PasswordChange;
  Y := Y + Px(40);
  FShowPassword := NewCheckBox(Page, rsDlgShowPassword, Pad + Px(110), Y,
    Px(200), Px(cCheckH));
  FShowPassword.OnChange := @ShowPasswordChange;
  Y := Y + Px(34);
  FEncryptNames := NewCheckBox(Page, rsDlgEncryptNames, Pad + Px(110), Y,
    Px(300), Px(cCheckH));
  Y := Y + Px(30);
  FAES := NewCheckBox(Page, rsDlgAES256, Pad + Px(110), Y, Px(300), Px(cCheckH));
  Y := Y + Px(30);
  NewLabel(Page, rsDlgEncryptNote, Pad + Px(110), Y, CW - Px(2 * cPad) - Px(110),
    Px(cLabelH));

  { ---------------- tab 3: 高级 ----------------
    Threads first: almost every format has them, and starting with it keeps the
    page from opening with a blank area on the formats where the LZMA-only rows
    are hidden. }
  Page := NewTabPage(Tabs, rsDlgTabAdvanced);
  Y := Pad;

  FLblThreads := NewLabel(Page, rsDlgThreads, Pad, Y, Px(110), Px(cLabelH));
  FThreads := TTySpinEdit.Create(Page);
  FThreads.Parent := Page;
  FThreads.Left := Pad + Px(110);
  FThreads.Top := Y - Px(4);
  FThreads.Width := Px(90);
  FThreads.Height := Px(cEditH);
  FThreads.MinValue := 0;
  FThreads.MaxValue := 64;
  FThreads.Value := 0;
  FThreads.OnChange := @MethodChange;
  FLblThreadsAuto := NewLabel(Page, rsDlgThreadsAuto, Pad + Px(208), Y,
    Px(200), Px(cLabelH));
  Y := Y + Px(36);

  FLblDict := NewLabel(Page, rsDlgDictSize, Pad, Y, Px(110), Px(cLabelH));
  FDict := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(160), Px(cComboH));
  for I := 0 to High(CreateDictSizes) do
    FDict.Items.Add(TzDictPresetText(I));
  FDict.ItemIndex := 4;
  FDict.OnChange := @MethodChange;
  Y := Y + Px(36);

  FLblMatch := NewLabel(Page, rsDlgMatchFinder, Pad, Y, Px(110), Px(cLabelH));
  FMatchFinder := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(120), Px(cComboH));
  FMatchFinder.Items.Add('bt4');
  FMatchFinder.Items.Add('bt3');
  FMatchFinder.Items.Add('bt2');
  FMatchFinder.Items.Add('hc4');
  FMatchFinder.ItemIndex := 0;
  Y := Y + Px(36);

  FLblWord := NewLabel(Page, rsDlgWordSize, Pad, Y, Px(110), Px(cLabelH));
  FWordSize := NewCombo(Page, Pad + Px(110), Y - Px(4), Px(120), Px(cComboH));
  FWordSize.Items.Add('16');
  FWordSize.Items.Add('32');
  FWordSize.Items.Add('64');
  FWordSize.Items.Add('128');
  FWordSize.Items.Add('256');
  FWordSize.ItemIndex := 2;
  Y := Y + Px(36);

  FLblPasses := NewLabel(Page, rsDlgPasses, Pad, Y, Px(110), Px(cLabelH));
  FPasses := TTySpinEdit.Create(Page);
  FPasses.Parent := Page;
  FPasses.Left := Pad + Px(110);
  FPasses.Top := Y - Px(4);
  FPasses.Width := Px(90);
  FPasses.Height := Px(cEditH);
  FPasses.MinValue := 1;
  FPasses.MaxValue := 256;
  FPasses.Value := 32;
  Y := Y + Px(40);
  FMemLabel := NewLabel(Page, '', Pad, Y, CW - Px(2 * cPad), Px(cLabelH));

  { ---------------- tab 4: 参数 ---------------- }
  Page := NewTabPage(Tabs, rsDlgTabOptions);
  Y := Pad;
  NewLabel(Page, rsDlgExtraLabel, Pad, Y, Px(110), Px(cLabelH));
  FExtra := NewEdit(Page, Pad, Y + Px(22), CW - Px(2 * cPad), Px(cEditH));
  NewLabel(Page, rsDlgExtraHint, Pad, Y + Px(58), CW - Px(2 * cPad), Px(cLabelH * 3));

  FFormat.ItemIndex := 0;
  for I := 0 to FFormat.Items.Count - 1 do
    if SameText(FFormat.Items[I], ADefaultFormat) then
      FFormat.ItemIndex := I;
  FFormat.OnChange := @FormatChange;

  { Setting ItemIndex above does not fire OnChange, so normalise the name here:
    the caller's suggestion may carry the wrong suffix for this format, and a
    single-stream format needs its tar form for a multi-file selection. }
  ApplyFormatSuffix;
  UpdateFormatControls;

  AddButton(rsDlgOK, mrOk, True, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Tabs.Top + Tabs.Height);
end;

{ Fill the preset combo. Slot 0 is always "none"; the saved presets follow. }
procedure TNewArchiveDialog.RefreshPresetCombo;
var
  I: Integer;
begin
  FPreset.Items.Clear;
  FPreset.Items.Add(rsDlgPresetNone);
  for I := 0 to High(FPresets) do
    FPreset.Items.Add(FPresets[I].Name + '  (' + DescribePreset(FPresets[I]) + ')');
  FPreset.ItemIndex := 0;
end;

procedure TNewArchiveDialog.PresetChange(Sender: TObject);
begin
  if FPreset.ItemIndex <= 0 then Exit;
  if FPreset.ItemIndex - 1 > High(FPresets) then Exit;
  ApplyPreset(FPresets[FPreset.ItemIndex - 1]);
end;

{ Push a preset into the controls and then run the same normalisation a manual
  edit would, so the dialog cannot end up showing something the engine will not
  do. }
procedure TNewArchiveDialog.ApplyPreset(const APreset: TArchivePreset;
  const APassword: string);
var
  I: Integer;
  S: TCreateSettings;
begin
  S := APreset.Settings;
  { Password first: the encryption rows' visibility depends on it. }
  if APassword <> '' then
  begin
    FPassword.Text := APassword;
    FPassword2.Text := APassword;
  end;
  I := FFormat.Items.IndexOf(S.FormatName);
  if I >= 0 then FFormat.ItemIndex := I;
  { Rebuild the method list and the per-format visibility before the remaining
    values are pushed in: UpdateFormatControls resets the method ItemIndex and
    decides which of the dictionary/word-size/passes rows exist at all. }
  UpdateFormatControls;

  { Values map by INDEX/TABLE, never by their text. The old code looked up
    IntToStr(Level) and IntToStr(Codepage) among localised labels, so those two
    fields never matched -- and TzFormatSize(VolumeSize) rendered "100.0 MB"
    against a "100 MB" label, losing the volume the same way. }
  I := FMethod.Items.IndexOf(S.Method);
  if I >= 0 then FMethod.ItemIndex := I;
  { Method-specific rows (dictionary, word size, passes) are decided from the
    method, so re-evaluate once it has been restored. }
  UpdateFormatControls;

  I := TzLevelComboIndex(S.Level);
  if I >= 0 then FLevel.ItemIndex := I;
  FThreads.Value := S.Threads;
  FSolid.Checked := S.Solid;
  I := TzDictComboIndex(S.DictionarySize);
  if I >= 0 then FDict.ItemIndex := I;
  I := FWordSize.Items.IndexOf(IntToStr(S.WordSize));
  if I >= 0 then FWordSize.ItemIndex := I;
  if S.MatchFinder <> '' then
  begin
    I := FMatchFinder.Items.IndexOf(S.MatchFinder);
    if I >= 0 then FMatchFinder.ItemIndex := I;
  end;
  FPasses.Value := S.NumPasses;
  I := TzVolumeComboIndex(S.VolumeSize);
  if I >= 0 then FVolume.ItemIndex := I;
  I := TzCodepageComboIndex(S.Codepage);
  if I >= 0 then FCodepage.ItemIndex := I;
  FExtra.Text := S.ExtraOptions;

  { The three fields the preset used to drop. They are set after
    UpdateFormatControls, which clears the encryption checkboxes when no password
    is typed yet; a preset cannot carry a password, so clearing them here would
    lose exactly the settings the preset does contain. The hidden-but-checked
    state becomes visible as soon as a password is entered. }
  FAES.Checked := S.ZipAES256;
  FEncryptNames.Checked := S.EncryptNames;
  FDeleteAfter.Checked := S.DeleteSources;
  UpdateMemoryLabel;
end;

{ Save the CURRENT settings under a name the user types. The password is not
  part of a preset, which PresetSafeSettings enforces. }
procedure TNewArchiveDialog.SavePresetClick(Sender: TObject);
var
  PresetName: string;
begin
  { "Name" is taken by TComponent, hence PresetName. }
  PresetName := '';
  if not PromptForText(Self, rsDlgSavePreset, rsDlgPresetName, '', PresetName) then Exit;
  PresetName := Trim(PresetName);
  if PresetName = '' then Exit;
  if PutPreset(FPresets, PresetName, Settings) < 0 then
  begin
    TyMessageDlg(rsErrPresetSlotsFull, mtError, [mbOK]);
    Exit;
  end;
  SavePresetsToApp(FPresets);
  RefreshPresetCombo;
  TyMessageDlg(Format(rsDlgPresetSavedFmt, [PresetName]), mtInformation, [mbOK]);
end;

function TNewArchiveDialog.CurrentFormat: string;
begin
  if FFormat.ItemIndex < 0 then
    Result := '7z'
  else
    Result := FFormat.Items[FFormat.ItemIndex];
end;

procedure TNewArchiveDialog.BrowseClick(Sender: TObject);
var
  P, Ext: string;
  D: TTySaveDialog;
begin
  P := Trim(FPath.Text);
  Ext := TzCreateExtForSources(CurrentFormat, FSourceCount, TzLoadFormats);
  if (Ext <> '') and (Ext[1] = '.') then Delete(Ext, 1, 1);
  { This button chooses the ARCHIVE FILE, not a folder: a save dialog is the
    native way to name and place a new file. The old code reused the folder
    chooser and also rooted its tree at the current folder, so only that subtree
    was reachable (ticket 47). }
  D := TTySaveDialog.Create(Self);
  try
    D.Title := rsDlgSaveAs;
    if Ext <> '' then
      D.Filter := Format('%s (*.%s)|*.%s|All files (*.*)|*.*',
        [CurrentFormat, Ext, Ext])
    else
      D.Filter := 'All files (*.*)|*.*';
    D.DefaultExt := Ext;
    D.FileName := ExtractFileName(P);
    D.InitialDir := ExtractFileDir(P);
    if D.Execute then FPath.Text := D.FileName;
  finally D.Free; end;
end;

{ Rewrite the extension when the format changes, so the name always matches what
  will actually be written. The rules live in tzip.createopts (they are derived
  from the engine's own format table and covered by tests): an extension that
  already matches is kept, a single-stream format keeps a user-typed compound
  ".tar.*" name, and for any other format the whole suffix is replaced. }
procedure TNewArchiveDialog.ApplyFormatSuffix;
begin
  FPath.Text := TzArchiveNameForCreate(FPath.Text, CurrentFormat, FSourceCount,
    TzLoadFormats);
end;

procedure TNewArchiveDialog.FormatChange(Sender: TObject);
begin
  UpdateFormatControls;
  ApplyFormatSuffix;
end;

procedure TNewArchiveDialog.PasswordChange(Sender: TObject);
begin
  UpdateFormatControls;
end;

procedure TNewArchiveDialog.ShowPasswordChange(Sender: TObject);
var
  C: Char;
begin
  if FShowPassword.Checked then C := #0 else C := '*';
  FPassword.PasswordChar := C;
  FPassword2.PasswordChar := C;
end;

procedure TNewArchiveDialog.MethodChange(Sender: TObject);
begin
  UpdateMemoryLabel;
end;

{ Show exactly the controls that matter for the current format, and put the
  method list together from what that format can actually encode. }
procedure TNewArchiveDialog.UpdateFormatControls;
var
  Caps: TFormatCaps;
  Fmt, M: string;
  HasPw: Boolean;
  IsPpmd, IsLzma, IsPasses: Boolean;
  J: Integer;
begin
  Fmt := CurrentFormat;
  Caps := TzFormatCaps(Fmt);
  HasPw := Trim(FPassword.Text) <> '';

  { --- first tab --- }
  FLblLevel.Visible := Caps.HasLevel;
  FLevel.Visible := Caps.HasLevel;
  FLblMethod.Visible := Caps.HasMethod;
  FMethod.Visible := Caps.HasMethod;
  FChkSolid.Visible := Caps.HasSolid;
  FLblVolume.Visible := Caps.HasVolume;
  FVolume.Visible := Caps.HasVolume;
  FDeleteAfter.Visible := True;

  { --- second tab --- }
  FLblCodepage.Visible := Caps.HasCodePage;
  FCodepage.Visible := Caps.HasCodePage;
  { The explanation belongs to the control it explains: on wim or tar there is
    no encoding choice, so a sentence about entry names would be noise. }
  FLblCpNote.Visible := Caps.HasCodePage;
  FEncryptNames.Visible := Caps.HasEncryptNames and HasPw;
  FAES.Visible := Caps.HasAES and HasPw;
  if not HasPw then
  begin
    FEncryptNames.Checked := False;
    FAES.Checked := False;
  end;
  FPassword.Enabled := Caps.HasEncrypt;
  FPassword2.Enabled := Caps.HasEncrypt;

  if not Caps.HasMethod then
  begin
    FMethod.Items.Clear;
    FMethod.Items.Add(rsDlgMethodDefault);
    FMethod.ItemIndex := 0;
  end
  else
  begin
    M := '';
    if FMethod.ItemIndex >= 0 then M := FMethod.Items[FMethod.ItemIndex];
    FMethod.Items.Clear;
    if SameText(Fmt, '7z') then
    begin
      FMethod.Items.Add('LZMA2');
      FMethod.Items.Add('LZMA');
      FMethod.Items.Add('PPMd');
      FMethod.Items.Add('BZip2');
      FMethod.Items.Add('Deflate');
      FMethod.Items.Add('Copy');
    end
    else if SameText(Fmt, 'zip') then
    begin
      FMethod.Items.Add('Deflate');
      FMethod.Items.Add('Deflate64');
      FMethod.Items.Add('BZip2');
      FMethod.Items.Add('LZMA');
      FMethod.Items.Add('PPMd');
      FMethod.Items.Add('Copy');
    end
    else
    begin
      FMethod.Items.Add('LZX');
      FMethod.Items.Add('XPRESS');
      FMethod.Items.Add('Copy');
    end;
    FMethod.ItemIndex := 0;
    for J := 0 to FMethod.Items.Count - 1 do
      if SameText(FMethod.Items[J], M) then
        FMethod.ItemIndex := J;
  end;

  { Read the selection through a guard: the row list can be empty in a corner
    case, and indexing it directly used to raise instead of showing no rows. }
  if (FMethod.ItemIndex >= 0) and (FMethod.ItemIndex < FMethod.Items.Count) then
    M := FMethod.Items[FMethod.ItemIndex]
  else
    M := '';
  IsPpmd := Caps.HasMethod and SameText(M, 'PPMd');
  IsLzma := Caps.HasMethod and (SameText(M, 'LZMA') or SameText(M, 'LZMA2'));

  { --- third tab --- }
  FLblDict.Visible := Caps.HasDictionary and IsLzma;
  FDict.Visible := Caps.HasDictionary and IsLzma;
  FLblMatch.Visible := Caps.HasDictionary and IsLzma;
  FMatchFinder.Visible := Caps.HasDictionary and IsLzma;
  FLblWord.Visible := Caps.HasWordSize and IsPpmd;
  FWordSize.Visible := Caps.HasWordSize and IsPpmd;
  { Passes exist for BZip2 and Deflate only; LZMA/LZMA2 reject the property and
      fail the whole create, so the row must not appear for them. }
  IsPasses := Caps.HasMethod and (SameText(M, 'BZip2') or SameText(M, 'Deflate'));
  FLblPasses.Visible := IsPasses;
  FPasses.Visible := IsPasses;
  FLblThreads.Visible := Caps.HasLevel;
  FLblThreadsAuto.Visible := Caps.HasLevel;
  FThreads.Visible := Caps.HasLevel;

  UpdateMemoryLabel;
end;

procedure TNewArchiveDialog.UpdateMemoryLabel;
var
  Need, Avail: QWord;
  Txt: string;
begin
  Need := 0;
  if FDict.Visible and (FDict.ItemIndex >= 0) then
    Need := Trunc(TzDictPresetBytes(FDict.ItemIndex) * DictBlockFactor);
  Avail := GetPhysicalMemory;
  if Need = 0 then
    Txt := ''
  else if Avail = 0 then
    { The platform could not be asked; still state the requirement rather than
      claiming "0 B available", which looked like a broken reading. }
    Txt := Format(rsDlgMemNeedFmt, [TzFormatSize(Need)])
  else if Need > Avail then
    Txt := Format(rsDlgMemTooMuchFmt, [TzFormatSize(Need), TzFormatSize(Avail)])
  else
    Txt := Format(rsDlgMemEstimateFmt, [TzFormatSize(Need), TzFormatSize(Avail)]);
  FMemLabel.Caption := Txt;
  if (Avail > 0) and (Need > Avail) then
    FMemLabel.Font.Color := clRed
  else if FMemLabel.Font.Color <> clDefault then
    FMemLabel.Font.Color := clDefault;
end;

function TNewArchiveDialog.GetPath: string;
begin
  Result := FPath.Text;
end;

function TNewArchiveDialog.Settings: TCreateSettings;
var
  M: string;
  Caps: TFormatCaps;
  I: Integer;
begin
  Result := Default(TCreateSettings);
  Caps := TzFormatCaps(CurrentFormat);
  Result.FormatName := CurrentFormat;

  { A single-stream format holding a tree or several files gets the compound
    name from ApplyFormatSuffix (.tar.gz). The CREATE side must then make a tar
    first and compress that; TzCreateArchive does exactly that when it sees a
    compound name, so FormatName stays as chosen (gzip/bzip2/xz).

    Every combo is read through its table, with an index guard: the old version
    bailed out at the top when any index was -1, returning a record with an
    EMPTY FormatName that the caller then handed to the engine. }

  if Caps.HasLevel then
    Result.Level := TzLevelValue(FLevel.ItemIndex)
  else
    Result.Level := -1;
  if Caps.HasMethod then
  begin
    M := '';
    I := FMethod.ItemIndex;
    if (I >= 0) and (I < FMethod.Items.Count) then M := FMethod.Items[I];
    if SameText(M, rsDlgMethodDefault) then M := '';
    Result.Method := M;
  end;
  Result.Solid := Caps.HasSolid and FChkSolid.Checked;
  if Caps.HasLevel then Result.Threads := FThreads.Value;
  Result.Password := Trim(FPassword.Text);
  if Result.Password <> '' then
  begin
    Result.EncryptNames := Caps.HasEncryptNames and FEncryptNames.Checked;
    Result.ZipAES256 := Caps.HasAES and FAES.Checked;
  end;
  if Caps.HasVolume then
    Result.VolumeSize := TzVolumeValue(FVolume.ItemIndex);
  if Caps.HasDictionary and FDict.Visible then
    Result.DictionarySize := TzDictPresetBytes(FDict.ItemIndex);
  if Caps.HasWordSize and FWordSize.Visible then
  begin
    I := FWordSize.ItemIndex;
    if (I >= 0) and (I < FWordSize.Items.Count) then
      Result.WordSize := StrToIntDef(FWordSize.Items[I], 0);
  end;
  if Caps.HasDictionary and FMatchFinder.Visible then
  begin
    I := FMatchFinder.ItemIndex;
    if (I >= 0) and (I < FMatchFinder.Items.Count) then
      Result.MatchFinder := FMatchFinder.Items[I];
  end;
  if FPasses.Visible and (Result.Method <> '') then
    Result.NumPasses := FPasses.Value;
  if Caps.HasCodePage and (FCodepage.ItemIndex > 0) then
  begin
    Result.Codepage := TzCodepageValue(FCodepage.ItemIndex);
    Result.ForceUtf8 := Result.Codepage = CodepageUtf8;
  end;
  Result.ExtraOptions := Trim(FExtra.Text);
  Result.DeleteSources := FDeleteAfter.Checked;
end;


function ShowNewArchiveDialog(AOwner: TForm; ASourceCount: Integer;
  const ADefaultPath, ADefaultFormat: string;
  out APath: string; out ASettings: TCreateSettings;
  const ASeed: TCreateSettings; AConverting: Boolean): Boolean;
var
  D: TNewArchiveDialog;
  P: TArchivePreset;
begin
  D := TNewArchiveDialog.Create(AOwner, ASourceCount, ADefaultPath, ADefaultFormat);
  try
    { A conversion is not a new archive: the dialog would otherwise say "New
      Archive" while the user is replacing one. }
    if AConverting then D.Caption := rsDlgConvertTitle;
    { Pre-fill from the caller's settings through the same path a preset uses, so
      the controls end up in a state the dialog itself would have produced. }
    if ASeed.FormatName <> '' then
    begin
      P.Name := '';
      P.Settings := ASeed;
      D.ApplyPreset(P, ASeed.Password);
    end;
    Result := D.ShowModal = mrOk;
    if Result then
    begin
      APath := D.ArchivePath;
      ASettings := D.Settings;
    end;
  finally D.Free; end;
end;

{ ---------------------------------------------------------------------------
  Settings
  --------------------------------------------------------------------------- }

constructor TSettingsForm.Create(AOwner: TComponent; const ASettings: TAppSettings;
  const AIconCacheDir: string);
var
  Body: TTyPanel;
  Pad, CW: Integer;
  N: TStringArray;
  I, Idx: Integer;
  Lang: string;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  FBase := ASettings;
  FCacheDir := AIconCacheDir;
  Caption := rsDlgSettings;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(520);

  Body := NewBody(Self);

  { Theme }
  NewLabel(Body, rsDlgTheme, Pad, Pad, Px(240), Px(cLabelH));
  FTheme := NewCombo(Body, Pad, Pad + Px(20), Px(240), Px(cComboH));
  N := TyBuiltinThemeNames;
  for I := 0 to High(N) do FTheme.Items.Add(N[I]);
  Idx := FTheme.Items.IndexOf(ASettings.ThemeName);
  if Idx >= 0 then FTheme.ItemIndex := Idx
  else if FTheme.Items.Count > 0 then FTheme.ItemIndex := 0;

  { Appearance }
  NewLabel(Body, rsDlgMode, Pad + Px(256), Pad, Px(240), Px(cLabelH));
  FMode := NewCombo(Body, Pad + Px(256), Pad + Px(20), Px(140), Px(cComboH));
  FMode.Items.Add(rsDlgSystemDefault);
  FMode.Items.Add(rsDlgLight);
  FMode.Items.Add(rsDlgDark);
  if SameText(ASettings.Mode, 'dark') then FMode.ItemIndex := 2
  else if SameText(ASettings.Mode, 'light') then FMode.ItemIndex := 1
  else FMode.ItemIndex := 0;

  { Language -- choices and ids come from tzip.i18n; keep the ids in step. }
  NewLabel(Body, rsDlgLanguage, Pad, Pad + Px(60), Px(240), Px(cLabelH));
  FLanguageIds := TStringList.Create;
  FLanguage := NewCombo(Body, Pad, Pad + Px(80), Px(240), Px(cComboH));
  TzLanguageChoices(FLanguage.Items, FLanguageIds);
  Lang := ASettings.Language;
  if Trim(Lang) = '' then Lang := LanguageSystem;
  Idx := FLanguageIds.IndexOf(Lang);
  if Idx < 0 then Idx := 0;
  FLanguage.ItemIndex := Idx;

  { Restart note }
  NewLabel(Body, rsDlgLanguageRestart, Pad, Pad + Px(116), CW, Px(36)).WordWrap := True;

  FHidden := NewCheckBox(Body, rsDlgShowHidden, Pad, Pad + Px(160),
    Px(420), Px(cCheckH));
  FHidden.Checked := ASettings.ShowHidden;

  FFoldersFirst := NewCheckBox(Body, rsDlgFoldersFirst, Pad, Pad + Px(188),
    Px(420), Px(cCheckH));
  FFoldersFirst.Checked := ASettings.FoldersFirst;

  FConfirm := NewCheckBox(Body, rsDlgConfirmDelete, Pad, Pad + Px(216),
    Px(420), Px(cCheckH));
  FConfirm.Checked := ASettings.ConfirmDelete;

  FOpenAfter := NewCheckBox(Body, rsDlgOpenAfterExtract, Pad, Pad + Px(244),
    Px(420), Px(cCheckH));
  FOpenAfter.Checked := ASettings.OpenAfterExtract;

  NewLabel(Body, rsDlgDefaultExtractDir, Pad, Pad + Px(280), Px(300), Px(cLabelH));
  FExtractDir := NewEdit(Body, Pad, Pad + Px(300), Px(420), Px(cEditH));
  FExtractDir.Text := ASettings.DefaultExtractDir;
  NewBodyButton(Body, rsDlgChoose, Pad + Px(428), Pad + Px(299),
    Px(92), Px(cBodyBtnH), @BrowseClick);

  { Icon cache. The size is shown beside the button so the user can see what
    clearing it would reclaim before pressing it. }
  NewLabel(Body, rsDlgIconCache, Pad, Pad + Px(340), Px(300), Px(cLabelH));
  FCacheLabel := NewLabel(Body, '', Pad, Pad + Px(360), Px(300), Px(cLabelH));
  NewBodyButton(Body, rsDlgClearIconCache, Pad + Px(320), Pad + Px(356),
    Px(150), Px(cBodyBtnH), @ClearCacheClick);
  UpdateCacheLabel;

  AddButton(rsDlgSave, mrOk, True, False);
  AddButton(rsDlgCancel, mrCancel, False, True);
  AutoSizeToContent(CW, Pad + Px(400));
end;

procedure TSettingsForm.UpdateCacheLabel;
var
  Bytes: Int64;
  Files: Integer;
begin
  if (FCacheDir = '') or (not DirectoryExists(FCacheDir)) then
  begin
    FCacheLabel.Caption := rsDlgIconCacheNone;
    Exit;
  end;
  TIconCacheSize(FCacheDir, Bytes, Files);
  FCacheLabel.Caption := Format(rsDlgIconCacheSizeFmt, [TzFormatSize(Bytes), Files]);
end;

procedure TSettingsForm.ClearCacheClick(Sender: TObject);
var
  N: Integer;
begin
  N := TIconCacheClear(FCacheDir);
  UpdateCacheLabel;
  { Say what happened rather than leaving the label to change quietly. }
  TyMessageDlg(Format(rsDlgIconCacheClearedFmt, [N]), mtInformation, [mbOK]);
end;

destructor TSettingsForm.Destroy;
begin
  FLanguageIds.Free;
  inherited Destroy;
end;

procedure TSettingsForm.BrowseClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := FExtractDir.Text;
  if TySelectDirectory(rsDlgChooseDefaultExtract, '', Dir) then FExtractDir.Text := Dir;
end;

function TSettingsForm.GetSettings: TAppSettings;
var
  Edited: TAppSettings;
begin
  { Start from the record the dialog was opened with, so only the controls this
    page actually has can change a field. The old version rebuilt the record from
    Default and copied ShowSidebar/ShowPreview by hand, which is how the two pane
    widths were saved as 0 every time the page was OKed. }
  Edited := FBase;
  if (FTheme.ItemIndex >= 0) and (FTheme.ItemIndex < FTheme.Items.Count) then
    Edited.ThemeName := FTheme.Items[FTheme.ItemIndex];
  case FMode.ItemIndex of
    1: Edited.Mode := 'light';
    2: Edited.Mode := 'dark';
  else Edited.Mode := '';
  end;
  if (FLanguage.ItemIndex >= 0) and (FLanguage.ItemIndex < FLanguageIds.Count) then
    Edited.Language := FLanguageIds[FLanguage.ItemIndex];
  Edited.ShowHidden := FHidden.Checked;
  Edited.FoldersFirst := FFoldersFirst.Checked;
  Edited.ConfirmDelete := FConfirm.Checked;
  Edited.OpenAfterExtract := FOpenAfter.Checked;
  Edited.DefaultExtractDir := FExtractDir.Text;
  Result := TzApplyDialogSettings(FBase, Edited);
end;

function ShowSettingsDialog(AOwner: TForm; const ASettings: TAppSettings;
  const AIconCacheDir: string; out ANew: TAppSettings): Boolean;
var
  D: TSettingsForm;
begin
  D := TSettingsForm.Create(AOwner, ASettings, AIconCacheDir);
  try
    Result := D.ShowModal = mrOk;
    if Result then ANew := D.GetSettings;
  finally D.Free; end;
end;

{ ---------------------------------------------------------------------------
  Archive info
  --------------------------------------------------------------------------- }

{ A structure-preserving archive information dialog: rsInfo* labels with the
  values on the right, and the nesting chain in a read-only memo. }
type
  TArchiveInfoForm = class(TZipDialog)
  public
    constructor Create(AOwner: TComponent; ACtx: TArchiveContext); reintroduce;
  end;

constructor TArchiveInfoForm.Create(AOwner: TComponent; ACtx: TArchiveContext);
var
  Body: TTyPanel;
  M: TTyMemo;
  Pad, CW, CapW, RowH, Y, Dirs, Files: Integer;
  Size, PackedSize: QWord;
  E: TArchiveEntry;
  Chain: TArchiveContext;
begin
  inherited CreateNew(AOwner);
  { A dialog must never scroll as a form: its custom title and button bars are
    children, so one wheel tick over the surface would otherwise shift the whole
    dialog content and push the buttons off screen. }
  AutoScroll := False;
  Caption := rsDlgArchiveInfo;
  Position := poMainFormCenter;
  Pad := Px(cPad);
  CW := Px(560);
  CapW := Px(130);
  RowH := Px(cLabelH);

  Dirs := 0; Files := 0; Size := 0; PackedSize := 0;
  if ACtx <> nil then
    for E in ACtx.Entries do
    begin
      if E.IsDir then Inc(Dirs)
      else
      begin
        Inc(Files);
        Inc(Size, E.Size);
        Inc(PackedSize, E.PackedSize);
      end;
    end;

  Body := NewBody(Self);
  Y := Pad;

  if ACtx <> nil then
  begin
    NewLabel(Body, rsInfoName, Pad, Y, CapW, RowH);
    NewLabel(Body, ACtx.DisplayName, Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoSource, Pad, Y, CapW, RowH);
    NewLabel(Body, ACtx.SourcePath, Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoFormat, Pad, Y, CapW, RowH);
    NewLabel(Body, ACtx.FormatName, Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoEntries, Pad, Y, CapW, RowH);
    NewLabel(Body, Format(rsDlgInfoCountsFmt,
      [Length(ACtx.Entries), Files, Dirs]),
      Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoUnpacked, Pad, Y, CapW, RowH);
    NewLabel(Body, TzFormatSize(Size), Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoPacked, Pad, Y, CapW, RowH);
    NewLabel(Body, TzFormatSize(PackedSize), Pad + CapW + Px(cGap), Y,
      CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoRatio, Pad, Y, CapW, RowH);
    if Size > 0 then
      NewLabel(Body, FormatFloat('0.0', PackedSize * 100 / Size) + ' %',
        Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH)
    else
      NewLabel(Body, '-', Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoEncrypted, Pad, Y, CapW, RowH);
    NewLabel(Body, BoolToStr(ACtx.HasEncrypted, rsYes, rsNo),
      Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoCanUpdate, Pad, Y, CapW, RowH);
    NewLabel(Body, BoolToStr(ACtx.CanUpdate, rsYes, rsNo),
      Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoNested, Pad, Y, CapW, RowH);
    NewLabel(Body, BoolToStr(ACtx.IsNested, rsYes, rsNo),
      Pad + CapW + Px(cGap), Y, CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(24));
    NewLabel(Body, rsInfoOpenedFrom, Pad, Y, CapW, RowH);
    NewLabel(Body, ACtx.OpenedFromFs, Pad + CapW + Px(cGap), Y,
      CW - CapW - Px(cGap), RowH);
    Inc(Y, Px(28));
  end
  else
    Inc(Y, Px(4));

  NewLabel(Body, rsInfoChain, Pad, Y, CW, RowH);
  Inc(Y, Px(24));

  M := TTyMemo.Create(Body);
  M.Parent := Body;
  M.Left := Pad;
  M.Top := Y;
  M.Width := CW;
  M.Height := Px(96);
  M.ScrollBars := ssAutoBoth;
  M.WordWrap := False;
  M.ReadOnly := True;
  if ACtx <> nil then
  begin
    Chain := ACtx;
    while Chain <> nil do
    begin
      M.Lines.Add('  ' + Chain.DisplayName + '  (' + Chain.FormatName + ')');
      Chain := Chain.Parent;
    end;
  end;

  AddButton(rsDlgOK, mrOk, True, False);
  AutoSizeToContent(CW, Y + Px(96));
end;

procedure ShowArchiveInfo(AOwner: TForm; ACtx: TArchiveContext);
var
  D: TArchiveInfoForm;
begin
  if ACtx = nil then Exit;
  D := TArchiveInfoForm.Create(AOwner, ACtx);
  try
    D.ShowModal;
  finally D.Free; end;
end;

end.
