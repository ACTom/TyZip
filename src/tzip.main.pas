unit tzip.main;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}{$modeswitch objectivec1}{$ENDIF}
{$WARN 5079 OFF} { SynEditWrappedView: experimental, but it is the supported word-wrap view }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, StdCtrls,
  ExtCtrls, LCLType, LCLIntf, FileUtil, DateUtils, Math, IniFiles,
  Clipbrd,
  BGRABitmap, BGRABitmapTypes,
  tyControls.Types, tyControls.Controller, tyControls.BuiltinThemes, tyControls.Form,
  tyControls.FormSurface, tyControls.Panel,
  tyControls.Button, tyControls.GlyphButtons, tyControls.IconFont, tyControls.ImageDraw,
  tyControls.Icons.Lucide, tyControls.ToolBar, tyControls.TyLabel,
  tyControls.Edit, tyControls.ComboBox, tyControls.CheckBox, tyControls.ListBox,
  tyControls.StatusBar, tyControls.Splitter, tyControls.Breadcrumb,
  tyControls.Menu, tyControls.ShellListView,
  tyControls.Memo,
  tzip.ui.icons, tzip.ui.menu, tzip.settings,
  {$IFDEF DARWIN}CocoaConfig, CocoaAll, CocoaMenus, tzip.services_macos,
  tzip.dragout, tzip.dragout_macos,{$ENDIF}
  tyControls.TreeView, tyControls.ListView, tyControls.Columns,
  tyControls.ListView.Layout, tyControls.ImageCollection,
  tyControls.ProgressBar, tyControls.ActivityIndicator,
  tyControls.PaintPanel, tyControls.Painter, tyControls.StyleModel,
  tyControls.FileSystem, tyControls.Dialogs, tyControls.Dialogs.FileDialog,
  tyControls.Dialogs.SelectPath,
  { SynEdit is the preview viewer; the wrap view is still flagged experimental
    by its own unit, hence the warning note is expected here. }
  SynEdit, SynEditTypes, SynEditHighlighter, SynEditMiscClasses, SynGutter,
  SynEditWrappedView, LConvEncoding,
  tzip.i18n, tzip.i18n.lcl, tzip.nameenc, tzip.api, tzip.engine, tzip.progress,
  tzip.jobs, tzip.platform, tzip.dialogs,
  tzip.createopts,
  tzip.preview, tzip.preview.session, tzip.preview.workers, tzip.preview.pane,
  tzip.extract,
  tzip.passwords,
  tzip.passwordstore, tzip.search,
  tzip.appcache, tzip.iconkeys, tzip.navpaths,
  tzip.arcpath, tzip.navstate, tzip.iconstore, tzip.jobcontrol, tzip.commands,
  tzip.timing,
  tzip.batch,
  tzip.rename, tzip.editwrite,
  { UI units last: they inherit from the tyControls types listed above. }
  tzip.ui.arclist, tzip.ui.fslist, tzip.ui.sidebartree,
  tzip.ui.arctree, tzip.ui.scrollguard;

type
  TZ7ZInputArray = array of TZ7ZInput;

  { The shell list's built-in glyph set covers only folder/text/image/sheet/exec.
    This subclass feeds it the platform icon list instead. }
  { Per-suffix platform icons on disk, so a cold start does not have to ask
    NSWorkspace for every type it meets and watch the list fill in.

    ADIR holds one PNG per lowercase suffix, literally "<suffix>.png" (no dot):
    a file type with no suffix is the one file called "@none.png". Names are not
    hashed because the suffix itself is already a safe file name; a suffix
    containing anything else simply is not cached. }



const
  OverlayRevealMs = 140;
  { Listings for archives up to this many entries finish in a few tens of
    milliseconds, so they stay on the UI thread (no async flicker, no ordering
    surprises).  Bigger ones go to a worker. }
  SyncListingEntries = 20000;

type
  { What the main form does with a finished background job. }
  TZJobPurpose = (
    jpNone,
    jpOpenBrowse,          { open an archive and show it }
    jpOpenInner,           { open and jump straight to a folder inside it }
    jpOpenExtractHere,     { open an archive only to extract it next to itself }
    jpOpenConvert,         { open an archive only to convert it }
    jpOpenNestedThenView,  { open a just-extracted nested archive }
    jpOpenAfterModify,     { reopen the archive an update just rewrote }
    jpList,                { rebuild the archive listing }
    jpSearch,             { run a search over the archive's entries }
    jpExtract,
    jpTest,
    jpExtractOneOpen,      { extract one entry, then hand it to the OS }
    jpConvert,
    { One item of a batch: extract every archive in one go. }
    jpBatchExtract,
    { One item of a batch: test every archive in one go. }
    jpBatchTest,
    { One archive of the conflict-aware batch pipeline: fetch its entry list. }
    jpBatchList,
    { One archive of the same pipeline: extract the entries the resolver kept. }
    jpBatchStage,
    jpCreate,
    jpModify);
  { What a per-purpose completion handler did. joDone reproduces the old "Exit"
    inside a branch of CompleteJob: the shared tail (tally, free the job, hand the
    queue on, refresh the status) must not run for this branch. }
  TJobHandlerOutcome = (joContinue, joDone);
  TJobHandler = function(AJob: TZJob; APurpose: TZJobPurpose;
    AResult: Integer; const AError: string): TJobHandlerOutcome of object;
  TJobHandlerEntry = record
    Purpose: TZJobPurpose;
    Handler: TJobHandler;
  end;


  { TMainForm }
  TMainForm = class(TTyForm)
  private
    FFormats: TFormatInfoArray;
    FReady: Boolean;

    FSurface: TTyFormSurface;
    FTitleBar: TTyTitleBar;
    FMenuBar: TTyMenuBar;
    FMainMenu: TMainMenu;

    FSidePanel: TTyPanel;
    FFsTree: TFsSidebarTree;
    FArcNavTree: TTyTreeView;
    FArcListPaths: TStringList;
    { The context the archive tree was built for. Navigating inside the same
      archive only changes the selection; its folder tree does not. }
    FArcTreeCtx: TArchiveContext;
    FSplitter: TTySplitter;

    FPathPanel: TTyPanel;
    FBackBtn, FForwardBtn, FUpBtn: TTyGlyphButton;
    FBreadcrumb: TTyBreadcrumb;
    FPathEdit: TTyEdit;
    { The crumbs currently shown, parallel to the breadcrumb items. }
    FCrumbs: TCrumbArray;
    FPathEditing: Boolean;
    FToolBar: TTyToolBar;
    FNewBtn, FOpenBtn, FExtractBtn, FTestBtn, FAddBtn, FDelBtn, FInfoBtn,
    FConvertBtn: TTyGlyphButton;
    FLanguageMenu, FShowHiddenMenu, FThemeMenu, FModeMenu: TMenuItem;
    FNameEncodingMenu: TMenuItem;
    { About and Settings. On macOS the widgetset places them in the application
      menu; elsewhere they are ordinary items in Tools and Help. }
    FAboutMenu, FSettingsMenu: TMenuItem;
    { The language submenu, shown as a submenu of the application menu on macOS
      and inside Tools elsewhere. }
    FSidebarMenu, FPreviewMenu: TMenuItem;
    FFilterEdit: TTyEdit;
    FPreviewToggleBtn: TTyGlyphButton;
    FStatus: TTyStatusBar;
    FToolButtons: array of TTyGlyphButton;

    FFsList: TZipShellListView;
    FArcList: TArcListView;
    { Armed on a left mouse down in the archive listing; a move past the
      threshold starts the Cocoa promise drag. }
    FArcDragArmed: Boolean;
    FArcDragStart: TPoint;
    { Bridges the list's data requests to this form's methods. }
    FArcSource: TArcCallbackSource;
    FArcListCallbacks: TArcListCallbacks;
    FContent: TTyPanel;

    { Right-hand preview pane.  It is shared by the filesystem and archive
      listings; text goes into a themed memo, images into a TImage. }
    FPreviewSplitter: TTySplitter;
    { The pane owns the text side (title, hint, the two viewers, their bar). The
      image controls below are still created by the window into the pane and its
      bar until their own step moves them. }
    FPreviewPanel: TPreviewPane;
    FPreviewBar: TTyPanel;
    { The image decoder's own state: the worker, what it is decoding for, and the
      generation that decides whether a finished decode still belongs here. The
      pixels themselves belong to the pane. }
    FImageLoader: TImageLoadThread;
    FImageLoadName: string;
    FImageLoadPath: string;
    FPreviewTempFile: string;
    FPreviewWorker: TPreviewLoaderThread;
    { Workers asked to stop but not finished. They are never waited for on the UI
      thread: an image decode cannot be interrupted, and blocking a click on the
      next picture until the previous one is decoded is the freeze this removes. }
    FRetiring: TList;
    FPreviewTimer: TTimer;
    FPreviewGen: Integer;
    FPreviewPending: Boolean;
    FPreviewPendingName: string;
    FPreviewPendingIndex: Integer;
    FPreviewPendingGen: Integer;

    FMode: TNavKind;
    FFsPath: string;
    FCtx: TArchiveContext;
    FInnerPath: string;
    { The per-archive ZIP name-encoding choice (a tzip.nameenc id); empty means
      "follow the setting". Only the current session and archive remember it. }
    FNameEncodingOverride: string;
    FFilter: string;
    FListing: TListing;
    { Non-empty while the listing shows search results. Kept separate from the
      filter box, which narrows one folder. }
    FSearchQuery: string;
    FSearchOptions: TSearchOptions;
    { The entry currently extracted for external editing, so a change can be
      noticed when the user comes back to us. One at a time: opening a second
      entry replaces the first, which is what a single-click-then-double-click
      user expects. }
    FEditSession: TEditSession;
    FSortCol: TArchiveSortColumn;
    FSortDesc: Boolean;

    FHistory: TNavHistory;
    FNavGuard: Boolean;

    FTempRoot: string;
    { Set when an external open is in flight, so FormDropFiles does not repeat it. }
    FExternalOpen: Boolean;
    FSettingsIni: string;
    FSettings: TAppSettings;

    FIconCollection: TTyImageCollection;
    FIconImages: TTyVirtualImageList;
    { Which image slot a file type or bundle owns, and what still has to be asked
      for. The tables and queues live in tzip.iconstore; this form owns the image
      list they point into. }
    FIconStore: TZIconStore;
    FFsPopup: TTyPopupMenu;
    FArcPopup: TTyPopupMenu;
    FFsPopupPaths: TStringList;
    { Application bundle paths, parallel to the "Open With" submenu items. }
    FOpenWithPaths: TStringList;
    FIconTimer: TTimer;
    { When this window came up. Icon lookups stay off for the first seconds so
      the window answers the first clicks before it starts paying for glyphs. }
    FIconWorkStartTick: QWord;
    { Background sweep that caches the /Applications icons. Nil when the icon
      cache is unavailable. }
    FAppPrefetcher: TAppIconPrefetcher;
    { Picks up icons the sweep has finished since the last tick. }
    FAppIconTimer: TTimer;
    { On-disk icon cache (<config>/iconcache/): suffix-named PNGs restored into
      the image list before the first paint, plus a background pass that re-checks
      each of them once per run against the icon the system reports now. }
    FIconCache: TIconCache;
    FIconCacheDir: string;
    { Number of app_* cache files seen last time the timer looked. A warmer
      count means new bundle icons arrived; the visible list repaints and
      AppIconIndex adopts the files it needs. }
    FIconCacheAppFiles: Integer;
    { False until the app-icon timer has done its one batched cache restore. }
    FAppIconsRestored: Boolean;
    FBusyCount: Integer;

    { Busy overlay: a dim card over the content area that says what is running
      and how far it got.  It never animates a blocking call -- every operation
      that can take long runs as a job below. }
    FOverlay: TTyPaintPanel;
    FOverlayCard: TTyPanel;
    FOverlayTitle: TTyLabel;
    FOverlayDetail: TTyLabel;
    FOverlayStatElapsed: TTyLabel;
    FOverlayStatEta: TTyLabel;
    FOverlayStatTotal: TTyLabel;
    FOverlayStatSpeed: TTyLabel;
    FOverlayStatFiles: TTyLabel;
    FOverlayStatPacked: TTyLabel;
    FOverlayCurrent: TTyLabel;
    FOverlayBar: TTyProgressBar;
    FOverlaySpin: TTyActivityIndicator;
    FOverlayCancel: TTyButton;
    FOverlayPause: TTyButton;
    { A cold-start Finder tool service: no main window, only the small progress
      window, and the process quits when the run ends. }
    FServiceMode: Boolean;
    FServiceProgress: TServiceProgressForm;
    { When this process started: a service arriving moments later was the reason
      macOS launched it, so the main window must not be shown. }
    FLaunchTick: QWord;
    { The process was started by "Open with TyZip" for a file whose extension is
      not ours; its path must be forced through the archive view. }
    FStartupAsArchive: Boolean;
    FOverlayReveal: TTimer;
    FOverlayShown: Boolean;
    FOverlayDeterminate: Boolean;
    { The determinate bar takes over from the spinner only once the worker has
      reported a total. Header parsing and wrapper unwrapping have no progress
      of their own, and a bar frozen at 0% explains less than the spinner. }
    FOverlayProgressSeen: Boolean;
    FOverlayCancelable: Boolean;
    FOverlayTitleText: string;
    FOverlayDetailText: string;
    FOverlayHiddenAt: QWord;

    { The one running archive job plus the action to take when it lands. }
    FJob: TZJob;
    { Jobs waiting for the running one to finish. Empty when idle. The queue is
      an object container: shifting a record that holds strings with Move()/
      SetLength() leaves the moved strings dangling (see tzip.jobqueue). }
    { Waiting jobs, batch tally and password retry. The queue, the counters and
      the error list live in tzip.jobcontrol. }
    FJobs: TJobController;
    { One completion handler per purpose; see RegisterJobHandlers. }
    FJobHandlers: array of TJobHandlerEntry;
    { Set by a handler that owns the status line, so the shared tail does not
      overwrite a result message with the archive summary. }
    FCompletionMsgSet: Boolean;
    { Tallied across a batch so the last item can report the whole run. Reset
      when a batch starts, i.e. when a job is queued onto an idle window. }
    FJobTimer: TTimer;
    FJobPurpose: TZJobPurpose;
    FJobTitle: string;
    FJobDetail: string;
    FJobCancelable: Boolean;
    FJobDeterminate: Boolean;

    { Pending "open archive" request, kept so a password retry can restart it. }
    { Last archive opened, with the password used then -- a cache for the next
      open of the same file, not the request in flight. }
    FLastOpenPath: string;
    FLastOpenPassword: string;
    { The one open parameter TZJob has no field for (see StartOpenArchive). }
    FOpenAddHistory: Boolean;

    FListPending: Boolean;
    FFilterTimer: TTimer;
    FFilterTyped: string;
    FListTotalBytes: QWord;
    FListTotalFiles: Integer;

    { Path to re-select in the filesystem list once NavigateFs has rebuilt it
      (going up out of an archive lands on the archive that was open). }
    FSelectFsPath: string;
    FExtractOpenAfter: Boolean;
    { Carried from the extract dialog to the completion handler. }
    FExtractDeleteAfter: Boolean;
    { The conflict-aware batch pipeline: one run object per batch, plus the
      choices the whole run shares. The run owns the per-archive stages and counts;
      the window only starts the next job it asks for. }
    FBatchRun: TBatchRun;
    { The run's own summary tally: a batch's archives are counted here, not in
      FJobs, so the shared batch summary cannot fire between two stages. }
    FBatchTally: TJobController;
    FBatchNextPending: Boolean;
    FBatchDest: string;
    FBatchOpenAfter: Boolean;
    FBatchDeleteAfter: Boolean;
    { Batch summary waiting for the timer callback to return before it is shown. }
    FPendingBatchSummary: string;
    FPendingBatchHadFailures: Boolean;
    { Further files handed over by the OS, opened one timer tick apart. }
    FPendingOpenPaths: TStringList;
    FOpenOneTimer: TTimer;
    { Plain launch: an empty-window hint is shown a beat after the first paint,
      so a pending "Open With" / double-click document event still wins. }
    FStartupHint: TTyLabel;
    { The welcome screen's own entries: a file chooser and a folder chooser. }
    FStartupBrowseFiles, FStartupBrowseFolder: TTyButton;
    { Cocoa's form scroll view can keep a titlebar-high scroll offset even when
      LCL reports range 0; this timer keeps snapping it back. }
    FScrollGuardTimer: TTimer;
    { True until the first real navigation/archive view: startup shows either the
      welcome hint or the opening card, never an empty window. }
    FStartupPhase: Boolean;
    FRecentArchives: TStringList;
    FRecentTitle: TTyLabel;
    FRecentList: TTyListBox;
    FExtractOneName: string;
    { The entry the extract-one worker is pulling out: whether it is encrypted,
      and whether a wrong password already used the one automatic retry (#34). }
    FExtractOneEncrypted: Boolean;
    FExtractOnePasswordRetried: Boolean;
    FModifyMessage: string;

    procedure BuildUi;
    procedure BuildMenu;
    procedure BuildThemeMenus;
    procedure BuildIcons;
    function  AppIconIndex(const APath: string; out AImageIndex: Integer): Boolean;
    function  FsEntryIcon(Sender: TObject; const APath: string;
      AIsDir: Boolean; out AImageIndex: Integer): Boolean;
    procedure PurgeIconsFromBadBuild;
    procedure AppIconTimerTick(Sender: TObject);
    procedure RestoreIconCache;
    { Load every cached bundle icon in ONE batch, after the first frame. Called
      once from the app-icon timer: doing it before the first frame delayed the
      window; doing it per painted row made every refill a full list rebuild. }
    procedure RestoreAppIcons;
    { One-shot Application.OnIdle hook: marks the first painted frame and
      unhooks itself. No effect unless TYZIP_TIMING is set. }
    procedure FirstIdleMark(Sender: TObject; var Done: Boolean);
    procedure ScrollGuardTick(Sender: TObject);
    procedure FormResized(Sender: TObject);
    function  CacheEntryIsStale(const APath: string): Boolean;
    procedure CreateToolButton(var ABtn: TTyGlyphButton; const ACaption,
      AGlyph: string; AWidth: Integer; AOnClick: TNotifyEvent);
    procedure CreatePathButton(var ABtn: TTyGlyphButton; const AHint,
      AGlyph: string; AOnClick: TNotifyEvent);
    procedure SetupArchiveColumns;
    procedure PopulateArchiveTree;
    procedure SyncArchiveTreeSelection;
    function NodePath(ANode: PTyTreeNode): string;
    procedure SelectFsEntry(const APath: string);
    procedure FsTreePathChange(Sender: TObject);
    procedure ArcNavNodeMoved(Sender: TTyCustomTreeView; ANode: PTyTreeNode);
    procedure ArcNavGetImage(Sender: TTyCustomTreeView; ANode: PTyTreeNode;
      AKind: TTyVTImageKind; AColumn: Integer; var AGhosted: Boolean;
      var AImageIndex: Integer);
    procedure UpdateLanguageChecks;
    procedure UpdateThemeChecks;

    procedure MenuCloseArchiveClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuSelectAllClick(Sender: TObject);
    procedure MenuShowHiddenClick(Sender: TObject);
    procedure MenuSidebarClick(Sender: TObject);
    procedure MenuPreviewClick(Sender: TObject);
    procedure MenuLanguageClick(Sender: TObject);
    procedure MenuNameEncodingClick(Sender: TObject);
    { Ticks the per-archive name-encoding menu and grays it out unless the
      current archive is a top-level ZIP. }
    procedure UpdateNameEncodingMenu;
    procedure MenuThemeClick(Sender: TObject);
    procedure MenuModeClick(Sender: TObject);
    procedure MenuSettingsClick(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuAddFolderClick(Sender: TObject);

    procedure NewClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure ExtractClick(Sender: TObject);
    procedure TestClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure InfoClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure ForwardClick(Sender: TObject);
    procedure UpClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure FilterChange(Sender: TObject);
    procedure CrumbClick(Sender: TObject; AIndex: Integer);
    procedure BreadcrumbDblClick(Sender: TObject);
    procedure PathEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PathEditExit(Sender: TObject);
    procedure HidePathEdit;
    function BreadcrumbPathText: string;
    function NavigatePathText(const AText: string): Boolean;
    function ArchiveDirExists(ACtx: TArchiveContext; const APath: string): Boolean;

    procedure FsDirectoryChange(Sender: TObject);
    procedure FsFileActivate(Sender: TObject; AIndex: Integer);
    procedure ActivateFsData(AIndex: Integer);
    procedure FsSelectItem(Sender: TObject; AIndex: Integer; ASelected: Boolean);
    procedure ApplySidebarVisibility;
    procedure SideSplitterMoved(Sender: TObject);
    procedure PreviewSplitterMoved(Sender: TObject);
    procedure PreviewSplitterReleased(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ApplySplitterLook;
    procedure ApplyFlatContainers;
    procedure SideSplitterReleased(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ApplyPreviewVisibility;
    procedure ClearPreview;
    procedure ShowPreviewHint(const AText: string);
    procedure ShowPreviewFile(const APath, AName: string);
    procedure LoadPreviewText(const APath, AName: string; ASize: Int64);
    procedure CancelImageLoad;
    { Ask a worker to stop and remember it; it is freed when it finishes. }
    procedure RetireThread(AThread: TThread);
    procedure ReapRetiredThreads;
    procedure JoinRetiredThreads;
    { Resolve one suffix's icon NOW, on the main thread. }
    procedure ResolveIconNow(const AExt: string);
    { Resolve one bundle's icon NOW, on the main thread. }
    procedure ResolveAppIconNow(const APath: string);
    procedure PollImageLoad;
    procedure ApplyPreviewTheme;
    procedure PreviewFsAt(AIndex: Integer);
    procedure PreviewArchiveItem(const AItem: TListingItem);
    procedure PreviewTimerTick(Sender: TObject);
    procedure CancelPreviewRequest;
    procedure TryStartPreview;
    procedure StopPreview;
    procedure FsAddItem(Sender: TObject; const ABasePath: string;
      const AEntry: TTyFsEntry; var ACanAdd: Boolean);
    procedure BuildFsPopup;
    procedure FsListContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
    procedure FsPopupPopup(Sender: TObject);
    procedure FsPopupOpenClick(Sender: TObject);
    procedure FsPopupOpenArchiveClick(Sender: TObject);
    procedure FsPopupExtractHereClick(Sender: TObject);
    procedure FsPopupRevealClick(Sender: TObject);
    procedure FsPopupCopyPathClick(Sender: TObject);
    function FsPopupPath: string;
    procedure ExtractArchiveHere(const APath: string);
    procedure ArcItemActivate(Sender: TObject; AIndex: Integer);
    procedure ArcColumnClick(Sender: TObject; AColumn: Integer);
    function  ArcCellText(AIndex, AColumn: Integer): string;
    function  ArcCellImage(AIndex: Integer): Integer;
    procedure ArcSelectionChanged(Sender: TObject; AIndex: Integer;
      ASelected: Boolean);
    procedure ArcListMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ArcListMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure ArcListMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure StartArchiveDragOut;
    function  SelectedArchiveRootNames: TStringArray;
    procedure ArcKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    { Right-click menu for entries INSIDE an archive. The filesystem list has had
      one all along; without this, extracting one entry meant selecting it and
      going to the File menu. }
    procedure ArcListContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
    procedure ArcPopupPopup(Sender: TObject);
    procedure ArcPopupExtractClick(Sender: TObject);
    procedure ArcPopupExtractHereClick(Sender: TObject);
    procedure ArcPopupOpenClick(Sender: TObject);
    procedure ArcPopupTestClick(Sender: TObject);
    procedure ArcPopupCopyPathClick(Sender: TObject);
    procedure ArcPopupDeleteClick(Sender: TObject);
    procedure SearchClick(Sender: TObject);
    procedure ClearSearchClick(Sender: TObject);
    { Renaming rewrites the archive: 7-Zip has no rename, so the entry is
      extracted, re-added under its new path and the old one removed. }
    procedure ArcPopupRenameClick(Sender: TObject);
    procedure DoRenameEntry;
    procedure CollectEntryPaths(AList: TStrings);
    procedure StartRenameJob(const AEntry: TArchiveEntry; const ATarget: string);
    { Search across the whole archive rather than the current folder. Results
      replace the listing until the user clears the search or navigates. }

    function  SearchActive: Boolean;
    function ArcPopupOnEntry: Boolean;
    function IsArchiveForDefaultOpen(const APath: string): Boolean;
    function IconIndexFor(const AName: string; AIsDir, AIsArchive: Boolean): Integer;
    procedure QueueExtIcon(const AExt: string);
    procedure NeedFileIcon(Sender: TObject; const AExt: string);
    procedure IconTimerTick(Sender: TObject);
    procedure AddLoadedIcon(const AExt: string; ABitmap: TBGRABitmap;
      AStoreOnDisk: Boolean);
    function ArcSelectedRows: Integer;

    procedure NavigateFs(const APath: string; AAddHistory: Boolean = True);
    procedure LoadFsUi;
    procedure LoadArchiveUi;
    procedure RefreshArchiveListing;
    procedure UpdateBreadcrumbFs;
    procedure UpdateBreadcrumbArchive;
    procedure SetCrumbs(const ACrumbs: TCrumbArray);
    { The display names of the open archive chain, outermost first. }
    function ChainNames: TNavNameArray;
    procedure UpdateStatus;
    { Named RefreshActions rather than UpdateActions: the form's ancestor has an
      UpdateActions and hiding it was a compiler warning (and an easy way to call
      the wrong one). }
    procedure RefreshActions;
    procedure BeginBusy(const AMsg: string);
    procedure EndBusy;
    procedure PushBack;
    function CurrentState: TNavState;
    procedure ApplyState(const AState: TNavState);
    procedure GoBack;
    procedure GoForward;
    procedure SetArchiveContext(ACtx: TArchiveContext; const AInner: string;
      AAddHistory: Boolean = True);
    procedure ApplyListing(const AListing: TListing);
    procedure RefreshFilter;
    procedure ResetArchiveListing;
    procedure EnqueueJob(AJob: TZJob; APurpose: TZJobPurpose;
      const ATitle, ADetail: string);
    function  StartNextQueued: Boolean;
    procedure FinishBatch;
    { Show the summary the timer composed, after the timer has returned. }
    procedure ShowPendingBatchSummary(AData: PtrInt);
    procedure ClearQueuedJobs;
    procedure StartJobNow(AJob: TZJob; APurpose: TZJobPurpose;
      const ATitle, ADetail: string; ADeterminate, ACancelable: Boolean);
    procedure StartJob(AJob: TZJob; APurpose: TZJobPurpose;
      const ATitle, ADetail: string; ADeterminate, ACancelable: Boolean);
    procedure JobTimerTick(Sender: TObject);
    procedure CompleteJob(AResult: Integer; const AError: string);
    { The shared end of every completion, and the per-purpose handlers.
      RegisterJobHandlers fills the table once, in the constructor. }
    procedure RegisterJobHandlers;
    function  JobHandlerFor(APurpose: TZJobPurpose): TJobHandler;
    procedure FinishJob(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string);
    function HandleJobList(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobSearch(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobBatchList(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobBatchStage(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    { Start the next list->resolve->extract step of the batch pipeline. }
    procedure ContinueBatch;
    { The pipeline is over: optionally open the destination once, release the run. }
    procedure FinishBatchRun;
    { Drop rows whose name does not contain the current name filter. }
    function FilterListingByName(const AListing: TListing;
      const AFilter: string): TListing;
    { Ask a running search to stop; its result is discarded by design. }
    procedure CancelSearchJob;
    function HandleJobOpenExtractHere(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobOpen(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobOpenConvert(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobExtract(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobConvert(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobTest(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobCreate(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobModify(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function HandleJobExtractOne(AJob: TZJob; APurpose: TZJobPurpose;
      AResult: Integer; const AError: string): TJobHandlerOutcome;
    function RestartJobWithPassword(const APrompt: string): Boolean;
    procedure CreateOverlay;
    procedure RevealOverlay(Sender: TObject);
    procedure ShowOverlay(const ATitle, ADetail: string;
      ADeterminate, ACancelable: Boolean);
    procedure UpdateOverlayStats(ADone, ATotal: QWord);
    procedure SetOverlayProgress(ADone, ATotal: QWord; const ADetail: string);
    procedure HideOverlay;
    procedure OverlayCancelClick(Sender: TObject);
    procedure OverlayPauseClick(Sender: TObject);
    { Free the service progress window and quit, once nothing is running. }
    procedure MaybeFinishService;
    procedure LayoutOverlay;
    procedure ContentResize(Sender: TObject);
    procedure FilterTimerTick(Sender: TObject);
    { AExtractDest is only used by "extract here from the file list": the open
      job carries it so the completion does not have to read a form field that a
      different code path may have left behind. }
    procedure StartOpenArchive(const APath, ADisplayName: string;
      AParent: TArchiveContext; AIsNested: Boolean; const AOpenedFromFs: string;
      AAddHistory: Boolean; APurpose: TZJobPurpose; const AInner: string;
      const AExtractDest: string = ''; ANameCodepage: LongWord = 0);
    { The settings an update uses: the archive's own format and protection, plus
      the name encoding it was opened with, so a rewrite does not change it. }
    function ArchiveUpdateSettings: TCreateSettings;
    function SelectedArchiveIndices(ANeedSelection: Boolean): TLongWordArray;
    function SelectedArchiveRows: Integer;
    function SelectedFsPaths: TStringList;
    function CtxChain: TArchiveContextArray;
    function TempPathFor(const AName: string): string;

    procedure EnsureTempRoot;
    procedure ShowError(const AMsg: string);
    procedure OpenPathExternally(const APath: string);
    procedure OpenWithSpecificApp(const APath, AAppPath: string);
    function OpenWithPromptForApp(const APath: string): TZChooseAppResult;
    procedure OpenWithAppClick(Sender: TObject);
    procedure OpenWithOtherClick(Sender: TObject);
    procedure DeleteCreatedSources(AJob: TZJob);
    procedure DoCreateArchive(const ASources: TStringList; const APath: string;
      const ASettings: TCreateSettings);
    function CheckArchiveWritable: Boolean;
    procedure DoExtract(AExtractAll: Boolean);
    { The entries AIndices names, as tzip.extract's conflict policy wants them. }
    function ExtractEntryList(const AIndices: TLongWordArray): TExtractEntryArray;
    function  ExtractFallbackDir(const AArchivePath: string = ''): string;
    procedure DoTest;
    procedure DoAddFiles;
    procedure DoAddFolder;
    procedure DoDeleteEntries;
    procedure DoInfo;
    procedure ShowSettings;
    procedure ApplySettings;
    procedure ApplyTheme(const ATheme: string);
    procedure ApplyMode(const AMode: string);
    procedure SaveSettings;
    procedure LoadSettings;
    { What kind of control owns the keyboard right now, for the shortcut gate in
      tzip.navpaths. }
    function FocusedControlKind: TNavFocusKind;
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure AppDropFiles(Sender: TObject; const FileNames: array of string);
    procedure OpenStartupPath(const APath: string);
    { Files handed over by the OS (Finder "Open With"). One file opens here; a
      multi-selection opens the first here and hands the rest to new instances. }
    procedure OpenFilesFromSystem(const APaths: array of string);
    { Open one more file from the pending list, one per timer tick. }
    procedure OpenNextInstanceTick(Sender: TObject);
    procedure OpenOne(const APath: string);
    procedure AddDroppedFiles(const APaths: array of string);
    function  ConfirmDropAdd(const AMsg: string): Boolean;
    function  AskDropConflict(const AMsg: string): TModalResult;
    procedure FocusFsList(AData: PtrInt);
    procedure FocusStartupList(AData: PtrInt);
    procedure RememberRecentArchive(const APath: string);
    procedure RecentArchiveActivate(Sender: TObject);
    procedure LayoutStartupHint;
    procedure ShowStartupHint;
    procedure HideStartupHint;
    procedure StartupBrowseFilesClick(Sender: TObject);
    procedure StartupBrowseFolderClick(Sender: TObject);
    procedure ApplyTabOrder;
    procedure ActivateFsDataAsync(AData: PtrInt);
    procedure ReleaseStuckCapture;

    procedure AppActivate(Sender: TObject);
    procedure CheckEditWriteBack;
    procedure WriteEditedEntryBack(const AEntryPath, ATempPath: string);
    procedure ShowArchiveComment;
    procedure SaveArchiveComment(const AComment: string);
    procedure DoConvertArchive(AAllowBusy: Boolean = False);
    procedure StartConvertForOpenArchive;
    procedure MenuConvertClick(Sender: TObject);
    procedure DoCreateFromPaths(APaths: TStringList);
    { Ask before replacing an existing target archive. }
    function  ConfirmReplaceTarget(const APath: string): Boolean;
    { Returns how many archives were queued (0 when none qualified). }
    function  BatchExtract(const APaths: TStrings; const ADest: string): Integer;
    procedure BatchTest(const APaths: TStrings);
    procedure MenuExtractAllClick(Sender: TObject);
    procedure BatchExtractToOwnFolders(const APaths: TStrings);
    function  CountArchivesIn(APaths: TStrings): Integer;
    procedure FsPopupCreateFromSelectionClick(Sender: TObject);
    procedure FsPopupCreateClick(Sender: TObject);
    procedure FsPopupCreateHereClick(Sender: TObject);
    procedure FsPopupCreateEachClick(Sender: TObject);
    procedure FsPopupConvertClick(Sender: TObject);
    procedure BeginConvertFor(const APath: string);
    procedure FsPopupBatchExtractDialogClick(Sender: TObject);
    procedure FsPopupBatchExtractHereClick(Sender: TObject);
    procedure FsPopupBatchExtractToFolderClick(Sender: TObject);
    procedure FsPopupBatchTestClick(Sender: TObject);
    procedure DoCreateHere(APaths: TStrings);
    function  CreateHereTargetFor(const APath: string): string;
    { The archive format used when the user has not chosen one yet. }
    function  DefaultArchiveFormat: string;
    { The synthetic ".." first row of an archive listing. }
    procedure InitParentListingItem(var AItem: TListingItem);
    { Restart a debounce timer from now (a running TTimer ignores Enabled := True). }
    procedure RestartTimer(ATimer: TTimer);
    procedure DoCreateEachArchive(APaths: TStrings);
    procedure StartExtractFrom(AArchives: TStrings);
    { Finder's "Smart Extract": one click, no dialog, layout by archive structure. }
    procedure StartSmartExtract(AArchives: TStrings);
    {$IFDEF DARWIN}
    { Finder Services: build an archive from what was selected, or extract. }
    function HandleService(ARequest: TServiceRequest;
      APaths: TStrings): string;
    {$ENDIF}
    procedure ArcPopupCommentClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AfterConstruction; override;
    { Row count of the current archive listing (TArcListView's data source). }
    function  ListingCount: Integer;
  end;

var
  MainForm: TMainForm;



{ Install a deterministic icon source for tests, BEFORE the window is built. The
  window never calls this itself; a normal run uses tzip.platform's real icons. }
procedure TzInstallTestIconProvider(AProvider: TZIconProvider);

implementation


{ A real, existing file with this extension, for the platform to resolve an icon
  from. NSWorkspace's iconForFile returns the coloured, fully styled glyph; its
  iconForFileType returns the type's template outline, which is why every document
  row looked like a blank sheet. The probe files are empty, created once per
  extension, and left for the session. }


function TzTempRootForPid: string; forward;
procedure TzDeleteTempRoot(const AStatedRoot: string); forward;


constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FLaunchTick := GetTickCount64;
  { No form-level scrolling.  Every pane is aligned to the client area, and an
    absolutely positioned child (the welcome block or the busy card) must not be
    able to give the form an auto-scroll range: one wheel tick would then shift
    the whole surface -- title bar included -- and push the status bar off
    screen. }
  AutoScroll := False;
  Caption := rsAppName;
  Name := 'MainForm';
  Position := poScreenCenter;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Constraints.MinWidth := 980;
  Constraints.MinHeight := 620;
  Width := 1280;
  Height := 820;
  KeyPreview := True;
  OnKeyDown := @FormKeyDown;
  OnCloseQuery := @FormCloseQuery;
  AllowDropFiles := True;
  OnDropFiles := @FormDropFiles;
  { TWO channels, deliberately:

    Application.OnDropFiles fires for files the OS asked us to OPEN (a Finder
    "Open With", a double click, files dropped on the app icon). The Cocoa
    widgetset funnels those through Application.IntfDropFiles and then -- in the
    same breath -- through MainForm.IntfDropFiles, so both this and FormDropFiles
    would see them; the application-level one is the ONLY one that a real drag
    onto a window never reaches. Routing opens here is what keeps "drag a file
    into an archive" and "ask TyZip to open a file" from being the same gesture.

    FormDropFiles therefore means drag-and-drop only. }
  Application.OnDropFiles := @AppDropFiles;
  FSortCol := ascName;
  FSortDesc := False;
  FArcListPaths := TStringList.Create;
  FHistory := TNavHistory.Create;
  FIconStore := TZIconStore.Create;
  FFsPopupPaths := TStringList.Create;
  FOpenWithPaths := TStringList.Create;
  FJobs := TJobController.Create;
  RegisterJobHandlers;
  FRetiring := TList.Create;
  FRecentArchives := TStringList.Create;
  FPendingOpenPaths := TStringList.Create;
  FOpenOneTimer := TTimer.Create(Self);
  FOpenOneTimer.Interval := 1500;
  FOpenOneTimer.Enabled := False;
  FOpenOneTimer.OnTimer := @OpenNextInstanceTick;
  FScrollGuardTimer := TTimer.Create(Self);
  FScrollGuardTimer.Interval := 100;
  FScrollGuardTimer.Enabled := False;
  FScrollGuardTimer.OnTimer := @ScrollGuardTick;
  FIconWorkStartTick := GetTickCount64;
end;

destructor TMainForm.Destroy;
var
  Seen: TList;
  Files: TStringList;
  I: Integer;
  NavStates: TNavStateArray;

  procedure Remember(C: TArchiveContext);
  begin
    if (C <> nil) and (Seen.IndexOf(C) < 0) then Seen.Add(C);
  end;

begin
  { Detach the application-level callbacks FIRST: they point at methods of this
    object, and they can fire from the platform's run loop while the window is
    being destroyed (the Finder "open with" channel, app activation and the
    installed services provider all live outside the form). }
  FReady := False;
  if FScrollGuardTimer <> nil then FScrollGuardTimer.Enabled := False;
  TzUnguardFormScroll(Self);
  Application.OnDropFiles := nil;
  Application.OnActivate := nil;
  {$IFDEF DARWIN}
  { The provider itself stays registered with AppKit, but with no handler it can
    no longer call into a freed form. }
  TzInstallServices(nil);
  {$ENDIF}
  { Construction can fail half-way -- BuildIcons or BuildUi raise before the
    overlay's timer exists -- and the destructor must not turn that original
    exception into a second, masking crash. }
  if FJobTimer <> nil then FJobTimer.Enabled := False;
  if FJob <> nil then
  begin
    FJob.RequestCancel;
    FJob.WaitFor;
    FreeAndNil(FJob);
  end;
  StopPreview;
  Seen := TList.Create;
  try
    Remember(FCtx);
    NavStates := FHistory.BackStates;
    for I := 0 to High(NavStates) do Remember(NavStates[I].Ctx);
    NavStates := FHistory.ForwardStates;
    for I := 0 to High(NavStates) do Remember(NavStates[I].Ctx);
    for I := 0 to Seen.Count - 1 do
      TArchiveContext(Seen[I]).Free;
  finally
    Seen.Free;
  end;
  if FAppPrefetcher <> nil then
  begin
    FAppPrefetcher.Stop;
    FreeAndNil(FAppPrefetcher);
  end;
  FHistory.Free;
  CancelImageLoad;
  { A worker must not outlive the form: here, at teardown, waiting is correct --
    the bitmap it is decoding and the temp file it is writing are freed below. }
  JoinRetiredThreads;
  { Everything this session unpacked for "open/view" lives in one directory named
    after the PID, and it is removed only now: deleting it while a preview worker
    was still writing into it (what FormCloseQuery used to do) made the running
    extraction fail on a file that had just been unlinked. TempRootForPid is used
    rather than FTempRoot, which is only assigned once something needed a temp
    file. }
  TzDeleteTempRoot(FTempRoot);
  FArcListPaths.Free;
  FIconStore.Free;
  FIconCache.Free;
  FFsPopupPaths.Free;
  FOpenWithPaths.Free;
  FRecentArchives.Free;
  FPendingOpenPaths.Free;
  FRetiring.Free;

  { Any job still waiting for its turn: freed here, before the contexts below, so
    closing the window mid-batch does not leak a thread and its inputs. }
  FreeAndNil(FBatchRun);
  FreeAndNil(FBatchTally);
  FJobs.Free;
  { The list's Source is created and owned by this form, not by the list. Detach it
    before freeing: the control is destroyed later (in inherited Destroy) and must
    not be left holding a freed pointer. }
  if FArcList <> nil then FArcList.Source := nil;
  FreeAndNil(FArcSource);
  FIconImages.Free;
  FIconCollection.Free;
  inherited Destroy;
end;

procedure TMainForm.AfterConstruction;
var
  StartupPath: string;
begin
  inherited AfterConstruction;
  FStartupPhase := True;
  { Cache location, chosen at runtime: the settings folder when the environment
    lets us create a subdirectory there, otherwise the OS temp root. It is ONE
    path per run -- a directory that cannot be created must not be retried for
    every icon, and an unwritable choice simply leaves icons loading live. }
  TzMark('AfterConstruction begin');
  FIconCacheDir := ChooseIconCacheDir;
  FIconCache := TIconCache.Create(FIconCacheDir);
  { Earlier builds cached the fallback DRAWING when NSWorkspace answered late,
    and a cached base glyph is permanent: the tree and list fall back on it, so
    every folder wore a blank page until the file was deleted by hand. Those
    files cannot be told from real icons by name, so they are dropped once when a
    marker file says they came from such a build. }
  if FIconCache <> nil then
    PurgeIconsFromBadBuild;
  BuildIcons;
  TzMark('BuildIcons done');
  BuildUi;
  TzMark('BuildUi done');
  BuildMenu;
  TzMark('BuildMenu done');
  FSettingsIni := TzConfigDir + 'TyZip.ini';
  LoadSettings;
  LoadRecentArchives(FSettingsIni, FRecentArchives);
  { Startup starts with no navigator panes: until a view is chosen the file list,
    the sidebar tree and the breadcrumb would show the working directory (or the
    home folder) before the archive the user actually asked for. }
  FSidePanel.Visible := False;
  FPathPanel.Visible := False;
  FPreviewPanel.Visible := False;
  FPreviewSplitter.Visible := False;
  TzMark('LoadSettings done');
  UpdateLanguageChecks;
  FReady := True;
  TzLoadLibrary;
  if TzLibraryPath <> '' then
  begin
    FFormats := TzLoadFormats;
    StartupPath := '';
    FStartupAsArchive := False;
    if (ParamCount >= 2) and (ParamStr(1) = '--open-as-archive') and
       (ParamStr(2) <> '') then
    begin
      FStartupAsArchive := True;
      StartupPath := ExpandFileName(ParamStr(2));
    end
    else if (ParamCount >= 1) and (ParamStr(1) <> '') and
       (Copy(ParamStr(1), 1, 2) <> '--') then
      StartupPath := ExpandFileName(ParamStr(1));
    if (StartupPath <> '') and FileExists(StartupPath) and
       (FStartupAsArchive or TzIsArchiveName(StartupPath)) then
    begin
      { Opening an archive is the whole request: no folder view first.  FFsPath
        still gets the archive's folder so the extract/save dialogs have a
        sensible default, but nothing is listed until something leaves it. }
      FFsPath := ExcludeTrailingPathDelimiter(ExtractFileDir(StartupPath));
      TzMark('startup archive: skip home');
    end
    else if StartupPath <> '' then
    begin
      NavigateFs(GetUserDir);
      TzMark('NavigateFs(home)');
    end;
    if StartupPath <> '' then
    begin
      TzMark('before startup path');
      OpenStartupPath(StartupPath);
    end
    else
    begin
      { The shell list loads the working directory when it is created, which set
        FFsPath behind our back; a plain launch has no folder yet. }
      FFsPath := '';
      { Shown before the first paint: the window is never empty, and if a Finder
        double click arrives a moment later the opening card simply replaces it. }
      ShowStartupHint;
    end;
    TzMark('startup path opened');
    { Reveal the opening card on the very first paint.  The deferred 140 ms
      reveal exists to avoid a flash for fast jobs, but a launch that opens an
      archive has no other content to show; without this the first frame is an
      empty window and the card appears a beat later. }
    if FJob <> nil then
      RevealOverlay(nil);
  end
  else
    ShowError(rsErrEngineMissing);
  { Startup focus belongs on the listing, not on the first focusable control the
    window happens to offer (the Back button, which is also disabled at that
    point). Deferred for the same reason as in NavigateFs: touching focus before
    the first paint upsets the window. }
  { Kick the icon timer once: it drains the base-glyph queue and reads the disk
    cache on its first tick, i.e. after the window is on screen. }
  if FIconTimer <> nil then
  begin
    FIconTimer.Enabled := True;
  end;
  Application.QueueAsyncCall(@FocusStartupList, 0);
  Application.OnIdle := @FirstIdleMark;
end;

{ Tab order, per parent: TabOrder counts within one parent only, so the two
  listings (both children of FContent) and the surface's own children are two
  separate runs. The listings get 0 and 1 there, and the surface's children start
  after the content panel, which gives the window's initial focus to the listing
  instead of to the Back button -- the first focusable control created, and one
  that is disabled at startup anyway. }
procedure TMainForm.ApplyTabOrder;
begin
  { Inside FContent: the divider, the visible listing, then the preview pane. }
  if FPreviewSplitter <> nil then FPreviewSplitter.TabOrder := 0;
  if FFsList <> nil then FFsList.TabOrder := 1;
  if FArcList <> nil then FArcList.TabOrder := 2;
  if FPreviewPanel <> nil then FPreviewPanel.TabOrder := 3;
  { Inside FSurface: the listings' container first, then the chrome around it. }
  if FContent <> nil then FContent.TabOrder := 0;
  if FSidePanel <> nil then FSidePanel.TabOrder := 1;
  if FPathPanel <> nil then FPathPanel.TabOrder := 2;
  if FToolBar <> nil then FToolBar.TabOrder := 3;
  if FStatus <> nil then FStatus.TabOrder := 4;
end;







{ Centre the hint over the visible listing, not the whole content panel: the
  preview pane on the right would otherwise paint over half of the text. }
procedure TMainForm.LayoutStartupHint;
var
  Right, X, ButtonsLeft, ButtonsWidth, ButtonHeight, ButtonTop, Total, Y: Integer;
begin
  if (FStartupHint = nil) or (FContent = nil) then Exit;
  Right := FContent.ClientWidth;
  if (FPreviewSplitter <> nil) and FPreviewSplitter.Visible then
    Right := FPreviewSplitter.Left;
  X := (Right - FStartupHint.Width) div 2;
  if X < 8 then X := 8;
  FStartupHint.Left := X;

  ButtonHeight := 32;
  if FStartupBrowseFiles <> nil then ButtonHeight := FStartupBrowseFiles.Height;
  ButtonsWidth := 0;
  if FStartupBrowseFiles <> nil then ButtonsWidth := FStartupBrowseFiles.Width;
  if FStartupBrowseFolder <> nil then
  begin
    if ButtonsWidth > 0 then Inc(ButtonsWidth, 8);
    Inc(ButtonsWidth, FStartupBrowseFolder.Width);
  end;
  ButtonsLeft := X + (FStartupHint.Width - ButtonsWidth) div 2;
  if ButtonsLeft < 8 then ButtonsLeft := 8;

  Total := FStartupHint.Height + 12 + ButtonHeight;
  if (FRecentList <> nil) and FRecentList.Visible then
    Inc(Total, 16 + FRecentTitle.Height + 4 + FRecentList.Height);

  Y := (FContent.ClientHeight - Total) div 2;
  { Before the form has a size ClientHeight is 0; a negative Top would put the
    label above the client area (and would enable form auto-scrolling even
    though AutoScroll is off).  ContentResize re-centres it once sized. }
  if Y < 8 then Y := 8;
  FStartupHint.Top := Y;

  ButtonTop := Y + FStartupHint.Height + 12;
  if FStartupBrowseFiles <> nil then
  begin
    FStartupBrowseFiles.Left := ButtonsLeft;
    FStartupBrowseFiles.Top := ButtonTop;
  end;
  if FStartupBrowseFolder <> nil then
  begin
    FStartupBrowseFolder.Left := ButtonsLeft + FStartupBrowseFiles.Width + 8;
    FStartupBrowseFolder.Top := ButtonTop;
  end;

  if (FRecentList <> nil) and FRecentList.Visible then
  begin
    FRecentTitle.Left := X;
    FRecentTitle.Top := ButtonTop + ButtonHeight + 16;
    FRecentList.Left := X;
    FRecentList.Top := FRecentTitle.Top + FRecentTitle.Height + 4;
  end;
end;

procedure TMainForm.ShowStartupHint;
var
  I: Integer;
  P: string;
begin
  if FStartupHint = nil then Exit;
  FRecentList.Items.BeginUpdate;
  try
    FRecentList.Items.Clear;
    for I := 0 to FRecentArchives.Count - 1 do
    begin
      P := FRecentArchives[I];
      if FileExists(P) then FRecentList.Items.Add(P);
    end;
  finally
    FRecentList.Items.EndUpdate;
  end;
  FRecentList.Height := 24 * FRecentList.Items.Count + 6;
  if FRecentList.Height > 150 then FRecentList.Height := 150;
  FRecentTitle.Visible := FRecentList.Items.Count > 0;
  FRecentList.Visible := FRecentList.Items.Count > 0;
  if FStartupBrowseFiles <> nil then FStartupBrowseFiles.Visible := True;
  if FStartupBrowseFolder <> nil then FStartupBrowseFolder.Visible := True;
  LayoutStartupHint;
  FStartupHint.Visible := True;
  FStartupHint.BringToFront;
  if FStartupBrowseFiles <> nil then FStartupBrowseFiles.BringToFront;
  if FStartupBrowseFolder <> nil then FStartupBrowseFolder.BringToFront;
  if FRecentTitle.Visible then
  begin
    FRecentTitle.BringToFront;
    FRecentList.BringToFront;
  end;
  { The welcome screen is the only state with no archive and no folder: grey out
    the archive-only toolbar actions now. LoadFsUi/LoadArchiveUi run this again
    after the first navigation; until this call the buttons kept their creation
    default, Enabled=true (ticket 41). }
  RefreshActions;
end;

procedure TMainForm.HideStartupHint;
begin
  if FStartupHint <> nil then FStartupHint.Visible := False;
  if FStartupBrowseFiles <> nil then FStartupBrowseFiles.Visible := False;
  if FStartupBrowseFolder <> nil then FStartupBrowseFolder.Visible := False;
  if FRecentTitle <> nil then FRecentTitle.Visible := False;
  if FRecentList <> nil then FRecentList.Visible := False;
end;

{ The welcome screen's file chooser: the same archive dialog the toolbar's
  "Open" uses. }
procedure TMainForm.StartupBrowseFilesClick(Sender: TObject);
begin
  OpenClick(Sender);
end;

{ The welcome screen's folder chooser: pick any folder and enter the file
  manager there (NavigateFs hides the welcome view). }
procedure TMainForm.StartupBrowseFolderClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := GetUserDir;
  if not TySelectDirectory(rsStartupChooseFolder, '', Dir) then Exit;
  if Dir = '' then Exit;
  NavigateFs(Dir);
end;

{ A real archive opened from disk is what the welcome list remembers. }
procedure TMainForm.RememberRecentArchive(const APath: string);
var
  P: string;
  I: Integer;
begin
  P := ExpandFileName(APath);
  if not FileExists(P) then Exit;
  for I := FRecentArchives.Count - 1 downto 0 do
    if SameText(ExpandFileName(FRecentArchives[I]), P) then
      FRecentArchives.Delete(I);
  FRecentArchives.Insert(0, P);
  while FRecentArchives.Count > MaxRecentArchives do
    FRecentArchives.Delete(FRecentArchives.Count - 1);
  SaveRecentArchives(FSettingsIni, FRecentArchives);
end;

procedure TMainForm.RecentArchiveActivate(Sender: TObject);
var
  P: string;
begin
  if (FRecentList = nil) or (FRecentList.ItemIndex < 0) then Exit;
  P := FRecentList.Items[FRecentList.ItemIndex];
  if not FileExists(P) then
  begin
    ShowError(Format(rsErrFileNotFoundFmt, [P]));
    Exit;
  end;
  HideStartupHint;
  StartOpenArchive(P, ExtractFileName(P), nil, False,
    ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False, jpOpenBrowse, '');
end;

procedure TMainForm.FocusStartupList(AData: PtrInt);
begin
  if not FReady then Exit;
  if FMode = nkArchive then
  begin
    if (FArcList <> nil) and FArcList.CanFocus and FArcList.Visible then
    begin
      try
        FArcList.SetFocus;
      except
        { focus is cosmetic; never let it break startup }
      end;
      Exit;
    end;
  end;
  FocusFsList(0);
end;



{ ---------------------------------------------------------------------------
  TFsSidebarTree
  --------------------------------------------------------------------------- }


procedure TMainForm.BuildUi;
var
  X, I: Integer;
  Sep: TTyToolSeparator;
  P: TTyPanel;
begin
  TyRegisterBuiltinThemes;
  { SynEdit's default editor font quality is fqNonAntialiased on every platform;
    set it once here so no editor the app creates inherits jagged text. }
  SynDefaultFontQuality := fqDefault;
  TyDefaultController.ThemeName := 'default';
  Self.Controller := TyDefaultController;

  { TTyForm content host + custom title bar + menu bar (the toolwindows example's
    structure; on macOS TTyForm hands the TMainMenu to the global menu bar). }
  FSurface := TTyFormSurface.Create(Self);
  FSurface.Parent := Self;
  FSurface.Align := alClient;
  FSurface.Name := 'Surface';

  FMainMenu := TMainMenu.Create(Self);
  FMainMenu.Name := 'MainMenu1';

  FTitleBar := TTyTitleBar.Create(Self);
  FTitleBar.Parent := FSurface;
  FTitleBar.Align := alTop;
  FTitleBar.Height := 36;
  FTitleBar.Caption := rsAppName;
  FTitleBar.ShowIcon := True;
  FTitleBar.TitleAlignment := taLeftJustify;

  FMenuBar := TTyMenuBar.Create(Self);
  FMenuBar.Parent := FTitleBar;
  FMenuBar.Align := alLeft;
  FMenuBar.BorderSpacing.Top := 5;
  FMenuBar.BorderSpacing.Bottom := 5;
  FMenuBar.Menu := FMainMenu;
  FMenuBar.AutoSizeWidth := True;

  Self.TitleBar := FTitleBar;
  Self.MenuBar := FMenuBar;

  { Navigation bar: back / forward / up, editable breadcrumb, filter on its right.
    It is created before the toolbar; explicit Top values put the toolbar ABOVE it
    (LCL's alTop stack sorts its children by Top). }
  FPathPanel := TTyPanel.Create(Self);
  FPathPanel.Parent := FSurface;
  FPathPanel.Align := alTop;
  FPathPanel.Height := 44;
  FPathPanel.Top := 96;
  FPathPanel.Caption := '';

  CreatePathButton(FBackBtn, rsMenuBack, TyIconArrowLeft, @BackClick);
  FBackBtn.Left := 8; FBackBtn.Top := 8;
  CreatePathButton(FForwardBtn, rsMenuForward, TyIconArrowRight, @ForwardClick);
  FForwardBtn.Left := 42; FForwardBtn.Top := 8;
  CreatePathButton(FUpBtn, rsMenuUp, TyIconArrowUp, @UpClick);
  FUpBtn.Left := 76; FUpBtn.Top := 8;

  FBreadcrumb := TTyBreadcrumb.Create(Self);
  FBreadcrumb.Parent := FPathPanel;
  FBreadcrumb.Left := 118;
  FBreadcrumb.Top := 8;
  FBreadcrumb.Height := 28;
  FBreadcrumb.Width := 620;
  FBreadcrumb.Anchors := [akLeft, akTop, akRight];
  FBreadcrumb.OnCrumbClick := @CrumbClick;
  FBreadcrumb.OnDblClick := @BreadcrumbDblClick;

  { Filter lives at the right end of the navigation bar. }
  FFilterEdit := TTyEdit.Create(Self);
  FFilterEdit.Parent := FPathPanel;
  FFilterEdit.Width := 220;
  FFilterEdit.Height := 28;
  FFilterEdit.Top := 8;
  FFilterEdit.Anchors := [akTop, akRight];
  FFilterEdit.AnchorSide[akRight].Control := FPathPanel;
  FFilterEdit.AnchorSide[akRight].Side := asrRight;
  FFilterEdit.BorderSpacing.Right := 10;
  FFilterEdit.TextHint := rsFilterHint;
  FFilterEdit.OnChange := @FilterChange;
  FFilterEdit.Name := 'FilterEdit';

  { Preview-pane toggle lives to the right of the filter, not inside the pane
    itself, so it stays reachable when the pane is collapsed. }
  CreatePathButton(FPreviewToggleBtn, rsPreviewHideHint, TyIconPanelRightClose,
    @MenuPreviewClick);
  { Keep this a pure glyph button: no Name/Caption is assigned, so the button
    does not reserve caption space beside the icon. }
  FPreviewToggleBtn.Caption := '';
  FPreviewToggleBtn.AutoSize := False;
  { CreatePathButton leaves Top at 0, but the navigation bar is 44px tall and
    the button 28px: the three navigation buttons set Top := 8 by hand right
    after their factory call, and this one has to match or it sits glued to the
    bar's top edge. }
  FPreviewToggleBtn.Top := 8;
  FPreviewToggleBtn.Width := 30;
  FPreviewToggleBtn.Anchors := [akTop, akRight];
  FPreviewToggleBtn.AnchorSide[akRight].Control := FPathPanel;
  FPreviewToggleBtn.AnchorSide[akRight].Side := asrRight;
  FPreviewToggleBtn.BorderSpacing.Right := 10;
  { Shift the filter left by the button's width and a small gap. }
  FFilterEdit.AnchorSide[akRight].Control := FPreviewToggleBtn;
  FFilterEdit.AnchorSide[akRight].Side := asrLeft;
  FFilterEdit.BorderSpacing.Right := 8;

  { In-place address editor: a double-click on the breadcrumb swaps this edit in. }
  FPathEdit := TTyEdit.Create(Self);
  FPathEdit.Parent := FPathPanel;
  FPathEdit.Left := FBreadcrumb.Left;
  FPathEdit.Top := FBreadcrumb.Top;
  FPathEdit.Width := FBreadcrumb.Width;
  FPathEdit.Height := FBreadcrumb.Height;
  FPathEdit.Visible := False;
  FPathEdit.Anchors := [akLeft, akTop, akRight];
  FPathEdit.AnchorSide[akRight].Control := FFilterEdit;
  FPathEdit.AnchorSide[akRight].Side := asrLeft;
  FPathEdit.BorderSpacing.Right := 8;
  FPathEdit.OnKeyDown := @PathEditKeyDown;
  FPathEdit.OnExit := @PathEditExit;
  FPathEdit.Name := 'PathEdit';

  { The breadcrumb stops where the filter starts, so overflow elides before it
    can run underneath the filter box. }
  FBreadcrumb.AnchorSide[akRight].Control := FFilterEdit;
  FBreadcrumb.AnchorSide[akRight].Side := asrLeft;
  FBreadcrumb.BorderSpacing.Right := 8;

  { Toolbar: big buttons with the glyph stacked ABOVE the caption. }
  FToolBar := TTyToolBar.Create(Self);
  FToolBar.Parent := FSurface;
  FToolBar.Align := alTop;
  FToolBar.Top := 36;
  FToolBar.Height := 52;
  FToolBar.Flat := True;
  FToolBar.ShowCaptions := True;
  FToolBar.ButtonHeight := 40;
  FToolBar.ButtonSpacing := 6;
  FToolBar.Indent := 10;
  FToolBar.Caption := '';

  X := 10;
  CreateToolButton(FNewBtn, rsToolNew, TyIconFilePlus, 92, @NewClick);
  FNewBtn.Left := X; Inc(X, FNewBtn.Width + 4);
  CreateToolButton(FOpenBtn, rsToolOpen, TyIconFolderOpen, 92, @OpenClick);
  FOpenBtn.Left := X; Inc(X, FOpenBtn.Width + 6);
  Sep := TTyToolSeparator.Create(Self); Sep.Parent := FToolBar;
  Sep.Left := X; Sep.Top := 12; Sep.Width := 8; Inc(X, 12);
  CreateToolButton(FExtractBtn, rsToolExtract, TyIconArchiveRestore, 102, @ExtractClick);
  FExtractBtn.Left := X; Inc(X, FExtractBtn.Width + 4);
  CreateToolButton(FTestBtn, rsToolTest, TyIconShieldCheck, 88, @TestClick);
  FTestBtn.Left := X; Inc(X, FTestBtn.Width + 6);
  Sep := TTyToolSeparator.Create(Self); Sep.Parent := FToolBar;
  Sep.Left := X; Sep.Top := 12; Sep.Width := 8; Inc(X, 12);
  CreateToolButton(FAddBtn, rsToolAdd, TyIconPlus, 90, @AddClick);
  FAddBtn.Left := X; Inc(X, FAddBtn.Width + 4);
  CreateToolButton(FDelBtn, rsToolDelete, TyIconTrash2, 94, @DeleteClick);
  FDelBtn.Left := X; Inc(X, FDelBtn.Width + 4);
  CreateToolButton(FInfoBtn, rsToolInfo, TyIconInfo, 84, @InfoClick);
  FInfoBtn.Left := X; Inc(X, FInfoBtn.Width + 4);
  CreateToolButton(FConvertBtn, rsToolConvert, TyIconRefreshCw, 96, @MenuConvertClick);
  FConvertBtn.Left := X; Inc(X, FConvertBtn.Width + 8);

  FStatus := TTyStatusBar.Create(Self);
  FStatus.Parent := FSurface;
  FStatus.Align := alBottom;
  FStatus.Height := 26;
  FStatus.SimplePanel := True;

  FSidePanel := TTyPanel.Create(Self);
  FSidePanel.Parent := FSurface;
  FSidePanel.Align := alLeft;
  FSidePanel.Width := 260;
  FSidePanel.Caption := '';

  { No heading. macOS source lists do not carry one, and it cost 30 px of vertical
    space that the content pane does not lose: the sidebar's first row started a
    header's height below the file list's first row, so the two columns never lined
    up. The tree now begins where the list's header begins. }

  { Custom filesystem sidebar: unlike the stock TTyShellTreeView constructor this
    does not scan /Volumes at startup. It reads only "/" and expands one folder at
    a time. See TFsSidebarTree for the macOS network-volume prompt background. }
  FFsTree := TFsSidebarTree.Create(Self);
  FFsTree.Parent := FSidePanel;
  FFsTree.Align := alClient;
  { Flush to the panel edges: the tree's rows start where the panel's tint starts,
    and the hairline divider that separates it from the content is the panel's own.
    An inset here left a white frame around the tinted source list. }
  FFsTree.Images := FIconImages;
  FFsTree.ShowHidden := False;
  { Keep the current folder visible while the user works in the file list: with
    the tree unfocused the highlight used to disappear entirely, so there was no
    way to tell which folder was open. }
  FFsTree.HideSelection := False;
  { Dotted guide lines make a file tree noisy, and the expander triangles already
    show where the nesting is. }
  FFsTree.ShowTreeLines := False;
  FFsTree.OnPathChange := @FsTreePathChange;
  FFsTree.Name := 'FsTree';

  FArcNavTree := TTyTreeView.Create(Self);
  FArcNavTree.Parent := FSidePanel;
  FArcNavTree.Align := alClient;
  { Same flush layout as the sidebar tree. }
  FArcNavTree.Visible := False;
  FArcNavTree.ShowButtons := True;
  FArcNavTree.ShowTreeLines := False;
  FArcNavTree.ShowRoot := False;
  FArcNavTree.HideSelection := False;
  FArcNavTree.Images := FIconImages;
  { The archive tree is single-select: TyControls announces the move through
    OnChange, not OnSelectionChanged (see tzip.ui.arctree). Binding the wrong one
    made every click on a folder row silent. }
  TzBindTreeMoved(FArcNavTree, @ArcNavNodeMoved);
  { Without this the tree had an image list but no image provider, so every
    archive folder row painted text with a blank 16px slot in front of it. }
  FArcNavTree.OnGetImageIndex := @ArcNavGetImage;
  FArcNavTree.Name := 'ArcNavTree';

  { Divider between the sidebar and the content. LCL sorts alLeft siblings by
    their CURRENT Left and breaks ties by the order they were aligned in, and
    once a control has been laid out at x=0 the sort keeps it there. Created at
    the default Left it therefore landed BEFORE the sidebar, where there is no
    control on its left to resize -- which is why dragging the sidebar's edge did
    nothing. Starting it beyond the sidebar makes the first layout pass put it to
    the sidebar's right, which is where a splitter resizes the sidebar. }
  FSplitter := TTySplitter.Create(Self);
  FSplitter.Parent := FSurface;
  FSplitter.Left := 1000;
  FSplitter.Width := 5;
  FSplitter.MinSize := 180;
  FSplitter.Align := alLeft;
  FSplitter.Name := 'Splitter';
  FSplitter.OnMoved := @SideSplitterMoved;
  FSplitter.OnMouseUp := @SideSplitterReleased;

  FContent := TTyPanel.Create(Self);
  FContent.Parent := FSurface;
  FContent.Align := alClient;
  FContent.Caption := '';

  { Preview pane on the right.  Create the panel before its splitter so the
    splitter lands on the pane's outer edge and the file list keeps alClient. }
  { The pane builds the title, hint, the two text viewers and their bar. The
    image controls below are still created here and parented into the pane/bar,
    because their step has not moved yet. }
  FPreviewPanel := TPreviewPane.Create(Self);
  FPreviewPanel.Parent := FContent;
  FPreviewBar := FPreviewPanel.Bar;

  FPreviewTimer := TTimer.Create(Self);
  FPreviewTimer.Interval := 30;
  FPreviewTimer.Enabled := False;
  FPreviewTimer.OnTimer := @PreviewTimerTick;

  { alRight siblings are laid out right to left, largest Left + Width first, and
    the pane (created above with Width 320) therefore lands against the right edge
    while this divider follows it on the pane's inner side -- which is where a
    pane divider belongs, and where TTySplitter's alRight target search expects to
    find the pane. Leaving Left at its default keeps both at zero so that
    comparison decides the order; giving the divider a Left of its own (it was
    4000) sorted it in front of the pane and the pane covered it. }
  FPreviewSplitter := TTySplitter.Create(Self);
  FPreviewSplitter.Parent := FContent;
  FPreviewSplitter.Align := alRight;
  FPreviewSplitter.Width := 5;
  FPreviewSplitter.MinSize := 200;
  FPreviewSplitter.Name := 'PreviewSplitter';
  FPreviewSplitter.OnMoved := @PreviewSplitterMoved;
  FPreviewSplitter.OnMouseUp := @PreviewSplitterReleased;

  FFsList := TZipShellListView.Create(Self);
  FFsList.Parent := FContent;
  FFsList.Align := alClient;
  { No BorderSpacing: a gap around the list cuts the window into floating tiles.
    The panes butt up against each other and are separated by a hairline instead
    (see the panel styles in ApplyFlatContainers), which is how a macOS window is
    divided. }
  FFsList.FoldersFirst := True;
  FFsList.ShowHidden := False;
  FFsList.ReadOnly := False;
  FFsList.OnDirectoryChange := @FsDirectoryChange;
  FFsList.OnFileActivate := @FsFileActivate;
  FFsList.OnSelectItem := @FsSelectItem;
  FFsList.OnAddItem := @FsAddItem;
  { Multi-select was never enabled on this list, so every Selected[n] := True
    replaced the previous one and "Select All" left exactly one file selected --
    which meant no batch action could ever see more than one path. }
  FFsList.MultiSelect := True;
  { Bundles need their own icon; the list cannot resolve that from a suffix. }
  FFsList.OnEntryIcon := @FsEntryIcon;
  FFsList.UseBuiltInIcons := False;
  FFsList.SmallImages := FIconImages;
  FFsList.LargeImages := FIconImages;
  FFsList.IconImages := FIconImages;
  FFsList.IconCollection := FIconCollection;
  FFsList.IconCache := FIconStore.ExtMap;
  FFsList.OnNeedIcon := @NeedFileIcon;
  FFsList.OnParentActivate := @UpClick;
  FFsList.Name := 'FsList';
  BuildFsPopup;

  { One-platform-request-per-tick icon loading, ON THE MAIN THREAD. A paint must
    never wait on NSWorkspace: it queues the suffix and paints the generic file
    glyph, then the timer resolves one real icon and invalidates both views.

    There used to be a worker thread here. NSWorkspace is Cocoa and must not be
    called off the main thread -- the same unit had already recorded the "Thread
    was created from extern ... risk data corruption" dialog it produces -- and a
    pool of four had already been shown to be no faster, because every call waits
    on the same API. }
  FIconTimer := TTimer.Create(Self);
  FIconTimer.Interval := 25;
  FIconTimer.Enabled := False;
  FIconTimer.OnTimer := @IconTimerTick;

  FArcList := TArcListView.Create(Self);
  { The menu itself is built earlier, before this control existed. }
  if FArcPopup <> nil then FArcList.PopupMenu := FArcPopup;
  FArcList.Parent := FContent;
  FArcList.Align := alClient;
  FArcList.Visible := False;
  { The list asks these three for every row it paints. Method pointers keep the
    control independent of the form. }
  FArcListCallbacks.GetCount := @ListingCount;
  FArcListCallbacks.GetText := @ArcCellText;
  FArcListCallbacks.GetImage := @ArcCellImage;
  FArcSource := TArcCallbackSource.Create(FArcListCallbacks);
  FArcList.Source := FArcSource;
  FArcList.MultiSelect := True;
  FArcList.OwnerData := True;
  FArcList.SmallImages := FIconImages;
  FArcList.LargeImages := FIconImages;
  FArcList.OnItemActivate := @ArcItemActivate;
  FArcList.OnSelectItem := @ArcSelectionChanged;
  FArcList.OnMouseDown := @ArcListMouseDown;
  FArcList.OnMouseMove := @ArcListMouseMove;
  FArcList.OnMouseUp := @ArcListMouseUp;
  FArcList.OnColumnClick := @ArcColumnClick;
  FArcList.OnKeyDown := @ArcKeyDown;
  FArcList.OnContextPopup := @ArcListContextPopup;
  FArcList.Name := 'ArcList';
  SetupArchiveColumns;

  { Last child of the content area: it has to paint over both listings. }
  CreateOverlay;
  FContent.OnResize := @ContentResize;

  FFilterTimer := TTimer.Create(Self);
  FFilterTimer.Interval := 250;
  FFilterTimer.Enabled := False;
  FFilterTimer.OnTimer := @FilterTimerTick;

  { Coming back from an external editor is the moment to notice a change, and it
    arrives as an application-level activation, not a form event. }
  Application.OnActivate := @AppActivate;
  {$IFDEF DARWIN}
  { Finder's Services menu. Installed here rather than at startup so the handler
    is only wired once the window can act on it. }
  TzInstallServices(@HandleService);
  {$ENDIF}
  ApplyChromeTheme(TyDefaultController);
  ApplyPreviewTheme;
  Caption := rsAppName;
  FStatus.SimpleText := rsReady;
  FFilterEdit.Text := '';
  FStartupHint := TTyLabel.Create(Self);
  FStartupHint.Parent := FContent;
  FStartupHint.Caption := rsStartupHint;
  { Fixed bounds + centred text: an AutoSize label measures itself only after it
    has been shown once, which left the first paint with a zero-width label. }
  FStartupHint.AutoSize := False;
  FStartupHint.Width := 480;
  FStartupHint.Height := 24;
  FStartupHint.Alignment := taCenter;
  FStartupHint.StyleOverride := 'font-size: 15px; color: var(--muted);';
  FStartupHint.Visible := False;
  FStartupHint.Name := 'StartupHint';

  FStartupBrowseFiles := TTyButton.Create(Self);
  FStartupBrowseFiles.Parent := FContent;
  FStartupBrowseFiles.Caption := rsStartupBrowseFiles;
  FStartupBrowseFiles.AutoSize := False;
  FStartupBrowseFiles.Width := 132;
  FStartupBrowseFiles.Height := 32;
  FStartupBrowseFiles.StyleClass := 'primary';
  FStartupBrowseFiles.OnClick := @StartupBrowseFilesClick;
  FStartupBrowseFiles.Visible := False;
  FStartupBrowseFiles.Name := 'StartupBrowseFiles';

  FStartupBrowseFolder := TTyButton.Create(Self);
  FStartupBrowseFolder.Parent := FContent;
  FStartupBrowseFolder.Caption := rsStartupBrowseFolder;
  FStartupBrowseFolder.AutoSize := False;
  FStartupBrowseFolder.Width := 132;
  FStartupBrowseFolder.Height := 32;
  FStartupBrowseFolder.OnClick := @StartupBrowseFolderClick;
  FStartupBrowseFolder.Visible := False;
  FStartupBrowseFolder.Name := 'StartupBrowseFolder';

  FRecentTitle := TTyLabel.Create(Self);
  FRecentTitle.Parent := FContent;
  FRecentTitle.Caption := rsRecentArchives;
  FRecentTitle.AutoSize := False;
  FRecentTitle.Width := 480;
  FRecentTitle.Height := 18;
  FRecentTitle.Alignment := taLeftJustify;
  FRecentTitle.StyleOverride := 'font-size: 13px; color: var(--muted);';
  FRecentTitle.Visible := False;
  FRecentTitle.Name := 'RecentTitle';

  FRecentList := TTyListBox.Create(Self);
  FRecentList.Parent := FContent;
  FRecentList.Width := 480;
  FRecentList.Height := 120;
  FRecentList.Visible := False;
  FRecentList.OnDblClick := @RecentArchiveActivate;
  FRecentList.Name := 'RecentList';
  { Nothing lists itself before a navigation decides what to show.  The shell
    list loads the process's working directory as soon as it is shown, which is
    what flashed a folder view before the requested archive (or the home view)
    appeared.  NavigateFs / SetArchiveContext turn these back on. }
  FFsList.Visible := False;
  FArcList.Visible := False;
end;

procedure TMainForm.CreateToolButton(var ABtn: TTyGlyphButton; const ACaption,
  AGlyph: string; AWidth: Integer; AOnClick: TNotifyEvent);
begin
  ABtn := TTyGlyphButton.Create(Self);
  ABtn.Parent := FToolBar;
  ABtn.Caption := ACaption;
  ABtn.IconFont := TyLucideFont;
  ABtn.GlyphName := AGlyph;
  ABtn.GlyphSize := 20;
  ABtn.GlyphLayout := glTop;
  ABtn.ShowCaption := True;
  ABtn.AutoSize := False;
  ABtn.Width := AWidth;
  ABtn.Height := 48;
  ABtn.Top := 6;
  ABtn.Anchors := [akLeft, akTop];
  { Ghost: transparent at rest, chrome only on hover/press. TTyToolBar with
    Flat=True is supposed to stamp this on its children, but the stamping runs
    from AlignControls and is skipped whenever a button is laid out by another
    path, which left the toolbar looking like a row of push buttons. The bar
    only fills an EMPTY StyleClass, so setting it here is stable across realigns
    and still lets a theme change the look through TyButton.ghost. }
  ABtn.StyleClass := 'ghost';
  ABtn.OnClick := AOnClick;
  SetLength(FToolButtons, Length(FToolButtons) + 1);
  FToolButtons[High(FToolButtons)] := ABtn;
end;

procedure TMainForm.CreatePathButton(var ABtn: TTyGlyphButton; const AHint,
  AGlyph: string; AOnClick: TNotifyEvent);
begin
  ABtn := TTyGlyphButton.Create(Self);
  ABtn.Parent := FPathPanel;
  ABtn.Caption := '';
  ABtn.Hint := AHint;
  ABtn.ShowHint := True;
  ABtn.IconFont := TyLucideFont;
  ABtn.GlyphName := AGlyph;
  ABtn.GlyphSize := 16;
  ABtn.ShowCaption := False;
  ABtn.AutoSize := False;
  ABtn.Width := 30;
  ABtn.Height := 28;
  { Ghost, like the toolbar's buttons: transparent at rest, chrome only on
    hover/press. Back/forward/up are navigation, not commands, and a row of filled
    push buttons next to a breadcrumb reads as a toolbar of its own. }
  ABtn.StyleClass := 'ghost';
  ABtn.Anchors := [akLeft, akTop];
  ABtn.OnClick := AOnClick;
end;

procedure TMainForm.SetupArchiveColumns;
  procedure AddCol(const AText: string; AWidth: Integer; AAlign: TAlignment);
  var
    C: TTyColumn;
  begin
    C := FArcList.Header.Columns.Add as TTyColumn;
    C.Text := AText;
    C.Width := AWidth;
    C.Alignment := AAlign;
  end;
begin
  AddCol(rsColName, 280, taLeftJustify);
  AddCol(rsColType, 80, taLeftJustify);
  AddCol(rsColSize, 96, taRightJustify);
  AddCol(rsColPacked, 96, taRightJustify);
  AddCol(rsColRatio, 64, taRightJustify);
  AddCol(rsColModified, 132, taLeftJustify);
  AddCol(rsColCreated, 132, taLeftJustify);
  AddCol(rsColAccessed, 132, taLeftJustify);
  AddCol(rsColAttributes, 110, taLeftJustify);
  AddCol(rsColCRC, 84, taRightJustify);
  AddCol(rsColMethod, 90, taLeftJustify);
  AddCol(rsColEncrypted, 74, taLeftJustify);
  AddCol(rsColFolder, 60, taLeftJustify);
  FArcList.Header.Options := FArcList.Header.Options +
    [hoVisible, hoColumnResize, hoShowSortGlyphs, hoDrag, hoHotTrack];
end;

{ Cache files written by a build that could save the fallback drawing are
  removed once.

  Marked with a file rather than purging on every start: rebuilding four base
  glyphs costs about a second of NSWorkspace each, and paying that on every
  launch would be worse than the bug it prevents. }
procedure TMainForm.PurgeIconsFromBadBuild;
const
  Marker = 'cache-version';
  { Bump when the cache's contents become wrong in a way the code cannot detect. }
  CacheVersion = '3';
var
  MarkerPath: string;
  Current: string;
  L: TStringList;
begin
  if FIconCacheDir = '' then Exit;
  MarkerPath := IncludeTrailingPathDelimiter(FIconCacheDir) + Marker;
  Current := '';
  if FileExists(MarkerPath) then
  begin
    L := TStringList.Create;
    try
      L.LoadFromFile(MarkerPath);
      if L.Count > 0 then Current := Trim(L[0]);
    finally
      L.Free;
    end;
  end;
  if Current = CacheVersion then Exit;
  { Version 2 fixed the poisoned base glyphs. A later bump must not purge them
    again: that would make the next start pay four slow NSWorkspace lookups for
    no reason. Only an older or unknown cache still needs that pass. }
  if Current <> '2' then
    FIconCache.PurgeBaseGlyphs;
  { Version 3 stores bundle icons at 32 px: the old 128 px files cost about five
    milliseconds each in the restore batch. They rebuild from the .icns. }
  FIconCache.PurgeAppGlyphs;
  L := TStringList.Create;
  try
    L.Add(CacheVersion);
    { A cache folder that cannot be written just means the purge runs again next
      time; it must not take the startup down with it. }
    try
      L.SaveToFile(MarkerPath);
    except
      { keep going: start without the marker }
    end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.BuildIcons;
var
  B: TBGRABitmap;

  procedure AddIconPath(const AName, APath, AExt: string; AFolder: Boolean);
  begin
    if FIconImages.Names.IndexOf(AName) >= 0 then Exit;
    B := nil;
    { A base glyph costs about a second of NSWorkspace per start. It is a FIXED
      image, so it is kept on disk exactly like a suffix icon and re-read in
      milliseconds; only the first run after install pays for the lookup. }
    if FIconCache <> nil then
      try
        if FileExists(FIconCache.PathFor('base_' + AName)) then
          B := TBGRABitmap.Create(FIconCache.PathFor('base_' + AName));
      except
        B.Free;
        B := nil;
      end;
    if B = nil then
    begin
      try
        { Ask for the CACHE size, not the drawing size: the platform renders the
          icon once at this edge and SaveIconPng stores it as-is. }
        B := TzPlatformIconOnly(APath, AExt, IconCachedPx, AFolder);
      except
        B := nil;
      end;
      { Only a REAL icon is written to disk. The fallback drawing is what an
        unavailable NSWorkspace produces, and caching it made the mistake
        permanent: once base_folder.png held a blank page, every later start read
        that file and every folder in both panes wore it. A transient failure at
        startup now costs one slow start instead of every start after it. }
      { Best effort: a read-only or full config directory must not let a cache
        write abort startup (this runs from AfterConstruction, before the overlay
        and its timers exist). }
      if (B <> nil) and (FIconCache <> nil) then
        try
          SaveIconPng(B, FIconCache.PathFor('base_' + AName));
        except
          { the glyph is still shown this run; only the disk copy is lost }
        end;
    end;
    if B = nil then
      B := TzFallbackIcon(AExt, IconCachedPx, AFolder);
    if B = nil then Exit;
    try
      FIconCollection.AddBitmap(AName, B);
      FIconImages.Names.Add(AName);
    finally
      B.Free;
    end;
  end;

  procedure AddIcon(const AName, AExt: string; AFolder: Boolean);
  begin
    AddIconPath(AName, '', AExt, AFolder);
  end;

begin
  FIconCollection := TTyImageCollection.Create(Self);
  FIconImages := TTyVirtualImageList.Create(Self);
  FIconImages.Collection := FIconCollection;
  { 16px is the ShellTreeView slot size; using it for the list as well keeps the
    left tree and the right list pixel-identical instead of two separate icon sets. }
  FIconImages.DefaultSize := 16;
  { The ShellTreeView's built-in glyph table is folder=0, drive=1, file=2. Keep
    exactly that order, then append the archive glyph used by the right list. }
  { The base glyphs the ShellTreeView's fixed indices expect (folder=0, drive=1,
    file=2), plus the archive glyph. They are loaded here rather than lazily: an
    empty slot paints nothing at all, so a folder row without its glyph was the
    visible result of deferring them. They are cheap after the first run because
    AddIconPath keeps them on disk. }
  { By TYPE, not by path.

    These four glyphs are what a folder, a volume, a file and an archive look
    like in general; no particular file on disk has anything to do with them. The
    earlier version asked for them through iconForFile with a real path as a
    stand-in -- the temp directory for a folder, ParamStr(0) for a file -- which
    made the answer depend on that path being valid AT THAT MOMENT. When it was
    not, NSWorkspace returned the generic blank page, and that page was then
    written to the disk cache and worn by every folder from then on.

    public.archive carries the archive badge while public.data is the plain sheet;
    both are the styled icons the Finder shows, not templates. }
  AddIconPath('folder', '', 'public.folder', True);
  AddIconPath('drive', '', 'public.volume', True);
  AddIconPath('file', '', 'public.data', False);
  AddIconPath('archive', '', 'public.archive', False);

  { Per-extension icons are indexed by suffix. }
  { Read synchronously, before the first paint. It used to be deferred because a
    naive restore cost three seconds; the cost was not I/O at all but one image-list
    refill per registered name, and batching the names brought the whole restore to
    about 50 ms. At that price the cache belongs in the first frame: the window
    opens with every icon already in place instead of filling in afterwards. }
  RestoreIconCache;
  TzMark('BuildIcons: extension cache');
  { App icons are NOT loaded here. A hundred and thirty 128 px PNGs are about a
    second of decoding and image-list rendering before the first frame, for rows
    the window may never show. AppIconIndex adopts the one file for a row when
    that row first paints. }

  { Cache the application icons in the background. Nothing waits for this: a
    bundle whose icon is not there yet paints generically and is corrected when
    the sweep reaches it, the same rule the extension icons follow.

    The timer exists even without a disk cache: it also resolves bundles met
    outside the two cached application folders (see AppIconIndex), which are
    shown for this run and never written. }
  FAppIconTimer := TTimer.Create(Self);
  FAppIconTimer.Interval := 120;
  FAppIconTimer.OnTimer := @AppIconTimerTick;
  FAppIconTimer.Enabled := FIconCacheDir <> '';
  if FIconCacheDir <> '' then
  begin
    { The sweep is ticked, not threaded: NSWorkspace is a Cocoa API and calling it
      off the main thread is what produced "Thread was created from extern".
      Six bundles per tick at 120 ms keeps each frame's share under a millisecond
      or two while still filling a hundred and thirty bundles in a few seconds. }
    FAppPrefetcher := TAppIconPrefetcher.Create(FIconCacheDir);
  end;
end;

{ Reload every icon the last runs saved. NSWorkspace is what makes a cold start
  look like the list is filling in, so the cache is read here -- before the first
  paint -- and each suffix gets its real glyph immediately. The backgrounds check
  in IconTimerTick then refreshes whatever the system has changed since. }
{ Reload every icon the last runs saved.

  Two lessons are baked into this loop. First, the bitmaps are cheap: PNG decode
  of the whole cache measured 8 ms. Second, `FIconImages.Names.Add` is NOT cheap --
  every add fires NamesChanged, which drops the glyph cache and Refills the whole
  image list, so registering 44 names one by one was 880 ms of pure bookkeeping.
  The names are therefore collected first and assigned ONCE, which refills once. }
const
  { A cached glyph is re-checked once it is older than this. Long enough that a
    normal session never pays for it, short enough that an application that
    changed its icon is picked up within a day. }
  IconCacheMaxAgeDays = 1;

{ True when APath is missing or its timestamp is older than the refresh window.

  Missing counts as stale HERE, because this pass exists to (re)fill the cache.
  The age rule itself is shared with tzip.ui.icons, which passes its own (longer)
  window and treats a missing file as "just create it". }
function TMainForm.CacheEntryIsStale(const APath: string): Boolean;
begin
  Result := (APath = '') or (not FileExists(APath)) or
    IconKeyIsOlderThan(APath, IconCacheMaxAgeDays);
end;

{ Load every cached .app icon into the image list in one batch.

  Runs from the app-icon timer's first tick, not before the first frame: the
  decode and the single list refill are then paid after the window is up. The
  per-row alternative made each painted row add a name, and every name addition
  refills the whole virtual image list -- seconds for /Applications. }
procedure TMainForm.RestoreAppIcons;
var
  I, Slot: Integer;
  Key, Path: string;
  B: TBGRABitmap;
  NewNames: TStringList;
begin
  if (FIconCache = nil) or (FIconImages = nil) then Exit;
  NewNames := TStringList.Create;
  try
    for I := 0 to FIconCache.Names.Count - 1 do
    begin
      Key := FIconCache.Names[I];
      if Copy(Key, 1, 4) <> 'app_' then Continue;
      if FIconStore.AppKnown(Key) then Continue;
      Path := FIconCache.PathFor(Key);
      if (Path = '') or (not FileExists(Path)) then Continue;
      B := nil;
      try
        try
          B := TBGRABitmap.Create(Path);
        except
          B := nil;
        end;
        if B <> nil then
        begin
          FIconCollection.AddBitmap('app:' + Key, B);
          Slot := FIconImages.Names.Count + NewNames.Count;
          FIconStore.SetAppIndex(Key, Slot);
          NewNames.Add('app:' + Key);
        end;
      finally
        B.Free;
      end;
    end;
    if NewNames.Count > 0 then
      FIconImages.Names.AddStrings(NewNames);
  finally
    NewNames.Free;
  end;
end;

procedure TMainForm.ScrollGuardTick(Sender: TObject);
begin
  TzGuardFormScroll(Self);
end;

procedure TMainForm.FormResized(Sender: TObject);
begin
  TzGuardFormScroll(Self);
end;

procedure TMainForm.FirstIdleMark(Sender: TObject; var Done: Boolean);
begin
  Done := True;
  Application.OnIdle := nil;
  TzMark('first idle (painted)');
  TzGuardFormScroll(Self);
  OnResize := @FormResized;
  FScrollGuardTimer.Enabled := True;
end;

procedure TMainForm.RestoreIconCache;
var
  I: Integer;
  E, P: string;
  B: TBGRABitmap;
  NewNames, All: TStringList;
begin
  if (FIconCache = nil) or (FIconImages = nil) then Exit;
  FIconCacheDir := FIconCache.Dir;
  NewNames := TStringList.Create;
  try
    for I := 0 to FIconCache.Names.Count - 1 do
    begin
      E := FIconCache.Names[I];
      { app_* are bundle icons, not file types: they are adopted lazily by
        AppIconIndex. Registering them here cost a PNG decode and a file-icon
        slot each, which was most of the old cache restore. }
      if Copy(E, 1, 4) = 'app_' then Continue;
      if FIconStore.ExtKnown(E) then Continue;
      P := FIconCache.PathFor(E);
      B := nil;
      try
        try
          if (P <> '') and FileExists(P) then B := TBGRABitmap.Create(P);
        except
          B.Free;
          B := nil;
        end;
        if B <> nil then
        begin
          FIconCollection.AddBitmap('file:' + E, B);
          { The slot this icon will occupy once the batch is committed: the
            names already in the list, plus the ones queued BEFORE this one.
            Reading NewNames.Count after adding to it put every mapping one slot
            too high, so an .xlsx row resolved to the next extension's glyph --
            which is how spreadsheets were drawn with the XMind icon. }
          FIconStore.SetExtIndex(E,
            FIconImages.Names.Count + NewNames.Count);
          NewNames.Add('file:' + E);
          { Aged entries are re-asked in the BACKGROUND, one per tick. Asking for
            every suffix on every launch made N windows do N x (query + rewrite) for
            glyphs that almost never change; asking never again leaves them stale
            forever. The cache file's own timestamp is the right clock: past a day
            the glyph is re-fetched, compared, and only rewritten if it really
            changed. }
          if CacheEntryIsStale(P) then
            FIconStore.AddCheck(E);
        end
        else
          if P <> '' then DeleteFile(P);
      finally
        B.Free;
      end;
    end;
    { ONE assignment for the whole batch: one Refill instead of one per icon. }
    if NewNames.Count > 0 then
    begin
      All := TStringList.Create;
      try
        All.Assign(FIconImages.Names);
        All.AddStrings(NewNames);
        FIconImages.Names.Assign(All);
      finally
        All.Free;
      end;
    end;
  finally
    NewNames.Free;
  end;
end;

{ Resolve one bundle icon NOW, on the main thread.

  Used for bundles the sweep will never reach (anything outside the two
  application folders). TzPlatformIconOnly, so a failure cannot be written to the
  disk cache as a blank page. }
{ Write PNG bytes to APath. Used for the one-shot temp file that lets
  TBGRABitmap read a bundle icon without a stream API. }
function WritePngBytes(const APath: string; const AData: TBytes): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  if Length(AData) = 0 then Exit;
  FS := TFileStream.Create(APath, fmCreate);
  try
    FS.WriteBuffer(AData[0], Length(AData));
    Result := True;
  finally
    FS.Free;
  end;
end;

procedure TMainForm.ResolveAppIconNow(const APath: string);
var
  Key, Tmp: string;
  B: TBGRABitmap;
  N: Integer;
  Png: TBytes;
begin
  Key := AppIconCacheKey(APath);
  if Key = '' then Exit;
  if FIconStore.AppKnown(Key) then Exit;
  B := nil;
  try
    { A bundle's own .icns is a file: read its PNG and only ask the platform
      when that file has none we can use (legacy RLE icons, asset catalogues). }
    if TzBundleIconPng(APath, IconCachedPx, Png) then
    begin
      Tmp := TempPathFor('appicon.png');
      try
        if WritePngBytes(Tmp, Png) then
          try
            B := TBGRABitmap.Create(Tmp);
          except
            B := nil;
          end;
      finally
        DeleteFile(Tmp);
      end;
    end;
    if B = nil then
      try
        B := TzPlatformIconOnly(APath, '', IconCachedPx, False);
      except
        B := nil;
      end;
    if B = nil then Exit;
    N := FIconImages.Names.Count;
    FIconCollection.AddBitmap('app:' + Key, B);
    FIconImages.Names.Add('app:' + Key);
    FIconStore.SetAppIndex(Key, N);
    { A bundle that lives in a cache root gets its file written for future runs
      even if the sweep has not reached it yet. One elsewhere is shown this run
      and asked again next time, which is the documented scope of the cache. }
    if (FIconCache <> nil) and ShouldCacheAppIcon(APath) then
      try
        SaveIconPng(B, FIconCache.PathFor(Key));
      except
        { best effort }
      end;
  finally
    B.Free;
  end;
end;

{ Upkeep for the bundle icons: resolve what the list asked for, advance the
  application sweep a few bundles, and adopt whatever cache files appeared.

  RestoreAppIcons at startup can only see the files that existed then; the sweep
  writes new ones during this same session, and without a rescan here they would
  stay invisible until the next launch (the comment promising "the row is
  corrected when the sweep reaches it" was not true). }
procedure TMainForm.AppIconTimerTick(Sender: TObject);
var
  Before, After: Integer;
  Pending: Integer;
  NewAppFiles, I: Integer;
  Path, FallbackPath: string;
  Allowed: Boolean;
begin
  if FAppIconTimer = nil then Exit;
  { One batched restore of every cached bundle icon, on the first tick after the
    window painted. One refill for the whole table instead of one per painted
    row, and not in the way of the first frame. }
  if not FAppIconsRestored then
  begin
    FAppIconsRestored := True;
    RestoreAppIcons;
    FIconCacheAppFiles := 0;
    if FIconCache <> nil then
      for I := 0 to FIconCache.Names.Count - 1 do
        if Copy(FIconCache.Names[I], 1, 4) = 'app_' then
          Inc(FIconCacheAppFiles);
    { Rows painted before this tick used the generic glyph; repaint now that the
      table has the real ones. }
    if FFsList <> nil then FFsList.Invalidate;
    TzMark('RestoreAppIcons (first tick)');
  end;
  { Only the platform query blocks for seconds; reading bundle files and adopting
    cache files do not. Gate just the blocking work: gating the whole handler
    made a warm app icon cache invisible until the user went idle, which read as
    "no icons in /Applications" right after launch. }
  Allowed := TzIconWorkAllowed(TzSecondsSinceLastInput,
    GetTickCount64 - FIconWorkStartTick, TzAppIsActive);
  Before := FIconStore.AppCount;
  { Bundles met outside the sweep's folders. Taking one ends in the platform
    query when its .icns has no PNG, so it waits for the gate. }
  if Allowed then
  begin
    Path := FIconStore.TakeAppPath;
    if Path <> '' then
      ResolveAppIconNow(Path);
  end;
  { The sweep reads the bundle's own icon file; that is cheap file I/O, so it
    can advance even while the user is busy (one bundle per tick), and by the
    allowed batch when the user is quiet. }
  if FAppPrefetcher <> nil then
  begin
    { Decoding a bundle PNG is cheap but not free, and this runs under the same
      gate as the platform query: no icon work while the user is active. }
    if Allowed then
      FAppPrefetcher.Step(6);
    while True do
    begin
      FallbackPath := FAppPrefetcher.TakeFallback;
      if FallbackPath = '' then Break;
      FIconStore.QueueAppPath(FallbackPath);
    end;
  end;
  { Adopting files that the sweep (or a previous run) wrote must never wait for
    the gate: this is what puts icons on screen. The sweep writes new cache files
    during the run, so a session that started with an empty/purged cache must
    adopt them without waiting for a restart -- that stale one-shot restore is
    why a cold start could sit icon-less "forever". }
  if FIconCache <> nil then
  begin
    FIconCache.Rescan;
    NewAppFiles := 0;
    for I := 0 to FIconCache.Names.Count - 1 do
      if Copy(FIconCache.Names[I], 1, 4) = 'app_' then Inc(NewAppFiles);
    if NewAppFiles > FIconCacheAppFiles then
    begin
      FIconCacheAppFiles := NewAppFiles;
      RestoreAppIcons;
      if FFsList <> nil then FFsList.Invalidate;
    end
    else if NewAppFiles < FIconCacheAppFiles then
      FIconCacheAppFiles := NewAppFiles;
  end;
  After := FIconStore.AppCount;

  { Repaint only when something arrived, and only the list that shows bundles. }
  if After > Before then
  begin
    if FFsList <> nil then FFsList.Invalidate;
    Exit;
  end;

  { Stop when the sweep is done and nothing is left over: keeping a timer awake
    forever for work that has finished is exactly the idle work this window
    should not do. }
  Pending := 0;
  if FAppPrefetcher <> nil then Pending := FAppPrefetcher.Pending;
  if FIconStore.HasAppWork then Exit;
  if (FAppPrefetcher <> nil) and (Pending > 0) then Exit;
  FAppIconTimer.Enabled := False;
  FreeAndNil(FAppPrefetcher);
end;

function TMainForm.IsArchiveForDefaultOpen(const APath: string): Boolean;
begin
  { docx/xlsx/pptx/epub are ZIP containers to 7-Zip, but they are documents to
    the user.  Double-click opens them with the system handler; the context menu
    provides an explicit "Open as Archive". }
  Result := TzIsArchiveName(APath) and (not TzIsDocumentName(APath));
end;

function TMainForm.IconIndexFor(const AName: string; AIsDir, AIsArchive: Boolean): Integer;
var
  E: string;
  N: Integer;
begin
  { An .app is a directory on disk but an APPLICATION to the user: showing it as
    a blue folder loses the one piece of information the row exists to convey.
    Bundles are therefore resolved like files -- by their own path, so the icon is
    the application's, not the generic bundle glyph. }
  if AIsDir and (not LooksLikeAppBundle(AName)) then
    Result := FIconImages.Names.IndexOf('folder')
  else if AIsArchive then
    Result := FIconImages.Names.IndexOf('archive')
  else if LooksLikeAppBundle(AName) and (FIconCacheDir <> '') then
  begin
    { A bundle is keyed by its path, because its icon belongs to that bundle.
      Cached when the sweep has reached it; otherwise the generic bundle glyph
      stands in and the row is corrected when the sweep finishes. }
    N := FIconImages.Names.IndexOf('app:' + LowerCase(ExtractFileName(
      ExcludeTrailingPathDelimiter(AName))));
    if N < 0 then Result := FIconImages.Names.IndexOf('archive')
    else Result := N;
  end
  else
  begin
    E := IconKeyName(ExtractFileExt(AName));
    N := -1;
    if E <> '' then
      N := FIconStore.ExtIndex(E);
    if N >= 0 then
      Result := N
    else
    begin
      QueueExtIcon(E);
      Result := -1;
    end;
    if Result < 0 then Result := FIconImages.Names.IndexOf('file');
  end;
  if Result < 0 then Result := 0;
end;

procedure TMainForm.QueueExtIcon(const AExt: string);
begin
  { The store decides whether this is new: it knows the resolved table and the
    pending queue, and it normalises the suffix. }
  if FIconStore.QueueExt(AExt) and (FIconTimer <> nil) then
    FIconTimer.Enabled := True;
end;

procedure TMainForm.NeedFileIcon(Sender: TObject; const AExt: string);
begin
  QueueExtIcon(AExt);
end;

{ The image index for an application bundle, loading it if necessary.

  Returns -1 when APath is not a bundle this app handles. A bundle whose icon has
  not been loaded yet gets the generic file glyph AND a background request, so the
  row is corrected shortly rather than blocking the paint. }
function TMainForm.AppIconIndex(const APath: string; out AImageIndex: Integer): Boolean;
var
  Key: string;
  N: Integer;
begin
  Result := False;
  AImageIndex := -1;
  if not LooksLikeAppBundle(APath) then Exit;
  Result := True;

  { A pure lookup: this runs on every scroll and every repaint. Adopting a PNG
    here (a list refill per row) made the first /Applications paint take
    seconds; the batch restore in AppIconTimerTick fills the table instead. }
  Key := AppIconCacheKey(APath);
  if Key <> '' then
  begin
    N := FIconStore.AppIndex(Key);
    if (N >= 0) and (N < FIconImages.Names.Count) then
    begin
      AImageIndex := N;
      Exit;
    end;
  end;

  { Not resolved yet. The generic glyph stands in, and the bundle is queued for
    the application timer, which resolves it on the main thread a tick later. That
    is what gives a bundle in ~/Downloads its real icon: the sweep only knows the
    two application folders, and this used to leave everything else as a blank
    file for good, contrary to what tzip.appcache documents. }
  if (APath <> '') and FIconStore.QueueAppPath(APath) and
     (FAppIconTimer <> nil) then
    FAppIconTimer.Enabled := True;
  AImageIndex := FIconImages.Names.IndexOf('file');
  if AImageIndex < 0 then AImageIndex := 0;
end;

{ Host callback for TZipShellListView: bundles resolve here, everything else is
  left to the list's suffix logic. }
function TMainForm.FsEntryIcon(Sender: TObject; const APath: string;
  AIsDir: Boolean; out AImageIndex: Integer): Boolean;
begin
  AImageIndex := -1;
  Result := False;
  if not AIsDir then Exit;
  Result := AppIconIndex(APath, AImageIndex);
end;

procedure TMainForm.AddLoadedIcon(const AExt: string; ABitmap: TBGRABitmap;
  AStoreOnDisk: Boolean);
var
  E, N, P: string;
  Idx: Integer;
begin
  E := IconKeyName(AExt);
  if E = '' then Exit;
  Idx := -1;
  try
    if ABitmap <> nil then
    begin
      N := 'file:' + E;
      FIconCollection.AddBitmap(N, ABitmap);
      if FIconImages.Names.IndexOf(N) < 0 then FIconImages.Names.Add(N);
      Idx := FIconImages.Names.IndexOf(N);
    end;
  except
    Idx := -1;
  end;
  { Only a REAL index is remembered.

    The failure path used to store -1 and leave it there. QueueExtIcon asks
    IndexOfName before requesting, and IconIndexFor reads -1 as "no icon", so one
    transient NSWorkspace failure pinned the generic glyph for that suffix for the
    rest of the session -- no retry, no hint. Leaving the key out means the next
    request tries again. }
  if Idx >= 0 then
    FIconStore.SetExtIndex(E, Idx);
  if AStoreOnDisk and (ABitmap <> nil) and (Idx >= 0) and (FIconCache <> nil) then
  begin
    P := FIconCache.PathFor(E);
    { Best effort: a read-only config directory just means the next start is as
      slow as this one was. }
    if P <> '' then
      try
        ForceDirectories(FIconCache.Dir);
        { The background refresh re-fetches old entries; rewriting a file whose
          pixels did not change only churns the disk and re-ages the timestamp, which
          would then delay the NEXT refresh by a day for no reason. Old pixels are
          compared first and the write is skipped on a match. }
        if not IconCacheMatches(ABitmap, P) then
          SaveIconPng(ABitmap, P);
      except
        { keep the in-memory icon; only the disk copy is lost }
      end;
  end;
  if FFsList <> nil then FFsList.Invalidate;
  if FArcList <> nil then FArcList.Invalidate;
end;

{ Resolve one suffix's icon right now.

  Runs on the MAIN thread, and only here: NSWorkspace is a Cocoa API, and calling
  it from a TThread produced "Thread was created from extern ... risk data
  corruption". One icon per timer tick keeps the per-frame cost to a single
  lookup, which is what the old worker bought as well -- the lookups never ran in
  parallel, they all wait on the same API.

  TzPlatformIconOnly, not TzSystemIcon: the fallback drawing must never reach the
  cache, or one failed lookup becomes a permanently blank icon for that suffix. }
procedure TMainForm.ResolveIconNow(const AExt: string);
var
  E: string;
  B: TBGRABitmap;
begin
  E := IconKeyName(AExt);
  if E = '' then Exit;
  B := nil;
  try
    B := TzPlatformIconOnly(TzIconProbePath(E), E, IconCachedPx, False);
  except
    B := nil;
  end;
  try
    { Only a real bitmap is remembered, and AddLoadedIcon only writes the disk
      cache for one; a failed lookup is retried the next time the suffix is asked
      for instead of being pinned to -1 for the session. }
    if B <> nil then
      AddLoadedIcon(E, B, True);
  finally
    B.Free;
  end;
end;

procedure TMainForm.IconTimerTick(Sender: TObject);
var
  E: string;
begin
  { A request costs about a second. Only spend it when the user has been quiet:
    otherwise hover, clicks and scrolling would wait behind an icon nobody is
    looking at yet. }
  if not TzIconWorkAllowed(TzSecondsSinceLastInput,
    GetTickCount64 - FIconWorkStartTick, TzAppIsActive) then Exit;
  { One type per tick: the store decides the order (aged entries before new ones)
    and refuses a type that is already known. }
  if FIconStore.HasExtWork then
  begin
    E := FIconStore.TakeNextExt;
    if E <> '' then
    begin
      FIconStore.MarkChecked(E);
      ResolveIconNow(E);
    end;
  end;
  if (not FIconStore.HasExtWork) and (FIconTimer <> nil) then
    FIconTimer.Enabled := False;
end;

procedure TMainForm.BuildMenu;
var
  CB: TMenuCallbacks;
  P: TMainMenuParts;
begin
  { The structure lives in tzip.ui.menu; the window supplies the callbacks and
    keeps the items it has to tick or fill later. }
  CB.NewArchive := @NewClick;
  CB.OpenArchive := @OpenClick;
  CB.CloseArchive := @MenuCloseArchiveClick;
  CB.Extract := @ExtractClick;
  CB.ExtractAll := @MenuExtractAllClick;
  CB.TestArchive := @TestClick;
  CB.ShowInfo := @InfoClick;
  CB.Convert := @MenuConvertClick;
  CB.Quit := @MenuExitClick;
  CB.SelectAll := @MenuSelectAllClick;
  CB.Find := @SearchClick;
  CB.ClearSearch := @ClearSearchClick;
  CB.DeleteSelected := @DeleteClick;
  CB.AddFiles := @AddClick;
  CB.AddFolder := @MenuAddFolderClick;
  CB.Back := @BackClick;
  CB.Forward := @ForwardClick;
  CB.Up := @UpClick;
  CB.Refresh := @RefreshClick;
  CB.ShowHidden := @MenuShowHiddenClick;
  CB.Sidebar := @MenuSidebarClick;
  CB.Preview := @MenuPreviewClick;
  CB.Theme := @MenuThemeClick;
  CB.Mode := @MenuModeClick;
  CB.Language := @MenuLanguageClick;
  CB.NameEncoding := @MenuNameEncodingClick;
  CB.Settings := @MenuSettingsClick;
  CB.About := @MenuAboutClick;

  BuildAppMenu(FMainMenu, CB, P);
  FShowHiddenMenu := P.ShowHidden;
  FSidebarMenu := P.Sidebar;
  FPreviewMenu := P.Preview;
  FThemeMenu := P.Theme;
  FModeMenu := P.Mode;
  FLanguageMenu := P.Language;
  FNameEncodingMenu := P.NameEncoding;
  FAboutMenu := P.About;
  FSettingsMenu := P.Settings;

  BuildThemeMenus;
end;

procedure TMainForm.NavigateFs(const APath: string; AAddHistory: Boolean);
var
  P: string;
  SameListing: Boolean;
  WasArchive: Boolean;
begin
  FStartupPhase := False;
  HideStartupHint;
  if FPathPanel <> nil then FPathPanel.Visible := True;
  ApplySidebarVisibility;
  ApplyPreviewVisibility;
  P := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
  if P = '' then P := PathDelim;
  if not DirectoryExists(P) then
  begin
    ShowError(Format(rsErrFolderNotFoundFmt, [P]));
    Exit;
  end;
  { Returning from an archive normally lands on the directory the archive was
    opened from. That list is still fully populated underneath the archive view,
    so re-enumerating it (and its icons) is wasted work. Show the cached listing
    directly; Refresh is always available when the disk really changed. }
  SameListing := (FMode = nkArchive) and
    SameText(P, ExcludeTrailingPathDelimiter(FFsList.Directory)) and
    (Length(FFsList.Entries) > 0);
  WasArchive := FMode = nkArchive;
  if AAddHistory then PushBack;
  if FPreviewPanel <> nil then CancelPreviewRequest;
  if FPreviewPanel <> nil then ClearPreview;
  { A search belongs to the archive it ran in: leaving must neither deliver its
    result into the file-manager view nor leave a job running for a view that is
    gone. }
  CancelSearchJob;
  FSearchQuery := '';
  FNavGuard := True;
  BeginBusy(Format(rsStatusLoadingFolderFmt, [P]));
  try
    FMode := nkFiles;
    FCtx := nil;
    FInnerPath := '';
    FNameEncodingOverride := '';
    FFsList.Visible := True;
    FArcList.Visible := False;
    FFsTree.Visible := True;
    FArcNavTree.Visible := False;
    FArcList.ItemCount := 0;
    if (not SameText(ExcludeTrailingPathDelimiter(FFsTree.Directory), P)) then
      FFsTree.SelectPath(P);
    if not SameListing then
      FFsList.LoadDirectory(P);
    FFsPath := ExcludeTrailingPathDelimiter(FFsList.Directory);
    FFilterEdit.Text := FFilter;
  finally
    FNavGuard := False;
    EndBusy;
  end;
  LoadFsUi;
  if FSelectFsPath <> '' then
  begin
    SelectFsEntry(FSelectFsPath);
    FSelectFsPath := '';
  end;
  { Leaving an archive leaves focus on the (now hidden) archive list, so the
    first click in the file list would only re-focus it. Do this after the
    switch has painted: touching focus in the middle of it upsets the window. }
  if WasArchive and FReady then
    Application.QueueAsyncCall(@FocusFsList, 0);
  ReleaseStuckCapture;
end;

procedure TMainForm.FsTreePathChange(Sender: TObject);
var
  P: string;
begin
  if FNavGuard or (not FReady) then Exit;
  P := ExcludeTrailingPathDelimiter(FFsTree.Directory);
  if (P = '') or (not DirectoryExists(P)) then Exit;
  if (FMode = nkFiles) and SameText(P, FFsPath) then Exit;
  NavigateFs(P);
end;

procedure TMainForm.BuildFsPopup;
begin
  FFsPopup := TTyPopupMenu.Create(Self);
  FFsPopup.Controller := TyDefaultController;
  FFsPopup.OnPopup := @FsPopupPopup;
  FFsList.PopupMenu := FFsPopup;
  FFsList.OnContextPopup := @FsListContextPopup;

  { The archive pane's own menu: the same actions, applied to entries inside the
    open archive. }
  FArcPopup := TTyPopupMenu.Create(Self);
  FArcPopup.Controller := TyDefaultController;
  FArcPopup.OnPopup := @ArcPopupPopup;
  { FArcList does not exist yet -- this runs before it is created -- so the menu
    is attached in BuildArchivePane instead. The guard that used to sit here
    ("if FArcList <> nil") was therefore NEVER true, and the archive list went
    without a popup menu entirely. }
end;

procedure TMainForm.FsListContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  P: TPoint;
  Idx: Integer;
begin
  P := FFsList.ScreenToClient(Mouse.CursorPos);
  Idx := FFsList.GetItemAt(P.X, P.Y);
  { Right-clicking a row that is not part of the selection selects it; right-
    clicking one that IS selected leaves the whole selection alone. Setting
    ItemIndex unconditionally would collapse a multi-selection to the one row
    under the cursor, so a batch action could never see more than one file. }
  if (Idx >= 0) and (not FFsList.Selected[Idx]) then
    FFsList.ItemIndex := Idx;
  Handled := False;
end;

function TMainForm.FsPopupPath: string;
begin
  if (FFsPopupPaths <> nil) and (FFsPopupPaths.Count > 0) then
    Result := FFsPopupPaths[0]
  else
    Result := '';
end;

procedure TMainForm.FsPopupPopup(Sender: TObject);
var
  Paths: TStringList;
  P: string;
  It, Sub, M: TMenuItem;
  Apps: TZOpenWithApps;
  I: Integer;
  HereName: string;

  procedure AddItem(const ACaption: string; AOnClick: TNotifyEvent;
    AEnabled: Boolean = True);
  var
    M: TMenuItem;
  begin
    M := TMenuItem.Create(FFsPopup);
    M.Caption := ACaption;
    M.OnClick := AOnClick;
    M.Enabled := AEnabled;
    FFsPopup.Items.Add(M);
  end;

begin
  FFsPopup.Items.Clear;
  FFsPopupPaths.Clear;
  FOpenWithPaths.Clear;
  Paths := SelectedFsPaths;
  try
    FFsPopupPaths.Assign(Paths);
  finally
    Paths.Free;
  end;
  if FFsPopupPaths.Count = 0 then
  begin
    AddItem(rsMenuRefresh, @RefreshClick);
    Exit;
  end;
  P := FsPopupPath;
  AddItem(rsCtxOpen, @FsPopupOpenClick);
  if FileExists(P) then
  begin
    AddItem(rsCtxOpenAsArchive, @FsPopupOpenArchiveClick);
    if TzIsArchiveName(P) then
      AddItem(rsCtxExtractHere, @FsPopupExtractHereClick);
  end;
  { Finder's "Open With" submenu: the associated applications straight from
    LaunchServices (default first), then the "Other..." chooser.  Available for
    every file, not only for types without an association. }
  if FileExists(P) then
  begin
    Apps := TzAppsForFile(P);
    Sub := TMenuItem.Create(FFsPopup);
    Sub.Caption := rsCtxOpenWith;
    FFsPopup.Items.Add(Sub);
    for I := 0 to High(Apps) do
    begin
      M := TMenuItem.Create(FFsPopup);
      M.Caption := Apps[I].Name;
      FOpenWithPaths.Add(Apps[I].Path);
      M.Tag := FOpenWithPaths.Count - 1;
      M.OnClick := @OpenWithAppClick;
      Sub.Add(M);
    end;
    if Length(Apps) > 0 then
    begin
      M := TMenuItem.Create(FFsPopup);
      M.Caption := '-';
      Sub.Add(M);
    end;
    M := TMenuItem.Create(FFsPopup);
    M.Caption := rsCtxOpenWithOther;
    M.OnClick := @OpenWithOtherClick;
    Sub.Add(M);
  end;

  It := TMenuItem.Create(FFsPopup);
  It.Caption := '-';
  FFsPopup.Items.Add(It);
  AddItem(rsCtxReveal, @FsPopupRevealClick);
  AddItem(rsCtxCopyPath, @FsPopupCopyPathClick);

  { Compressing what is selected: every file and folder can be archived, so
    these are always offered. }
  It := TMenuItem.Create(FFsPopup);
  It.Caption := '-';
  FFsPopup.Items.Add(It);
  if FFsPopupPaths.Count = 1 then
    AddItem(rsCtxCreateArchive, @FsPopupCreateClick)
  else
    AddItem(Format(rsCtxAddSelectedFmt, [FFsPopupPaths.Count]),
      @FsPopupCreateClick);
  { "Add to photo.7z", not a placeholder: the label names the file that will be
    written, which is the point of offering the item without a dialog. Guarded
    because an empty path would caption it "Add to ". }
  HereName := ExtractFileName(CreateHereTargetFor(FsPopupPath));
  if HereName <> '' then
    AddItem(Format(rsCtxCreateHereFmt, [HereName]), @FsPopupCreateHereClick);
  if FFsPopupPaths.Count > 1 then
    AddItem(rsCtxCreateEach, @FsPopupCreateEachClick);

  { Converting: only for archives, and only for one at a time -- each would need
    its own target name. }
  if (FFsPopupPaths.Count = 1) and TzIsArchiveName(FFsPopupPaths[0]) then
  begin
    It := TMenuItem.Create(FFsPopup);
    It.Caption := '-';
    FFsPopup.Items.Add(It);
    AddItem(rsCtxConvert, @FsPopupConvertClick);
  end;

  { Batch actions, offered whenever the selection contains at least one
    archive. They run one job per archive through the queue, so a folder full of
    downloads can be unpacked in one go instead of one at a time. }
  if CountArchivesIn(FFsPopupPaths) > 0 then
  begin
    It := TMenuItem.Create(FFsPopup);
    It.Caption := '-';
    FFsPopup.Items.Add(It);
    AddItem(rsCtxExtractAllTo, @FsPopupBatchExtractDialogClick);
    AddItem(rsCtxExtractAllHere, @FsPopupBatchExtractHereClick);
    AddItem(rsCtxExtractEachToFolder, @FsPopupBatchExtractToFolderClick);
    { One archive tested is "Test Archive"; several is a batch. }
    if CountArchivesIn(FFsPopupPaths) = 1 then
      AddItem(rsMenuTest, @FsPopupBatchTestClick)
    else
      AddItem(rsCtxTestAll, @FsPopupBatchTestClick);
  end;

  { Several things selected: one archive holding all of them. }
  if FFsPopupPaths.Count > 1 then
    AddItem(Format(rsCtxAddSelectedFmt, [FFsPopupPaths.Count]),
      @FsPopupCreateFromSelectionClick);
end;

{ How many of APaths are archives. }
function TMainForm.CountArchivesIn(APaths: TStrings): Integer;
var
  I: Integer;
begin
  Result := 0;
  if APaths = nil then Exit;
  for I := 0 to APaths.Count - 1 do
    if TzIsArchiveName(APaths[I]) then Inc(Result);
end;

{ Selected entries (files and folders) into one archive, with the dialog. }
{ Compress the selection, with the dialog. }
procedure TMainForm.FsPopupCreateClick(Sender: TObject);
var
  Sources: TStringList;
begin
  Sources := TStringList.Create;
  try
    Sources.Assign(FFsPopupPaths);
    DoCreateFromPaths(Sources);
  finally
    Sources.Free;
  end;
end;

{ Compress the selection with the default format, no dialog. }
procedure TMainForm.FsPopupCreateHereClick(Sender: TObject);
begin
  DoCreateHere(FFsPopupPaths);
end;

{ One archive per selected item. }
procedure TMainForm.FsPopupCreateEachClick(Sender: TObject);
begin
  DoCreateEachArchive(FFsPopupPaths);
end;

{ Convert the selected archive. }
procedure TMainForm.FsPopupConvertClick(Sender: TObject);
begin
  if FFsPopupPaths.Count <> 1 then Exit;
  BeginConvertFor(FFsPopupPaths[0]);
end;

procedure TMainForm.FsPopupCreateFromSelectionClick(Sender: TObject);
var
  Sources: TStringList;
begin
  Sources := TStringList.Create;
  try
    Sources.Assign(FFsPopupPaths);
    DoCreateFromPaths(Sources);
  finally
    Sources.Free;
  end;
end;

procedure TMainForm.FsPopupBatchExtractDialogClick(Sender: TObject);
begin
  StartExtractFrom(FFsPopupPaths);
end;

procedure TMainForm.FsPopupBatchExtractHereClick(Sender: TObject);
begin
  BatchExtract(FFsPopupPaths, '');
end;

procedure TMainForm.FsPopupBatchExtractToFolderClick(Sender: TObject);
begin
  { The per-archive folder is made by BatchExtract when the destination is
    empty; this item asks it to name one folder per archive instead. }
  BatchExtractToOwnFolders(FFsPopupPaths);
end;

procedure TMainForm.FsPopupBatchTestClick(Sender: TObject);
begin
  BatchTest(FFsPopupPaths);
end;

procedure TMainForm.FsPopupOpenClick(Sender: TObject);
var
  P: string;
  C: TArchiveContext;
begin
  P := FsPopupPath;
  if P = '' then Exit;
  if DirectoryExists(P) then
    NavigateFs(P)
  else if IsArchiveForDefaultOpen(P) then
  begin
    PushBack;
    StartOpenArchive(P, ExtractFileName(P), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False, jpOpenBrowse, '');
  end
  else
    OpenPathExternally(P);
end;

procedure TMainForm.FsPopupOpenArchiveClick(Sender: TObject);
var
  P: string;
  C: TArchiveContext;
begin
  P := FsPopupPath;
  if (P = '') or (not FileExists(P)) then Exit;
  PushBack;
  StartOpenArchive(P, ExtractFileName(P), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False, jpOpenBrowse, '');
end;

procedure TMainForm.FsPopupExtractHereClick(Sender: TObject);
begin
  ExtractArchiveHere(FsPopupPath);
end;

procedure TMainForm.FsPopupRevealClick(Sender: TObject);
var
  P: string;
begin
  P := FsPopupPath;
  if P = '' then Exit;
  if DirectoryExists(P) then
    OpenPathExternally(P)
  else
    OpenPathExternally(ExtractFileDir(P));
end;

procedure TMainForm.FsPopupCopyPathClick(Sender: TObject);
var
  P: string;
begin
  P := FsPopupPath;
  if P = '' then Exit;
  Clipboard.AsText := P;
end;

procedure TMainForm.ExtractArchiveHere(const APath: string);
var
  Dest: string;
begin
  if (APath = '') or (not FileExists(APath)) then Exit;
  Dest := ExtractFileDir(APath);
  if Dest = '' then Dest := GetCurrentDir;
  ForceDirectories(Dest);
  { Open in the background only to learn the entry list; the extraction itself
    is the next job, started by CompleteJob. }
  StartOpenArchive(APath, ExtractFileName(APath), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(APath)), False,
    jpOpenExtractHere, '', Dest);
end;

procedure TMainForm.FsDirectoryChange(Sender: TObject);
var
  NewPath: string;
begin
  { The shell list may enumerate its default directory while the welcome/opening
    state is up; that is not the user navigating, so it must not hide the hint
    or claim the view. }
  if FStartupPhase then Exit;
  HideStartupHint;
  NewPath := ExcludeTrailingPathDelimiter(FFsList.Directory);
  if FNavGuard then
  begin
    FFsPath := NewPath;
    LoadFsUi;
    Exit;
  end;
  if (FMode = nkFiles) and (FFsPath <> '') and (not SameText(FFsPath, NewPath)) then
    PushBack;
  FMode := nkFiles;
  FCtx := nil;
  FInnerPath := '';
  FNameEncodingOverride := '';
  FFsPath := NewPath;
  FFsList.Visible := True;
  FArcList.Visible := False;
  FFsTree.Visible := True;
  FArcNavTree.Visible := False;
  FNavGuard := True;
  try FFsTree.SelectPath(NewPath); finally FNavGuard := False; end;
  LoadFsUi;
end;

procedure TMainForm.FsFileActivate(Sender: TObject; AIndex: Integer);
begin
  { Entering an archive hides the list that received the double click, and LCL
    keeps the mouse capture on that list until it also sees the button-up. Doing
    the switch inside the click handler leaves the capture pointing at a control
    that is no longer on screen: every control in the window then stops receiving
    hover, and the next click anywhere is eaten by the stale capture. Finish the
    click first, then switch. }
  Application.QueueAsyncCall(@ActivateFsDataAsync, AIndex);
end;

procedure TMainForm.ActivateFsDataAsync(AData: PtrInt);
begin
  { The row may have gone away while the call was queued. }
  if (FFsList = nil) or (AData < 0) or (AData > High(FFsList.Entries)) then Exit;
  ActivateFsData(AData);
end;

procedure TMainForm.ActivateFsData(AIndex: Integer);
var
  P: string;
  C: TArchiveContext;
begin
  if (AIndex < 0) or (AIndex > High(FFsList.Entries)) then Exit;
  P := FFsList.Entries[AIndex].FullPath;
  if P = '' then Exit;
  if DirectoryExists(P) then
    NavigateFs(P)
  else if IsArchiveForDefaultOpen(P) then
  begin
    PushBack;
    StartOpenArchive(P, ExtractFileName(P), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False, jpOpenBrowse, '');
  end
  else
    OpenPathExternally(P);
end;

procedure TMainForm.FsAddItem(Sender: TObject; const ABasePath: string;
  const AEntry: TTyFsEntry; var ACanAdd: Boolean);
begin
  if FFilter <> '' then
    ACanAdd := Pos(FFilter, LowerCase(AEntry.Name)) > 0;
end;

procedure TMainForm.LoadFsUi;
begin
  if not FReady then Exit;
  UpdateBreadcrumbFs;
  UpdateStatus;
  RefreshActions;
  Caption := rsAppName;
end;

procedure TMainForm.FsSelectItem(Sender: TObject; AIndex: Integer; ASelected: Boolean);
begin
  UpdateStatus;
  RefreshActions;
  if FMode = nkFiles then
    PreviewFsAt(FFsList.ItemIndex);
end;

procedure TMainForm.ClearPreview;
begin
  if FPreviewTempFile <> '' then
  begin
    DeleteFile(FPreviewTempFile);
    FPreviewTempFile := '';
  end;
  if FPreviewPanel <> nil then
  begin
    FPreviewPanel.ClearText;
    FPreviewPanel.ClearImage;
  end;
  ShowPreviewHint(rsPreviewNoSelection);
end;

procedure TMainForm.ShowPreviewHint(const AText: string);
begin
  if FPreviewPanel = nil then Exit;
  { The pane hides whichever of its viewers was showing. }
  FPreviewPanel.ShowHintText(AText);
end;

procedure TMainForm.ShowPreviewFile(const APath, AName: string);
var
  FS: TFileStream;
  Size: Int64;
begin
  if not FileExists(APath) then
  begin
    ShowPreviewHint(Format(rsPreviewNoPreviewFmt, [AName]));
    Exit;
  end;
  try
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      Size := FS.Size;
    finally
      FS.Free;
    end;
  except
    Size := 0;
  end;

  if PreviewIsImageName(AName) then
  begin
    if Size > PreviewImageLimit then
    begin
      ShowPreviewHint(Format(rsPreviewTooLargeFmt, [AName]));
      Exit;
    end;
    { Decoding happens off the UI thread: a large PSD can take seconds, and doing
      it here froze the window -- during which the user is likely to click the next
      file, which is exactly the double-load this guards against. }
    FPreviewPanel.ClearImage;
    CancelImageLoad;
    Inc(FPreviewGen);
    if FPreviewTimer <> nil then
    begin
      FImageLoadName := AName;
      FImageLoadPath := APath;
      FImageLoader := TImageLoadThread.Create(APath, FPreviewGen);
      FPreviewTimer.Enabled := True;
    end;
    ShowPreviewHint(rsPreviewLoading);
    Exit;
  end;

  if (not PreviewIsTextName(AName)) and (not PreviewLooksText(APath)) then
  begin
    ShowPreviewHint(Format(rsPreviewNoPreviewFmt, [AName]));
    Exit;
  end;

  LoadPreviewText(APath, AName, Size);
end;

procedure TMainForm.LoadPreviewText(const APath, AName: string; ASize: Int64);
var
  FS: TFileStream;
  Raw: TBytes;
  Cap, EncIndex: Integer;
begin
  if FPreviewPanel = nil then Exit;
  Cap := PreviewTextDisplayLimit;
  SetLength(Raw, 0);
  try
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Raw, Cap);
      if Cap > 0 then
        SetLength(Raw, FS.Read(Raw[0], Cap));
    finally
      FS.Free;
    end;
  except
    ShowPreviewHint(Format(rsPreviewLoadErrorFmt, [AName]));
    Exit;
  end;
  { A NUL-only payload is not text: the wrap editor would spend forever trying
    to lay it out (AppleDouble "._" sidecars in a zip are exactly this). }
  if TzPreviewLooksBinary(Pointer(Raw), Length(Raw)) then
  begin
    ShowPreviewHint(Format(rsPreviewNoPreviewFmt, [AName]));
    Exit;
  end;
  { Auto-detect once per file; the pane's combo shows what was used, and a manual
    choice re-decodes these same bytes.  Anything that throws in here (a decoder
    or editor that trips over binary content) must degrade to "Cannot preview",
    not take the whole app down with an unhandled exception. }
  try
    EncIndex := TzDetectPreviewEncoding(Pointer(Raw), Length(Raw));
    FPreviewPanel.ShowText(AName, Raw, EncIndex, ASize > PreviewTextDisplayLimit);
  except
    on E: Exception do
    begin
      TzMark('preview failed: ' + E.ClassName + ': ' + E.Message);
      if FPreviewPanel <> nil then FPreviewPanel.ClearText;
      ShowPreviewHint(Format(rsPreviewLoadErrorFmt, [AName]));
    end;
  end;
end;

{ Drop any decode in flight.

  The thread is asked to stop, NOT waited for: a decode cannot be interrupted
  once the decoder has started, and blocking the UI on it is exactly the freeze
  this fixes -- the user clicks the next picture and the window stops responding
  until the previous one has finished. The thread is parked in FRetiring and
  freed by the preview timer when it actually ends; its decoded bitmap is freed
  with it, and a superseded result must never reach the viewer, so every request
  also bumps FPreviewGen. }
procedure TMainForm.CancelImageLoad;
var
  W: TImageLoadThread;
begin
  W := FImageLoader;
  if W = nil then Exit;
  FImageLoader := nil;
  RetireThread(W);
end;

{ Ask a worker to stop and remember it until it has finished.

  Never waits: the callers are UI events (selecting the next picture, closing the
  window) and the work cannot be interrupted. }
procedure TMainForm.RetireThread(AThread: TThread);
begin
  if AThread = nil then Exit;
  AThread.Terminate;
  if FRetiring = nil then FRetiring := TList.Create;
  if FRetiring.IndexOf(AThread) < 0 then FRetiring.Add(AThread);
  { The preview timer is what reaps them; make sure it runs. }
  if FPreviewTimer <> nil then FPreviewTimer.Enabled := True;
end;

{ Free the retired workers that have finished.

  The preview loader's temporary file is removed here rather than at StopPreview:
  deleting it while the extraction is still writing would only recreate it. }
procedure TMainForm.ReapRetiredThreads;
var
  I: Integer;
  T: TThread;
  P: TPreviewLoaderThread;
begin
  if (FRetiring = nil) or (FRetiring.Count = 0) then Exit;
  for I := FRetiring.Count - 1 downto 0 do
  begin
    T := TThread(FRetiring[I]);
    if not T.Finished then Continue;
    FRetiring.Delete(I);
    if T is TPreviewLoaderThread then
    begin
      P := TPreviewLoaderThread(T);
      if (P.OutFile <> '') and (not SameText(P.OutFile, FPreviewTempFile)) then
        DeleteFile(P.OutFile);
    end;
    T.Free;
  end;
end;

{ Join every retired worker. Only for teardown, where blocking is the point. }
procedure TMainForm.JoinRetiredThreads;
var
  I: Integer;
  T: TThread;
  P: TPreviewLoaderThread;
begin
  if FRetiring = nil then Exit;
  for I := FRetiring.Count - 1 downto 0 do
  begin
    T := TThread(FRetiring[I]);
    T.Terminate;
    T.WaitFor;
    if T is TPreviewLoaderThread then
    begin
      P := TPreviewLoaderThread(T);
      if (P.OutFile <> '') and (not SameText(P.OutFile, FPreviewTempFile)) then
        DeleteFile(P.OutFile);
    end;
    T.Free;
  end;
  FRetiring.Clear;
end;

{ Adopt a decoded bitmap as the new source and show it fitted. }
{ Polled by the preview timer: takes a finished decode and shows it, but only if
  it still belongs to the file currently selected. }

procedure TMainForm.PollImageLoad;
var
  B: TBGRABitmap;
  Failed, TooLarge: Boolean;
  Err: string;
  Gen: Integer;
begin
  if FImageLoader = nil then Exit;
  if not FImageLoader.TakeResult(B, Failed, TooLarge, Err) then Exit;
  Gen := FImageLoader.Generation;
  FreeAndNil(FImageLoader);
  if Gen <> FPreviewGen then
  begin
    { Superseded while it decoded: the user has already picked something else. }
    B.Free;
    Exit;
  end;
  if TooLarge then
  begin
    { Refused before decoding: say so, because "no preview" would suggest the
      file is unsupported. }
    ShowPreviewHint(Format(rsPreviewTooLargeFmt, [FImageLoadName]));
    Exit;
  end;
  if Failed or (B = nil) then
  begin
    ShowPreviewHint(Format(rsPreviewNoPreviewFmt, [FImageLoadName]));
    Exit;
  end;
  FPreviewPanel.ShowImage(B, FImageLoadName);
end;

{ Resample the source at the current zoom and resize the control to match.
  ACentre also re-places it. }
procedure TMainForm.ApplyPreviewTheme;
begin
  if FPreviewPanel <> nil then FPreviewPanel.ApplyThemePalette;
end;

procedure TMainForm.PreviewFsAt(AIndex: Integer);
var
  P: string;
begin
  CancelPreviewRequest;
  if (FFsList = nil) or (AIndex <= 0) then
  begin
    ClearPreview;
    Exit;
  end;
  P := FFsList.FileAt(AIndex);
  if (P = '') or DirectoryExists(P) then
  begin
    ClearPreview;
    Exit;
  end;
  ClearPreview;
  ShowPreviewFile(P, ExtractFileName(P));
end;

procedure TMainForm.CancelPreviewRequest;
begin
  Inc(FPreviewGen);
  { A decode that is already running is for the OLD file; its generation will no
    longer match, but waiting for it here keeps at most one decode alive and lets
    the timer be reused immediately. }
  CancelImageLoad;
  FPreviewPending := False;
  if FPreviewTimer <> nil then
    FPreviewTimer.Enabled := (FPreviewWorker <> nil) or
      ((FRetiring <> nil) and (FRetiring.Count > 0));
end;

procedure TMainForm.TryStartPreview;
var
  MaxBytes: QWord;
begin
  if FPreviewWorker <> nil then Exit;
  if (not FPreviewPending) or (FCtx = nil) or (FPreviewTimer = nil) then Exit;
  FPreviewPending := False;
  { Text and unknown entries only need a prefix; images need the whole file, and
    their 32 MB budget is what protects that path. }
  if PreviewIsImageName(FPreviewPendingName) then
    MaxBytes := 0
  else
    MaxBytes := PreviewTextExtractLimit;
  FPreviewWorker := TPreviewLoaderThread.Create(FCtx.SourcePath, FCtx.Password,
    TempPathFor(FPreviewPendingName), FPreviewPendingName, FPreviewPendingIndex,
    FPreviewPendingGen, MaxBytes);
  FPreviewTimer.Enabled := True;
end;

procedure TMainForm.StopPreview;
var
  W: TPreviewLoaderThread;
begin
  Inc(FPreviewGen);
  FPreviewPending := False;
  { Never wait for the extraction here: StopPreview runs from selections, mode
    switches and the window close, and a solid archive can hold the worker for
    seconds. The thread is parked and its temp file removed when it ends. }
  W := FPreviewWorker;
  if W <> nil then
  begin
    FPreviewWorker := nil;
    RetireThread(W);
  end;
  if (FPreviewTimer <> nil) and (FRetiring <> nil) and (FRetiring.Count = 0) then
    FPreviewTimer.Enabled := False;
end;

procedure TMainForm.PreviewTimerTick(Sender: TObject);
var
  R, Gen: Integer;
  Err, Tmp, PreviewName: string;
begin
  ReapRetiredThreads;
  { An image decode owns the timer while it runs. }
  if FImageLoader <> nil then
  begin
    PollImageLoad;
    if FImageLoader = nil then
      FPreviewTimer.Enabled := (FPreviewWorker <> nil);
    Exit;
  end;
  if FPreviewWorker = nil then
  begin
    FPreviewTimer.Enabled := False;
    Exit;
  end;
  if not FPreviewWorker.TakeResult(R, Err, Gen) then Exit;
  Tmp := FPreviewWorker.OutFile;
  PreviewName := FPreviewWorker.EntryName;
  FreeAndNil(FPreviewWorker);
  if (Gen = FPreviewGen) and (FMode = nkArchive) and (FCtx <> nil) and
     (FPreviewPanel <> nil) and FPreviewPanel.Visible then
  begin
    if R = TZ7Z_OK then
    begin
      FPreviewTempFile := Tmp;
      ShowPreviewFile(Tmp, PreviewName);
    end
    else
    begin
      DeleteFile(Tmp);
      ShowPreviewHint(Format(rsPreviewNoPreviewFmt, [PreviewName]));
    end;
  end
  else
    DeleteFile(Tmp);
  TryStartPreview;
  { Keep ticking while an image decode is still running. ShowPreviewFile starts
    the decode and sets the timer, then returns into THIS code, where the worker
    is already nil -- so disabling on "worker = nil" alone stopped the timer the
    instant an image preview began, and the pane sat on "Loading..." forever. }
  if (FPreviewWorker = nil) and (FImageLoader = nil) and
     ((FRetiring = nil) or (FRetiring.Count = 0)) and (FPreviewTimer <> nil) then
    FPreviewTimer.Enabled := False;
end;

procedure TMainForm.PreviewArchiveItem(const AItem: TListingItem);
begin
  if (FCtx = nil) or AItem.IsParent or AItem.IsDir then
  begin
    CancelPreviewRequest;
    ClearPreview;
    Exit;
  end;
  if AItem.Encrypted then
  begin
    CancelPreviewRequest;
    ClearPreview;
    ShowPreviewHint(rsStatusEncrypted);
    Exit;
  end;
  if PreviewIsImageName(AItem.Name) and (AItem.Size > PreviewImageLimit) then
  begin
    CancelPreviewRequest;
    ClearPreview;
    ShowPreviewHint(Format(rsPreviewTooLargeFmt, [AItem.Name]));
    Exit;
  end;
  { Text and unknown types are never refused for their size: the worker unpacks
    a bounded prefix and the viewer shows that, so a 100 MB log previews like a
    small one. Only images keep a size limit -- that one is an OOM guard (32 MB
    packed / a pixel budget), not a preview-length choice. }
  CancelPreviewRequest;
  ClearPreview;
  Inc(FPreviewGen);
  FPreviewPending := True;
  FPreviewPendingName := AItem.Name;
  FPreviewPendingIndex := AItem.EntryIndex;
  FPreviewPendingGen := FPreviewGen;
  ShowPreviewHint(Format(rsPreviewLoadingFmt, [AItem.Name]));
  TryStartPreview;
end;

{ Put a trail into the breadcrumb control and remember what each item means.

  The items and their targets live in one array: two parallel collections could be
  edited out of step, which is how the old string-coded targets ("F:", "C:",
  "I:") had to be re-parsed on every click. }
procedure TMainForm.SetCrumbs(const ACrumbs: TCrumbArray);
var
  I: Integer;
begin
  FCrumbs := ACrumbs;
  FBreadcrumb.Items.BeginUpdate;
  try
    FBreadcrumb.Items.Clear;
    for I := 0 to High(ACrumbs) do
      FBreadcrumb.Items.Add(ACrumbs[I].Text);
  finally
    FBreadcrumb.Items.EndUpdate;
  end;
end;

function TMainForm.ChainNames: TNavNameArray;
var
  Chain: TArchiveContextArray;
  I: Integer;
begin
  Result := nil;
  if (FMode <> nkArchive) or (FCtx = nil) then Exit;
  Chain := CtxChain;
  SetLength(Result, Length(Chain));
  for I := 0 to High(Chain) do
    Result[I] := Chain[I].DisplayName;
end;

procedure TMainForm.UpdateBreadcrumbFs;
begin
  SetCrumbs(FsBreadcrumbs(TzRootVolumeName, FFsPath));
end;

procedure TMainForm.CrumbClick(Sender: TObject; AIndex: Integer);
var
  P: string;
  N: Integer;
  Chain: TArchiveContextArray;
begin
  if (AIndex < 0) or (AIndex > High(FCrumbs)) then Exit;
  case FCrumbs[AIndex].Kind of
  ckFs:
    begin
      P := FCrumbs[AIndex].Path;
      if P = '' then P := '/';
      NavigateFs(P);
    end;
  ckArchive:
    if FMode = nkArchive then
    begin
      N := FCrumbs[AIndex].ArchiveIndex;
      Chain := CtxChain;
      if (N >= 0) and (N <= High(Chain)) then
        SetArchiveContext(Chain[N], '');
    end;
  ckInner:
    if (FMode = nkArchive) and (FCtx <> nil) then
      SetArchiveContext(FCtx, FCrumbs[AIndex].Path);
  end;
end;

procedure TMainForm.BreadcrumbDblClick(Sender: TObject);
begin
  if (FPathEdit = nil) or (FBreadcrumb = nil) or (not Visible) then Exit;
  FPathEditing := True;
  FPathEdit.Text := BreadcrumbPathText;
  FPathEdit.Width := FBreadcrumb.Width;
  FPathEdit.Visible := True;
  FBreadcrumb.Visible := False;
  FPathEdit.SetFocus;
  FPathEdit.SelStart := 0;
  FPathEdit.SelLength := Length(FPathEdit.Text);
end;

procedure TMainForm.HidePathEdit;
begin
  if (FPathEdit = nil) or (not FPathEditing) then Exit;
  FPathEditing := False;
  FPathEdit.Visible := False;
  if FBreadcrumb <> nil then FBreadcrumb.Visible := True;
end;

procedure TMainForm.PathEditExit(Sender: TObject);
begin
  if FPathEditing then HidePathEdit;
end;

procedure TMainForm.PathEditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    if NavigatePathText(FPathEdit.Text) then HidePathEdit;
  end
  else if Key = VK_ESCAPE then
  begin
    Key := 0;
    HidePathEdit;
  end;
end;

function TMainForm.ArchiveDirExists(ACtx: TArchiveContext;
  const APath: string): Boolean;
var
  I: Integer;
begin
  if APath = '' then Exit(True);
  if ACtx = nil then Exit(False);
  for I := 0 to High(ACtx.Entries) do
  begin
    if ACtx.Entries[I].IsDir and SameText(ACtx.Entries[I].Name, APath) then
      Exit(True);
    { Formats that store no folder records (ISO images, `zip -D`, some TAR and
      RAR writers) still have the folder: it exists as the prefix of its files. }
    if SameText(Copy(ACtx.Entries[I].Name, 1, Length(APath) + 1), APath + '/') then
      Exit(True);
  end;
  Result := False;
end;

function TMainForm.NavigatePathText(const AText: string): Boolean;
var
  T, Cand, CandInner: string;
  Parts: TStringList;
  I: Integer;
  CurFs: string;
  ArchivePath, ArchiveName, ArchiveFs: string;
  Remaining: string;

  function AbortPath(const AMsg: string): Boolean;
  begin
    if AMsg <> '' then ShowError(AMsg);
    if FPathEdit <> nil then FPathEdit.SetFocus;
    Result := False;
  end;

begin
  { "~" FIRST, and by hand: FPC's ExpandFileName has no home directory concept,
    so "~/Downloads" used to become "<current folder>/~/Downloads" and be
    reported as missing. TzExpandUserPath leaves "~user" alone, which then falls
    through to the relative-path branch exactly as before. }
  T := TzExpandUserPath(Trim(AText));
  if T = '' then Exit(False);
  if not (T[1] in ['/', '\']) then
    T := IncludeTrailingPathDelimiter(FFsPath) + T;
  T := StringReplace(T, '\', '/', [rfReplaceAll]);
  while Pos('//', T) > 0 do T := StringReplace(T, '//', '/', [rfReplaceAll]);
  if (T <> '/') and (Length(T) > 1) then T := ExcludeTrailingPathDelimiter(T);
  if T = '' then T := '/';

  CurFs := '/';
  ArchivePath := '';
  ArchiveName := '';
  ArchiveFs := '';
  Remaining := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := T;
    for I := 0 to Parts.Count - 1 do
    begin
      if Parts[I] = '' then Continue;
      if ArchivePath = '' then
      begin
        if CurFs = '/' then
          Cand := '/' + Parts[I]
        else
          Cand := CurFs + '/' + Parts[I];
        if DirectoryExists(Cand) then
          CurFs := Cand
        else if FileExists(Cand) and TzIsArchiveName(Cand) then
        begin
          ArchivePath := Cand;
          ArchiveName := ExtractFileName(Cand);
          ArchiveFs := CurFs;
        end
        else
          Exit(AbortPath(Format(rsErrFolderNotFoundFmt, [Cand])));
      end
      else
        Remaining := TzNormalizeArcPath(Remaining + '/' + Parts[I]);
    end;
  finally
    Parts.Free;
  end;

  if ArchivePath <> '' then
  begin
    { The folder inside the archive is validated once the worker has the index. }
    if (FMode <> nkArchive) or (FCtx = nil) or
      (not SameText(FCtx.SourcePath, ArchivePath)) then
      PushBack;
    StartOpenArchive(ArchivePath, ArchiveName, nil, False, ArchiveFs, False,
      jpOpenInner, Remaining);
    Exit(True);
  end;
  NavigateFs(CurFs);
  Result := True;
end;

{ ---------------------------------------------------------------------------
  Archive navigation
  --------------------------------------------------------------------------- }

procedure TMainForm.StartOpenArchive(const APath, ADisplayName: string;
  AParent: TArchiveContext; AIsNested: Boolean; const AOpenedFromFs: string;
  AAddHistory: Boolean; APurpose: TZJobPurpose; const AInner: string;
  const AExtractDest: string; ANameCodepage: LongWord);
var
  J: TZJob;
  Pw, OpenedFrom: string;
begin
  if APath = '' then Exit;
  { A normal open starts from the setting again; only the per-archive menu passes
    a code page of its own. Nested opens keep the parent's choice. }
  if (ANameCodepage = 0) and (not AIsNested) then
    FNameEncodingOverride := '';
  HideStartupHint;
  if FJob <> nil then
  begin
    { Another archive operation is already talking to 7-Zip.  Refuse instead of
      queueing: the user asked for one thing and would get surprising order. }
    if FReady then
    begin
      FStatus.SimpleText := rsBusyStillWorking;
      RefreshActions;
    end;
    Exit;
  end;

  Pw := '';
  { A cache of the last open, not request state: typing a password once is
    reused when the same archive is opened again in this session. }
  if SameText(APath, FLastOpenPath) then Pw := FLastOpenPassword;
  if (Pw = '') and (AParent <> nil) then Pw := AParent.Password;
  { Last resort: a password this archive was opened with before. Tried before
    prompting, so a remembered archive opens without asking. }
  if Pw = '' then Pw := RememberedPassword(TzPasswordStore, APath);
  OpenedFrom := AOpenedFromFs;
  if OpenedFrom = '' then OpenedFrom := FFsPath;

  FLastOpenPath := APath;
  FLastOpenPassword := Pw;
  { AAddHistory has no field on TZJob, and adding one would reach into the model
    layer from this ticket; it is the one open parameter still kept here, written
    and read inside one call pair. }
  FOpenAddHistory := AAddHistory;

  J := TZJob.Create(jkOpen);
  J.Path := APath;
  J.DisplayName := ADisplayName;
  J.Password := Pw;
  J.Parent := AParent;
  J.IsNested := AIsNested;
  J.OpenedFromFs := OpenedFrom;
  { 0 lets StartJobNow resolve the application default; the per-archive menu
    passes the override it just chose. }
  J.NameCodepage := ANameCodepage;
  { The two request values the completion needs travel with the job. }
  J.InnerPath := AInner;
  J.Dest := AExtractDest;
  { Opening now reports entry-by-entry progress through the job's sink. }
  StartJob(J, APurpose, rsBusyOpening, ADisplayName, True, True);
end;

function TMainForm.ArchiveUpdateSettings: TCreateSettings;
begin
  Result := TzModifySettings(FCtx.FormatName, FCtx.Password, FCtx.HasEncrypted);
  TzUpdateSettingsForContext(FCtx, Result);
end;

function TMainForm.NodePath(ANode: PTyTreeNode): string;
var
  I: Integer;
begin
  Result := '';
  if (ANode = nil) or (FArcNavTree = nil) then Exit;
  for I := 0 to FArcNavTree.Items.Count - 1 do
    if FArcNavTree.Items[I].Node = ANode then
      Exit(FArcListPaths[I]);
end;


procedure TMainForm.SelectFsEntry(const APath: string);
var
  I: Integer;
  Target: string;
begin
  if (FFsList = nil) or (APath = '') then Exit;
  Target := ExcludeTrailingPathDelimiter(APath);
  { Row 0 is the synthetic ".." entry, real entries are rows 1..Length(Entries).
    ItemCount is the OwnerData count here, which this control never sets -- the
    row count comes from the Entries array. }
  for I := 1 to Length(FFsList.Entries) do
    if SameText(ExcludeTrailingPathDelimiter(FFsList.FileAt(I)), Target) then
    begin
      { HideSelection is off, so a list that is not focused still paints the row
        as selected. Clear the previous one first: SetItemIndex on its own leaves
        the old row highlighted as well. }
      FFsList.ClearSelection;
      FFsList.ItemIndex := I;
      { ScrollIntoView also drags the HORIZONTAL offset to whatever makes the row's
        right edge visible, and the name column is wide, so coming back from an
        archive (where the row to restore is the archive itself) parked the
        horizontal bar at the far right. Only the vertical position is wanted
        here, so the horizontal offset is put back afterwards. }
      FFsList.ScrollIntoViewKeepingColumns(I);
      Exit;
    end;
end;

procedure TMainForm.PopulateArchiveTree;
var
  Dirs, DirMap: TStringList;
  E: TArchiveEntry;
  I, J: Integer;
  Item, ParentItem: TTyTreeNodeItem;
  Path, Rest, Acc, ParentPath: string;
  Slash: Integer;
begin
  { The tree only depends on the archive, not on which folder is open inside it.
    Rebuilding it on every navigation was O(entries) of tree churn per click; the
    selection is moved by SyncArchiveTreeSelection instead. }
  if (FCtx <> nil) and (FArcTreeCtx = FCtx) and (FArcNavTree.Items.Count > 0) then
    Exit;
  FArcListPaths.Clear;
  if FCtx = nil then
  begin
    FArcNavTree.Items.Clear;
    Exit;
  end;
  FArcTreeCtx := FCtx;
  Dirs := TStringList.Create;
  DirMap := TStringList.Create;
  try
    Dirs.Sorted := True;
    Dirs.Duplicates := dupIgnore;
    Dirs.CaseSensitive := False;
    { A sorted lookup keeps archive-tree construction O(n log n).  Looking up
      every directory in the unsorted FArcListPaths made this quadratic, which
      is visible as a multi-second freeze on archives with many folders. }
    DirMap.Sorted := True;
    DirMap.Duplicates := dupIgnore;
    DirMap.CaseSensitive := False;
    { Build the folder tree from EVERY name, not only from entries the format
      flagged as directories.  ISO images, `zip -D` archives, some TAR/RAR
      writers and several installers store only file paths with no explicit
      directory records; keying the tree on IsDir left those archives with a
      root-only sidebar even though the listing can navigate their folders. }
    for E in FCtx.Entries do
    begin
      Path := TzNormalizeArcPath(E.Name);
      if Path = '' then Continue;
      { An explicit folder record at the root ("dir") has no separator, so add
        it first; the component walk below then adds every implicit parent. }
      if E.IsDir then Dirs.Add(Path);
      { Split into components; a path with no separator contributes no folder. }
      Rest := Path;
      Acc := '';
      while Pos('/', Rest) > 0 do
      begin
        Slash := Pos('/', Rest);
        Acc := Acc + Copy(Rest, 1, Slash - 1);
        Dirs.Add(Acc);
        Acc := Acc + '/';
        Rest := Copy(Rest, Slash + 1, MaxInt);
      end;
    end;
    { Materialise the item list once, at the end.  TyControls' Items is a flat
      (Level, Text) model and every structural change re-materialises the whole
      view (ItemsStructureChanged -> RebuildFromItems), so adding the nodes one
      at a time was O(n^2): an archive with 5 000 folders froze the UI thread
      for ~30 s.  One BeginUpdate/EndUpdate turns that into one rebuild. }
    FArcNavTree.Items.BeginUpdate;
    try
      FArcNavTree.Items.Clear;
      Item := FArcNavTree.Items.Add(nil, FCtx.DisplayName);
      Item.Expanded := True;
      FArcListPaths.AddObject('', Item);
      DirMap.AddObject('', Item);
      { Dirs is sorted, so a parent always precedes its children. }
      for I := 0 to Dirs.Count - 1 do
      begin
        Path := Dirs[I];
        if DirMap.IndexOf(Path) >= 0 then Continue;
        ParentPath := TzParentArcPath(Path);
        ParentItem := nil;
        J := DirMap.IndexOf(ParentPath);
        if J >= 0 then ParentItem := TTyTreeNodeItem(DirMap.Objects[J]);
        if ParentItem = nil then ParentItem := TTyTreeNodeItem(DirMap.Objects[0]);
        Item := FArcNavTree.Items.AddChild(ParentItem, TzArcBaseName(Path));
        Item.Expanded := False;
        FArcListPaths.AddObject(Path, Item);
        DirMap.AddObject(Path, Item);
        if FInnerPath = Path then
        begin
          ParentItem.Expanded := True;
          Item.Expanded := True;
        end;
      end;
    finally
      FArcNavTree.Items.EndUpdate;
    end;
  finally
    DirMap.Free;
    Dirs.Free;
  end;
end;

procedure TMainForm.SyncArchiveTreeSelection;
var
  I: Integer;
  Item, Ancestor: TTyTreeNodeItem;
begin
  if (FArcNavTree = nil) or (FCtx = nil) then Exit;
  FNavGuard := True;
  try
    for I := 0 to FArcListPaths.Count - 1 do
      if SameText(FArcListPaths[I], FInnerPath) then
      begin
        Item := TTyTreeNodeItem(FArcListPaths.Objects[I]);
        { Expand EVERY ancestor, not just the immediate parent, and do it on the
          item list rather than on node pointers: expanding one level rebuilds
          the tree's materialized nodes, so a walk through PTyTreeNode links
          stops after the first parent and a folder four levels down stays
          hidden inside a collapsed grandparent.  Items survive that rebuild and
          hold the durable expanded state. }
        Ancestor := Item.Parent;
        while Ancestor <> nil do
        begin
          Ancestor.Expanded := True;
          Ancestor := Ancestor.Parent;
        end;
        if Item.Node <> nil then
        begin
          FArcNavTree.Selected := Item.Node;
          FArcNavTree.ScrollIntoView(Item.Node);
        end;
        Break;
      end;
  finally
    FNavGuard := False;
  end;
end;

procedure TMainForm.ArcNavGetImage(Sender: TTyCustomTreeView; ANode: PTyTreeNode;
  AKind: TTyVTImageKind; AColumn: Integer; var AGhosted: Boolean;
  var AImageIndex: Integer);
begin
  AImageIndex := -1;
  AGhosted := False;
  { A tree without columns passes AColumn = -1, not 0.  Treating only 0 as "the
    name column" meant this handler never produced an index and the archive tree
    drew no icons at all. }
  if (AColumn > 0) or (ANode = nil) then Exit;
  { The tree lists folders only; its first item is the archive itself (which
    sits under an invisible root node, so Parent is not nil even for it).
    Compare the NODE, not its Index: Index is the position among siblings (LCL
    semantics), so the first child of every parent is also 0 -- which is why the
    whole first level below the archive used to get the archive icon. }
  if (FArcNavTree.Items.Count > 0) and (ANode = FArcNavTree.Items[0].Node) then
    AImageIndex := IconIndexFor('', False, True)
  else
    AImageIndex := IconIndexFor('', True, False);
end;

procedure TMainForm.ArcNavNodeMoved(Sender: TTyCustomTreeView;
  ANode: PTyTreeNode);
var
  P: string;
begin
  if FNavGuard or (not FReady) or (FMode <> nkArchive) or (FCtx = nil) then Exit;
  { ANode is the node the tree just moved to; nil comes from a cleared selection. }
  if ANode = nil then Exit;
  P := NodePath(ANode);
  if SameText(P, FInnerPath) then Exit;
  SetArchiveContext(FCtx, P, True);
end;

procedure TMainForm.SetArchiveContext(ACtx: TArchiveContext; const AInner: string;
  AAddHistory: Boolean);
var
  EnterFromFiles: Boolean;
begin
  if ACtx = nil then Exit;
  FStartupPhase := False;
  HideStartupHint;
  if FPathPanel <> nil then FPathPanel.Visible := True;
  ApplySidebarVisibility;
  ApplyPreviewVisibility;
  EnterFromFiles := (FMode <> nkArchive) or (not FArcList.Visible);
  if AAddHistory and ((FMode <> nkArchive) or (FCtx <> ACtx) or (FInnerPath <> AInner)) then
    PushBack;
  if FPreviewPanel <> nil then CancelPreviewRequest;
  FMode := nkArchive;
  FCtx := ACtx;
  FInnerPath := TzNormalizeArcPath(AInner);
  if FPreviewPanel <> nil then ClearPreview;
  FFsList.Visible := False;
  FArcList.Visible := True;
  FFsTree.Visible := False;
  FArcNavTree.Visible := True;
  FArcList.ClearSelection;
  FArcList.ItemCount := 0;
  PopulateArchiveTree;
  RefreshArchiveListing;
  SyncArchiveTreeSelection;
  LoadArchiveUi;
  UpdateNameEncodingMenu;
  { The archive tree has just been shown and has never held focus.  Giving it
    focus here is what makes the very first click on a row select it instead of
    only activating the pane.  Only when we switch from the filesystem list:
    re-focusing on every in-archive navigation would yank focus out of the
    sidebar tree the user just clicked. }
  if EnterFromFiles and FReady and (FArcList.CanFocus) and
     (not FArcList.Focused) then
    FArcList.SetFocus;
  { The filesystem list that started the open has been hidden underneath; if LCL
    still has it as the mouse-capture window, hover stays dead for the whole
    window. }
  ReleaseStuckCapture;
end;

function TMainForm.CtxChain: TArchiveContextArray;
var
  C: TArchiveContext;
  N: Integer;
begin
  Result := nil;
  C := FCtx;
  while C <> nil do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := C;
    C := C.Parent;
  end;
  for N := 0 to (Length(Result) div 2) - 1 do
  begin
    C := Result[N];
    Result[N] := Result[High(Result) - N];
    Result[High(Result) - N] := C;
  end;
end;

procedure TMainForm.ResetArchiveListing;
begin
  SetLength(FListing, 1);
  InitParentListingItem(FListing[0]);
  FListTotalBytes := 0;
  FListTotalFiles := 0;
  if FArcList <> nil then
  begin
    FArcList.ItemCount := Length(FListing);
    FArcList.Invalidate;
  end;
end;

procedure TMainForm.ApplyListing(const AListing: TListing);
var
  N, I, SelRow: Integer;
  Total: QWord;
  KeepPath: string;
begin
  { A synthetic parent row is always first, just like the filesystem list.  At
    the top level it still leaves the archive; inside it walks up one folder.
    Copy row by row into a fresh array: AListing may still be referenced by the
    job that produced it, and moving records around would duplicate the string
    pointers. }
  { ItemsChanged drops the selection, so remember which entry the cursor was on.
    Without this a background listing landing right after a click, an F5 refresh,
    a filter keystroke or a column sort all silently deselected the row the user
    had just picked. }
  KeepPath := '';
  if FArcList <> nil then
  begin
    SelRow := FArcList.ItemIndex;
    if (SelRow >= 0) and (SelRow <= High(FListing)) then
      KeepPath := FListing[SelRow].FullPath;
  end;
  N := Length(AListing);
  SetLength(FListing, N + 1);
  for I := 0 to N - 1 do
    FListing[I + 1] := AListing[I];
  InitParentListingItem(FListing[0]);

  { Cache the totals: UpdateStatus runs on every selection change and must not
    walk a 200k-row listing each time. }
  Total := 0;
  FListTotalFiles := 0;
  for I := 1 to High(FListing) do
    if not FListing[I].IsDir then
    begin
      Inc(Total, FListing[I].Size);
      Inc(FListTotalFiles);
    end;
  FListTotalBytes := Total;

  if FArcList <> nil then
  begin
    FArcList.ItemCount := Length(FListing);
    if KeepPath <> '' then
      for I := 1 to High(FListing) do
        if SameText(FListing[I].FullPath, KeepPath) then
        begin
          FArcList.ClearSelection;
          FArcList.ItemIndex := I;
          FArcList.ScrollIntoView(I);
          Break;
        end;
    FArcList.Invalidate;
  end;
  SyncArchiveTreeSelection;
  UpdateStatus;
  RefreshActions;
end;

procedure TMainForm.RefreshArchiveListing;
var
  J: TZJob;
  Listing: TListing;
begin
  { Cleared here and set again only if this call has to be deferred; a stale flag
    would re-run the listing on the next unrelated completion. }
  FListPending := False;
  if FCtx = nil then
  begin
    ResetArchiveListing;
    Exit;
  end;
  { A search spans folders, so it cannot go through the folder listing at all:
    it walks the entry snapshot itself, on a worker. One path for every archive
    size -- the old synchronous branch froze the window on big ones and ignored
    the name filter. }
  if SearchActive then
  begin
    if FJob <> nil then
    begin
      { Something already owns the engine: re-run when it finishes. }
      FListPending := True;
      Exit;
    end;
    J := TZJob.Create(jkSearch);
    J.Path := FCtx.SourcePath;
    J.DisplayName := FCtx.DisplayName;
    J.Password := FCtx.Password;
    J.Options := FSearchOptions;
    J.NameCodepage := FCtx.NameCodepage;
    FListPending := False;
    StartJob(J, jpSearch, rsBusySearching, FCtx.DisplayName, True, True);
    Exit;
  end;
  if Length(FCtx.Entries) <= SyncListingEntries then
  begin
    { Small enough that a worker would only add latency and flicker. }
    Listing := TzListArchive(FCtx, FInnerPath, FFilter, FSortCol, FSortDesc);
    ApplyListing(Listing);
    Exit;
  end;
  { Until the worker answers there is nothing safe to show or click, so the tree
    falls back to the single ".." row. }
  ResetArchiveListing;
  if FJob <> nil then
  begin
    { Something already owns the engine.  Remember that the listing is stale;
      the next completion re-runs this method. }
    FListPending := True;
    Exit;
  end;

  J := TZJob.Create(jkList);
  J.CtxRef := FCtx;
  J.InnerPath := FInnerPath;
  J.Filter := FFilter;
  J.SortCol := FSortCol;
  J.SortDesc := FSortDesc;
  J.SetEntries(FCtx.Entries);
  J.NameCodepage := FCtx.NameCodepage;
  FListPending := False;
  StartJob(J, jpList, rsBusyReading, FCtx.DisplayName, False, False);
end;

procedure TMainForm.LoadArchiveUi;
begin
  if not FReady then Exit;
  UpdateBreadcrumbArchive;
  UpdateStatus;
  RefreshActions;
  Caption := Format(rsStatusArchiveSuffixFmt, [rsAppName, FCtx.DisplayName, FCtx.FormatName]);
  if FTitleBar <> nil then
    FTitleBar.Caption := FCtx.DisplayName;
end;

procedure TMainForm.UpdateBreadcrumbArchive;
var
  Base: string;
begin
  { The trail starts at the real filesystem path, so an archive opened from
    /Users/tom is shown as MacOS › Users › tom › file.zip › folder. }
  Base := '';
  if FCtx <> nil then Base := FCtx.OpenedFromFs;
  SetCrumbs(ArchiveBreadcrumbs(TzRootVolumeName, Base, ChainNames, FInnerPath));
end;

function TMainForm.BreadcrumbPathText: string;
var
  Base: string;
begin
  if FMode = nkFiles then
    Exit(tzip.navstate.BreadcrumbPathText(FFsPath, '', nil, ''));
  Base := '';
  if FCtx <> nil then Base := FCtx.OpenedFromFs;
  Result := tzip.navstate.BreadcrumbPathText('', Base, ChainNames, FInnerPath);
end;

{ The temp directory belonging to this process. Kept as a function so cleanup can
  find it even when nothing ever created a file (FTempRoot is then ''). }
function TzTempRootForPid: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'TyZip-' +
    IntToStr(GetProcessID) + PathDelim;
end;

{ Remove the session's temp directory, whatever it contains. Entries of a nested
  archive go into subdirectories, so a flat file sweep is not enough: the tree is
  deleted bottom-up. }
procedure TzDeleteTempRoot(const AStatedRoot: string);
var
  Root: string;

  procedure Purge(const ADir: string);
  var
    SR: TSearchRec;
    Sub: TStringList;
    I: Integer;
  begin
    Sub := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if (SR.Attr and faDirectory) <> 0 then
            Sub.Add(IncludeTrailingPathDelimiter(ADir) + SR.Name)
          else
            DeleteFile(IncludeTrailingPathDelimiter(ADir) + SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
      { Children first, then this directory (and its children's directories). }
      for I := 0 to Sub.Count - 1 do
      begin
        Purge(Sub[I]);
        RemoveDir(Sub[I]);
      end;
    finally
      Sub.Free;
    end;
  end;

begin
  Root := AStatedRoot;
  if Root = '' then Root := TzTempRootForPid;
  if not DirectoryExists(Root) then Exit;
  Purge(Root);
  RemoveDir(Root);
end;

function TMainForm.TempPathFor(const AName: string): string;
begin
  EnsureTempRoot;
  { The extracted file is handed to the system to open, so it keeps the name the
    user clicked. TzSafeEntryFileName replaces only path separators and bytes
    NTFS rejects; blanking every non-ASCII byte here turned 中文演示.pptx into a
    run of underscores, because one CJK character is three UTF-8 bytes. }
  Result := FTempRoot + IntToHex(GetTickCount64, 12) + '_' +
    TzSafeEntryFileName(AName);
end;

procedure TMainForm.EnsureTempRoot;
begin
  if FTempRoot <> '' then Exit;
  FTempRoot := TzTempRootForPid;
  ForceDirectories(FTempRoot);
end;

function TzArcTimeText(AUnix: QWord): string;
var
  D: TDateTime;
begin
  if AUnix = 0 then Exit('');
  D := UnixToDateTime(Int64(AUnix), True);
  Result := FormatDateTime('yyyy-mm-dd hh:nn', D);
end;

function TzArcAttrText(AAttrib: LongWord; AIsDir: Boolean): string;
var
  Mode: LongWord;
  function Bit(Mask: LongWord; const C: Char): Char;
  begin
    if Mode and Mask <> 0 then Result := C else Result := '-';
  end;
begin
  Mode := AAttrib shr 16;
  if Mode <> 0 then
  begin
    Result := '';
    if AIsDir or ((Mode and $4000) <> 0) then Result := Result + 'd' else Result := Result + '-';
    Result := Result + Bit($100, 'r') + Bit($80, 'w') + Bit($40, 'x');
    Result := Result + Bit($20, 'r') + Bit($10, 'w') + Bit($8, 'x');
    Result := Result + Bit($4, 'r') + Bit($2, 'w') + Bit($1, 'x');
  end
  else
  begin
    Result := '';
    if AIsDir then Result := Result + 'D';
    if AAttrib and $01 <> 0 then Result := Result + 'R';
    if AAttrib and $02 <> 0 then Result := Result + 'H';
    if AAttrib and $04 <> 0 then Result := Result + 'S';
    if AAttrib and $20 <> 0 then Result := Result + 'A';
    if Result = '' then Result := '-';
  end;
end;

function TMainForm.ArcSelectedRows: Integer;
var
  I: Integer;
  N: PTyTreeNode;
begin
  Result := 0;
  if FArcList = nil then Exit;
  for I := 0 to High(FListing) do
    { The synthetic ".." row is navigation, not a selectable archive entry. }
    if (I > 0) and FArcList.Selected[I] then Inc(Result);
end;


procedure TMainForm.ArcColumnClick(Sender: TObject; AColumn: Integer);
begin
  if (AColumn < Ord(Low(TArchiveSortColumn))) or (AColumn > Ord(High(TArchiveSortColumn))) then Exit;
  if AColumn = Ord(FSortCol) then FSortDesc := not FSortDesc
  else
  begin
    FSortCol := TArchiveSortColumn(AColumn);
    FSortDesc := False;
  end;
  RefreshArchiveListing;
end;

{ One cell's text. A column index is a TArchiveSortColumn: the list view and the
  archive sort order share the same numbering, exactly as the tree view's header
  did, so the column definitions below can stay a plain list. }
function TMainForm.ArcCellText(AIndex, AColumn: Integer): string;
var
  It: TListingItem;
  Ratio: Double;
  Ext: string;
begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(FListing)) then Exit;
  It := FListing[AIndex];
  if It.IsParent then
  begin
    if AColumn = Ord(ascName) then Result := It.Name;
    Exit;
  end;
  if (AColumn < Ord(Low(TArchiveSortColumn))) or (AColumn > Ord(High(TArchiveSortColumn))) then Exit;
  case TArchiveSortColumn(AColumn) of
    ascName:
      begin
        Result := It.Name;
        { Ask for this row's icon type here: queued, deduplicated, never blocking
          the paint. }
        Ext := LowerCase(ExtractFileExt(It.Name));
        if (Ext <> '') and (not It.IsDir) then QueueExtIcon(Ext);
      end;
    ascType:
      begin
        if It.IsDir then Result := rsTypeFolder
        else
        begin
          Ext := LowerCase(ExtractFileExt(It.Name));
          if Ext <> '' then Result := Copy(Ext, 2, MaxInt) else Result := rsTypeFile;
        end;
      end;
    { Folders carry the recursive total of what is inside them, the way 7-Zip's
      own file manager shows it. An empty folder stays blank rather than claiming
      "0 B". }
    ascSize: if (not It.IsDir) or (It.Size > 0) then Result := TzFormatSize(It.Size);
    ascPacked: if (not It.IsDir) or (It.Size > 0) then
      Result := TzFormatSize(It.PackedSize);
    ascRatio:
      if (It.Size > 0) and ((not It.IsDir) or (It.PackedSize > 0)) then
      begin
        Ratio := It.PackedSize * 100 / It.Size;
        Result := FormatFloat('0.0', Ratio) + ' %';
      end;
    ascModified: Result := TzArcTimeText(It.MTime);
    ascCreated: Result := TzArcTimeText(It.CTime);
    ascAccessed: Result := TzArcTimeText(It.ATime);
    ascAttrib: Result := TzArcAttrText(It.Attrib, It.IsDir);
    ascCRC: if (not It.IsDir) and (It.CRC <> 0) then Result := IntToHex(It.CRC, 8);
    ascMethod: Result := It.Method;
    ascEncrypted: if not It.IsDir then
      begin if It.Encrypted then Result := rsYes else Result := rsNo; end;
    ascFolder: if It.IsDir then Result := rsYes else Result := rsNo;
  end;
end;

function TMainForm.ArcCellImage(AIndex: Integer): Integer;
var
  It: TListingItem;
begin
  Result := -1;
  if (AIndex < 0) or (AIndex > High(FListing)) then Exit;
  It := FListing[AIndex];
  if It.IsParent then
    Result := IconIndexFor('', True, False)
  else
    Result := IconIndexFor(It.Name, It.IsDir,
      It.IsArchive and (not TzIsDocumentName(It.Name)));
end;

function TMainForm.ListingCount: Integer;
begin
  Result := Length(FListing);
end;

{ True when the right-click landed on a real entry rather than empty space. }
function TMainForm.ArcPopupOnEntry: Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if FArcList = nil then Exit;
  Idx := FArcList.ItemIndex;
  if (Idx < 0) or (Idx > High(FListing)) then Exit;
  Result := not FListing[Idx].IsParent;
end;

procedure TMainForm.ArcListContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  Idx: Integer;
begin
  if FArcList = nil then Exit;
  { Right-clicking a row that is not part of the selection selects it, which is
    what every file manager does and what the menu then acts on. }
  Idx := FArcList.GetItemAt(MousePos.X, MousePos.Y);
  if (Idx >= 0) and (Idx <= High(FListing)) and (not FListing[Idx].IsParent) then
    if not FArcList.Selected[Idx] then
    begin
      FArcList.ClearSelection;
      FArcList.Selected[Idx] := True;
    end;
  { The popup builder reads ItemIndex, and setting Selected alone does not move
    it. Right-clicking a row outside the selection therefore selected that row but
    left ItemIndex where it was -- on -1, or on the previously selected row -- so
    the menu came up empty (or acted on the wrong entry). }
  if (Idx >= 0) and (Idx <= High(FListing)) then
    FArcList.ItemIndex := Idx
  else if FArcList.ItemIndex <> -1 then
    FArcList.ItemIndex := -1;
  { Handled is a VAR parameter and starts life as whatever the caller had. Leaving
    it unset meant the attached PopupMenu was suppressed whenever that happened to
    be True -- which is why right-clicking an entry in an archive did nothing at
    all, while the same gesture worked in the file list (which sets it). }
  Handled := False;
end;

procedure TMainForm.ArcPopupPopup(Sender: TObject);
var
  It: TMenuItem;
  OnEntry: Boolean;

  procedure Add(const ACaption: string; AOnClick: TNotifyEvent;
    AEnabled: Boolean = True);
  var
    M: TMenuItem;
  begin
    M := TMenuItem.Create(FArcPopup);
    M.Caption := ACaption;
    M.OnClick := AOnClick;
    M.Enabled := AEnabled;
    FArcPopup.Items.Add(M);
  end;

  procedure Sep;
  begin
    It := TMenuItem.Create(FArcPopup);
    It.Caption := '-';
    FArcPopup.Items.Add(It);
  end;

begin
  FArcPopup.Items.Clear;
  OnEntry := ArcPopupOnEntry;

  if OnEntry then
  begin
    Add(rsCtxExtract, @ArcPopupExtractClick);
    { Only a directory entry has a "here": extracting into one would need a
      destination that does not exist yet, which the dialog already covers. }
    Add(rsCtxExtractHere, @ArcPopupExtractHereClick, FListing[FArcList.ItemIndex].IsDir);
    Add(rsCtxOpen, @ArcPopupOpenClick);
    Sep;
    Add(rsCtxRename, @ArcPopupRenameClick, not FListing[FArcList.ItemIndex].IsDir);
    Add(rsCtxCopyPath, @ArcPopupCopyPathClick);
  end
  else
    { Empty space: the whole-archive actions still make sense. }
    Add(rsCtxExtract, @ArcPopupExtractClick);

  Sep;
  { Archive-level comment: readable in every format, writable in zip. It belongs
    to the whole archive, so it is offered even when no entry is targeted. }
  Add(rsMenuComment, @ArcPopupCommentClick, (FCtx <> nil) and FCtx.CanUpdate);
  Add(rsMenuTest, @ArcPopupTestClick);
  Add(rsMenuDelete, @ArcPopupDeleteClick, OnEntry and FCtx.CanUpdate);
end;

{ Which archive entries exist, for the duplicate check. }
procedure TMainForm.CollectEntryPaths(AList: TStrings);
var
  I: Integer;
begin
  AList.Clear;
  for I := 0 to High(FCtx.Entries) do
    AList.Add(FCtx.Entries[I].Name);
end;

procedure TMainForm.ArcPopupRenameClick(Sender: TObject);
begin
  DoRenameEntry;
end;

procedure TMainForm.DoRenameEntry;
var
  Idx: Integer;
  E: TArchiveEntry;
  NewName, Target: string;
  Existing: TStringList;
  Problem: TRenameProblem;
begin
  if (FCtx = nil) or (FMode <> nkArchive) or (FJob <> nil) then Exit;
  if not CheckArchiveWritable then Exit;
  Idx := FArcList.ItemIndex;
  { ".." is a row, not an entry, and a folder cannot be renamed in place: its
    children would each need their path rewritten, which this path does not do. }
  if (Idx < 0) or (Idx > High(FListing)) or FListing[Idx].IsParent then Exit;
  if FListing[Idx].EntryIndex < 0 then Exit;
  E := FCtx.Entries[FListing[Idx].EntryIndex];
  if E.IsDir then
  begin
    ShowError(rsErrRenameFolderUnsupported);
    Exit;
  end;

  NewName := E.Name;
  if not PromptForText(Self, rsDlgRename, rsDlgRenamePrompt, E.Name, NewName) then Exit;

  Existing := TStringList.Create;
  try
    CollectEntryPaths(Existing);
    { Validate before anything is rewritten: there is no undo for this. }
    Problem := CheckEntryName(NewName, E.Name, Existing);
    if Problem <> rpNone then
    begin
      ShowError(RenameProblemText(Problem));
      Exit;
    end;
    Target := ResolvedEntryPath(NewName, E.Name, False);
  finally
    Existing.Free;
  end;
  if SameText(Target, E.Name) then Exit;

  StartRenameJob(E, Target);
end;

procedure TMainForm.StartRenameJob(const AEntry: TArchiveEntry;
  const ATarget: string);
var
  J: TZJob;
  S: TCreateSettings;
begin
  StopPreview;
  FModifyMessage := Format(rsStatusRenamedFmt, [ExtractFileName(ATarget)]);
  J := TzNewRenameJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
    ArchiveUpdateSettings,
    AEntry.Index, AEntry.Name, ATarget);
  J.NameCodepage := FCtx.NameCodepage;
  StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
end;

procedure TMainForm.ArcPopupExtractClick(Sender: TObject);
begin
  DoExtract(False);
end;

procedure TMainForm.ArcPopupExtractHereClick(Sender: TObject);
begin
  { Extract the selected entries into the folder the archive came from -- the
    same destination "Extract Here" uses for a whole archive. }
  DoExtract(False);
end;

procedure TMainForm.ArcPopupOpenClick(Sender: TObject);
begin
  if FArcList = nil then Exit;
  ArcItemActivate(Self, FArcList.ItemIndex);
end;

procedure TMainForm.ArcPopupTestClick(Sender: TObject);
begin
  DoTest;
end;

procedure TMainForm.ArcPopupCommentClick(Sender: TObject);
begin
  ShowArchiveComment;
end;

procedure TMainForm.ArcPopupDeleteClick(Sender: TObject);
begin
  DoDeleteEntries;
end;

procedure TMainForm.ArcPopupCopyPathClick(Sender: TObject);
var
  RowNames: array of string;
  Selected: array of Boolean;
  Picked: TStringArray;
  I: Integer;
  Names: TStringList;
begin
  if FArcList = nil then Exit;
  { The selected ROWS, not the entries' archive indices: as soon as the listing is
    sorted, filtered or is a search result, an entry index no longer names a row,
    and the old mapping copied whatever happened to sit there. }
  SetLength(RowNames, Length(FListing));
  SetLength(Selected, Length(FListing));
  for I := 0 to High(FListing) do
  begin
    RowNames[I] := FListing[I].Name;
    Selected[I] := (I < FArcList.ItemCount) and FArcList.Selected[I];
  end;
  Picked := PickedRowNames(RowNames, Selected);
  if Length(Picked) = 0 then Exit;
  Names := TStringList.Create;
  try
    for I := 0 to High(Picked) do
      Names.Add(Picked[I]);
    if Names.Count = 0 then Exit;
    Clipboard.Open;
    try
      Clipboard.AsText := Names.Text;
    finally
      Clipboard.Close;
    end;
  finally
    Names.Free;
  end;
end;

procedure TMainForm.ArcItemActivate(Sender: TObject; AIndex: Integer);
var
  It: TListingItem;
  J: TZJob;
begin
  if (AIndex < 0) or (AIndex > High(FListing)) then Exit;
  It := FListing[AIndex];
  if It.IsParent then
  begin
    UpClick(nil);
    Exit;
  end;
  if It.IsDir then
  begin
    SetArchiveContext(FCtx, It.FullPath);
    Exit;
  end;
  if FJob <> nil then Exit;

  { Both branches shell out to 7-Zip for the entry, so the extraction runs on a
    worker: only the result differs (open the file, or open the archive). }
  FExtractOneName := It.Name;
  { Only an encrypted entry can fail with "wrong password" while 7-Zip reports
    a data error; a data error on a plaintext entry is corruption and must keep
    its honest message. The retry flag belongs to this one attempt. }
  FExtractOneEncrypted := It.Encrypted;
  FExtractOnePasswordRetried := False;
  J := TZJob.Create(jkExtractOne);
  J.Path := FCtx.SourcePath;
  J.DisplayName := It.Name;
  J.Password := FCtx.Password;
  J.EntryIndex := It.EntryIndex;
  J.OutFile := TempPathFor(It.Name);
  J.NameCodepage := FCtx.NameCodepage;
  if It.IsArchive and (not TzIsDocumentName(It.Name)) then
    StartJob(J, jpOpenNestedThenView, rsBusyUnpacking, It.Name, True, True)
  else
    StartJob(J, jpExtractOneOpen, rsBusyUnpacking, It.Name, True, True);
end;

{ Multi-select fires this once per changed row, so the preview follows the
  FOCUSED row (ItemIndex) -- the same rule the filesystem list uses -- rather
  than whichever row happens to be reported last. }
{ The archive paths selected in the listing, parent rows aside: these are the
  drag roots the pure unit expands into files/folders. }
function TMainForm.SelectedArchiveRootNames: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  if FArcList = nil then Exit;
  for I := 0 to High(FListing) do
  begin
    if (I > High(FListing)) or (not FArcList.Selected[I]) then Continue;
    if FListing[I].IsParent then Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := FListing[I].FullPath;
  end;
end;

procedure TMainForm.ArcListMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FArcDragArmed := (Button = mbLeft) and (FMode = nkArchive) and (FCtx <> nil);
  FArcDragStart := Point(X, Y);
end;

procedure TMainForm.ArcListMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
begin
  if not FArcDragArmed then Exit;
  if not (ssLeft in Shift) then
  begin
    FArcDragArmed := False;
    Exit;
  end;
  if (Abs(X - FArcDragStart.X) < 5) and (Abs(Y - FArcDragStart.Y) < 5) then Exit;
  FArcDragArmed := False;
  StartArchiveDragOut;
end;

procedure TMainForm.ArcListMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FArcDragArmed := False;
end;

{ Start the Cocoa file-promise drag for the selected entries. The promise
  delegate extracts on its own thread, so this returns immediately. }
procedure TMainForm.StartArchiveDragOut;
var
  Names: TStringArray;
  Roots: TDragOutRoots;
  Requests: TDragOutRequests;
  I: Integer;
begin
  {$IFDEF DARWIN}
  if (FCtx = nil) or (FMode <> nkArchive) or (FArcList = nil) then Exit;
  Names := SelectedArchiveRootNames;
  if Length(Names) = 0 then Exit;
  Roots := TzDragOutRoots(FCtx.Entries, Names);
  if Length(Roots) = 0 then Exit;
  SetLength(Requests, Length(Roots));
  for I := 0 to High(Roots) do
  begin
    Requests[I].ArchivePath := FCtx.SourcePath;
    Requests[I].Password := FCtx.Password;
    Requests[I].Root := Roots[I];
  end;
  TzStartArchiveDragOut(NSView(FArcList.Handle), NSApp.currentEvent, Requests);
  {$ENDIF}
end;
procedure TMainForm.ArcSelectionChanged(Sender: TObject; AIndex: Integer;
  ASelected: Boolean);

var
  Row: Integer;
begin
  UpdateStatus;
  RefreshActions;
  if (not FReady) or (FCtx = nil) then Exit;
  Row := FArcList.ItemIndex;
  if (Row < 0) or (Row > High(FListing)) then
  begin
    ClearPreview;
    Exit;
  end;
  PreviewArchiveItem(FListing[Row]);
end;

procedure TMainForm.ArcKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  Row: Integer;
begin
  if Shift <> [] then Exit;
  if Key = VK_RETURN then
  begin
    Row := FArcList.ItemIndex;
    if Row >= 0 then
    begin
      ArcItemActivate(FArcList, Row);
      Key := 0;
    end;
  end
  else if (Key = VK_DELETE) or (Key = VK_BACK) then
  begin
    if Key = VK_BACK then UpClick(nil) else DeleteClick(nil);
    Key := 0;
  end;
end;


{ ---------------------------------------------------------------------------
  History
  --------------------------------------------------------------------------- }

function TMainForm.CurrentState: TNavState;
begin
  Result.Kind := FMode;
  Result.FsPath := FFsPath;
  Result.Ctx := FCtx;
  Result.Inner := FInnerPath;
end;

procedure TMainForm.PushBack;
var
  S: TNavState;
begin
  if FNavGuard then Exit;
  S := CurrentState;
  if S.Kind = nkFiles then
  begin
    S.Ctx := nil;
    S.Inner := '';
  end;
  FHistory.PushBack(S);
end;

procedure TMainForm.GoBack;
var
  S, Cur: TNavState;
begin
  Cur := CurrentState;
  if not FHistory.Back(Cur, S) then Exit;
  ApplyState(S);
end;

procedure TMainForm.GoForward;
var
  S, Cur: TNavState;
begin
  Cur := CurrentState;
  if not FHistory.Forward(Cur, S) then Exit;
  ApplyState(S);
end;

procedure TMainForm.ApplyState(const AState: TNavState);
begin
  FNavGuard := True;
  try
    if AState.Kind = nkArchive then
    begin
      if AState.Ctx = nil then Exit;
      FMode := nkArchive;
      FCtx := AState.Ctx;
      FInnerPath := AState.Inner;
      FFsList.Visible := False;
      FArcList.Visible := True;
      FFsTree.Visible := False;
      FArcNavTree.Visible := True;
      PopulateArchiveTree;
      RefreshArchiveListing;
      SyncArchiveTreeSelection;
      LoadArchiveUi;
      Exit;
    end
    else
    begin
      FMode := nkFiles;
      FCtx := nil;
      FInnerPath := '';
      FNameEncodingOverride := '';
      FFsList.Visible := True;
      FArcList.Visible := False;
      FFsTree.Visible := True;
      FArcNavTree.Visible := False;
      FFsPath := AState.FsPath;
      { Same cached-listing fast path as NavigateFs: Back from an archive should
        not re-read the whole folder and its icons. }
      if not (SameText(ExcludeTrailingPathDelimiter(FFsList.Directory),
                       ExcludeTrailingPathDelimiter(AState.FsPath)) and
              (Length(FFsList.Entries) > 0)) then
      begin
        BeginBusy(Format(rsStatusLoadingFolderFmt, [AState.FsPath]));
        try
          FFsList.LoadDirectory(AState.FsPath);
        finally
          EndBusy;
        end;
      end;
      if not SameText(ExcludeTrailingPathDelimiter(FFsTree.Directory),
                      ExcludeTrailingPathDelimiter(AState.FsPath)) then
        FFsTree.SelectPath(AState.FsPath);
      LoadFsUi;
      Exit;
    end;
  finally
    FNavGuard := False;
  end;
  { Both branches above finish with LoadArchiveUi/LoadFsUi and Exit, so there is
    no shared tail. A line here would be unreachable (and used to be). }
end;

procedure TMainForm.BackClick(Sender: TObject);
begin GoBack; end;
procedure TMainForm.ForwardClick(Sender: TObject);
begin GoForward; end;

procedure TMainForm.UpClick(Sender: TObject);
var
  P: string;
begin
  if FMode = nkArchive then
  begin
    if FInnerPath <> '' then
      SetArchiveContext(FCtx, TzParentArcPath(FInnerPath))
    else if FCtx.Parent <> nil then
      SetArchiveContext(FCtx.Parent, '')
    else
    begin
      { Leaving the archive must land on the archive itself, not on whichever
        file row happened to be under the pointer when the archive was opened. }
      FSelectFsPath := FCtx.SourcePath;
      NavigateFs(FCtx.OpenedFromFs);
    end;
    Exit;
  end;
  P := ExcludeTrailingPathDelimiter(FFsPath);
  if P = '/' then Exit;
  P := ExtractFileDir(P);
  if P = '' then P := '/';
  NavigateFs(P);
end;

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  if FMode = nkArchive then RefreshArchiveListing else FFsList.UpdateView;
end;

{ ---------------------------------------------------------------------------
  Status / actions
  --------------------------------------------------------------------------- }

function TMainForm.SelectedArchiveRows: Integer;
begin
  Result := ArcSelectedRows;
end;

function TMainForm.SelectedArchiveIndices(ANeedSelection: Boolean): TLongWordArray;
var
  Sel: array of Boolean;
  I, Idx: Integer;
  N: PTyTreeNode;
begin
  SetLength(Sel, Length(FListing));
  for I := 0 to High(FListing) do
    if FArcList.Selected[I] then Sel[I] := True;
  Result := TzSelectedIndices(FCtx, FListing, Sel);
  if ANeedSelection and (Length(Result) = 0) then
    SetLength(Result, 0);
end;

function TMainForm.SelectedFsPaths: TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 0 to High(FFsList.Entries) do
    if FFsList.Selected[I + 1] then
      Result.Add(FFsList.Entries[I].FullPath);
end;

procedure TMainForm.BeginBusy(const AMsg: string);
begin
  Inc(FBusyCount);
  if FStatus <> nil then
  begin
    FStatus.SimpleText := AMsg;
    { Paint the status line now: the operation that follows is synchronous, so
      waiting for the next event-loop idle would leave the window looking frozen. }
    FStatus.Update;
  end;
  Screen.Cursor := crHourGlass;
end;

procedure TMainForm.EndBusy;
begin
  if FBusyCount > 0 then Dec(FBusyCount);
  if FBusyCount > 0 then Exit;
  Screen.Cursor := crDefault;
  if FReady then UpdateStatus;
end;

{ ---------------------------------------------------------------------------
  Busy overlay
  --------------------------------------------------------------------------- }

procedure TMainForm.CreateOverlay;
  { One factory for the four muted statistics labels: only their position and
    name differ. }
  function NewStatLabel(ALeft, ATop: Integer; const AName: string): TTyLabel;
  begin
    Result := TTyLabel.Create(Self);
    Result.Parent := FOverlayCard;
    Result.AutoSize := False;
    Result.Left := ALeft;
    Result.Top := ATop;
    Result.Width := 180;
    Result.Height := 18;
    Result.Caption := '';
    Result.StyleOverride := 'color: var(--muted);';
    Result.Name := AName;
  end;

begin
  FOverlay := TTyPaintPanel.Create(Self);
  FOverlay.Parent := FContent;
  { NOT alClient.  A full-size child control cannot be transparent: TyControls
    fills a control's rect with the parent's OPAQUE background before painting,
    so the rest of the window would sit behind a dark sheet.  Sized to the card
    and centred on it, only the card covers anything and the window stays
    visible around it. }
  FOverlay.Align := alNone;
  FOverlay.Visible := False;
  { No Name: a caption-less TTyPaintPanel/TTyPanel paints TControl.Caption, which
    falls back to the component name. Naming these drew "BusyOverlayCard" inside
    the card. }
  { No themed frame: the card's own background is the only surface.  Keep a
    normal solid background (NOT 'none'): the rounded card is a windowed child,
    so its corner pixels are alpha 0 in its own bitmap, and without an opaque
    parent fill they land black on screen.  A solid parent fill paints them with
    the window surface colour instead. }
  FOverlay.StyleOverride := 'border: none; padding: 0px;';

  FOverlayCard := TTyPanel.Create(Self);
  FOverlayCard.Parent := FOverlay;
  FOverlayCard.Caption := '';
  FOverlayCard.Visible := False;
  { No shadow: the default theme has no --shadow token, and a shadow on a
    windowed child can only paint its own corner gaps with the parent's opaque
    colour -- that is the black corner the card used to show. }
  FOverlayCard.StyleOverride :=
    'background: var(--card-bg); border: 1px solid var(--border); ' +
    'border-radius: 12px; padding: 0px;';

  FOverlayTitle := TTyLabel.Create(Self);
  FOverlayTitle.Parent := FOverlayCard;
  FOverlayTitle.AutoSize := False;
  FOverlayTitle.Left := 20;
  FOverlayTitle.Top := 16;
  FOverlayTitle.Width := 400;
  FOverlayTitle.Height := 22;
  FOverlayTitle.Caption := '';
  FOverlayTitle.StyleOverride := 'font-weight: bold;';
  FOverlayTitle.Name := 'BusyOverlayTitle';

  FOverlayDetail := TTyLabel.Create(Self);
  FOverlayDetail.Parent := FOverlayCard;
  FOverlayDetail.AutoSize := False;
  FOverlayDetail.Left := 20;
  FOverlayDetail.Top := 40;
  FOverlayDetail.Width := 400;
  FOverlayDetail.Height := 20;
  FOverlayDetail.Caption := '';
  FOverlayDetail.StyleOverride := 'color: var(--muted);';
  FOverlayDetail.Name := 'BusyOverlayDetail';

  FOverlayStatElapsed := NewStatLabel(20, 86, 'BusyOverlayElapsed');
  FOverlayStatEta := NewStatLabel(220, 86, 'BusyOverlayEta');
  FOverlayStatTotal := NewStatLabel(20, 106, 'BusyOverlayTotal');
  FOverlayStatSpeed := NewStatLabel(220, 106, 'BusyOverlaySpeed');
  FOverlayStatFiles := NewStatLabel(20, 126, 'BusyOverlayFiles');
  FOverlayStatPacked := NewStatLabel(220, 126, 'BusyOverlayPacked');

  FOverlayCurrent := TTyLabel.Create(Self);
  FOverlayCurrent.Parent := FOverlayCard;
  FOverlayCurrent.AutoSize := False;
  FOverlayCurrent.Left := 20;
  FOverlayCurrent.Top := 148;
  FOverlayCurrent.Width := 400;
  FOverlayCurrent.Height := 18;
  FOverlayCurrent.Caption := '';
  FOverlayCurrent.StyleOverride := 'color: var(--muted);';
  FOverlayCurrent.Name := 'BusyOverlayCurrent';

  FOverlayBar := TTyProgressBar.Create(Self);
  FOverlayBar.Parent := FOverlayCard;
  FOverlayBar.Left := 20;
  FOverlayBar.Top := 64;
  FOverlayBar.Width := 400;
  FOverlayBar.Height := 10;
  FOverlayBar.Min := 0;
  FOverlayBar.Max := 100;
  FOverlayBar.Position := 0;
  FOverlayBar.BarShowText := False;
  FOverlayBar.Name := 'BusyOverlayBar';

  FOverlaySpin := TTyActivityIndicator.Create(Self);
  FOverlaySpin.Parent := FOverlayCard;
  FOverlaySpin.Left := 20;
  FOverlaySpin.Top := 64;
  FOverlaySpin.Width := 18;
  FOverlaySpin.Height := 18;
  FOverlaySpin.Thickness := 4;
  FOverlaySpin.Active := False;
  FOverlaySpin.Visible := False;
  FOverlaySpin.Name := 'BusyOverlaySpin';

  FOverlayCancel := TTyButton.Create(Self);
  FOverlayCancel.Parent := FOverlayCard;
  FOverlayCancel.Caption := rsDlgCancel;
  FOverlayCancel.Left := 280;
  FOverlayCancel.Top := 170;
  FOverlayCancel.Width := 80;
  FOverlayCancel.Height := 28;
  FOverlayCancel.Visible := False;
  FOverlayCancel.OnClick := @OverlayCancelClick;
  FOverlayCancel.Name := 'BusyOverlayCancel';

  FOverlayPause := TTyButton.Create(Self);
  FOverlayPause.Parent := FOverlayCard;
  FOverlayPause.Caption := rsDlgPause;
  FOverlayPause.Left := 190;
  FOverlayPause.Top := 170;
  FOverlayPause.Width := 80;
  FOverlayPause.Height := 28;
  FOverlayPause.Visible := False;
  FOverlayPause.OnClick := @OverlayPauseClick;
  FOverlayPause.Name := 'BusyOverlayPause';

  FOverlayReveal := TTimer.Create(Self);
  FOverlayReveal.Interval := OverlayRevealMs;
  FOverlayReveal.Enabled := False;
  FOverlayReveal.OnTimer := @RevealOverlay;

  FJobTimer := TTimer.Create(Self);
  FJobTimer.Interval := 60;
  FJobTimer.Enabled := False;
  FJobTimer.OnTimer := @JobTimerTick;
end;

procedure TMainForm.LayoutOverlay;
const
  CardW = 440;
  CardH = 214;
var
  X, Y: Integer;
begin
  if (FOverlayCard = nil) or (FOverlay = nil) or (FContent = nil) then Exit;
  { The panel is exactly the card: the smallest opaque area that still catches
    clicks on it.  Everything around the card stays the real window. }
  X := (FContent.ClientWidth - CardW) div 2;
  Y := (FContent.ClientHeight - CardH) div 2;
  if X < 0 then X := 0;
  if Y < 0 then Y := 0;
  FOverlay.SetBounds(X, Y, CardW, CardH);
  FOverlayCard.SetBounds(0, 0, CardW, CardH);
  if FOverlayCancel.Visible then
    FOverlayCancel.Left := CardW - FOverlayCancel.Width - 20;
  if FOverlayPause.Visible then
  begin
    FOverlayPause.Left := CardW - FOverlayPause.Width - 20 -
      FOverlayCancel.Width - 8;
    if FOverlayPause.Left < 20 then FOverlayPause.Left := 20;
  end;
end;

procedure TMainForm.ContentResize(Sender: TObject);
begin
  if FOverlayShown then LayoutOverlay;
  if (FStartupHint <> nil) and FStartupHint.Visible then LayoutStartupHint;
end;

procedure TMainForm.FilterTimerTick(Sender: TObject);
begin
  RefreshFilter;
end;

procedure TMainForm.ShowOverlay(const ATitle, ADetail: string;
  ADeterminate, ACancelable: Boolean);
begin
  if (FOverlay = nil) or (FJob = nil) then Exit;
  FOverlayTitleText := ATitle;
  FOverlayDetailText := ADetail;
  FOverlayDeterminate := ADeterminate;
  FOverlayCancelable := ACancelable;
  FOverlayTitle.Caption := ATitle;
  FOverlayDetail.Caption := ADetail;
  FOverlayCancel.Enabled := ACancelable;
  if FOverlayPause <> nil then
  begin
    FOverlayPause.Visible := ACancelable;
    FOverlayPause.Enabled := ACancelable;
    FOverlayPause.Caption := rsDlgPause;
  end;
  { The main window is not on screen for a cold-start service: the same task
    sentence and the same pause/cancel reach the small window instead. }
  if FServiceMode then
  begin
    if FServiceProgress = nil then
    begin
      FServiceProgress := TServiceProgressForm.Create(Self);
      FServiceProgress.OnPauseClick := @OverlayPauseClick;
      FServiceProgress.OnCancelClick := @OverlayCancelClick;
    end;
    FServiceProgress.SetTask(ATitle, ADetail, ADeterminate);
  end;
  FOverlayProgressSeen := False;
  UpdateOverlayStats(0, 0);
  { Startup: reveal at once.  The deferred reveal below exists to avoid a flash
    on fast jobs, but at startup there is nothing else on screen -- waiting showed
    an empty window first. }
  if FStartupPhase then
  begin
    RevealOverlay(nil);
    Exit;
  end;
  if FOverlayShown then
  begin
    { A follow-up job (open then extract, extract then open): keep the card up
      instead of flashing it away and back. }
    LayoutOverlay;
    FOverlayCard.Invalidate;
    Exit;
  end;
  { The reveal is deferred: a job that finishes in 40 ms should not flash a
    card.  A job that really is slow gets one after OverlayRevealMs.  A job that
    follows another within a few hundred ms (open then list, open then extract)
    reveals at once, so the card does not blink off and on. }
  if (FOverlayHiddenAt <> 0) and
    (GetTickCount64 - FOverlayHiddenAt < 400) then
  begin
    RevealOverlay(nil);
    Exit;
  end;
  RestartTimer(FOverlayReveal);
end;

procedure TMainForm.RevealOverlay(Sender: TObject);
begin
  FOverlayReveal.Enabled := False;
  if (FOverlay = nil) or (FJob = nil) then Exit;
  FOverlay.Visible := True;
  FOverlay.BringToFront;
  FOverlayTitle.Caption := FOverlayTitleText;
  FOverlayDetail.Caption := FOverlayDetailText;
  FOverlayBar.Visible := FOverlayDeterminate and FOverlayProgressSeen;
  FOverlaySpin.Visible := not FOverlayBar.Visible;
  FOverlaySpin.Active := FOverlaySpin.Visible;
  FOverlayCancel.Visible := FOverlayCancelable;
  FOverlayCancel.Enabled := FOverlayCancelable;
  FOverlayPause.Visible := FOverlayCancelable;
  FOverlayPause.Enabled := True;
  FOverlayPause.Caption := rsDlgPause;
  FOverlayCancel.Caption := rsDlgCancel;
  FOverlayBar.Position := 0;
  UpdateOverlayStats(0, 0);
  FOverlayCard.Visible := True;
  LayoutOverlay;
  FOverlayCard.Invalidate;
  FOverlayShown := True;
  Screen.Cursor := crHourGlass;
end;

procedure TMainForm.UpdateOverlayStats(ADone, ATotal: QWord);
var
  Elapsed, Rate, PhaseElapsed: QWord;
  Info: TZJobProgressDetail;
  Ratio: Integer;
  PackedText, PhaseText: string;
begin
  if (FOverlayStatElapsed = nil) or (FJob = nil) then Exit;
  if FJob.StartedAt = 0 then
    Elapsed := 0
  else
    Elapsed := GetTickCount64 - FJob.StartedAt;
  FOverlayStatElapsed.Caption := Format(rsDlgElapsedFmt,
    [TzFormatDurationMs(Elapsed)]);

  { Per-item data from the ABI-v4 sink; blank when the phase cannot provide it
    (for example a 7z header parse, which has no item events). }
  Info := Default(TZJobProgressDetail);
  PhaseElapsed := Elapsed;
  if FJob.SnapshotDetail(Info) then
  begin
    if Info.PhaseStartedAt > 0 then
      PhaseElapsed := GetTickCount64 - Info.PhaseStartedAt;
    PhaseText := '';
    case Info.Phase of
      TZ7Z_PH_EXTRACT: PhaseText := rsDlgPhaseExtract;
      TZ7Z_PH_CREATE: PhaseText := rsDlgPhaseCreate;
      TZ7Z_PH_TEST: PhaseText := rsDlgPhaseTest;
      TZ7Z_PH_OPEN: PhaseText := rsDlgPhaseOpen;
    end;
    if (Info.ItemCount > 0) and (Info.ItemIndex < Info.ItemCount) then
      FOverlayStatFiles.Caption := Format(rsDlgFilesFmt,
        [Int64(Info.ItemIndex) + 1, Int64(Info.ItemCount)])
    else
      FOverlayStatFiles.Caption := '';
    if Info.PackedKnown and (Info.PackedDone > 0) then
    begin
      if (Info.BytesDone > 0) and (Info.PackedDone <= High(Int64)) then
      begin
        Ratio := Integer((Info.PackedDone * 100) div Info.BytesDone);
        PackedText := Format(rsDlgPackedRatioFmt,
          [TzFormatSize(Info.PackedDone), Ratio]);
      end
      else
        PackedText := Format(rsDlgPackedFmt, [TzFormatSize(Info.PackedDone)]);
      FOverlayStatPacked.Caption := PackedText;
    end
    else
      FOverlayStatPacked.Caption := '';
    if Info.ItemName <> '' then
      FOverlayCurrent.Caption := Format(rsDlgCurrentFileFmt,
        [TzShortenText(Info.ItemName, 64)])
    else
      FOverlayCurrent.Caption := '';
    if PhaseText <> '' then
    begin
      if FOverlayCurrent.Caption <> '' then
        FOverlayCurrent.Caption := Format(rsDlgPhaseCurrentFmt,
          [PhaseText, FOverlayCurrent.Caption])
      else
        FOverlayCurrent.Caption := PhaseText;
    end;
  end;

  if ATotal = 0 then
  begin
    FOverlayStatEta.Caption := '';
    FOverlayStatTotal.Caption := '';
    FOverlayStatSpeed.Caption := '';
    Exit;
  end;
  Rate := TzProgressRate(ADone, PhaseElapsed);
  if FJob.ProgressKind = jpkItems then
    FOverlayStatTotal.Caption := Format(rsDlgItemsTotalFmt, [Int64(ATotal)])
  else
    FOverlayStatTotal.Caption := Format(rsDlgTotalSizeFmt, [TzFormatSize(ATotal)]);
  if ADone >= ATotal then
    FOverlayStatEta.Caption := Format(rsDlgRemainingFmt,
      [TzFormatDurationMs(0)])
  else if Rate > 0 then
    FOverlayStatEta.Caption := Format(rsDlgRemainingFmt,
      [TzFormatDurationMs(TzProgressEtaMs(ATotal, ADone, Rate))])
  else
    FOverlayStatEta.Caption := rsDlgRemainingUnknown;
  if Rate = 0 then
    FOverlayStatSpeed.Caption := ''
  else if FJob.ProgressKind = jpkItems then
    FOverlayStatSpeed.Caption := Format(rsDlgItemsRateFmt, [Int64(Rate)])
  else
    FOverlayStatSpeed.Caption := Format(rsDlgSpeedFmt, [TzFormatSize(Rate)]);
end;

procedure TMainForm.SetOverlayProgress(ADone, ATotal: QWord;
  const ADetail: string);
var
  Pct: Integer;
  Line: string;
begin
  if FServiceProgress <> nil then
    FServiceProgress.SetProgress(ADone, ATotal);
  if (FOverlayBar = nil) or (not FOverlayShown) then Exit;
  if (FJob <> nil) and FJob.CancelRequested then Exit;
  if (FJob <> nil) and FJob.Paused then
  begin
    UpdateOverlayStats(ADone, ATotal);
    FOverlayDetail.Caption := rsDlgPaused;
    Exit;
  end;
  UpdateOverlayStats(ADone, ATotal);
  if ATotal > 0 then
  begin
    if not FOverlayProgressSeen then
    begin
      FOverlayProgressSeen := True;
      FOverlaySpin.Active := False;
      FOverlaySpin.Visible := False;
      FOverlayBar.Visible := FOverlayDeterminate;
    end;
    Pct := TzProgressPercent(ADone, ATotal);
    FOverlayBar.Position := Pct;
    if (FJob <> nil) and (FJob.ProgressKind = jpkItems) then
      Line := Format(rsDlgProgressItemsFmt, [Int64(ADone), Int64(ATotal), Pct])
    else
      Line := Format(rsDlgProgressFmt,
        [TzFormatSize(ADone), TzFormatSize(ATotal), Pct]);
    if FOverlayDetailText <> '' then
      FOverlayDetail.Caption := FOverlayDetailText + '  ·  ' + Line
    else
      FOverlayDetail.Caption := Line;
  end
  else
  begin
    if ADetail <> '' then FOverlayDetail.Caption := ADetail
    else FOverlayDetail.Caption := TzFormatSize(ADone);
  end;
end;

procedure TMainForm.HideOverlay;
begin
  FOverlayReveal.Enabled := False;
  if FOverlay = nil then Exit;
  if FOverlayShown then Screen.Cursor := crDefault;
  FOverlayShown := False;
  FOverlayProgressSeen := False;
  FOverlayCard.Visible := False;
  FOverlaySpin.Active := False;
  FOverlaySpin.Visible := False;
  FOverlayPause.Visible := False;
  FOverlay.Visible := False;
  FOverlayHiddenAt := GetTickCount64;
  FOverlayTitle.Caption := '';
  FOverlayDetail.Caption := '';
  if FOverlayStatElapsed <> nil then
  begin
    FOverlayStatElapsed.Caption := '';
    FOverlayStatEta.Caption := '';
    FOverlayStatTotal.Caption := '';
    FOverlayStatSpeed.Caption := '';
    FOverlayStatFiles.Caption := '';
    FOverlayStatPacked.Caption := '';
    FOverlayCurrent.Caption := '';
  end;
  FOverlayBar.Position := 0;
end;

procedure TMainForm.OverlayCancelClick(Sender: TObject);
begin
  if FJob <> nil then FJob.RequestCancel;
  FOverlayCancel.Enabled := False;
  FOverlayCancel.Caption := rsDlgCancelling;
  FOverlayPause.Enabled := False;
  FOverlayDetail.Caption := rsDlgCancelling;
  if FServiceProgress <> nil then FServiceProgress.SetCancelling;
end;

procedure TMainForm.OverlayPauseClick(Sender: TObject);
begin
  if FJob = nil then Exit;
  if FJob.Paused then
  begin
    FJob.Resume;
    FOverlayPause.Caption := rsDlgPause;
    FOverlayDetail.Caption := FOverlayDetailText;
  end
  else
  begin
    FJob.Pause;
    FOverlayPause.Caption := rsDlgResume;
    FOverlayDetail.Caption := rsDlgPaused;
  end;
  if FServiceProgress <> nil then FServiceProgress.SetPaused(FJob.Paused);
end;

procedure TMainForm.MaybeFinishService;
begin
  if not FServiceMode then Exit;
  { A batch may still be handing one archive over to the next; only a fully idle
    form ends the process. }
  if (FJob <> nil) or (FJobs.QueuedCount > 0) or (FBatchRun <> nil) then Exit;
  FServiceMode := False;
  FreeAndNil(FServiceProgress);
  { The service was the only reason this process exists: do not leave a dock
    icon and no window behind. }
  Application.Terminate;
end;

{ ---------------------------------------------------------------------------
  Background jobs
  --------------------------------------------------------------------------- }

{ Park a job until the current one finishes.

  The job object is kept whole: it already carries everything the operation needs
  (path, indices, destination, settings), so replaying it is just starting it
  again. The queue owns the job until it is taken out again. }
procedure TMainForm.EnqueueJob(AJob: TZJob; APurpose: TZJobPurpose;
  const ATitle, ADetail: string);
begin
  FJobs.Enqueue(AJob, Ord(APurpose), ATitle, ADetail);
end;

{ Report the batch that just ended.

  The tally and its summary belong to tzip.jobcontrol; what is left here is the
  window: the status line, the (deferred) dialog and the refreshed folder. }
procedure TMainForm.FinishBatch;
var
  Msg: string;
begin
  if not FJobs.HasBatch then Exit;
  Msg := FJobs.SummaryText;
  FStatus.SimpleText := Format(rsStatusBatchDoneFmt, [FJobs.SummaryCount]);
  { The summary is a modal dialog, and this runs inside the job timer's callback.
    Opening it there re-entered the message loop from a timer event (windows could
    stack, and the paint/settle order became whichever timer fired first). Compose
    it now, show it once the callback has returned. A service quits on completion,
    so it has no use for a summary dialog. }
  if not FServiceMode then
  begin
    FPendingBatchSummary := Msg;
    FPendingBatchHadFailures := FJobs.BatchHadFailures;
    Application.QueueAsyncCall(@ShowPendingBatchSummary, 0);
  end;
  FJobs.EndBatch;
  { The extraction wrote into the folder being shown, so the new folders have to
    appear without the user pressing F5. Done once at the end of the batch rather
    than after every archive. }
  if (FMode <> nkArchive) and (FFsList <> nil) then
    FFsList.LoadDirectory(FFsPath);
end;

function TMainForm.StartNextQueued: Boolean;
var
  Job: TZJob;
  { NOT "Tag": TComponent already has one, and a local of that name is a
    duplicate identifier. }
  PurposeTag: Integer;
  Purpose: TZJobPurpose;
  Title, Detail: string;
begin
  Result := False;
  { Takes the job out of the queue and frees the wrapper: the TZJob itself is now
    owned by the form again. Nothing is shifted, so the labels that go with it
    cannot be left pointing at freed memory. }
  if not FJobs.TakeNext(Job, PurposeTag, Title, Detail) then Exit;
  Purpose := TZJobPurpose(PurposeTag);
  StartJobNow(Job, Purpose, Title, Detail, True, True);
  Result := True;
end;

procedure TMainForm.ClearQueuedJobs;
begin
  { The controller frees both the waiting jobs and their labels. }
  if FJobs <> nil then FJobs.Clear;
end;

procedure TMainForm.StartJob(AJob: TZJob; APurpose: TZJobPurpose;
  const ATitle, ADetail: string; ADeterminate, ACancelable: Boolean);
begin
  if FJob <> nil then
  begin
    { Serialised: one job at a time. A second request is queued rather than
      discarded, which is what makes selecting ten archives and asking for them
      all to be extracted mean ten extractions instead of one. }
    EnqueueJob(AJob, APurpose, ATitle, ADetail);
    Exit;
  end;
  { Starting from idle begins a new run: any previous batch tally is stale. }
  if (APurpose in [jpBatchExtract, jpBatchTest]) and (FJobs.QueuedCount = 0) then
    FJobs.BeginBatch;
  StartJobNow(AJob, APurpose, ATitle, ADetail, ADeterminate, ACancelable);
end;

{ Actually start a job. Separated from StartJob so the queue can start the next
  one without going through the "already busy" check it would fail. }
procedure TMainForm.StartJobNow(AJob: TZJob; APurpose: TZJobPurpose;
  const ATitle, ADetail: string; ADeterminate, ACancelable: Boolean);
begin
  { Every archive a job opens needs the ZIP name code page. A job that carries
    a context override keeps it; otherwise the settings default is resolved here,
    once, before the worker reads any name. }
  if AJob.NameCodepage = 0 then
    AJob.NameCodepage := TzResolveNameCodepage(FSettings.NameEncoding,
      TzEffectiveLanguageId);
  FJob := AJob;
  FJobPurpose := APurpose;
  FJobTitle := ATitle;
  FJobDetail := ADetail;
  FJobDeterminate := ADeterminate;
  FJobCancelable := ACancelable;
  ShowOverlay(ATitle, ADetail, ADeterminate, ACancelable);
  RefreshActions;
  FJobTimer.Enabled := True;
  AJob.Start;
end;

procedure TMainForm.JobTimerTick(Sender: TObject);
var
  Done, Total: QWord;
  Detail: string;
  R: Integer;
  Err: string;
begin
  if FJob = nil then
  begin
    FJobTimer.Enabled := False;
    Exit;
  end;
  if FJob.Snapshot(Done, Total, Detail) then
  begin
    if FJobDeterminate then
      SetOverlayProgress(Done, Total, Detail)
    else
      UpdateOverlayStats(0, 0);
  end;
  if not FJob.TakeResult(R, Err) then Exit;
  CompleteJob(R, Err);
end;

function TMainForm.RestartJobWithPassword(const APrompt: string): Boolean;
var
  Pw: string;
  Retry: TZJob;
begin
  Result := False;
  if FJob = nil then Exit;
  Pw := FJob.Password;
  if not AskPassword(Self, APrompt, Pw) then Exit;
  if FJobPurpose in [jpOpenBrowse, jpOpenInner, jpOpenExtractHere,
    jpOpenAfterModify] then
    FLastOpenPassword := Pw;
  { A finished TThread cannot run again, so the retry is a fresh job with the
    same inputs.  The old one is finished by now and safe to free. }
  Retry := FJobs.CloneForRetry(FJob, Pw);
  FJob.Free;
  FJob := Retry;
  FJobTimer.Enabled := True;
  ShowOverlay(FJobTitle, FJobDetail, FJobDeterminate, FJobCancelable);
  FJob.Start;
  Result := True;
end;

procedure TMainForm.RegisterJobHandlers;

  procedure Add(APurpose: TZJobPurpose; AHandler: TJobHandler);
  begin
    SetLength(FJobHandlers, Length(FJobHandlers) + 1);
    FJobHandlers[High(FJobHandlers)].Purpose := APurpose;
    FJobHandlers[High(FJobHandlers)].Handler := AHandler;
  end;

begin
  SetLength(FJobHandlers, 0);
  Add(jpList, @HandleJobList);
  Add(jpSearch, @HandleJobSearch);
  Add(jpBatchList, @HandleJobBatchList);
  Add(jpBatchStage, @HandleJobBatchStage);
  Add(jpOpenExtractHere, @HandleJobOpenExtractHere);
  Add(jpOpenBrowse, @HandleJobOpen);
  Add(jpOpenInner, @HandleJobOpen);
  Add(jpOpenAfterModify, @HandleJobOpen);
  Add(jpOpenConvert, @HandleJobOpenConvert);
  Add(jpExtract, @HandleJobExtract);
  Add(jpConvert, @HandleJobConvert);
  Add(jpTest, @HandleJobTest);
  Add(jpCreate, @HandleJobCreate);
  Add(jpModify, @HandleJobModify);
  Add(jpExtractOneOpen, @HandleJobExtractOne);
  Add(jpOpenNestedThenView, @HandleJobExtractOne);
end;

function TMainForm.JobHandlerFor(APurpose: TZJobPurpose): TJobHandler;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(FJobHandlers) do
    if FJobHandlers[I].Purpose = APurpose then
      Exit(FJobHandlers[I].Handler);
  { jpNone, jpBatchExtract and jpBatchTest have no work of their own: they only
    need the shared tail (tally included), so no handler is registered for them. }
end;

procedure TMainForm.CompleteJob(AResult: Integer; const AError: string);
var
  Job: TZJob;
  Purpose: TZJobPurpose;
  Handler: TJobHandler;
  RetryPassword: Boolean;
  Prompt: string;
begin
  FCompletionMsgSet := False;
  Job := FJob;
  Purpose := FJobPurpose;
  FJob := nil;
  FJobPurpose := jpNone;
  FJobTimer.Enabled := False;
  HideOverlay;

  if Job = nil then Exit;

  { A data-encrypted 7z reports a wrong password as a data error, not as
    TZ7Z_E_PASSWORD (#09 keeps the error code honest), so the generic error box
    would say "data error" right after the user typed the password. Pulling one
    entry out of an encrypted archive is interactive and its only correctable
    input is the password, so retry it once; every other job keeps its handling. }
  RetryPassword := (AResult = TZ7Z_E_PASSWORD) or
    ((Purpose in [jpExtractOneOpen, jpOpenNestedThenView]) and
     TzShouldRetryPasswordAfterExtractError(AResult, FExtractOneEncrypted,
       Job.Password <> '', FExtractOnePasswordRetried));

  if RetryPassword then
  begin
    { Keep the job so the same request can be re-run with the new password. }
    FJob := Job;
    FJobPurpose := Purpose;
    if AResult = TZ7Z_E_PASSWORD then
      Prompt := Format(rsPasswordForFmt, [Job.DisplayName])
    else
    begin
      FExtractOnePasswordRetried := True;
      Prompt := Format(rsPasswordWrongForFmt, [Job.DisplayName]);
    end;
    if RestartJobWithPassword(Prompt) then Exit;
    FJob := nil;
    FJobPurpose := jpNone;
    { Declining the password prompt IS cancelling the request. Settle it exactly
      like the Cancel button does: tally the batch item, drop the rest of the
      queue and report. Leaving them behind meant the next, unrelated completion
      started a stale archive and the batch summary counted the wrong run. }
    if Purpose in [jpBatchExtract, jpBatchTest] then
      FJobs.NoteResult(Job.DisplayName, TZ7Z_E_CANCEL, '');
    Job.Free;
    ClearQueuedJobs;
    if FJobs.QueuedCount = 0 then FinishBatch;
    UpdateStatus;
    RefreshActions;
    Exit;
  end;

  { The per-purpose work is a handler, not a branch: adding a purpose means one
    method and one line in RegisterJobHandlers. joDone is what the old Exit
    inside a branch meant -- stop before the shared tail. }
  Handler := JobHandlerFor(Purpose);
  if (Handler <> nil) and
     (Handler(Job, Purpose, AResult, AError) = joDone) then Exit;

  FinishJob(Job, Purpose, AResult, AError);
end;

{ The shared end of every completion. Extracted so a handler cannot forget a
  step, and so the tally happens exactly once. }
procedure TMainForm.FinishJob(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string);
begin
  { The tally is read from the job, so it happens BEFORE the object is freed --
    and from APurpose, not FJobPurpose: that field was cleared on entry. }
  if APurpose in [jpBatchExtract, jpBatchTest] then
    FJobs.NoteResult(AJob.DisplayName, AResult, AError);
  { FJob has to be cleared BEFORE the object goes: the queue check below asks
    whether a job is running, and leaving the field pointing at freed memory made
    it answer yes -- so only the first archive of a batch ever ran. }
  if FJob = AJob then FJob := nil;
  AJob.Free;
  { The queue runs one at a time; starting the next one here is what turns a
    batch into a sequence rather than a single operation. A batch is abandoned
    when the user cancelled, because the remaining items would only be refused
    in the same way. }
  if FJob = nil then
  begin
    if AResult = TZ7Z_E_CANCEL then
      ClearQueuedJobs
    else
      StartNextQueued;
    { Only the last item ends the run: if another job was started, the tally
      continues. Checking the queue alone was not enough, because a job that
      finishes faster than the handoff leaves it empty again. }
    if (FJob = nil) and (FJobs.QueuedCount = 0) then
    begin
      { A listing requested while the engine was busy was dropped with a flag and
        never retried, so a big archive could sit on its ".." placeholder until
        the user pressed refresh. This is the retry point the flag was for. }
      if (FMode = nkArchive) and FListPending then
        RefreshArchiveListing;
      FinishBatch;
      { Continue the conflict-aware batch pipeline only after the finished job is
        fully cleaned up: one archive at a time. }
      if FBatchNextPending then
      begin
        FBatchNextPending := False;
        ContinueBatch;
      end;
    end;
  end;
  if (not FCompletionMsgSet) or (FStatus.SimpleText = '') then UpdateStatus;
  RefreshActions;
  MaybeFinishService;
end;

function TMainForm.HandleJobList(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
begin
  Result := joContinue;
  if (AResult = TZ7Z_OK) and (FMode = nkArchive) and (AJob.CtxRef = FCtx) and
    (AJob.InnerPath = FInnerPath) and (AJob.Filter = FFilter) and
    (AJob.SortCol = FSortCol) and (AJob.SortDesc = FSortDesc) then
  begin
    ApplyListing(AJob.Listing);
    FListPending := False;
    Exit;
  end;
  { The user moved somewhere else (or the archive changed) while the worker was
    listing. Drop the result and list the current place. }
  FListPending := False;
  AJob.Free;
  if FMode = nkArchive then RefreshArchiveListing;
  Result := joDone;
end;

{ A search result is applied on the main thread, never in the worker: the listing
  belongs to the UI, and the name filter is whatever the box says NOW, not what it
  said when the search started. }
function TMainForm.HandleJobSearch(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  Listing: TListing;
begin
  Result := joContinue;
  if AResult = TZ7Z_E_CANCEL then
  begin
    { Cancelled on purpose -- a new search, a closed archive, a closing window.
      The caller already set the state it wants, and no partial result arrives. }
    Exit;
  end;
  if AResult <> TZ7Z_OK then
  begin
    if SearchActive then
      ShowError(rsErrCannotOpenArchive + LineEnding + AError);
    Exit;
  end;
  { The user may have cleared the search or left the archive while it ran. }
  if not SearchActive then Exit;
  Listing := FilterListingByName(AJob.Listing, FFilter);
  ApplyListing(Listing);
  if Length(Listing) = 0 then
    FStatus.SimpleText := rsStatusSearchNone
  else
    FStatus.SimpleText := Format(rsStatusSearchFmt, [Length(Listing)]);
  FCompletionMsgSet := True;
end;

{ One archive of the conflict-aware batch pipeline: its entry list arrived. Resolve
  the destination conflicts for exactly those entries, then extract the ones the
  resolver kept. Nothing here touches FCtx or the visible listing: the run has its
  own state. }
function TMainForm.HandleJobBatchList(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  Idx, I, N, Collisions: Integer;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
  Keep: TExtractEntryKeep;
  Listing: TListing;
  Plan: TSmartPlan;
  Choice: TExtractConflict;
  J: TZJob;
  P, Base: string;
begin
  Result := joContinue;
  if (FBatchRun = nil) or (AJob = nil) then Exit;
  Idx := FBatchRun.ActiveItem;
  if Idx < 0 then Exit;
  if AResult = TZ7Z_E_CANCEL then
  begin
    FBatchRun.NoteCancelled(Idx);
    if FBatchTally <> nil then
      FBatchTally.NoteResult(ExtractFileName(FBatchRun[Idx].Path),
        TZ7Z_E_CANCEL, '');
    FBatchNextPending := True;
    Exit;
  end;
  if AResult <> TZ7Z_OK then
  begin
    FBatchRun.NoteListingFailed(Idx, AError);
    if FBatchTally <> nil then
      FBatchTally.NoteResult(ExtractFileName(FBatchRun[Idx].Path),
        TZ7Z_E_EXTRACT, AError);
    FBatchNextPending := True;
    Exit;
  end;
  Listing := AJob.Listing;
  SetLength(Entries, Length(Listing));
  SetLength(Indices, Length(Listing));
  N := 0;
  for I := 0 to High(Listing) do
  begin
    if Listing[I].IsParent or (Listing[I].EntryIndex < 0) then Continue;
    Entries[N] := Default(TExtractEntry);
    Entries[N].Name := Listing[I].FullPath;
    Entries[N].IsDir := Listing[I].IsDir;
    Indices[N] := LongWord(Listing[I].EntryIndex);
    Inc(N);
  end;
  SetLength(Entries, N);
  SetLength(Indices, N);
  { The Finder smart service carries no conflict policy: ask once for this
    archive before anything is written. The dialog flow already answered it. }
  Choice := FBatchRun.Conflict;
  if (FBatchRun.Mode = bmSmart) and (Choice = ecAsk) then
  begin
    Base := FBatchDest;
    if Base = '' then Base := ExtractFileDir(FBatchRun[Idx].Path);
    Plan := TzSmartPlan(FBatchRun[Idx].Path, Base, Entries);
    Collisions := 0;
    if Plan.Layout <> slNothing then
      Collisions := ResolveExtractConflicts(Plan.Dest,
        TzSmartTargetEntries(Plan, Entries), ecSkip, Keep);
    if Collisions > 0 then
    begin
      Choice := ShowSmartConflictDialog(Self,
        ExtractFileName(FBatchRun[Idx].Path), Plan.Dest);
      if Choice = ecAsk then
      begin
        { Cancel means: stop the batch. The archive in flight was never started. }
        FBatchRun.NoteCancelled(Idx);
        if FBatchTally <> nil then
          FBatchTally.NoteResult(ExtractFileName(FBatchRun[Idx].Path),
            TZ7Z_E_CANCEL, '');
        FBatchNextPending := True;
        Exit;
      end;
    end
    else
      { Nothing collides, so the policy does not matter. }
      Choice := ecSkip;
  end;
  { Ticket 04's entry-level rules, applied against this archive's landing place. }
  if not FBatchRun.Resolve(Idx, Entries, Indices, Choice) then
  begin
    { Everything collided and the policy skipped it: nothing to write. }
    FBatchNextPending := True;
    Exit;
  end;
  P := FBatchRun[Idx].Path;
  if FBatchRun.Mode = bmSmart then
    J := TzNewSmartExtractJob(P, ExtractFileName(P),
      RememberedPassword(TzPasswordStore, P), FBatchRun[Idx].Dest,
      FBatchRun[Idx].Root, FBatchRun.CurrentIndices)
  else
    J := TzNewExtractJob(P, ExtractFileName(P),
      RememberedPassword(TzPasswordStore, P), FBatchRun[Idx].Dest,
      FBatchRun.CurrentIndices);
  { A different job starts here, so this one is finished before the shared tail
    could see it again. }
  AJob.Free;
  StartJob(J, jpBatchStage, rsBusyExtracting, J.DisplayName, True, True);
  Result := joDone;
end;

{ One archive's extraction finished: count it, honour the per-archive delete, and
  let the shared tail continue the pipeline. }
function TMainForm.HandleJobBatchStage(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  Idx: Integer;
begin
  Result := joContinue;
  if FBatchRun = nil then Exit;
  Idx := FBatchRun.ActiveItem;
  if Idx < 0 then Exit;
  if AResult = TZ7Z_E_CANCEL then
  begin
    FBatchRun.NoteCancelled(Idx);
    if FBatchTally <> nil then
      FBatchTally.NoteResult(ExtractFileName(FBatchRun[Idx].Path),
        TZ7Z_E_CANCEL, '');
    FBatchNextPending := True;
    Exit;
  end;
  FBatchRun.NoteExtracted(Idx, AResult, AError);
  if FBatchTally <> nil then
    FBatchTally.NoteResult(ExtractFileName(FBatchRun[Idx].Path), AResult, AError);
  { Only that archive, and only after it succeeded: a failed extraction must never
    cost the user the archive. }
  if (AResult = TZ7Z_OK) and FBatchDeleteAfter then
    DeleteArchiveAfterExtract(AJob.Path);
  FBatchNextPending := True;
end;

{ Keep the rows whose name contains the current name filter, exactly as the folder
  listing does. Empty filter keeps everything. }
function TMainForm.FilterListingByName(const AListing: TListing;
  const AFilter: string): TListing;
var
  I, N: Integer;
  Needle: string;
begin
  if AFilter = '' then
    Exit(AListing);
  Needle := LowerCase(AFilter);
  SetLength(Result, Length(AListing));
  N := 0;
  for I := 0 to High(AListing) do
    if Pos(Needle, LowerCase(AListing[I].Name)) > 0 then
    begin
      Result[N] := AListing[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

procedure TMainForm.CancelSearchJob;
begin
  if (FJob <> nil) and (FJobPurpose = jpSearch) then
    FJob.RequestCancel;
end;

function TMainForm.HandleJobOpenExtractHere(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  Ctx: TArchiveContext;
  Fresh: TZJob;
  Indices: TLongWordArray;
  SrcPath: string;
  NameCp: LongWord;
begin
  Result := joContinue;
  if AResult <> TZ7Z_OK then
  begin
    if AResult <> TZ7Z_E_CANCEL then
      ShowError(rsErrCannotOpenArchive + LineEnding + AError);
    Exit;
  end;
  Ctx := AJob.Ctx;
  AJob.Ctx := nil;          { claimed }
  if Ctx = nil then Exit;
  SrcPath := Ctx.SourcePath;
  NameCp := Ctx.NameCodepage;
  Indices := TzAllIndices(Ctx);
  Ctx.Free;
  if Length(Indices) = 0 then Exit;
  { A different job starts here, so this one is done before the shared tail could
    see it again. }
  AJob.Free;
  Fresh := TZJob.Create(jkExtract);
  Fresh.Path := SrcPath;
  Fresh.Password := AJob.Password;
  Fresh.Dest := AJob.Dest;
  Fresh.Indices := Indices;
  Fresh.NameCodepage := NameCp;
  StartJob(Fresh, jpExtract, rsDlgExtracting, ExtractFileName(SrcPath), True, True);
  UpdateStatus;
  Result := joDone;
end;

function TMainForm.HandleJobOpen(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  Ctx: TArchiveContext;
  Inner: string;
begin
  Result := joContinue;
  if AResult <> TZ7Z_OK then
  begin
    if AResult <> TZ7Z_E_CANCEL then
    begin
      if APurpose = jpOpenAfterModify then
        ShowError(rsErrReopenFailed + LineEnding + AError)
      else
        ShowError(rsErrCannotOpenArchive + LineEnding + AError);
    end;
    { A launch that skipped the folder view has nothing to show when the archive
      cannot be opened: land on home instead of an empty window. }
    if (FFsList <> nil) and (FFsList.Directory = '') then
      NavigateFs(GetUserDir);
    Exit;
  end;
  Ctx := AJob.Ctx;
  AJob.Ctx := nil;          { claimed }
  { A success with no context should be impossible, but every other open branch
    checks before dereferencing and this one used to assume it, so one broken
    worker result became an access violation in the timer. }
  if Ctx = nil then
  begin
    ShowError(rsErrCannotOpenArchive);
    Exit;
  end;
  if AJob.IsNested then Ctx.TemporarySource := True;
  { Remember only what the user can open again: a top-level archive file, not a
    nested context or a temporary unwrapped stream. }
  if (Ctx.Parent = nil) and (not Ctx.TemporarySource) and
     FileExists(Ctx.SourcePath) then
    RememberRecentArchive(Ctx.SourcePath);
  Inner := AJob.InnerPath;
  if (Inner <> '') and (not ArchiveDirExists(Ctx, Inner)) then
  begin
    ShowError(Format(rsErrFolderNotFoundFmt, [Inner]));
    Inner := '';
  end;
  if APurpose = jpOpenAfterModify then
    SetArchiveContext(Ctx, Inner, False)
  else
    SetArchiveContext(Ctx, Inner, FOpenAddHistory);
end;

function TMainForm.HandleJobOpenConvert(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  Ctx: TArchiveContext;
begin
  Result := joContinue;
  if AResult <> TZ7Z_OK then
  begin
    if AResult <> TZ7Z_E_CANCEL then
      ShowError(rsErrCannotOpenArchive + LineEnding + AError);
    Exit;
  end;
  Ctx := AJob.Ctx;
  AJob.Ctx := nil;          { claimed }
  if Ctx = nil then Exit;
  { Show it first, so the user ends up looking at the archive they just converted.
    The conversion itself is started from here rather than through
    DoConvertArchive: this runs inside a completion, where FJob is still set, and
    DoConvertArchive bails out when it is. }
  SetArchiveContext(Ctx, '', False);
  StartConvertForOpenArchive;
end;

function TMainForm.HandleJobExtract(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  LeaveDir: string;
  OpenAfter, DeleteAfter: Boolean;
begin
  Result := joContinue;
  { The two "after" choices belong to THIS job. Read them here and clear them
    immediately: a failed or cancelled extraction used to leave them set, and the
    next successful extraction then deleted the archive (or opened the
    destination) because of a choice made for another operation. }
  OpenAfter := FExtractOpenAfter;
  DeleteAfter := FExtractDeleteAfter;
  FExtractOpenAfter := False;
  FExtractDeleteAfter := False;
  if AResult = TZ7Z_OK then
  begin
    if FCtx <> nil then FCtx.Password := AJob.Password;
    { A successful extraction is proof the password was right, which is a better
      moment to remember it than the open: opening an archive only reads its
      header, and a header can be unencrypted while the entries are not. }
    if (AJob.Password <> '') and (FCtx <> nil) and (not FCtx.IsNested) then
      RememberPassword(TzPasswordStore, FCtx.SourcePath, AJob.Password);
    FStatus.SimpleText := Format(rsStatusExtractedFmt,
      [Length(AJob.Indices), AJob.Dest]);
    FCompletionMsgSet := True;
    { Only after the extraction actually succeeded, and only when the user asked:
      a failed job must never cost them the archive. }
    if DeleteAfter then
    begin
      { Leave the archive BEFORE deleting it: Close Archive does the same, and a
        listing that still points at a removed file would fail every later browse
        (and keep the breadcrumb on a path that is gone). }
      if (FCtx <> nil) and (not FCtx.IsNested) and
         SameText(FCtx.SourcePath, AJob.Path) then
      begin
        LeaveDir := ExcludeTrailingPathDelimiter(FCtx.OpenedFromFs);
        if LeaveDir = '' then LeaveDir := ExtractFileDir(AJob.Path);
        NavigateFs(LeaveDir);
      end;
      { The deletion is best effort, but the failure has to be reported: silently
        keeping the archive leaves the user believing it is gone. }
      if not DeleteArchiveAfterExtract(AJob.Path) then
        ShowError(Format(rsErrDeleteArchiveFmt, [ExtractFileName(AJob.Path)]));
    end;
    if OpenAfter then OpenDocument(AJob.Dest);
  end
  else if AResult = TZ7Z_E_CANCEL then
  begin
    { Without this the status line was immediately replaced by the archive
      summary, so a cancelled extraction looked like it had succeeded. }
    FStatus.SimpleText := rsStatusCancelled;
    FCompletionMsgSet := True;
  end
  else
    ShowError(rsErrExtractionFailed + LineEnding + AError);
end;

function TMainForm.HandleJobConvert(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
begin
  Result := joContinue;
  if AResult = TZ7Z_OK then
  begin
    if FModifyMessage <> '' then
      FStatus.SimpleText := FModifyMessage
    else
      FStatus.SimpleText := Format(rsStatusConvertedFmt,
        [ExtractFileName(AJob.Dest)]);
    FCompletionMsgSet := True;
    { Land on the new archive rather than leaving the user looking at the old one
      and wondering whether it worked. }
    { Reveal the new file in the file manager rather than only opening its
      folder: a conversion's whole point is that new file. }
    if FileExists(AJob.Dest) then
      TzRevealFile(AJob.Dest);
  end
  else if AResult = TZ7Z_E_CANCEL then
  begin
    FStatus.SimpleText := rsStatusCancelled;
    FCompletionMsgSet := True;
  end
  else
    ShowError(rsErrConvertFailed + LineEnding + AError);
end;

function TMainForm.HandleJobTest(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
begin
  Result := joContinue;
  if AResult = TZ7Z_OK then
  begin
    FStatus.SimpleText := Format(rsInfoTestDoneFmt, [Length(AJob.Indices)]);
    FCompletionMsgSet := True;
    TyMessageDlg(FStatus.SimpleText, mtInformation, [mbOK]);
  end
  else if AResult = TZ7Z_E_CANCEL then
  begin
    FStatus.SimpleText := rsStatusCancelled;
    FCompletionMsgSet := True;
  end
  else
    ShowError(rsErrArchiveDamagedOrWrongPassword + LineEnding + AError);
end;

function TMainForm.HandleJobCreate(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
var
  SrcPath: string;
begin
  Result := joContinue;
  if AResult = TZ7Z_OK then
  begin
    FSettings.LastArchiveFormat := AJob.Settings.FormatName;
    SaveSettings;
    if AJob.Settings.DeleteSources then
      DeleteCreatedSources(AJob);
    if FMode = nkFiles then FFsList.UpdateView;
    FStatus.SimpleText := Format(rsStatusCreatedFmt,
      [ExtractFileName(AJob.Path)]);
    FCompletionMsgSet := True;
    { Creating always offers the new archive: this was a field that was only ever
      set to True, so the condition was always true (and a batch created one
      reopen job per archive). }
    if TzIsArchiveName(AJob.Path) then
    begin
      SrcPath := AJob.Path;
      if (AJob.Settings.VolumeSize > 0) and FileExists(SrcPath + '.001') then
        SrcPath := SrcPath + '.001';
      if FileExists(SrcPath) then
      begin
        FLastOpenPassword := AJob.Settings.Password;
        StartOpenArchive(SrcPath, ExtractFileName(AJob.Path), nil, False,
          FFsPath, False, jpOpenBrowse, '');
      end;
    end;
  end
  else if AResult = TZ7Z_E_CANCEL then
  begin
    FStatus.SimpleText := rsStatusCancelled;
    FCompletionMsgSet := True;
  end
  else
    ShowError(rsErrCreateFailed + LineEnding + AError);
end;

function TMainForm.HandleJobModify(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
begin
  Result := joContinue;
  if AResult = TZ7Z_OK then
  begin
    if FModifyMessage <> '' then
      FStatus.SimpleText := FModifyMessage
    else
      FStatus.SimpleText := rsStatusUpdated;
    FCompletionMsgSet := True;
    FModifyMessage := '';
    { The archive on disk changed, so the open context is stale: reopen it from
      the file (also refreshes the sidebar tree).

      A top-level archive has no parent; passing the CURRENT context made the new
      one its own parent, which showed "photo.7z > photo.7z" in the breadcrumb and
      made Up return to a stale handle of the same file. The parent of a nested
      archive is the context that holds the outer one. }
    if (FCtx <> nil) and FCtx.IsNested then
      StartOpenArchive(AJob.Path, AJob.DisplayName, FCtx.Parent, True, '',
        False, jpOpenAfterModify, FInnerPath)
    else
      StartOpenArchive(AJob.Path, AJob.DisplayName, nil, False, '',
        False, jpOpenAfterModify, FInnerPath);
  end
  else if AResult = TZ7Z_E_CANCEL then
  begin
    FStatus.SimpleText := rsStatusCancelled;
    FCompletionMsgSet := True;
  end
  else
    ShowError(rsErrUpdateFailed + LineEnding + AError);
end;

function TMainForm.HandleJobExtractOne(AJob: TZJob; APurpose: TZJobPurpose;
  AResult: Integer; const AError: string): TJobHandlerOutcome;
begin
  Result := joContinue;
  if AResult <> TZ7Z_OK then
  begin
    if AResult <> TZ7Z_E_CANCEL then
    begin
      { After the one automatic password retry, a data error on an encrypted
        entry still means "wrong password" is a possibility 7-Zip cannot rule
        out, so say that instead of leaving the user with "data error" alone. }
      if (AResult = TZ7Z_E_EXTRACT) and FExtractOneEncrypted and
         (AJob.Password <> '') then
        ShowError(rsErrArchiveDamagedOrWrongPassword + LineEnding + AError)
      else
        ShowError(rsErrCannotExtractNested + LineEnding + AError);
    end;
    Exit;
  end;
  if APurpose = jpExtractOneOpen then
  begin
    OpenPathExternally(AJob.OutFile);
    { Watching for a change is cheap and only matters for a file that was
      actually handed to another application. Nested archives are opened inside
      TyZip and never need writing back. }
    FEditSession := StartEditSession(AJob.Path, FExtractOneName, AJob.OutFile,
      Now);
  end
  else
    StartOpenArchive(AJob.OutFile, FExtractOneName, FCtx, True, '',
      True, jpOpenBrowse, '');
end;

procedure TMainForm.UpdateStatus;
var
  N, Sel: Integer;
begin
  if not FReady then Exit;
  { A busy operation owns the status line; otherwise the intermediate repaint that
    LoadFsUi triggers while loading would overwrite "Loading folder ..." before the
    user can read it. EndBusy refreshes the real status when the work is done. }
  if FBusyCount > 0 then Exit;
  if FMode = nkArchive then
  begin
    N := Length(FListing) - 1;
    if N < 0 then N := 0;
    Sel := SelectedArchiveRows;
    FStatus.SimpleText := Format(rsStatusArchiveFmt,
      [FCtx.FormatName, N, Sel, TzFormatSize(FListTotalBytes), FCtx.DisplayName]);
    if FCtx.HasEncrypted then
      FStatus.SimpleText := FStatus.SimpleText + '  ·  ' + rsStatusEncrypted;
  end
  else
  begin
    N := Length(FFsList.Entries);
    Sel := FFsList.DataSelCount;
    FStatus.SimpleText := Format(rsStatusItemsFmt, [N, Sel, FFsPath]);
  end;
  RefreshActions;
end;

procedure TMainForm.RefreshActions;
var
  HasArc, HasSel, CanEdit: Boolean;
  Sel: Integer;
begin
  UpdateNameEncodingMenu;
  HasArc := (FMode = nkArchive) and (FCtx <> nil);
  Sel := 0;
  if FMode = nkArchive then Sel := SelectedArchiveRows else Sel := FFsList.DataSelCount;
  HasSel := Sel > 0;
  CanEdit := HasArc and FCtx.CanUpdate and HasSel and (FCtx.Parent = nil);
  { While a job owns 7-Zip, another command would only be refused: show that in
    the toolbar instead of letting the click do nothing. }
  if FJob <> nil then
  begin
    HasArc := False;
    CanEdit := False;
  end;
  { Creating an archive works from the filesystem view only: inside an archive
    there is no folder to create it in and no selection that means disk files.
    The action itself says so; the button shows it instead of failing on click. }
  if FNewBtn <> nil then FNewBtn.Enabled := (FMode <> nkArchive) and (FJob = nil)
    and (FFsList <> nil) and (FFsList.DataSelCount > 0);
  if FExtractBtn <> nil then FExtractBtn.Enabled := HasArc;
  if FTestBtn <> nil then FTestBtn.Enabled := HasArc;
  if FInfoBtn <> nil then FInfoBtn.Enabled := HasArc;
  { Convert only makes sense for an open archive that is not nested: a nested one
    has no file of its own to write to. }
  if FConvertBtn <> nil then
    FConvertBtn.Enabled := HasArc and (FCtx <> nil) and (not FCtx.IsNested);
  if FAddBtn <> nil then FAddBtn.Enabled := HasArc and FCtx.CanUpdate and (not FCtx.IsNested);
  if FDelBtn <> nil then FDelBtn.Enabled := CanEdit;
  if FBackBtn <> nil then FBackBtn.Enabled := FHistory.CanGoBack;
  if FForwardBtn <> nil then FForwardBtn.Enabled := FHistory.CanGoForward;
  if FUpBtn <> nil then FUpBtn.Enabled := (FMode = nkArchive) or ((FFsPath <> '') and (FFsPath <> '/'));
end;

{ ---------------------------------------------------------------------------
  Misc handlers (to be filled by the feature units)
  --------------------------------------------------------------------------- }

procedure TMainForm.FilterChange(Sender: TObject);
begin
  FFilterTyped := LowerCase(Trim(FFilterEdit.Text));
  if not FReady then Exit;
  if FMode = nkArchive then
  begin
    { Re-listing a huge archive takes hundreds of milliseconds; debounce so a
      burst of keystrokes costs one pass instead of one per character. }
    if FFilterTimer <> nil then
      RestartTimer(FFilterTimer)
    else
      RefreshFilter;
  end
  else if FFsPath <> '' then
  begin
    FFilter := FFilterTyped;
    FNavGuard := True;
    try FFsList.UpdateView; finally FNavGuard := False; end;
  end;
end;

procedure TMainForm.RefreshFilter;
begin
  FFilterTimer.Enabled := False;
  if FFilter = FFilterTyped then Exit;
  FFilter := FFilterTyped;
  if FReady and (FMode = nkArchive) then RefreshArchiveListing;
end;


procedure TMainForm.ShowError(const AMsg: string);
begin
  TyMessageDlg(AMsg, mtError, [mbOK]);
end;

procedure TMainForm.OpenPathExternally(const APath: string);
begin
  if TzOpenWithDefaultApp(APath) then Exit;
  { Nothing is registered for this type. Finder would put up its "choose an
    application" panel at this point, so do the same instead of only reporting
    that no application is associated. Backing out of that panel is a decision,
    not a failure. }
  if OpenWithPromptForApp(APath) <> caFailed then Exit;
  ShowError(rsErrNoAppForFile + LineEnding + APath);
end;

procedure TMainForm.OpenWithSpecificApp(const APath, AAppPath: string);
begin
  if TzOpenFileWithApp(APath, AAppPath) then Exit;
  ShowError(rsErrNoAppForFile + LineEnding + APath);
end;

{ Open APath in an application the user picks. Reports why nothing happened, so
  a cancelled panel is not mistaken for a missing association. }
function TMainForm.OpenWithPromptForApp(const APath: string): TZChooseAppResult;
var
  App: string;
begin
  Result := TzChooseAppForFile(APath, App);
  case Result of
    caChosen:
      if not TzOpenFileWithApp(APath, App) then
        Result := caFailed;
    caCancelled:
      Result := caCancelled;
  else
    Result := caFailed;
  end;
end;

{ Give AItem the icon of the application bundle at APath, if one is cached.

  Read from the PNG the prefetcher stores rather than asking NSWorkspace: the
  submenu is built while the popup is opening, and a synchronous query per entry
  would be felt. A bundle with no cached icon gets none. }

procedure TMainForm.OpenWithAppClick(Sender: TObject);
var
  P: string;
  I: Integer;
begin
  P := FsPopupPath;
  I := TMenuItem(Sender).Tag;
  if (P = '') or (FOpenWithPaths = nil) or (I < 0) or (I >= FOpenWithPaths.Count) then Exit;
  OpenWithSpecificApp(P, FOpenWithPaths[I]);
end;

procedure TMainForm.OpenWithOtherClick(Sender: TObject);
var
  P: string;
begin
  P := FsPopupPath;
  if P = '' then Exit;
  { Cancelling the panel is the user saying "never mind". Only a genuine failure
    raises "No application is associated with". }
  if OpenWithPromptForApp(P) = caFailed then
    ShowError(rsErrNoAppForFile + LineEnding + P);
end;

function TMainForm.FocusedControlKind: TNavFocusKind;
var
  C: TControl;
begin
  Result := nfOther;
  C := ActiveControl;
  if C = nil then Exit(nfNone);
  { The listings and the trees are where navigation shortcuts belong. }
  if (C = FFsList) or (C = FArcList) then Exit(nfListing);
  if (C = FFsTree) or (C = FArcNavTree) then Exit(nfTree);
  { Everything the user can type into. TTyEdit/TTyComboBox are custom-drawn and
    do NOT descend from TCustomEdit, so they are named here. }
  if (C = FFilterEdit) or (C = FPathEdit) or
     ((FPreviewPanel <> nil) and FPreviewPanel.IsTextInput(C)) then
    Exit(nfTextInput);
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  { These are list gestures. While the user types in the filter box, the path
    editor or a preview editor, the same keys belong to the text: Backspace used
    to trigger "up one folder" and Delete used to delete archive entries from
    inside the filter box, and Escape left the archive out of the path editor
    before PathEditKeyDown could see it. }
  if not NavigationShortcutAllowed(FocusedControlKind) then Exit;
  if (Key = VK_ESCAPE) and (FMode = nkArchive) and (Shift = []) then
  begin
    NavigateFs(FCtx.OpenedFromFs);
    Key := 0;
  end
  else if (Key = VK_DELETE) or (Key = VK_BACK) then
  begin
    if FMode = nkArchive then
    begin
      DoDeleteEntries;
      Key := 0;
    end;
  end
  else if Key = VK_RETURN then
  begin
    if FMode = nkArchive then
    begin
      if FArcList.ItemIndex >= 0 then ArcItemActivate(FArcList, FArcList.ItemIndex);
    end
    else if FFsList.ItemIndex = 0 then
      UpClick(nil)
    else if FFsList.ItemIndex > 0 then
      ActivateFsData(FFsList.ItemIndex - 1);
  end;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  { A search running at quit time is asked to stop: its result has nowhere to go
    and the destructor must not wait for a full archive walk. The batch pipeline
    stops the same way: no later archive starts. }
  CancelSearchJob;
  if FBatchRun <> nil then FBatchRun.RequestStop;
  { Do NOT delete the temp root here. It used to be removed while a preview
    extraction or an entry hand-off could still be writing into it, which made
    that worker fail on a file that had just disappeared. The destructor stops
    the workers first and deletes the root afterwards. }
  CanClose := True;
end;

{ Finder can hand over several files at once. This window shows the first one and
  every further file is opened by a NEW process, so a multi-selection becomes one
  window per archive instead of the last one overwriting the others. }
{ EXTERNAL OPEN -- the user asked TyZip, from outside, to open these files.

  The rules, per path:

   1. A folder, and nothing is open -> show it in this window.
   2. An archive -> its own window. This includes the ZIP-based documents
      (docx/xlsx/pptx/epub): asking for TyZip means the container is what should
      be shown, not a hand-off to whatever app owns .docx.
   3. A file TyZip cannot read -> say so. Staying on a folder view looks like the
      request was ignored.

  One behaviour overrides all of them: if THIS window already shows an archive,
  the files are offered as additions to it (rule 0), because replacing the archive
  the user is working on would be the destructive reading of the same gesture. }
procedure TMainForm.OpenFilesFromSystem(const APaths: array of string);
var
  I: Integer;
begin
  if Length(APaths) = 0 then Exit;
  if not FReady then Exit;
  TzMark('external open request');

  { An externally opened archive is something to SHOW. With an archive already
    open it gets a window of its own: replacing the current view is not what a
    Finder double click means, and adding it to the current archive (the old
    behaviour) is worse (tickets 44, 45). Only a plain non-archive file keeps the
    old "add it to the current archive" meaning (Open With TyZip on a text file);
    a folder still opens here. }
  case TzExternalOpenKind(APaths[0], (FMode = nkArchive) and (FCtx <> nil)) of
    eokAddToArchive:
      begin
        AddDroppedFiles(APaths);
        Exit;
      end;
    eokOpenInNewInstance:
      TzOpenInNewInstance(APaths[0]);
  else
    OpenOne(APaths[0]);
  end;
  { One instance per remaining file, spaced out: `open -n` forks and returns at
    once, and a burst of them races LaunchServices, which then starts the processes
    but drops their documents. The spacing used to be Sleep(1500) on the UI thread
    -- a frozen window per extra file; it is now one open per timer tick. }
  FPendingOpenPaths.Clear;
  for I := 1 to High(APaths) do
    FPendingOpenPaths.Add(APaths[I]);
  if (FPendingOpenPaths.Count > 0) and (FOpenOneTimer <> nil) then
    FOpenOneTimer.Enabled := True;
end;

procedure TMainForm.OpenNextInstanceTick(Sender: TObject);
begin
  if (FPendingOpenPaths = nil) or (FPendingOpenPaths.Count = 0) then
  begin
    if FOpenOneTimer <> nil then FOpenOneTimer.Enabled := False;
    Exit;
  end;
  TzOpenInNewInstance(FPendingOpenPaths[0]);
  FPendingOpenPaths.Delete(0);
  if FPendingOpenPaths.Count = 0 then
    FOpenOneTimer.Enabled := False;
end;

procedure TMainForm.ShowPendingBatchSummary(AData: PtrInt);
var
  Msg: string;
  Failed: Boolean;
begin
  { Queued from the job timer, so this runs after that callback returned and the
    message loop is its own again. }
  if not FReady then Exit;
  Msg := FPendingBatchSummary;
  Failed := FPendingBatchHadFailures;
  FPendingBatchSummary := '';
  FPendingBatchHadFailures := False;
  if Msg = '' then Exit;
  if Failed then
    TyMessageDlg(Msg, mtWarning, [mbOK])
  else
    TyMessageDlg(Msg, mtInformation, [mbOK]);
end;

procedure TMainForm.OpenOne(const APath: string);
var
  P: string;
begin
  P := ExpandFileName(APath);
  if DirectoryExists(P) then
  begin
    NavigateFs(P);
    Exit;
  end;
  if not FileExists(P) then
  begin
    ShowError(Format(rsErrFileNotFoundFmt, [ExtractFileName(P)]));
    Exit;
  end;
  if TzIsArchiveName(P) then
  begin
    StartOpenArchive(P, ExtractFileName(P), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False,
      jpOpenBrowse, '');
    Exit;
  end;
  ShowError(Format(rsErrUnsupportedFormatFmt, [ExtractFileName(P)]));
end;

procedure TMainForm.FocusFsList(AData: PtrInt);
begin
  if (not FReady) or (FMode <> nkFiles) or (FFsList = nil) then Exit;
  if not FFsList.Visible then Exit;
  try
    FFsList.SetFocus;
  except
    { focus is cosmetic; never let it break navigation }
  end;
end;

{ LCL keeps mouse capture on the control that received the button-down until it
  also receives the button-up.  A view switch that hides that control in the
  middle of a double click leaves the capture pointing at something that is no
  longer on screen, which kills hover for the whole window and eats the next
  click until the user clicks again.  If the capture belongs to a control that
  has meanwhile been hidden, drop it. }
procedure TMainForm.ReleaseStuckCapture;
var
  C: TControl;
begin
  C := GetCaptureControl;
  if (C = nil) or C.Visible then Exit;
  { SetCaptureControl(nil) already releases the widgetset capture. }
  SetCaptureControl(nil);
end;

{ A path handed to the program from outside -- argv, or a Finder "Open With" --
  becomes an archive view whenever it IS an archive, including the ZIP-based
  document types (docx/xlsx/pptx/epub). Ask for TyZip explicitly and you want
  TyZip's archive view; quietly handing the file to whatever the system associates
  with .docx is not that. Opening a document from INSIDE the file list still goes
  through IsArchiveForDefaultOpen, where "open the document" is the right call. }
procedure TMainForm.OpenStartupPath(const APath: string);
var
  P: string;
  C: TArchiveContext;
begin
  P := ExpandFileName(APath);
  if DirectoryExists(P) then
    NavigateFs(P)
  else if FileExists(P) then
  begin
    if FStartupAsArchive or TzIsArchiveName(P) then
      { Name the folder explicitly. An empty OpenedFromFs makes the engine fall
        back to FFsPath, which at this point is still whatever the window last
        browsed -- so a double-clicked archive in ~/Downloads produced a
        breadcrumb of MacOS > Users > tom with Downloads missing. }
      StartOpenArchive(P, ExtractFileName(P), nil, False,
        ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False,
        jpOpenBrowse, '')
    else
    begin
      { Opened with a file: show its folder and put the cursor on it, so its
        preview is already on screen. }
      NavigateFs(ExtractFileDir(P));
      SelectFsEntry(P);
    end;
  end;
end;

{ ONE handler, TWO meanings -- decided by what the window is showing:
   - inside an archive: the drop belongs to that archive, so the files are added
     to it (confirmed, with a replace/skip choice for name clashes);
   - in the file manager: the drop is a request to OPEN those paths, so the first
     opens here and the rest get their own processes. }
{ DRAG AND DROP -- always "bring these files into what is showing".

  This handler is reached ONLY by a real drag onto the window (the Apple Event
  path is taken below LCL by TzInstallExternalOpen, so a Finder "Open With" never
  lands here; that is the whole point of the split). Therefore:

   - inside an archive, the files belong to that archive and are added to it;
   - in the file manager, there is nothing to add to, and the sensible reading of
     a drop is "show me this": a folder navigates, an archive opens.

  Neither case ever closes the window or spawns a process behind the user's back. }
{ EXTERNAL OPEN -- the OS delivered files (Finder "Open With", a double click, an
  icon drop). The Cocoa widgetset funnels these through Application.IntfDropFiles
  and, immediately after, through the main form's IntfDropFiles; a real drag onto
  a window only ever reaches the FORM. So this handler is the discriminator: it
  records that the pair below belongs to an OPEN, and FormDropFiles consumes the
  mark instead of treating the same files as a drag. }
procedure TMainForm.AppDropFiles(Sender: TObject; const FileNames: array of string);
begin
  if Length(FileNames) = 0 then Exit;
  FExternalOpen := True;
  OpenFilesFromSystem(FileNames);
end;

procedure TMainForm.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
  P: string;
begin
  if Length(FileNames) = 0 then Exit;
  { Already handled as an external OPEN (see AppDropFiles). }
  if FExternalOpen then
  begin
    FExternalOpen := False;
    Exit;
  end;
  if (FMode = nkArchive) and (FCtx <> nil) then
  begin
    AddDroppedFiles(FileNames);
    Exit;
  end;
  { File-manager drop: take the FIRST path that makes sense, the way dropping
    onto a folder selects one thing. Folders navigate; archives open. }
  for I := Low(FileNames) to High(FileNames) do
  begin
    P := ExpandFileName(FileNames[I]);
    if DirectoryExists(P) then
    begin
      NavigateFs(P);
      Exit;
    end;
    if TzIsArchiveName(P) and FileExists(P) then
    begin
      PushBack;
      StartOpenArchive(P, ExtractFileName(P), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(P)), False,
        jpOpenBrowse, '');
      Exit;
    end;
  end;
end;


{ ---------------------------------------------------------------------------
  Feature commands
  --------------------------------------------------------------------------- }

procedure TMainForm.NewClick(Sender: TObject);
var
  P: TStringList;
begin
  if FMode = nkArchive then
  begin
    ShowError(rsErrArchiveOnlyInFiles);
    Exit;
  end;
  P := SelectedFsPaths;
  try
    if P.Count = 0 then
    begin
      ShowError(rsErrSelectFilesFirst);
      Exit;
    end;
    DoCreateFromPaths(P);
  finally
    P.Free;
  end;
end;

{ The create flow for an explicit set of paths, so the Finder service can drive
  it with what it was handed instead of what happens to be selected. }
{ Queue one job per archive: the generalisation of the single-archive operations.

  Each job carries its own inputs, so the queue only has to start them in turn:
  the first begins immediately and the rest wait. A selection that contains files
  which are not archives is accepted -- they are counted and reported rather than
  making the whole request fail. }
function TMainForm.BatchExtract(const APaths: TStrings; const ADest: string): Integer;
var
  I, N, Skipped: Integer;
  Dest: string;
  J: TZJob;
begin
  Result := 0;
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  Skipped := 0;
  N := 0;
  for I := 0 to APaths.Count - 1 do
  begin
    if not TzIsArchiveName(APaths[I]) then
    begin
      Inc(Skipped);
      Continue;
    end;
    Dest := ADest;
    if Dest = '' then
      Dest := ExcludeTrailingPathDelimiter(ExtractFileDir(APaths[I]));
    J := TzNewBatchExtractJob(APaths[I], Dest,
      RememberedPassword(TzPasswordStore, APaths[I]));
    Inc(N);
    StartJob(J, jpBatchExtract, rsBusyExtracting, J.DisplayName, True, True);
  end;
  if N = 0 then
    ShowError(rsErrNoArchivesSelected)
  else if Skipped > 0 then
    FStatus.SimpleText := TzBatchSkipStatus(Skipped);
  Result := N;
end;

{ Each archive into its own folder named after it, next to the archive.

  This is WinRAR's "Extract to <name>\": it keeps a folder of downloads from
  scattering a dozen loose files next to their archives. }
procedure TMainForm.BatchExtractToOwnFolders(const APaths: TStrings);
var
  I, N: Integer;
  Dest, Stem, P: string;
  J: TZJob;
begin
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  N := 0;
  for I := 0 to APaths.Count - 1 do
  begin
    P := APaths[I];
    if not TzIsArchiveName(P) then Continue;
    Dest := TzOwnFolderDest(P);
    J := TzNewBatchExtractJob(P, Dest, RememberedPassword(TzPasswordStore, P));
    Inc(N);
    StartJob(J, jpBatchExtract, rsBusyExtracting, J.DisplayName, True, True);
  end;
  if N = 0 then ShowError(rsErrNoArchivesSelected);
end;

procedure TMainForm.BatchTest(const APaths: TStrings);
var
  I, N: Integer;
  J: TZJob;
begin
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  N := 0;
  for I := 0 to APaths.Count - 1 do
  begin
    if not TzIsArchiveName(APaths[I]) then Continue;
    J := TzNewBatchTestJob(APaths[I], RememberedPassword(TzPasswordStore, APaths[I]));
    Inc(N);
    StartJob(J, jpBatchTest, rsBusyTesting, J.DisplayName, True, True);
  end;
  if N = 0 then ShowError(rsErrNoArchivesSelected);
end;

{ "Add to <name>.7z": create beside the first source with the default format,
  no dialog. }
{ The archive "Add to <name>.7z" would create for APath: beside it, named after
  it, in the default format. Shared by the menu caption and the action so the
  label cannot promise a different name from the one written. }
{ The format new archives are created in. `tzip.settings` has its own fallback
  for the settings it is given; this one is for the window's three create paths,
  which all used to spell it out. }
function TMainForm.DefaultArchiveFormat: string;
begin
  Result := FSettings.LastArchiveFormat;
  if Result = '' then Result := '7z';
end;

{ The synthetic ".." row is always first in an archive listing: at the top level it
  leaves the archive, inside it walks up one folder. Both listings built it by hand;
  they must agree field for field. }
procedure TMainForm.InitParentListingItem(var AItem: TListingItem);
begin
  AItem := Default(TListingItem);
  AItem.Name := '..';
  AItem.FullPath := '';
  AItem.IsDir := True;
  AItem.IsParent := True;
  AItem.EntryIndex := -1;
end;

{ A debounce/reveal timer restarted from now. Enabled := True on a timer that is
  already running does NOT restart its interval, so it has to be stopped first. }
procedure TMainForm.RestartTimer(ATimer: TTimer);
begin
  if ATimer = nil then Exit;
  ATimer.Enabled := False;
  ATimer.Enabled := True;
end;

function TMainForm.CreateHereTargetFor(const APath: string): string;
var
  Fmt: string;
begin
  Result := '';
  if APath = '' then Exit;
  Fmt := DefaultArchiveFormat;
  Result := IncludeTrailingPathDelimiter(
    ExcludeTrailingPathDelimiter(ExtractFileDir(APath))) +
    ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(APath)), '.' + Fmt);
end;

procedure TMainForm.DoCreateHere(APaths: TStrings);
var
  S: TCreateSettings;
  Sources: TStringList;
  Fmt, Target: string;
begin
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  Sources := TStringList.Create;
  try
    Sources.Assign(APaths);
    { The archive sits beside the first source and is named after it: one file
      gives "photo.7z", several give the first one's name. }
    Fmt := DefaultArchiveFormat;
    Target := CreateHereTargetFor(APaths[0]);
    { "Add to photo.7z" writes beside the source; if photo.7z is already there the
      create would silently replace it. Ask the same question the dialog path
      asks. }
    if not ConfirmReplaceTarget(Target) then Exit;
    DoCreateArchive(Sources, Target, TzCreateSettingsFor(Fmt));
  finally
    Sources.Free;
  end;
end;

{ "Add Each to a Separate Archive": one archive per selected file or folder,
  each next to its source. }
procedure TMainForm.DoCreateEachArchive(APaths: TStrings);
var
  I: Integer;
  S: TCreateSettings;
  One: TStringList;
  Fmt, Target: string;
begin
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  Fmt := DefaultArchiveFormat;
  S := TzCreateSettingsFor(Fmt);
  One := TStringList.Create;
  try
    for I := 0 to APaths.Count - 1 do
    begin
      One.Clear;
      One.Add(APaths[I]);
      Target := IncludeTrailingPathDelimiter(
        ExcludeTrailingPathDelimiter(ExtractFileDir(APaths[I]))) +
        ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(APaths[I])),
          '.' + Fmt);
      DoCreateArchive(One, Target, S);
    end;
  finally
    One.Free;
  end;
end;

{ Extract one or more archives, asking once for the destination. }
procedure TMainForm.ContinueBatch;
var
  Idx: Integer;
  J: TZJob;
  P: string;
begin
  if FBatchRun = nil then Exit;
  Idx := FBatchRun.StartNext;
  if Idx < 0 then
  begin
    { Nothing may start: the run finished, or it was stopped/cancelled and the
      archives left pending must not start behind the user's back. Either way the
      run is over, so its state and summary are released here. }
    FinishBatchRun;
    Exit;
  end;
  P := FBatchRun[Idx].Path;
  J := TZJob.Create(jkList);
  { A path-only list: no CtxRef and no SetEntries, so the executor opens the
    archive itself and the window's open archive is never touched. }
  J.Path := P;
  J.DisplayName := ExtractFileName(P);
  J.Password := RememberedPassword(TzPasswordStore, P);
  StartJob(J, jpBatchList, rsBusyReading, J.DisplayName, False, True);
end;

procedure TMainForm.FinishBatchRun;
var
  AnythingDone: Boolean;
  Summary: string;
  HadFailures: Boolean;
begin
  if FBatchRun = nil then Exit;
  AnythingDone := FBatchRun.DoneCount > 0;
  { One destination, after the last archive: opening it per archive would spawn a
    Finder window for every item in the batch. Nothing opens when nothing was
    extracted or the run was cancelled. }
  if FBatchOpenAfter and AnythingDone and (FBatchDest <> '') and
     DirectoryExists(FBatchDest) then
    OpenPathExternally(ExcludeTrailingPathDelimiter(FBatchDest));
  FStatus.SimpleText := Format(rsStatusBatchDoneFmt,
    [FBatchRun.DoneCount + FBatchRun.FailedCount + FBatchRun.CancelledCount]);
  if FBatchRun.SkippedEntryCount + FBatchRun.SkippedNonArchiveCount > 0 then
    FStatus.SimpleText := FStatus.SimpleText + ' ' +
      TzBatchSkipStatus(FBatchRun.SkippedEntryCount +
        FBatchRun.SkippedNonArchiveCount);
  { The per-archive failures and the summary come from this run's own tally: the
    shared batch summary would fire after every stage, because the job queue is
    empty between them. }
  if FBatchTally <> nil then
  begin
    Summary := FBatchTally.SummaryText;
    HadFailures := FBatchTally.BatchHadFailures;
    FreeAndNil(FBatchTally);
    if (Summary <> '') and (not FServiceMode) then
    begin
      FPendingBatchSummary := Summary;
      FPendingBatchHadFailures := HadFailures;
      Application.QueueAsyncCall(@ShowPendingBatchSummary, 0);
    end;
  end;
  FreeAndNil(FBatchRun);
  FBatchNextPending := False;
  FBatchDest := '';
  FBatchOpenAfter := False;
  FBatchDeleteAfter := False;
  UpdateStatus;
  MaybeFinishService;
end;

procedure TMainForm.StartExtractFrom(AArchives: TStrings);
var
  Dest, NewDest: string;
  O: TExtractOptions;
  Mode: TBatchMode;
begin
  if (AArchives = nil) or (AArchives.Count = 0) then Exit;
  if FBatchRun <> nil then
  begin
    { One batch at a time: a second click must not grow a parallel chain. }
    FStatus.SimpleText := rsBusyStillWorking;
    Exit;
  end;
  Dest := ExtractFallbackDir(AArchives[0]);
  if not ShowExtractDialog(Self, AArchives.Count, Dest, False, False, O) then
    Exit;
  NewDest := O.Destination;
  if NewDest = '' then NewDest := Dest;
  if NewDest = '' then Exit;
  { Conflicts are resolved per archive against the destination, so it has to exist
    first: the engine would create it, but then the resolver would see an empty
    folder and silently overwrite. }
  ForceDirectories(NewDest);
  FBatchDest := IncludeTrailingPathDelimiter(NewDest);
  FBatchOpenAfter := O.OpenAfter or FSettings.OpenAfterExtract;
  FBatchDeleteAfter := O.DeleteArchiveAfter;
  if O.SmartExtract then
    Mode := bmSmart
  else if O.SmartFolder then
    Mode := bmFolder
  else
    Mode := bmPlain;
  FreeAndNil(FBatchTally);
  FBatchTally := TJobController.Create;
  FBatchTally.BeginBatch;
  FBatchRun := TBatchRun.Create(AArchives, FBatchDest, O.Conflict, Mode);
  if FBatchRun.Count = FBatchRun.SkippedNonArchiveCount then
  begin
    FreeAndNil(FBatchRun);
    FreeAndNil(FBatchTally);
    FBatchDest := '';
    ShowError(rsErrNoArchivesSelected);
    Exit;
  end;
  ContinueBatch;
end;

{ Finder's one-click smart extraction: no dialog, no destination, no delete and
  no open after -- each archive lands next to itself, laid out by its structure.
  The only question asked is what to do about files that already exist. }
procedure TMainForm.StartSmartExtract(AArchives: TStrings);
var
  Run: TBatchRun;
begin
  if (AArchives = nil) or (AArchives.Count = 0) then Exit;
  if FBatchRun <> nil then
  begin
    { One batch at a time, same rule as the dialog path. }
    FStatus.SimpleText := rsBusyStillWorking;
    Exit;
  end;
  FBatchDest := '';
  FBatchOpenAfter := False;
  FBatchDeleteAfter := False;
  FreeAndNil(FBatchTally);
  FBatchTally := TJobController.Create;
  FBatchTally.BeginBatch;
  Run := TBatchRun.Create(AArchives, '', ecAsk, bmSmart);
  FBatchRun := Run;
  if Run.Count = Run.SkippedNonArchiveCount then
  begin
    FreeAndNil(FBatchRun);
    FreeAndNil(FBatchTally);
    ShowError(rsErrNoArchivesSelected);
    Exit;
  end;
  ContinueBatch;
end;

{ True when the target may be written: nothing there, or the user agreed to
  replace it. Shared by the dialog flow and the one-click "Add to <name>.7z". }
function TMainForm.ConfirmReplaceTarget(const APath: string): Boolean;
begin
  Result := (APath = '') or (not FileExists(APath)) or
    (TyMessageDlg(Format(rsErrReplaceFmt, [ExtractFileName(APath)]),
      mtConfirmation, [mbYes, mbNo]) = mrYes);
end;

procedure TMainForm.DoCreateFromPaths(APaths: TStringList);
var
  DefaultPath, DefaultFormat: string;
  Path: string;
  S, Seed: TCreateSettings;
begin
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  if FMode = nkArchive then Exit;
  DefaultFormat := DefaultArchiveFormat;
  { Put the default archive next to the first selected item instead of wherever
    the window happens to be: a Finder service can arrive before the window has
    navigated anywhere, which made the default path land in "/" (ticket 36).
    The name comes from the selection, not just the first file: several files
    share their folder's name (ticket 42). }
  DefaultPath := IncludeTrailingPathDelimiter(
    ExtractFileDir(ExcludeTrailingPathDelimiter(APaths[0]))) +
    TzDefaultArchiveName(APaths, DefaultFormat, FFormats);
  Seed := Default(TCreateSettings);
  if not ShowNewArchiveDialog(Self, APaths.Count, DefaultPath, DefaultFormat,
    Path, S, Seed, False) then Exit;
  if not ConfirmReplaceTarget(Path) then Exit;
  DoCreateArchive(APaths, Path, S);
end;

{ Remove the files a create job was given, once the archive is known good.
  Directories are removed deepest-first and only when they end up empty, so a
  folder that picked up a new file meanwhile survives. }
procedure TMainForm.DeleteCreatedSources(AJob: TZJob);
var
  Failed: Integer;
  Errs: TStringList;
begin
  if (AJob = nil) or (AJob.Sources = nil) then Exit;
  { The work lives in tzip.engine so it can be tested without a window: it also
    removes folders the archive emptied. }
  Errs := TStringList.Create;
  try
    Failed := TzDeleteSources(AJob.Sources, Errs);
    if Failed > 0 then
      FStatus.SimpleText := Format(rsStatusDeleteSomeFailedFmt, [Failed]);
  finally
    Errs.Free;
  end;
end;

procedure TMainForm.DoCreateArchive(const ASources: TStringList; const APath: string;
  const ASettings: TCreateSettings);
var
  J: TZJob;
begin
  { No "already busy" check here: StartJob queues, which is what lets the
    Services menu's "Add Each to a Separate Archive" build several archives in a
    row instead of only the first. }
  if ASources.Count = 0 then
  begin
    ShowError(rsErrNothingToCompress);
    Exit;
  end;
  { The recursive folder walk and the compression both live in the worker: on a
    big tree the walk alone freezes the window for seconds. }
  J := TZJob.Create(jkCreate);
  J.Path := APath;
  J.Settings := ASettings;
  J.Sources := TStringList.Create;
  J.Sources.Assign(ASources);
  J.ArcPrefix := '';
  StartJob(J, jpCreate, rsBusyCreating, ExtractFileName(APath), True, True);
end;

procedure TMainForm.OpenClick(Sender: TObject);
var
  D: TTyOpenDialog;
  C: TArchiveContext;
begin
  D := TTyOpenDialog.Create(Self);
  try
    D.Title := rsOpenArchiveTitle;
    D.Filter := rsArchiveFilter;
    D.InitialDir := FFsPath;
    { A plain launch (welcome screen's Browse Files…) has no folder yet. }
    if D.InitialDir = '' then D.InitialDir := GetUserDir;
    if not D.Execute then Exit;
    PushBack;
    StartOpenArchive(D.FileName, ExtractFileName(D.FileName), nil, False,
      ExcludeTrailingPathDelimiter(ExtractFileDir(D.FileName)), False,
      jpOpenBrowse, '');
  finally D.Free; end;
end;

{ File > Extract All: in the filesystem view this runs one extraction per
  selected archive; inside an archive it is the same as Extract. }
procedure TMainForm.MenuExtractAllClick(Sender: TObject);
var
  Paths: TStringList;
begin
  if FMode = nkArchive then
  begin
    DoExtract(False);
    Exit;
  end;
  Paths := SelectedFsPaths;
  try
    if CountArchivesIn(Paths) = 0 then
    begin
      ShowError(rsErrNoArchivesSelected);
      Exit;
    end;
    BatchExtractToOwnFolders(Paths);
  finally
    Paths.Free;
  end;
end;

procedure TMainForm.ExtractClick(Sender: TObject);
begin
  DoExtract(False);
end;

procedure TMainForm.TestClick(Sender: TObject);
begin
  DoTest;
end;

procedure TMainForm.AddClick(Sender: TObject);
begin
  DoAddFiles;
end;

procedure TMainForm.DeleteClick(Sender: TObject);
begin
  DoDeleteEntries;
end;

procedure TMainForm.InfoClick(Sender: TObject);
begin
  DoInfo;
end;

{ Where the Extract dialog starts: beside the archive itself. The configured
  default folder is only the fallback for an archive with no filesystem
  location (a nested archive opened from inside another archive) (ticket 38). }
function TMainForm.ExtractFallbackDir(const AArchivePath: string = ''): string;
var
  ArchiveDir: string;
begin
  { FCtx is nil when the extract flow starts from the FILE LIST (right-click an
    archive, Finder service); AArchivePath is the archive the caller selected,
    whose folder is what "beside the archive" means. }
  if AArchivePath <> '' then
    ArchiveDir := ExtractFileDir(ExcludeTrailingPathDelimiter(AArchivePath))
  else if FCtx <> nil then
    ArchiveDir := FCtx.OpenedFromFs
  else
    ArchiveDir := '';
  Result := ResolveDialogExtractDir(ArchiveDir, FSettings.DefaultExtractDir,
    GetUserDir);
end;

{ The entries AIndices names, in the order the indices give them. }
function TMainForm.ExtractEntryList(const AIndices: TLongWordArray): TExtractEntryArray;
var
  I, N: Integer;
begin
  Result := nil;
  if FCtx = nil then Exit;
  SetLength(Result, Length(AIndices));
  for I := 0 to High(AIndices) do
  begin
    Result[I].Name := '';
    Result[I].IsDir := False;
    N := AIndices[I];
    if (N >= 0) and (N < Length(FCtx.Entries)) then
    begin
      Result[I].Name := FCtx.Entries[N].Name;
      Result[I].IsDir := FCtx.Entries[N].IsDir;
    end;
  end;
end;

procedure TMainForm.DoExtract(AExtractAll: Boolean);
var
  Indices, Filtered: TLongWordArray;
  Entries: TExtractEntryArray;
  Keep: TExtractEntryKeep;
  Plan: TSmartPlan;
  O: TExtractOptions;
  Dest: string;
  Partial: Boolean;
  Cnt, I, N, Collisions: Integer;
  J: TZJob;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  if FJob <> nil then Exit;
  Partial := False;
  if AExtractAll then
    Indices := TzAllIndices(FCtx)
  else
  begin
    Indices := SelectedArchiveIndices(False);
    { A selection, not just the visible rows, is what makes this partial. }
    Partial := TzIsPartialExtraction(AExtractAll, Length(Indices));
    if not Partial then
      Indices := TzAllIndices(FCtx);
  end;
  if Length(Indices) = 0 then Exit;
  Cnt := Length(Indices);

  if not ShowExtractDialog(Self, Cnt, ExtractFallbackDir(FCtx.SourcePath),
    FCtx.HasEncrypted, Partial, O) then Exit;

  { A shortcut that named no folder means "next to the archive". }
  Dest := O.Destination;
  if Dest = '' then Dest := ExtractFallbackDir(FCtx.SourcePath);
  if Dest = '' then Exit;

  { The smart folder is resolved here, not in the dialog: only this side knows
    where the archive actually lives. Smart extraction resolves its own layout
    inside this same destination. }
  O.Destination := Dest;
  Dest := ResolveExtractDir(FCtx.SourcePath, O);
  if Dest = '' then Exit;

  if O.Password = '' then O.Password := FCtx.Password;
  FExtractOpenAfter := O.OpenAfter or FSettings.OpenAfterExtract;
  { Remembered for the completion handler: a failed extraction must not delete
    the archive. }
  FExtractDeleteAfter := O.DeleteArchiveAfter;

  Entries := ExtractEntryList(Indices);

  if O.SmartExtract then
  begin
    { The layout name must be the one the user sees: for a compound archive the
      context's SourcePath is a temporary unwrapped file (e.g. wrap_XXX.tar). }
    Plan := TzSmartPlan(FCtx.DisplayName, Dest, Entries);
    if Plan.Layout = slNothing then
    begin
      { Every entry was macOS junk or a directory: nothing to write, and no
        destination folder is created. }
      FStatus.SimpleText := rsStatusNoExtractableEntries;
      Exit;
    end;
    Dest := Plan.Dest;
    ForceDirectories(Dest);
    Entries := TzSmartTargetEntries(Plan, Entries);
  end
  else
    ForceDirectories(Dest);

  { The conflict policy is decided entry by entry, BEFORE the engine starts: it
    always overwrites and cannot stop to ask. "Skip" is expressed by not
    requesting those entries at all, and "rename" only moves aside the existing
    files those very entries would replace -- never anything else in the
    destination folder, which is usually the user's Downloads. }
  Collisions := ResolveExtractConflicts(Dest, Entries, O.Conflict, Keep);
  { Junk entries, directories and the stripped root have an empty target: they
    are never handed to the engine, whatever the conflict policy said. }
  if O.SmartExtract then
    TzSmartDropEmptyTargets(Entries, Keep);
  N := 0;
  SetLength(Filtered, Length(Indices));
  for I := 0 to High(Indices) do
    if (I > High(Keep)) or Keep[I] then
    begin
      Filtered[N] := Indices[I];
      Inc(N);
    end;
  SetLength(Filtered, N);
  if N = 0 then
  begin
    { Every selected entry already exists and the user asked to keep those. }
    if Collisions > 0 then FStatus.SimpleText := rsStatusNothingToExtract;
    Exit;
  end;
  Indices := Filtered;

  if O.SmartExtract then
    J := TzNewSmartExtractJob(FCtx.SourcePath, FCtx.DisplayName, O.Password,
      Dest, Plan.Root, Indices)
  else
    J := TzNewExtractJob(FCtx.SourcePath, FCtx.DisplayName, O.Password, Dest,
      Indices);
  J.NameCodepage := FCtx.NameCodepage;
  StartJob(J, jpExtract, rsBusyExtracting, FCtx.DisplayName, True, True);
end;

{ True while the listing shows search results rather than a folder. }
function TMainForm.SearchActive: Boolean;
begin
  Result := FSearchQuery <> '';
end;

procedure TMainForm.SearchClick(Sender: TObject);
var
  O: TSearchOptions;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  { A running search can be replaced by a new one; any other job owns the engine. }
  if (FJob <> nil) and (FJobPurpose <> jpSearch) then Exit;
  O := DefaultSearchOptions('');
  if not ShowSearchDialog(Self, O) then Exit;
  { The previous search is for the old query: stop it, and its completion will
    restart the listing with the new state (the result is discarded either way). }
  CancelSearchJob;
  FSearchQuery := O.Query;
  FSearchOptions := O;
  RefreshArchiveListing;
  { The match count is set when the worker's listing arrives: the synchronous
    count here would always be zero. }
end;

procedure TMainForm.ClearSearchClick(Sender: TObject);
begin
  if FSearchQuery = '' then Exit;
  CancelSearchJob;
  FSearchQuery := '';
  RefreshArchiveListing;
end;

{ Runs every time the app becomes active, which is when the user comes back from
  the editor. }
procedure TMainForm.AppActivate(Sender: TObject);
begin
  CheckEditWriteBack;
end;

procedure TMainForm.CheckEditWriteBack;
var
  Reason: string;
begin
  if FEditSession.TempPath = '' then Exit;
  if FCtx = nil then Exit;
  if FJob <> nil then Exit;
  { Not the same archive any more: the entry's path means nothing in this one. }
  if not SameText(FCtx.SourcePath, FEditSession.ArchivePath) then Exit;
  if not FileWasEdited(FEditSession, Reason) then Exit;

  if TyMessageDlg(Format(rsConfirmWriteBackFmt, [FEditSession.EntryPath]),
    mtConfirmation, [mbYes, mbNo]) = mrYes then
    WriteEditedEntryBack(FEditSession.EntryPath, FEditSession.TempPath);
  { Asked once per activation: a "no" must not bring the dialog back the next
    time the user clicks the window. }
  FEditSession := Default(TEditSession);
end;

{ Put the edited file back into the archive.

  This is the same extract-and-re-add shape as renaming: 7-Zip cannot replace an
  entry in place, so the archive is rewritten with the old entry removed and the
  edited file added under the same path. }
procedure TMainForm.WriteEditedEntryBack(const AEntryPath, ATempPath: string);
var
  I, Idx: Integer;
  S: TCreateSettings;
  J: TZJob;
begin
  if not CheckArchiveWritable then Exit;
  Idx := -1;
  for I := 0 to High(FCtx.Entries) do
    if SameText(FCtx.Entries[I].Name, AEntryPath) then
    begin
      Idx := FCtx.Entries[I].Index;
      Break;
    end;
  if Idx < 0 then Exit;
  StopPreview;
  FModifyMessage := Format(rsStatusWrittenBackFmt, [AEntryPath]);
  J := TzNewRenameJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
    ArchiveUpdateSettings,
    Idx, AEntryPath, AEntryPath);
  J.NameCodepage := FCtx.NameCodepage;
  StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
end;

{ Show the archive's own comment; read-only for a format that cannot store one. }
procedure TMainForm.ShowArchiveComment;
var
  Current, NewText: string;
  ReadOnly: Boolean;
begin
  if FCtx = nil then Exit;
  if FCtx.Archive <> nil then Current := FCtx.Archive.Comment else Current := '';
  { A nested archive and a format without update support are both read-only
    here, for the same reason the update actions are. }
  ReadOnly := FCtx.IsNested or (not FCtx.CanUpdate);
  if not ShowCommentDialog(Self, Current, ReadOnly, NewText) then Exit;
  if ReadOnly or (NewText = Current) then Exit;
  SaveArchiveComment(NewText);
end;

{ Rewrite the archive with the new comment. Nothing else changes: no entries are
  removed or added, so this is the same modify path with an empty delta. }
procedure TMainForm.SaveArchiveComment(const AComment: string);
var
  S: TCreateSettings;
  J: TZJob;
begin
  if not CheckArchiveWritable then Exit;
  StopPreview;
  FModifyMessage := rsStatusCommentSaved;
  J := TzNewModifyJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
    ArchiveUpdateSettings);
  J.NewComment := AComment;
  J.SetComment := True;
  J.NameCodepage := FCtx.NameCodepage;
  StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
end;

{ Convert the open archive to another format, next to the original. }
{ Convert an archive picked in the filesystem list.

  That archive is not open, and conversion needs its contents, so it is opened in
  the background first and jpOpenConvert takes over when the listing arrives. }
procedure TMainForm.BeginConvertFor(const APath: string);
var
  J: TZJob;
  C: TArchiveContext;
begin
  if (APath = '') or (not FileExists(APath)) then Exit;
  if not TzIsArchiveName(APath) then Exit;
  { Already the open archive: convert it directly. }
  if (FCtx <> nil) and (FMode = nkArchive) and SameText(FCtx.SourcePath, APath) then
  begin
    DoConvertArchive;
    Exit;
  end;
  C := nil;
  J := TZJob.Create(jkOpen);
  J.Path := APath;
  J.DisplayName := ExtractFileName(APath);
  J.Password := RememberedPassword(TzPasswordStore, APath);
  J.OpenedFromFs := FFsPath;
  StartJob(J, jpOpenConvert, rsBusyOpening, ExtractFileName(APath), True, True);
end;

{ The body of DoConvertArchive, for use when a job is already completing.
  Same prompts, same job; only the "is something running" guard is dropped. }
procedure TMainForm.StartConvertForOpenArchive;
begin
  DoConvertArchive(True);
end;

{ The format to offer first when converting FROM AFormat: the other common one,
  so the dialog does not open on "7z -> 7z". }
function TzDefaultConvertFormat(const AFormat: string): string;
begin
  if SameText(AFormat, '7z') then Result := 'zip' else Result := '7z';
end;

{ Convert the open archive to another format.

  The target and every compression setting come from the SAME dialog used to
  create an archive, so a conversion offers the formats and options it actually
  has. A one-line prompt for the file name (the first version) decided the format
  from whatever extension the user happened to type and forced level 5: neither
  was a choice the user made. }
procedure TMainForm.DoConvertArchive(AAllowBusy: Boolean);
var
  Target, DefaultTarget: string;
  S, Seed: TCreateSettings;
  J: TZJob;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  if (FJob <> nil) and (not AAllowBusy) then Exit;
  if FCtx.IsNested then
  begin
    ShowError(rsErrNestedReadOnly);
    Exit;
  end;

  { Default to a different format from the one being read: converting 7z to 7z
    is almost never what is meant, and the dialog lists formats the engine can
    actually write. }
  DefaultTarget := IncludeTrailingPathDelimiter(FCtx.OpenedFromFs) +
    ChangeFileExt(ExtractFileName(FCtx.SourcePath),
      '.' + TzDefaultConvertFormat(FCtx.FormatName));
  S := Default(TCreateSettings);
  S.FormatName := TzDefaultConvertFormat(FCtx.FormatName);
  S.Level := 5;
  { Carry the archive's own protection across: converting a password-protected
    archive should not silently produce an unprotected one. }
  S.Password := FCtx.Password;
  S.EncryptNames := FCtx.HasEncrypted;
  S.ForceUtf8 := True;

  { A separate seed: passing S as both the out settings and the const seed made
    the dialog read a record it was about to overwrite, which is undefined for a
    managed record. }
  Seed := S;
  if not ShowNewArchiveDialog(Self, Length(FCtx.Entries), DefaultTarget,
    TzDefaultConvertFormat(FCtx.FormatName), Target, S, Seed, True) then Exit;
  if Trim(Target) = '' then Exit;
  { Same FILE, not same name: converting /a/x.zip to /b/x.zip is legitimate. }
  if SameText(ExpandFileName(Target), ExpandFileName(FCtx.SourcePath)) then
  begin
    ShowError(rsErrConvertSameFile);
    Exit;
  end;
  if FileExists(Target) then
    if TyMessageDlg(Format(rsErrReplaceFmt, [ExtractFileName(Target)]),
      mtConfirmation, [mbYes, mbNo]) <> mrYes then Exit;
  if S.FormatName = '' then
  begin
    ShowError(rsErrNoConvertTarget);
    Exit;
  end;
  { A conversion always writes UTF-8 names: the entries have already survived one
    round trip through the filesystem. }
  S.ForceUtf8 := True;

  StopPreview;
  FModifyMessage := Format(rsStatusConvertedFmt, [ExtractFileName(Target)]);
  J := TZJob.Create(jkConvert);
  J.Path := FCtx.SourcePath;
  J.DisplayName := FCtx.DisplayName;
  J.Password := FCtx.Password;
  J.Settings := S;
  J.Dest := Target;
  J.NameCodepage := FCtx.NameCodepage;
  StartJob(J, jpConvert, rsBusyConverting, FCtx.DisplayName, True, True);
end;


procedure TMainForm.MenuConvertClick(Sender: TObject);
begin
  DoConvertArchive;
end;

{$IFDEF DARWIN}
{ The Services menu. Finder hands over the selected file URLs; each item does
  what its WinRAR/7-Zip counterpart does, and every one of them shows progress:
  even "Extract Here" runs through the same overlay, because a 2 GB archive
  would otherwise look like nothing happened. }
function TMainForm.HandleService(ARequest: TServiceRequest;
  APaths: TStrings): string;
var
  I: Integer;
  Paths, Archives: TStringList;
  First: string;
begin
  Result := '';
  if (APaths = nil) or (APaths.Count = 0) then Exit;
  { A cold "Open With" can arrive before the window is built: the handlers below
    assume lists and a context exist. Answer with no progress text instead of
    half-running a command. }
  if not FReady then Exit;

  { A tool service that arrives moments after launch has no user behind it: macOS
    started the app to run the service and would otherwise show the window first.
    Hide it and end the process when the run finishes. A TyZip the user already
    has open -- or one that has been up for a while -- is left untouched. "Open
    with TyZip" needs its window by definition. }
  if (ARequest <> srOpen) and (FCtx = nil) and
     (GetTickCount64 - FLaunchTick <= 15000) then
    FServiceMode := True;
  if FServiceMode then
  begin
    if Visible then Hide;
  end
  else
  begin
    if not Visible then Show;
    Application.BringToFront;
  end;

  Paths := TStringList.Create;
  Archives := TStringList.Create;
  try
    for I := 0 to APaths.Count - 1 do
      Paths.Add(APaths[I]);
    for I := 0 to Paths.Count - 1 do
      if TzIsArchiveName(Paths[I]) then Archives.Add(Paths[I]);

    case ARequest of
      srCompressDialog:
        begin
          DoCreateFromPaths(Paths);
          Result := Format(rsSvcCompressingFmt, [Paths.Count]);
        end;

      srCompressHere:
        begin
          DoCreateHere(Paths);
          Result := rsSvcCompressing;
        end;

      srCompressEach:
        begin
          DoCreateEachArchive(Paths);
          Result := Format(rsSvcCompressingFmt, [Paths.Count]);
        end;

      srOpen:
        begin
          { "Open with TyZip" is the archive-view action for any file, the same
            logic as "Open as Archive": a ZIP-based document or a self-extracting
            EXE is inspected through the unwrapping context. A TyZip that was
            already on screen opens a window of its own, the way opening a
            document twice does; a cold launch uses this window. Only the first
            selection opens: one window, one archive. }
          if Paths.Count > 0 then
          begin
            if (FCtx <> nil) or (GetTickCount64 - FLaunchTick > 15000) then
              TzOpenInNewInstanceAsArchive(Paths[0])
            else
              StartOpenArchive(Paths[0], ExtractFileName(Paths[0]), nil, False,
                ExcludeTrailingPathDelimiter(ExtractFileDir(Paths[0])), False,
                jpOpenBrowse, '');
            Result := rsSvcOpening;
          end;
        end;

      srExtractDialog, srExtractHere, srExtractToFolder, srSmartExtract:
        begin
          if Archives.Count = 0 then
          begin
            ShowError(rsErrNoArchivesSelected);
            Exit;
          end;
          First := Archives[0];
          case ARequest of
            srExtractDialog:
              begin
                { The dialog applies to one archive; a selection of several is
                  extracted one after another into the chosen folder. }
                StartExtractFrom(Archives);
                Result := Format(rsSvcExtractingFmt, [Archives.Count]);
              end;
            srExtractHere:
              begin
                BatchExtract(Archives, '');
                Result := rsSvcExtracting;
              end;
            srSmartExtract:
              begin
                { No dialog, no destination choice: the archive's own structure
                  decides the layout, and only a file collision asks anything. }
                StartSmartExtract(Archives);
                Result := rsSvcExtracting;
              end;
          else
            begin
              { "Extract to <name> Folder" creates one folder named after each
                archive beside it and extracts into that folder -- no picker:
                the menu item promises the same-name folder. }
              BatchExtractToOwnFolders(Archives);
              Result := rsSvcExtracting;
            end;
          end;
        end;
    else
      { An unknown service request: nothing to do, and nothing to say. }
      Result := '';
    end;
  finally
    Archives.Free;
    Paths.Free;
    { A dialog the user cancelled started no job: the one-shot service is over.
      When a job did start this sees FJob set and does nothing. }
    MaybeFinishService;
  end;
end;
{$ENDIF}

procedure TMainForm.DoTest;
var
  Indices: TLongWordArray;
  Cnt: Integer;
  J: TZJob;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  if FJob <> nil then Exit;
  Indices := SelectedArchiveIndices(False);
  if Length(Indices) = 0 then Indices := TzAllIndices(FCtx);
  if Length(Indices) = 0 then Exit;
  Cnt := Length(Indices);

  J := TzNewTestJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password, Indices);
  StartJob(J, jpTest, rsBusyTesting, FCtx.DisplayName, True, True);
end;

function TMainForm.CheckArchiveWritable: Boolean;
begin
  Result := False;
  if FCtx = nil then Exit;
  if FCtx.IsNested then
  begin
    ShowError(rsErrNestedReadOnly);
    Exit;
  end;
  if not FCtx.CanUpdate then
  begin
    ShowError(rsErrFormatNoUpdate);
    Exit;
  end;
  { Writing into one part of a split set rewrites only that file and leaves the
    remaining volumes pointing at bytes that are no longer where they were. There
    is no safe in-place update, so the operation is refused. }
  if TzIsSplitArchivePart(FCtx.SourcePath) then
  begin
    ShowError(rsErrSplitArchiveReadOnly);
    Exit;
  end;
  Result := True;
end;

{ A newline-separated preview of the first AMax entries, with a "… and N more"
  line when the list is longer. Shared by the two drop prompts. }
function ListPreview(AItems: TStrings; AMax: Integer; const AMoreFmt: string): string;
var
  I, N: Integer;
begin
  Result := '';
  N := AItems.Count;
  if N > AMax then N := AMax;
  for I := 0 to N - 1 do
  begin
    if I > 0 then Result := Result + #13#10;
    Result := Result + ExtractFileName(AItems[I]);
  end;
  if AItems.Count > AMax then
    Result := Result + #13#10 + Format(AMoreFmt, [AItems.Count - AMax]);
end;

function ListPreview(APaths: array of string; AMax: Integer;
  const AMoreFmt: string): string;
var
  L: TStringList;
  I, N: Integer;
begin
  L := TStringList.Create;
  try
    for I := Low(APaths) to High(APaths) do L.Add(APaths[I]);
    Result := ListPreview(L, AMax, AMoreFmt);
  finally
    L.Free;
  end;
end;

{ "Add these files to the archive?" -- one confirmation before anything is written. }
function TMainForm.ConfirmDropAdd(const AMsg: string): Boolean;
begin
  Result := TyMessageDlg(AMsg, mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

{ Both names already taken: replace them, or keep the archive's copies and add
  only the new files. Cancel aborts the whole drop. mrYes = replace, mrNo = skip. }
function TMainForm.AskDropConflict(const AMsg: string): TModalResult;
begin
  { Three answers need three buttons; TyMessageDlg maps them back to the standard
    set so the caller can switch on mrYes/mrNo/mrCancel. }
  Result := TyMessageDlg(AMsg, mtConfirmation, [mbYes, mbNo, mbCancel], 0);
end;

{ Files dropped onto an OPEN archive are added to it -- that is what dropping onto
  a window means. (Opening the dropped archive instead is what the old shared
  handler did, and it made "drag files into this archive" impossible.) The drop is
  confirmed first; when a name already exists the user chooses between replacing
  those entries and skipping them. }
procedure TMainForm.AddDroppedFiles(const APaths: array of string);
var
  Names: TStringList;       { archive path each dropped file will get }
  Conflicts: TStringList;   { the subset of Names that already exists }
  S: TCreateSettings;
  J: TZJob;
  I, K: Integer;
  Prefix, Body: string;
  Replacing: Boolean;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  if Length(APaths) = 0 then Exit;
  if not CheckArchiveWritable then Exit;
  if FJob <> nil then
  begin
    { A drop that cannot be acted on must say so: going quiet looks like the
      window ignored the drop. }
    FStatus.SimpleText := rsBusyStillWorking;
    Exit;
  end;

  { The archive path each dropped file will get: the folder currently shown,
    plus the file's own name. }
  Prefix := FInnerPath;
  Names := TStringList.Create;
  Conflicts := TStringList.Create;
  try
    for I := Low(APaths) to High(APaths) do
      { Exactly the archive path the engine will write (it appends the prefix with
        a separator too). Without the separator a drop into "docs" was checked as
        "docsfile.txt" and an existing entry of that name went unnoticed. }
      Names.Add(ArcChildPath(Prefix,
        ExtractFileName(ExcludeTrailingPathDelimiter(APaths[I]))));

    { Check against the archive's own entries, not the visible rows: a filter, a
      search or a collapsed folder can hide the entry this drop would replace, and
      the listing was exactly the wrong place to ask. }
    for I := 0 to Names.Count - 1 do
      for K := 0 to High(FCtx.Entries) do
        if SameText(FCtx.Entries[K].Name, Names[I]) then
        begin
          Conflicts.Add(Names[I]);
          Break;
        end;

    Body := ListPreview(APaths, 10, rsDropAddMoreFmt);
    if not ConfirmDropAdd(Format(rsDropAddConfirmFmt,
      [Length(APaths), FCtx.DisplayName, Body])) then Exit;

    Replacing := True;
    if Conflicts.Count > 0 then
    begin
      Body := ListPreview(Conflicts, 10, rsDropAddMoreFmt);
      case AskDropConflict(Format(rsDropConflictFmt, [Body])) of
        mrYes: Replacing := True;
        mrNo:  Replacing := False;
      else
        Exit;
      end;
    end;

    StopPreview;
    FModifyMessage := Format(rsStatusAddedFmt, [Length(APaths)]);
    J := TzNewModifyJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
      ArchiveUpdateSettings);
    J.NameCodepage := FCtx.NameCodepage;
    J.Sources := TStringList.Create;
    { Names[i] is exactly APaths[i]'s archive path (built in the first loop), so
      the two arrays stay parallel and no index arithmetic is needed. Skip means
      leave the existing entries alone but still add the genuinely new files. }
    for I := Low(APaths) to High(APaths) do
      if Replacing or (Conflicts.IndexOf(Names[I]) < 0) then
        J.Sources.Add(APaths[I]);
    if J.Sources.Count = 0 then
    begin
      J.Free;
      Exit;
    end;
    J.ArcPrefix := Prefix;
    StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
  finally
    Conflicts.Free;
    Names.Free;
  end;
end;

procedure TMainForm.DoAddFiles;
var
  D: TTyOpenDialog;
  Paths: TStringList;
  S: TCreateSettings;
  I: Integer;
  J: TZJob;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  if not CheckArchiveWritable then Exit;
  if FJob <> nil then Exit;
  D := TTyOpenDialog.Create(Self);
  Paths := TStringList.Create;
  try
    D.Title := rsAddFilesTitle;
    D.Options := [ofAllowMultiSelect, ofFileMustExist];
    D.Filter := rsAllFilesFilter;
    D.InitialDir := FFsPath;
    if not D.Execute then Exit;
    for I := 0 to D.Files.Count - 1 do Paths.Add(D.Files[I]);
    if Paths.Count = 0 then Exit;
    StopPreview;
    FModifyMessage := Format(rsStatusAddedFmt, [Paths.Count]);
    J := TzNewModifyJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
      ArchiveUpdateSettings, Paths);
    J.NameCodepage := FCtx.NameCodepage;
    J.ArcPrefix := FInnerPath;
    StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
  finally
    Paths.Free;
    D.Free;
  end;
end;

procedure TMainForm.DoAddFolder;
var
  D: string;
  Paths: TStringList;
  S: TCreateSettings;
  J: TZJob;
begin
  if (FCtx = nil) or (FMode <> nkArchive) then Exit;
  if not CheckArchiveWritable then Exit;
  if FJob <> nil then Exit;
  D := FFsPath;
  Paths := TStringList.Create;
  try
    if not TySelectDirectory(rsAddFolderTitle, '', D) then Exit;
    Paths.Add(D);
    StopPreview;
    FModifyMessage := rsStatusFolderAdded;
    J := TzNewModifyJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
      ArchiveUpdateSettings, Paths);
    J.NameCodepage := FCtx.NameCodepage;
    J.ArcPrefix := FInnerPath;
    StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
  finally
    Paths.Free;
  end;
end;

procedure TMainForm.DoDeleteEntries;
var
  Indices: TLongWordArray;
  S: TCreateSettings;
  J: TZJob;
begin
  if (FCtx = nil) then Exit;
  if not CheckArchiveWritable then Exit;
  if FJob <> nil then Exit;
  Indices := SelectedArchiveIndices(True);
  if Length(Indices) = 0 then
  begin
    ShowError(rsErrSelectDelete);
    Exit;
  end;
  if FSettings.ConfirmDelete then
    if TyMessageDlg(Format(rsConfirmDeleteFmt, [Length(Indices)]),
      mtConfirmation, [mbYes, mbNo]) <> mrYes then Exit;
  StopPreview;
  FModifyMessage := Format(rsStatusDeletedFmt, [Length(Indices)]);
  J := TzNewModifyJob(FCtx.SourcePath, FCtx.DisplayName, FCtx.Password,
    ArchiveUpdateSettings);
  J.NameCodepage := FCtx.NameCodepage;
  J.RemoveIndices := Indices;
  StartJob(J, jpModify, rsBusyUpdating, FCtx.DisplayName, True, True);
end;

procedure TMainForm.DoInfo;
begin
  if FCtx <> nil then ShowArchiveInfo(Self, FCtx);
end;

procedure TMainForm.ShowSettings;
var
  N: TAppSettings;
begin
  if not ShowSettingsDialog(Self, FSettings, FIconCacheDir, N) then Exit;
  N.DefaultExtractDir := ExcludeTrailingPathDelimiter(N.DefaultExtractDir);
  N.LastArchiveFormat := FSettings.LastArchiveFormat;
  FSettings := N;
  SaveSettings;
  ApplySettings;
end;

procedure TMainForm.ApplySettings;
begin
  if FSettings.ThemeName <> '' then
    TyDefaultController.ThemeName := FSettings.ThemeName;
  TyDefaultController.Mode := FSettings.Mode;
  { ThemeName/Mode notify registered controls, but TTyForm owns the title bar,
    surface and glass backdrop; it has to re-apply its chrome explicitly. }
  ApplyChromeTheme(TyDefaultController);
  ApplyPreviewTheme;
  if FFsList <> nil then
  begin
    FFsList.ShowHidden := FSettings.ShowHidden;
    FFsList.FoldersFirst := FSettings.FoldersFirst;
    if FFsTree <> nil then FFsTree.ShowHidden := FSettings.ShowHidden;
    if FShowHiddenMenu <> nil then FShowHiddenMenu.Checked := FSettings.ShowHidden;
    if FMode = nkFiles then FFsList.UpdateView;
  end;
  ApplySidebarVisibility;
  if FSidePanel <> nil then
  begin
    if FSettings.SidebarWidth < 160 then FSettings.SidebarWidth := 160;
    if FSettings.SidebarWidth > 600 then FSettings.SidebarWidth := 600;
    FSidePanel.Width := FSettings.SidebarWidth;
  end;
  if FPreviewPanel <> nil then
  begin
    if FSettings.PreviewWidth < 160 then FSettings.PreviewWidth := 160;
    if FSettings.PreviewWidth > 900 then FSettings.PreviewWidth := 900;
    FPreviewPanel.Width := FSettings.PreviewWidth;
  end;
  ApplyTabOrder;
  ApplyFlatContainers;
  ApplySplitterLook;
  ApplyPreviewVisibility;
  UpdateLanguageChecks;
  UpdateThemeChecks;
end;

procedure TMainForm.ApplySidebarVisibility;
begin
  if FSidePanel <> nil then FSidePanel.Visible := FSettings.ShowSidebar;
  if FSplitter <> nil then FSplitter.Visible := FSettings.ShowSidebar;
  if FSidebarMenu <> nil then FSidebarMenu.Checked := FSettings.ShowSidebar;
end;

procedure TMainForm.SideSplitterMoved(Sender: TObject);
begin
  if FSidePanel = nil then Exit;
  { In memory only: OnMoved fires on every pixel of a live drag, and an INI write
    per pixel would stutter. The width is persisted when the drag ends. }
  FSettings.SidebarWidth := FSidePanel.Width;
end;

procedure TMainForm.SideSplitterReleased(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if FSidePanel = nil then Exit;
  FSettings.SidebarWidth := FSidePanel.Width;
  SaveSettings;
end;

procedure TMainForm.PreviewSplitterMoved(Sender: TObject);
begin
  if FPreviewPanel = nil then Exit;
  FSettings.PreviewWidth := FPreviewPanel.Width;
end;

procedure TMainForm.PreviewSplitterReleased(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if FPreviewPanel = nil then Exit;
  FSettings.PreviewWidth := FPreviewPanel.Width;
  SaveSettings;
end;

{ Neither splitter draws a themed background in every theme (the default theme
  points TySplitter at the CHROME surface, while the default theme's panels use the
  CARD surface). The pane divider sits inside the content card, so it read as a
  white strip next to the sidebar's tinted one. Paint both from the panel surface
  instead: same token, same result in every theme, for both dividers. }
{ Flat, square containers. The content card, the sidebar and the preview pane are
  panes of one window, not floating cards: a rounded corner on each of them (plus
  the toolbar's) puts four curves into a layout made of straight edges, and at the
  window's own corners the radius is clipped by the frame anyway. The toolbar is a
  TTyToolBar, which has no radius rule of its own and inherits --radius. }
procedure TMainForm.ApplyFlatContainers;
const
  { Squares off a container AND drops the frame the theme gives it. The two
    entries: TyPanel and friends declare border-width from --input-border-width,
    so removing only the radius left a 1 px line around every pane -- it showed up
    along the preview pane's left and top edges as a stray rectangle. }
  Flat = 'border-radius: 0px; border: none;';
  { Rows are the busiest surface in this window, so they get a little more air
    than the theme default: the icon starts 10 px in, and 6 px separates it from
    the name. Both are per-control metrics (TyControls 3.0.4 tokens), so nothing
    else in the program is affected. }
  RowMetrics = '--listview-text-margin: 10px; --listview-icon-gap: 6px;';
  TreeMetrics = '--treeview-margin: 10px; --treeview-icon-gap: 6px;';
  { A sidebar is a step darker than the content it sits beside, the way every
    macOS source list is: without that, three white panes with two 5 px seams
    between them read as one plate cut in pieces rather than as a hierarchy. }
  Sidebar = 'border-radius: 0px; background: var(--surface-chrome);';
  { The preview pane has no divider of its own: the splitter beside it and the
    preview bar are enough, and a line there doubled the 5 px gap. }
  { Flush lists: the theme gives a list a border, a radius and 2 px of padding,
    which drew a white frame around the rows and pulled them off the panes'
    edges. The pane dividers above draw the only line this layout needs. }
  Bled = 'border-radius: 0px; border: none; padding: 0px;';
  { The margin token is the indent ahead of the first level; without it a
    ShowRoot=False tree starts at the very edge of its pane. 16 px reads as
    "inside the sidebar" rather than "clipped by it". }
  SideMetrics = '--treeview-margin: 16px; --treeview-icon-gap: 6px;';
begin
  if FToolBar <> nil then FToolBar.StyleOverride := Flat;
  { The one divider this layout keeps: it closes the chrome band. Without it the
    path bar and the panes below merge into a single white field. }
  { Order matters: the shorthand `border: none` in Flat resets every side, so the
    hairline has to come AFTER it in the same declaration (it does) and must be a
    side-specific longhand. Written as plain CSS here so the parser sees
    border-bottom last. }
  if FPathPanel <> nil then FPathPanel.StyleOverride := Flat +
    'border-bottom-width: 1px; border-bottom-style: solid; ' +
    'border-bottom-color: var(--border);';
  { The sidebar sits left of the content: its divider belongs on its right edge. }
  if FSidePanel <> nil then FSidePanel.StyleOverride := Sidebar +
    'border-right: 1px solid var(--border);';
  if FContent <> nil then FContent.StyleOverride := Flat;
  if FPreviewPanel <> nil then FPreviewPanel.StyleOverride := Flat;
  { The status bar closes the window: one line above it, square corners, and its
    own chrome background so it reads as a footer rather than a fourth pane. }
  if FStatus <> nil then FStatus.StyleOverride :=
    'border-radius: 0px; border: none; border-top: 1px solid var(--border);';
  if FFsList <> nil then FFsList.StyleOverride := Bled + RowMetrics;
  if FArcList <> nil then FArcList.StyleOverride := Bled + RowMetrics;
  { The sidebars are trees. They fill the panel, so their own background would
    cover the panel's tint: they are made transparent and the panel colour shows
    through. Their row metrics match the lists' so the rows line up. }
  if FFsTree <> nil then FFsTree.StyleOverride := SideMetrics + Bled +
    ' background: transparent;';
  if FArcNavTree <> nil then FArcNavTree.StyleOverride := SideMetrics + Bled +
    ' background: transparent;';
end;

procedure TMainForm.ApplySplitterLook;
begin
  { Both dividers take the theme's own TySplitter look. Every override tried here
    (transparent, border-coloured, a gradient hairline) made one of the two
    dividers differ from the other: a white 5 px strip beside a subtle grey band.
    With no override the two are the same control with the same style, which is
    what the eye expects in one window. }
  if FSplitter <> nil then FSplitter.StyleOverride := '';
  if FPreviewSplitter <> nil then FPreviewSplitter.StyleOverride := '';
end;

procedure TMainForm.ApplyPreviewVisibility;
begin
  if FPreviewPanel <> nil then FPreviewPanel.Visible := FSettings.ShowPreview;
  if FPreviewSplitter <> nil then FPreviewSplitter.Visible := FSettings.ShowPreview;
  if FPreviewMenu <> nil then FPreviewMenu.Checked := FSettings.ShowPreview;
  if FPreviewToggleBtn <> nil then
  begin
    if FSettings.ShowPreview then
    begin
      FPreviewToggleBtn.GlyphName := TyIconPanelRightClose;
      FPreviewToggleBtn.Hint := rsPreviewHideHint;
    end
    else
    begin
      FPreviewToggleBtn.GlyphName := TyIconPanelRightOpen;
      FPreviewToggleBtn.Hint := rsPreviewShowHint;
    end;
    FPreviewToggleBtn.Invalidate;
  end;
  if not FSettings.ShowPreview then
  begin
    CancelPreviewRequest;
    ClearPreview;
  end;
end;

procedure TMainForm.ApplyTheme(const ATheme: string);
begin
  if Trim(ATheme) = '' then Exit;
  FSettings.ThemeName := ATheme;
  TyDefaultController.ThemeName := ATheme;
  ApplyChromeTheme(TyDefaultController);
  ApplyPreviewTheme;
  UpdateThemeChecks;
  SaveSettings;
end;

procedure TMainForm.ApplyMode(const AMode: string);
begin
  FSettings.Mode := AMode;
  TyDefaultController.Mode := AMode;
  ApplyChromeTheme(TyDefaultController);
  ApplyPreviewTheme;
  UpdateThemeChecks;
  SaveSettings;
end;

procedure TMainForm.SaveSettings;
begin
  if FSettingsIni = '' then Exit;
  { Best effort by design: a read-only home must not turn a theme switch into a
    modal error, so a failed write keeps the in-memory copy. }
  SaveSettingsToFile(FSettingsIni, FSettings);
end;

procedure TMainForm.LoadSettings;
begin
  FSettings := LoadSettingsFromFile(FSettingsIni);
  ApplySettings;
end;

{ Menu dispatch }
procedure TMainForm.MenuCloseArchiveClick(Sender: TObject);
begin
  { Leaving the archive is what makes a running search meaningless; NavigateFs
    also clears the search state. }
  CancelSearchJob;
  if (FMode = nkArchive) and (FCtx <> nil) then NavigateFs(FCtx.OpenedFromFs);
end;
procedure TMainForm.MenuExitClick(Sender: TObject); begin Close; end;
procedure TMainForm.MenuSelectAllClick(Sender: TObject);
var I: Integer;
begin
  if FMode = nkArchive then
    FArcList.SelectAll
  else
  begin
    FFsList.Selected[0] := False;
    for I := 1 to Length(FFsList.Entries) do FFsList.Selected[I] := True;
  end;
  UpdateStatus;
end;
procedure TMainForm.MenuShowHiddenClick(Sender: TObject);
begin
  FSettings.ShowHidden := not FSettings.ShowHidden;
  FFsList.ShowHidden := FSettings.ShowHidden;
  FFsTree.ShowHidden := FSettings.ShowHidden;
  if FShowHiddenMenu <> nil then FShowHiddenMenu.Checked := FSettings.ShowHidden;
  SaveSettings;
  if FMode = nkFiles then FFsList.UpdateView;
end;

procedure TMainForm.MenuSidebarClick(Sender: TObject);
begin
  FSettings.ShowSidebar := not FSettings.ShowSidebar;
  ApplySidebarVisibility;
  SaveSettings;
end;

procedure TMainForm.MenuPreviewClick(Sender: TObject);
begin
  FSettings.ShowPreview := not FSettings.ShowPreview;
  ApplyPreviewVisibility;
  SaveSettings;
end;

procedure TMainForm.MenuLanguageClick(Sender: TObject);
begin
  if not (Sender is TMenuItem) then Exit;
  FSettings.Language := TMenuItem(Sender).Hint;
  SaveSettings;
  TyShowMessage(rsDlgLanguageRestart);
end;

{ A per-archive override: re-open the same archive with the chosen code page.
  The override belongs to this session only; closing or opening another archive
  goes back to the setting. }
procedure TMainForm.MenuNameEncodingClick(Sender: TObject);
var
  Id: string;
  Cp: LongWord;
begin
  if (FCtx = nil) or (FJob <> nil) then Exit;
  if FCtx.Parent <> nil then Exit;
  if not SameText(FCtx.FormatName, 'zip') then Exit;
  Id := '';
  if Sender is TMenuItem then Id := TMenuItem(Sender).Hint;
  if Id = '' then
  begin
    FNameEncodingOverride := '';
    Cp := 0;
  end
  else
  begin
    FNameEncodingOverride := TzNameEncodingById(Id).Id;
    Cp := TzNameEncodingById(FNameEncodingOverride).Codepage;
    { auto has no code page of its own: it means "follow the setting". }
    if Cp = 0 then FNameEncodingOverride := '';
  end;
  UpdateNameEncodingMenu;
  StartOpenArchive(FCtx.SourcePath, ExtractFileName(FCtx.SourcePath), nil, False,
    FCtx.OpenedFromFs, False, jpOpenAfterModify, FInnerPath, '', Cp);
end;

procedure TMainForm.UpdateNameEncodingMenu;
var
  I: Integer;
  It: TMenuItem;
  CanChange: Boolean;
begin
  if FNameEncodingMenu = nil then Exit;
  CanChange := (FMode = nkArchive) and (FCtx <> nil) and (FCtx.Parent = nil) and
    SameText(FCtx.FormatName, 'zip') and (FJob = nil);
  FNameEncodingMenu.Enabled := CanChange;
  for I := 0 to FNameEncodingMenu.Count - 1 do
  begin
    It := FNameEncodingMenu.Items[I];
    if It.Hint = '' then
      It.Checked := FNameEncodingOverride = ''
    else
      It.Checked := SameText(FNameEncodingOverride, It.Hint);
  end;
end;

procedure TMainForm.UpdateLanguageChecks;
var
  I: Integer;
begin
  if FLanguageMenu = nil then Exit;
  for I := 0 to FLanguageMenu.Count - 1 do
    FLanguageMenu.Items[I].Checked :=
      SameText(FLanguageMenu.Items[I].Hint, FSettings.Language);
end;

procedure TMainForm.BuildThemeMenus;
var
  Names: TStringArray;
  I: Integer;
  It: TMenuItem;

  procedure AddMode(const ACaption, AMode: string);
  var
    X: TMenuItem;
  begin
    X := TMenuItem.Create(Self);
    X.Caption := ACaption;
    X.Hint := AMode;
    X.OnClick := @MenuModeClick;
    FModeMenu.Add(X);
  end;

begin
  if FThemeMenu <> nil then
  begin
    FThemeMenu.Clear;
    Names := TyBuiltinThemeNames;
    for I := 0 to High(Names) do
    begin
      It := TMenuItem.Create(Self);
      It.Caption := Names[I];
      It.Hint := Names[I];
      It.OnClick := @MenuThemeClick;
      FThemeMenu.Add(It);
    end;
  end;
  if FModeMenu <> nil then
  begin
    FModeMenu.Clear;
    AddMode(rsDlgSystemDefault, '');
    AddMode(rsDlgLight, 'light');
    AddMode(rsDlgDark, 'dark');
  end;
end;

procedure TMainForm.UpdateThemeChecks;
var
  I: Integer;
begin
  if FThemeMenu <> nil then
    for I := 0 to FThemeMenu.Count - 1 do
      FThemeMenu.Items[I].Checked :=
        SameText(FThemeMenu.Items[I].Hint, FSettings.ThemeName);
  if FModeMenu <> nil then
    for I := 0 to FModeMenu.Count - 1 do
      FModeMenu.Items[I].Checked :=
        SameText(FModeMenu.Items[I].Hint, FSettings.Mode);
end;

procedure TMainForm.MenuThemeClick(Sender: TObject);
begin
  if Sender is TMenuItem then ApplyTheme(TMenuItem(Sender).Hint);
end;

procedure TMainForm.MenuModeClick(Sender: TObject);
begin
  if Sender is TMenuItem then ApplyMode(TMenuItem(Sender).Hint);
end;

procedure TMainForm.MenuSettingsClick(Sender: TObject); begin ShowSettings; end;
procedure TMainForm.MenuAboutClick(Sender: TObject);
begin
  { The version is read from the bundle at runtime; a plain development build
    shows 'dev'. }
  TyMessageDlg(Format(rsDlgAboutText, [TzAppVersion]), mtInformation, [mbOK]);
end;
procedure TMainForm.MenuAddFolderClick(Sender: TObject); begin DoAddFolder; end;



{ The test entry point for icons: see tzip.platform.TzSetIconProvider. Kept in the
  window's unit so a test harness only needs one import for "build the window with
  fake icons". }
procedure TzInstallTestIconProvider(AProvider: TZIconProvider);
begin
  TzSetIconProvider(AProvider);
end;

finalization
  { Second line of defence. Closing the window runs the form's destructor, which
    already deletes this directory; but a quit that bypasses it (a signal, or a
    framework-level termination) used to leave the whole session's unpacked files
    behind -- one such leftover was 244 MB. The directory is named after the PID,
    so it is unambiguous here even if the form never got to run its cleanup. }
  TzDeleteTempRoot('');

end.
