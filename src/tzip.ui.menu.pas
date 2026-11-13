{ The main menu: its structure and the macOS application menu.

  Extracted from tzip.main, where building it was 250 lines inside a 7000-line
  unit. The window keeps what genuinely belongs to it -- the callbacks, the theme
  and appearance submenus it fills at runtime, and the ticks it toggles.

  Two platform differences live here rather than in the form:

  - macOS puts About, Settings and Languages in the application menu, which the
    LCL widgetset creates itself; the items are handed over through
    CocoaConfigMenu and retitled once the widgetset has written its own English
    ones.
  - Everywhere else they are ordinary items in Tools and Help. }
unit tzip.ui.menu;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}{$modeswitch objectivec1}{$ENDIF}

interface

uses
  Classes, SysUtils, Menus, Forms, Controls, ExtCtrls, LCLType,
  {$IFDEF DARWIN}CocoaConfig, CocoaAll, CocoaMenus,{$ENDIF}
  tzip.i18n, tzip.nameenc;

type
  { Everything the menu needs from the window. Called on click; nil is allowed
    and leaves that item inert. }
  TMenuCallbacks = record
    NewArchive: TNotifyEvent;
    OpenArchive: TNotifyEvent;
    CloseArchive: TNotifyEvent;
    Extract: TNotifyEvent;
    { Batch: extract every selected archive. Only meaningful in the filesystem
      view with several archives chosen. }
    ExtractAll: TNotifyEvent;
    TestArchive: TNotifyEvent;
    ShowInfo: TNotifyEvent;
    Convert: TNotifyEvent;
    Quit: TNotifyEvent;
    SelectAll: TNotifyEvent;
    Find: TNotifyEvent;
    ClearSearch: TNotifyEvent;
    DeleteSelected: TNotifyEvent;
    AddFiles: TNotifyEvent;
    AddFolder: TNotifyEvent;
    Back: TNotifyEvent;
    Forward: TNotifyEvent;
    Up: TNotifyEvent;
    Refresh: TNotifyEvent;
    ShowHidden: TNotifyEvent;
    Sidebar: TNotifyEvent;
    Preview: TNotifyEvent;
    Theme: TNotifyEvent;
    Mode: TNotifyEvent;
    Language: TNotifyEvent;
    NameEncoding: TNotifyEvent;
    Settings: TNotifyEvent;
    About: TNotifyEvent;
  end;

  { The items the window talks to later: ticks, and the submenus it fills. }
  TMainMenuParts = record
    ShowHidden: TMenuItem;
    Sidebar: TMenuItem;
    Preview: TMenuItem;
    Theme: TMenuItem;
    Mode: TMenuItem;
    Language: TMenuItem;
    NameEncoding: TMenuItem;
    About: TMenuItem;
    Settings: TMenuItem;
  end;

{ Build the menu into AMenu, which the caller owns; any previous content is
  discarded. The created items the caller needs come back in AParts. }
procedure BuildAppMenu(AMenu: TMainMenu; const ACallbacks: TMenuCallbacks;
  out AParts: TMainMenuParts);

{ Fill a language submenu with the three choices, tagging each with the language
  id in its Hint ('' means "follow the system"). }
procedure PopulateLanguageMenu(ALanguageMenu: TMenuItem;
  AOnClick: TNotifyEvent);

implementation

var
  { The language submenu handed to the widgetset. Its hook is a plain procedure
    pointer with no way to carry state, so the item is kept here. }
  GHookLanguageMenu: TMenuItem = nil;

function NewTop(const ACaption: string; AOwner: TComponent): TMenuItem;
begin
  Result := TMenuItem.Create(AOwner);
  Result.Caption := ACaption;
end;

function NewLeaf(AParent: TMenuItem; const ACaption: string;
  AOnClick: TNotifyEvent; AOwner: TComponent): TMenuItem;
begin
  Result := TMenuItem.Create(AOwner);
  Result.Caption := ACaption;
  Result.OnClick := AOnClick;
  AParent.Add(Result);
end;

procedure AddSeparator(AParent: TMenuItem; AOwner: TComponent);
begin
  NewLeaf(AParent, '-', nil, AOwner);
end;

procedure PopulateLanguageMenu(ALanguageMenu: TMenuItem;
  AOnClick: TNotifyEvent);
var
  It: TMenuItem;
begin
  if ALanguageMenu = nil then Exit;
  ALanguageMenu.Clear;
  It := NewLeaf(ALanguageMenu, rsDlgSystemDefault, AOnClick, ALanguageMenu.Owner);
  It.Hint := LanguageSystem;
  It := NewLeaf(ALanguageMenu, 'English', AOnClick, ALanguageMenu.Owner);
  It.Hint := LanguageEnglish;
  It := NewLeaf(ALanguageMenu, '简体中文', AOnClick, ALanguageMenu.Owner);
  It.Hint := LanguageChinese;
end;

{$IFDEF DARWIN}
type
  { Holds the widgetset callback. A class so the timer's OnTimer -- an object
    method -- can point at it. }
  TAppMenuHook = class
  public
    class procedure Created(AMenu: NSMenu); static;
    class procedure TidySeparators(AMenu: NSMenu); static;
    procedure TidyTimerTick(Sender: TObject);
  end;

var
  GTidyTimer: TTimer = nil;
  GHook: TAppMenuHook = nil;

class procedure TAppMenuHook.TidySeparators(AMenu: NSMenu);
var
  I: Integer;
  Changed: Boolean;
begin
  if AMenu = nil then Exit;
  repeat
    Changed := False;
    for I := AMenu.numberOfItems - 1 downto 0 do
      if AMenu.itemAtIndex(I).isSeparatorItem then
        if (I = 0) or (I = AMenu.numberOfItems - 1) or
           AMenu.itemAtIndex(I - 1).isSeparatorItem then
        begin
          AMenu.removeItemAtIndex(I);
          Changed := True;
        end;
  until not Changed;
end;

procedure TAppMenuHook.TidyTimerTick(Sender: TObject);
var
  Mn: NSMenu;
begin
  if GTidyTimer <> nil then
  begin
    GTidyTimer.Enabled := False;
    FreeAndNil(GTidyTimer);
  end;
  if (NSApp = nil) or (NSApp.mainMenu = nil) then Exit;
  Mn := NSApp.mainMenu;
  if Mn.numberOfItems = 0 then Exit;
  TidySeparators(Mn.itemAtIndex(0).submenu);
end;

class procedure TAppMenuHook.Created(AMenu: NSMenu);
var
  I, InsAt: Integer;
  It, LangItem: NSMenuItem;
  LangMenu: NSMenu;
  T, Cap: string;
begin
  if AMenu = nil then Exit;
  InsAt := -1;
  for I := 0 to AMenu.numberOfItems - 1 do
  begin
    It := AMenu.itemAtIndex(I);
    if (It = nil) or (It.title = nil) then Continue;
    T := UTF8Encode(string(It.title.UTF8String));
    { English from the widgetset, but once the LCL catalogue is loaded it may
      already be translated, so both spellings are recognised.
      NSString.stringWithUTF8String (not NSSTR, which copies bytes) decodes the
      text properly. }
    if (Pos('About', T) = 1) or (T = rsMenuAbout) then
      It.setTitle(NSString.stringWithUTF8String(PAnsiChar(UTF8Encode(rsMenuAbout))))
    else if (Pos('Preferences', T) = 1) or (T = rsMenuSettings) then
    begin
      It.setTitle(NSString.stringWithUTF8String(PAnsiChar(UTF8Encode(rsMenuSettings))));
      InsAt := I + 1;
    end;
  end;

  if GHookLanguageMenu <> nil then
  begin
    Cap := GHookLanguageMenu.Caption;
    LangItem := NSMenuItem.alloc;
    LangItem := LangItem.initWithTitle_action_keyEquivalent(
      NSString.stringWithUTF8String(PAnsiChar(UTF8Encode(Cap))), nil, NSSTR(''));
    if LangItem <> nil then
    begin
      LangMenu := NSMenu.alloc;
      LangMenu := LangMenu.initWithTitle(
        NSString.stringWithUTF8String(PAnsiChar(UTF8Encode(Cap))));
      if LangMenu <> nil then
      begin
        LangItem.setSubmenu(LangMenu);
        LangMenu.release;
        { The widgetset's own routine: it wires each entry's target/action so a
          click reaches the TMenuItem's OnClick. A hand-built item with a nil
          action looks right and does nothing when clicked. }
        TCocoaMenuUtil.attachLCLMenu(LangMenu, GHookLanguageMenu);
      end;
      { Between Settings and the separator below it, where a preference-like
        entry belongs. }
      if InsAt < 0 then
        AMenu.addItem(LangItem)
      else
        AMenu.insertItem_atIndex(LangItem, InsAt);
      LangItem.release;
    end;
  end;

  { The widgetset keeps appending items after this returns, so adjacent
    separators do not exist yet. Tidy on the first idle turn instead. }
  if GTidyTimer = nil then
  begin
    if GHook = nil then GHook := TAppMenuHook.Create;
    GTidyTimer := TTimer.Create(nil);
    GTidyTimer.Interval := 50;
    GTidyTimer.OnTimer := @GHook.TidyTimerTick;
    GTidyTimer.Enabled := True;
  end;
end;
{$ENDIF}

procedure BuildAppMenu(AMenu: TMainMenu; const ACallbacks: TMenuCallbacks;
  out AParts: TMainMenuParts);
var
  Owner: TComponent;
  M, It: TMenuItem;
  I: Integer;
  {$IFNDEF DARWIN}
  Tools, HelpMenu: TMenuItem;
  {$ENDIF}
begin
  AParts := Default(TMainMenuParts);
  if AMenu = nil then Exit;
  Owner := AMenu.Owner;
  AMenu.Items.Clear;

  M := NewTop(rsFileMenu, Owner);
  AMenu.Items.Add(M);
  NewLeaf(M, rsMenuNew, ACallbacks.NewArchive, Owner).ShortCut := ShortCut(Ord('N'), [ssMeta]);
  NewLeaf(M, rsMenuOpen, ACallbacks.OpenArchive, Owner).ShortCut := ShortCut(Ord('O'), [ssMeta]);
  NewLeaf(M, rsMenuClose, ACallbacks.CloseArchive, Owner);
  AddSeparator(M, Owner);
  NewLeaf(M, rsMenuExtract, ACallbacks.Extract, Owner);
  NewLeaf(M, rsMenuExtractAllSelected, ACallbacks.ExtractAll, Owner);
  NewLeaf(M, rsMenuTest, ACallbacks.TestArchive, Owner);
  NewLeaf(M, rsMenuInfo, ACallbacks.ShowInfo, Owner);
  NewLeaf(M, rsMenuConvert, ACallbacks.Convert, Owner);
  AddSeparator(M, Owner);
  NewLeaf(M, rsMenuExit, ACallbacks.Quit, Owner).ShortCut := ShortCut(Ord('Q'), [ssMeta]);

  M := NewTop(rsEditMenu, Owner);
  AMenu.Items.Add(M);
  NewLeaf(M, rsMenuSelectAll, ACallbacks.SelectAll, Owner).ShortCut := ShortCut(Ord('A'), [ssMeta]);
  NewLeaf(M, rsMenuDelete, ACallbacks.DeleteSelected, Owner).ShortCut := ShortCut(VK_DELETE, []);
  NewLeaf(M, rsMenuAddFiles, ACallbacks.AddFiles, Owner);
  NewLeaf(M, rsMenuAddFolder, ACallbacks.AddFolder, Owner);
  AddSeparator(M, Owner);
  NewLeaf(M, rsMenuFind, ACallbacks.Find, Owner).ShortCut := ShortCut(Ord('F'), [ssMeta]);
  NewLeaf(M, rsMenuClearSearch, ACallbacks.ClearSearch, Owner);

  M := NewTop(rsGoMenu, Owner);
  AMenu.Items.Add(M);
  NewLeaf(M, rsMenuBack, ACallbacks.Back, Owner).ShortCut := ShortCut(VK_LEFT, [ssMeta]);
  NewLeaf(M, rsMenuForward, ACallbacks.Forward, Owner).ShortCut := ShortCut(VK_RIGHT, [ssMeta]);
  NewLeaf(M, rsMenuUp, ACallbacks.Up, Owner).ShortCut := ShortCut(VK_UP, [ssMeta]);
  NewLeaf(M, rsMenuRefresh, ACallbacks.Refresh, Owner);

  M := NewTop(rsViewMenu, Owner);
  AMenu.Items.Add(M);
  AParts.ShowHidden := NewLeaf(M, rsMenuShowHidden, ACallbacks.ShowHidden, Owner);
  AParts.ShowHidden.AutoCheck := True;
  AParts.ShowHidden.Checked := False;
  AddSeparator(M, Owner);
  AParts.Sidebar := NewLeaf(M, rsMenuSidebar, ACallbacks.Sidebar, Owner);
  AParts.Sidebar.AutoCheck := True;
  AParts.Sidebar.Checked := False;
  AParts.Preview := NewLeaf(M, rsMenuPreview, ACallbacks.Preview, Owner);
  AParts.Preview.AutoCheck := True;
  AParts.Preview.Checked := True;
  { Per-archive ZIP name encoding. The item hints carry the tzip.nameenc id;
    an empty hint is "follow the setting". Explicit entries start after auto. }
  AParts.NameEncoding := NewTop(rsMenuNameEncoding, Owner);
  M.Add(AParts.NameEncoding);
  It := NewLeaf(AParts.NameEncoding, rsEncFollowSettings,
    ACallbacks.NameEncoding, Owner);
  It.Hint := '';
  for I := 1 to High(NameEncodings) do
  begin
    It := NewLeaf(AParts.NameEncoding, TzNameEncodingLabel(NameEncodings[I].Id),
      ACallbacks.NameEncoding, Owner);
    It.Hint := NameEncodings[I].Id;
  end;
  AddSeparator(M, Owner);
  AParts.Theme := NewTop(rsMenuTheme, Owner);
  M.Add(AParts.Theme);
  AParts.Mode := NewTop(rsMenuAppearance, Owner);
  M.Add(AParts.Mode);

  { Language is an app-wide preference, so on macOS it belongs next to Settings
    rather than in a Tools menu that macOS apps generally do not have. }
  AParts.Language := NewTop(rsMenuLanguage, Owner);
  PopulateLanguageMenu(AParts.Language, ACallbacks.Language);

  {$IFDEF DARWIN}
  AParts.About := NewTop(rsMenuAbout, Owner);
  AParts.About.OnClick := ACallbacks.About;
  AParts.Settings := NewTop(rsMenuSettings, Owner);
  AParts.Settings.OnClick := ACallbacks.Settings;
  CocoaConfigMenu.appMenu.aboutItem := AParts.About;
  CocoaConfigMenu.appMenu.preferencesItem := AParts.Settings;
  GHookLanguageMenu := AParts.Language;
  CocoaConfigMenu.appMenu.onCreate := @TAppMenuHook.Created;
  {$ELSE}
  Tools := NewTop(rsToolsMenu, Owner);
  AMenu.Items.Add(Tools);
  AParts.Settings := NewLeaf(Tools, rsMenuSettings, ACallbacks.Settings, Owner);
  Tools.Add(AParts.Language);
  HelpMenu := NewTop(rsHelpMenu, Owner);
  AMenu.Items.Add(HelpMenu);
  AParts.About := NewLeaf(HelpMenu, rsMenuAbout, ACallbacks.About, Owner);
  {$ENDIF}
end;

end.
