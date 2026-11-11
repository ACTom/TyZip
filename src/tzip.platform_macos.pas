unit tzip.platform_macos;

{ macOS-only system integration: NSWorkspace icons and default applications.
  This is the only TyZip unit that imports Cocoa; the rest of the program talks
  to tzip.platform. }

{$IFDEF DARWIN}
{$mode objfpc}{$H+}
{$modeswitch objectivec1}

interface

uses
  SysUtils, Classes, BGRABitmap, BGRABitmapTypes, tzip.platform;

function TzMacSystemIcon(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
function TzMacOpenWithDefaultApp(const APath: string): Boolean;
function TzMacRootVolumeName: string;
function TzMacPhysicalMemory: QWord;
{ CFBundleShortVersionString of the running bundle, 'dev' when this executable is
  not inside one. The About box is the only caller. }
function TzMacAppVersion: string;
{ Seconds since the last keyboard or mouse event anywhere in the session. The
  icon timers pause their NSWorkspace lookups while this is small. }
function TzMacSecondsSinceLastInput: Double;
{ True when TyZip is the frontmost application. }
function TzMacAppIsActive: Boolean;
{ PNG bytes of the bundle's own icon file. Pure Foundation + file I/O, so the
  application sweep can call it without touching AppKit or the main thread's
  icon services. False for legacy .icns / Assets.car bundles. }
function TzMacBundleIconPng(const AAppPath: string; AWantedPx: Integer;
  out APng: TBytes): Boolean;
{ Every application LaunchServices claims can open APath, best match first (the
  Finder default is always first when it exists).  This is the same list Finder's
  "Open With" submenu shows. }
function TzMacAppsForFile(const APath: string): TZOpenWithApps;
{ Open APath with one specific bundle. }
function TzMacOpenFileWith(const APath, AAppPath: string): Boolean;
{ Finder's "Other..." application chooser. AAppPath is only meaningful for
  caChosen; a cancelled panel is not an error. }
function TzMacChooseAppForFile(const APath: string;
  out AAppPath: string): TZChooseAppResult;

{ Reveal APath in Finder with the item selected. }
function TzMacRevealFile(const APath: string): Boolean;

{ Ask LaunchServices to open APath in a NEW instance of this very bundle. A
  multi-file "Open With" only ever reaches one running process through the Apple
  Event, so the remaining files are handed to fresh instances this way. }
function TzMacOpenInNewInstance(const APath: string): Boolean;

{ Same launch, with the argument that tells the new process to force the archive
  view for a file whose extension TyZip does not register. }
function TzMacOpenInNewInstanceAsArchive(const APath: string): Boolean;

implementation

uses
  CocoaAll, LCLIntf, Dialogs, Process, Unix, tzip.i18n, tzip.icns;

{ LaunchServices is not bound by CocoaAll and FPC ships no usable binding for
  this call, so the few CoreFoundation entry points needed are declared here.
  Note: FPC already prepends the Mach-O underscore, so the names are unprefixed. }

{$linkframework CoreServices}
{$linkframework CoreGraphics}
const
  kLSRolesAll = $FFFFFFFF;

type
  CFURLRef = Pointer;
  CFArrayRef = Pointer;

function LSCopyApplicationURLsForURL(AURL: CFURLRef; ARoleMask: Cardinal): CFArrayRef;
  cdecl; external name 'LSCopyApplicationURLsForURL';

{ CoreGraphics input clock. kCGEventSourceStateCombinedSessionState (0) and
  kCGAnyInputEventType ($FFFFFFFF) ask for "any event from any device". }
type
  CGEventSourceStateID = Integer;
  CGEventType = Cardinal;
function CGEventSourceSecondsSinceLastEventType(AStateID: CGEventSourceStateID;
  AEventType: CGEventType): Double; cdecl;
  external name 'CGEventSourceSecondsSinceLastEventType';
function CFURLCreateFromFileSystemRepresentation(alloc: Pointer; buf: PAnsiChar;
  bufLen: LongInt; isDir: Boolean): CFURLRef;
  cdecl; external name 'CFURLCreateFromFileSystemRepresentation';
function CFURLGetFileSystemRepresentation(AURL: CFURLRef; resolve: Boolean;
  buf: PAnsiChar; maxLen: LongInt): Boolean;
  cdecl; external name 'CFURLGetFileSystemRepresentation';
function CFArrayGetCount(AArray: CFArrayRef): LongInt;
  cdecl; external name 'CFArrayGetCount';
function CFArrayGetValueAtIndex(AArray: CFArrayRef; idx: LongInt): Pointer;
  cdecl; external name 'CFArrayGetValueAtIndex';
procedure CFRelease(ACF: Pointer); cdecl; external name 'CFRelease';

{ FPC's Unix unit does not declare sysctlbyname, and hw.memsize is the only
  way to ask for installed memory. }
function sysctlbyname(name: PAnsiChar; oldp: Pointer; oldlenp: Pointer;
  newp: Pointer; newlen: PtrUInt): LongInt; cdecl; external name 'sysctlbyname';

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PAnsiChar(UTF8String(S)));
end;

function NSStrValue(const S: NSString): string;
begin
  if S = nil then
    Result := ''
  else
    Result := string(AnsiString(PAnsiChar(S.UTF8String)));
end;

function TzMacAppsForFile(const APath: string): TZOpenWithApps;
const
  MaxApps = 24;
var
  Pool: NSAutoreleasePool;
  WS: NSWorkspace;
  FM: NSFileManager;
  Fn: AnsiString;
  URL: CFURLRef;
  Arr: CFArrayRef;
  Count, I: LongInt;
  Buf: array[0..4095] of AnsiChar;
  DefaultApp, Candidate, Nm: string;
  Seen: TStringList;

  procedure AddOne(const ABundlePath: string);
  var
    N: Integer;
  begin
    if (ABundlePath = '') or (Length(Result) >= MaxApps) then Exit;
    if LowerCase(ExtractFileExt(ABundlePath)) <> '.app' then Exit;
    if Seen.IndexOf(ABundlePath) >= 0 then Exit;
    if not DirectoryExists(ABundlePath) then Exit;
    Seen.Add(ABundlePath);
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].Path := ABundlePath;
    Nm := NSStrValue(FM.displayNameAtPath(NSStr(ABundlePath)));
    if Nm = '' then Nm := ChangeFileExt(ExtractFileName(ABundlePath), '');
    Result[N].Name := Nm;
  end;

begin
  Result := nil;
  if APath = '' then Exit;
  Pool := NSAutoreleasePool.alloc.init;
  Seen := TStringList.Create;
  try
    Seen.CaseSensitive := False;
    Seen.Sorted := False;
    WS := NSWorkspace.sharedWorkspace;
    FM := NSFileManager.defaultManager;

    { The Finder association first: that is the "double click" answer and, when
      it exists, the one the user expects at the top of the menu. }
    if WS <> nil then
      DefaultApp := NSStrValue(
        WS.URLForApplicationToOpenURL(NSURL.fileURLWithPath(NSStr(APath))).path)
    else
      DefaultApp := '';
    AddOne(DefaultApp);

    Fn := AnsiString(APath);
    URL := CFURLCreateFromFileSystemRepresentation(nil, PAnsiChar(Fn),
      Length(Fn), False);
    Arr := nil;
    try
      if URL <> nil then
        Arr := LSCopyApplicationURLsForURL(URL, kLSRolesAll);
      if Arr <> nil then
      begin
        Count := CFArrayGetCount(Arr);
        for I := 0 to Count - 1 do
        begin
          Buf[0] := #0;
          if CFURLGetFileSystemRepresentation(CFArrayGetValueAtIndex(Arr, I),
            True, @Buf[0], SizeOf(Buf) - 1) then
          begin
            Candidate := string(AnsiString(PAnsiChar(@Buf[0])));
            AddOne(Candidate);
          end;
        end;
      end;
    finally
      if Arr <> nil then CFRelease(Arr);
      if URL <> nil then CFRelease(URL);
    end;
  finally
    Seen.Free;
    Pool.release;
  end;
end;

function TzMacOpenFileWith(const APath, AAppPath: string): Boolean;
var
  Pool: NSAutoreleasePool;
  WS: NSWorkspace;
begin
  Result := False;
  if (APath = '') or (AAppPath = '') then Exit;
  Pool := NSAutoreleasePool.alloc.init;
  try
    try
      WS := NSWorkspace.sharedWorkspace;
      if WS = nil then Exit;
      { Passing the bundle path (not the display name) makes this work for
        bundles that are not installed in /Applications. }
      Result := WS.openFile_withApplication_andDeactivate(NSStr(APath),
        NSStr(AAppPath), False);
    except
      Result := False;
    end;
  finally
    Pool.release;
  end;
end;

function TzMacChooseAppForFile(const APath: string;
  out AAppPath: string): TZChooseAppResult;
var
  Dlg: TOpenDialog;
begin
  AAppPath := '';
  Result := caFailed;

  { LCL's own dialog, not NSOpenPanel.runModal.

    runModal starts a second Cocoa modal loop inside the LCL one. The first call
    works; a later one crashes, because the LCL round trip that owns the mouse and
    key window never unwinds -- reported as an access violation right after
    cancelling the panel. TOpenDialog goes through the widgetset's modal handling,
    which is what every other dialog in this program already uses. }
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Options := [ofFileMustExist, ofEnableSizing];
    Dlg.Filter := rsAppBundleFilter;
    Dlg.Title := rsDlgChooseApp;
    { An application bundle almost always lives here, so the panel opens there
      instead of wherever the process happened to be. }
    if DirectoryExists('/Applications') then
      Dlg.InitialDir := '/Applications';

    if not Dlg.Execute then
    begin
      { Cancel, Escape and the title bar's close button all mean "never mind". }
      Result := caCancelled;
      Exit;
    end;
    AAppPath := Dlg.FileName;
    if AAppPath = '' then
      Result := caCancelled
    else
      Result := caChosen;
  finally
    Dlg.Free;
  end;
end;

{ The .app bundle this executable lives in, or '' when it is not bundled.
  `open -a` wants the bundle, not the Mach-O inside Contents/MacOS: given the
  executable it launches a process but delivers no document. }
function CurrentBundlePath: string;
var
  D: string;
  I: Integer;
begin
  Result := '';
  D := ExcludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(ParamStr(0))));
  for I := 1 to 4 do
  begin
    if LowerCase(ExtractFileExt(D)) = '.app' then Exit(D);
    D := ExcludeTrailingPathDelimiter(ExtractFileDir(D));
    if D = '' then Break;
  end;
end;

function TzMacRevealFile(const APath: string): Boolean;
var
  P: TProcess;
begin
  { `open -R` is Finder's own reveal: it selects the file in its folder instead
    of reopening the folder and leaving the user to find it. Spawning costs one
    short-lived process, the same trade as opening a folder. }
  Result := False;
  if (APath = '') or (not FileExists(APath)) then Exit;
  try
    P := TProcess.Create(nil);
    try
      P.Executable := '/usr/bin/open';
      P.Parameters.Add('-R');
      P.Parameters.Add(APath);
      P.Options := [];
      P.Execute;
      Result := True;
    finally
      P.Free;
    end;
  except
    Result := False;
  end;
end;

function TzMacOpenInNewInstance(const APath: string): Boolean;
var
  P: TProcess;
  Bundle: string;
begin
  { `open -n` is the LaunchServices way to ask for a NEW instance of the bundle.
    Spawning it costs one short-lived process and keeps this unit free of
    Apple Event sending, which would need a target PSN and a reply timeout. }
  Result := False;
  if APath = '' then Exit;
  { The path goes as an ARGUMENT, not as a document the new process must receive
    through LaunchServices. A burst of document deliveries races: several new
    processes start but only the first one is handed its file, which is exactly
    the "I selected three and only one window had content" failure. An argument
    is read by the new process itself, so every window gets its own file. }
  Bundle := CurrentBundlePath;
  if Bundle = '' then Exit;
  try
    P := TProcess.Create(nil);
    try
      P.Executable := '/usr/bin/open';
      P.Parameters.Add('-n');
      P.Parameters.Add('-a');
      P.Parameters.Add(Bundle);
      { --wait? No: `open` must not block the UI thread. The caller spaces the
        launches instead (see OpenFilesFromSystem). }
      P.Parameters.Add('--args');
      P.Parameters.Add(APath);
      P.Options := [];
      P.Execute;
      Result := True;
    finally
      P.Free;
    end;
  except
    Result := False;
  end;
end;

function TzMacOpenInNewInstanceAsArchive(const APath: string): Boolean;
var
  P: TProcess;
  Bundle: string;
begin
  Result := False;
  if APath = '' then Exit;
  Bundle := CurrentBundlePath;
  if Bundle = '' then Exit;
  try
    P := TProcess.Create(nil);
    try
      P.Executable := '/usr/bin/open';
      P.Parameters.Add('-n');
      P.Parameters.Add('-a');
      P.Parameters.Add(Bundle);
      P.Parameters.Add('--args');
      P.Parameters.Add('--open-as-archive');
      P.Parameters.Add(APath);
      P.Options := [];
      P.Execute;
      Result := True;
    finally
      P.Free;
    end;
  except
    Result := False;
  end;
end;

function NSDataToBitmap(AData: NSData): TBGRABitmap;
var
  MS: TMemoryStream;
begin
  Result := nil;
  if (AData = nil) or (AData.length = 0) or (AData.bytes = nil) then Exit;
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(AData.bytes^, AData.length);
    MS.Position := 0;
    Result := TBGRABitmap.Create(MS);
  finally
    MS.Free;
  end;
end;

{ Render the NSImage through TIFF into a bitmap.

  The "fast" version of this that picked a single NSBitmapImageRep and asked it for
  PNG was measurably quicker, and wrong: a system icon's representations are not
  all the same artwork. NSImage composes the icon at the size the caller asks for,
  combining the base artwork with its overlays; grabbing one representation hands
  back a generic document sheet instead of the type-specific glyph. The cost of
  TIFFRepresentation is the price of getting the RIGHT picture, so it stays -- the
  per-icon latency is instead hidden by caching and by doing it off the UI thread. }
function NSImageToBitmap(AImage: NSImage): TBGRABitmap;
var
  Rep: NSBitmapImageRep;
  Data: NSData;
begin
  Result := nil;
  if AImage = nil then Exit;
  Data := AImage.TIFFRepresentation;
  if Data = nil then Exit;
  Rep := NSBitmapImageRep.alloc.initWithData(Data);
  if Rep = nil then Exit;
  try
    Data := Rep.representationUsingType_properties(NSPNGFileType, nil);
    Result := NSDataToBitmap(Data);
  finally
    Rep.release;
  end;
end;

function TzMacSystemIcon(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
var
  WS: NSWorkspace;
  Img: NSImage;
  TypeName: NSString;
  Pool: NSAutoreleasePool;
begin
  Result := nil;
  Pool := NSAutoreleasePool.alloc.init;
  try
    try
      WS := NSWorkspace.sharedWorkspace;
      if WS = nil then Exit;
      if APath <> '' then
        Img := WS.iconForFile(NSString.stringWithUTF8String(PAnsiChar(UTF8String(APath))))
      else
      begin
        { AExtension here is a TYPE: either a UTI ("public.folder") or a bare
          suffix ("7z"). Neither is lowercased -- UTI components are case-
          sensitive to LaunchServices, and iconForFileType wants the identifier,
          not a file name. }
        if AExtension <> '' then
          TypeName := NSString.stringWithUTF8String(PAnsiChar(UTF8String(AExtension)))
        else if AFolder then
          TypeName := NSString.stringWithUTF8String(PChar('public.folder'))
        else
          TypeName := NSString.stringWithUTF8String(PChar('public.data'));
        Img := WS.iconForFileType(TypeName);
      end;
      Result := NSImageToBitmap(Img);
    except
      Result := nil;
    end;
  finally
    Pool.release;
  end;
end;

function TzMacOpenWithDefaultApp(const APath: string): Boolean;
var
  URL: NSURL;
  WS: NSWorkspace;
  Pool: NSAutoreleasePool;
begin
  Result := False;
  if APath = '' then Exit;
  Pool := NSAutoreleasePool.alloc.init;
  try
    URL := NSURL.fileURLWithPath(
      NSString.stringWithUTF8String(PAnsiChar(UTF8String(APath))));
    if URL = nil then Exit;
    WS := NSWorkspace.sharedWorkspace;
    if WS = nil then Exit;
    Result := WS.openURL(URL);
  finally
    Pool.release;
  end;
end;

function TzMacPhysicalMemory: QWord;
var
  Size: UInt64;
  Len: PtrUInt;
begin
  Result := 0;
  Size := 0;
  { oldlenp is an in/out parameter: sysctlbyname reads the buffer size from it
    and writes back how much it filled. Passing nil makes the call fail with
    EFAULT, which is why the dialog kept reporting 0 B of RAM. }
  Len := SizeOf(Size);
  if sysctlbyname('hw.memsize', @Size, @Len, nil, 0) = 0 then
    Result := Size;
end;

{ How long the user has been quiet. The icon timers ask this before every
  NSWorkspace lookup, because a single lookup can block this thread for seconds
  and that is exactly what made hover feedback lag behind the mouse. }
function TzMacSecondsSinceLastInput: Double;
const
  kCGEventSourceStateCombinedSessionState = 0;
  kCGAnyInputEventType = CGEventType($FFFFFFFF);
begin
  Result := CGEventSourceSecondsSinceLastEventType(
    kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
end;

function TzMacAppIsActive: Boolean;
begin
  Result := NSApplication.sharedApplication.isActive;
end;

{ The bundle's own icon file, read without AppKit.

  This is the fast path for the application sweep: Info.plist names the icon
  file, and a modern .icns carries PNG chunks, so the sweep copies a PNG into
  the cache instead of asking IconServices (which blocks the main thread for
  seconds). Foundation only parses the plist; no window, no NSWorkspace. }
function TzMacBundleIconPng(const AAppPath: string; AWantedPx: Integer;
  out APng: TBytes): Boolean;
var
  Pool: NSAutoreleasePool;
  Dict: NSDictionary;
  Value: NSString;
  BundleDir, InfoPath, ResDir, IconName, Candidate: string;
  Data: TBytes;

  function ReadAll(const APath: string; out ABytes: TBytes): Boolean;
  var
    FS: TFileStream;
  begin
    Result := False;
    ABytes := nil;
    if not FileExists(APath) then Exit;
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(ABytes, FS.Size);
      if Length(ABytes) > 0 then
        FS.ReadBuffer(ABytes[0], Length(ABytes));
      Result := True;
    finally
      FS.Free;
    end;
  end;

  function IsPng(const ABytes: TBytes): Boolean;
  begin
    Result := (Length(ABytes) >= 8) and (ABytes[0] = $89) and
      (ABytes[1] = $50) and (ABytes[2] = $4E) and (ABytes[3] = $47) and
      (ABytes[4] = $0D) and (ABytes[5] = $0A) and (ABytes[6] = $1A) and
      (ABytes[7] = $0A);
  end;

  function TryCandidate(const APath: string): Boolean;
  begin
    Result := False;
    if not ReadAll(APath, Data) then Exit;
    if IsPng(Data) then
    begin
      APng := Data;
      Exit(True);
    end;
    Result := TzIcnsBestPng(Data, AWantedPx, APng);
  end;

  function InfoString(const AKey: string): string;
  begin
    Result := '';
    Value := NSString(Dict.objectForKey(
      NSString.stringWithUTF8String(PAnsiChar(UTF8String(AKey)))));
    if Value = nil then Exit;
    Result := Trim(string(AnsiString(PAnsiChar(Value.UTF8String))));
  end;

begin
  Result := False;
  APng := nil;
  BundleDir := ExcludeTrailingPathDelimiter(AAppPath);
  if BundleDir = '' then Exit;
  ResDir := IncludeTrailingPathDelimiter(BundleDir) + 'Contents' + PathDelim +
    'Resources' + PathDelim;
  InfoPath := IncludeTrailingPathDelimiter(BundleDir) + 'Contents' + PathDelim +
    'Info.plist';
  if (not FileExists(InfoPath)) or (not DirectoryExists(ResDir)) then Exit;
  Pool := NSAutoreleasePool.alloc.init;
  try
    Dict := NSDictionary.dictionaryWithContentsOfFile(
      NSString.stringWithUTF8String(PAnsiChar(UTF8String(InfoPath))));
    if Dict = nil then Exit;
    { CFBundleIconFile is the file name; CFBundleIconName is used by bundles
      whose icon lives in an asset catalogue, but a few of them ship the .icns
      under that name too. }
    IconName := InfoString('CFBundleIconFile');
    if IconName = '' then
      IconName := InfoString('CFBundleIconName');
    IconName := ExtractFileName(IconName);
    if IconName = '' then Exit;
    Candidate := ResDir + IconName;
    if TryCandidate(Candidate) then Exit(True);
    if TryCandidate(Candidate + '.icns') then Exit(True);
    if TryCandidate(Candidate + '.png') then Exit(True);
  finally
    Pool.release;
  end;
end;

function TzMacRootVolumeName: string;
var
  Name: NSString;
  Pool: NSAutoreleasePool;
begin
  Result := '/';
  Pool := NSAutoreleasePool.alloc.init;
  try
    Name := NSFileManager.defaultManager.displayNameAtPath(
      NSString.stringWithUTF8String(PChar('/')));
    if Name <> nil then
      Result := string(AnsiString(PAnsiChar(Name.UTF8String)));
  finally
    Pool.release;
  end;
end;

{ The version the packaging step injected into the bundle. Reading it here is
  what keeps one source of truth: no Pascal file mentions a version number. }
function TzMacAppVersion: string;
var
  Pool: NSAutoreleasePool;
  Info: NSDictionary;
  Value: NSString;
  Bundle: NSBundle;
begin
  Result := 'dev';
  Pool := NSAutoreleasePool.alloc.init;
  try
    Bundle := NSBundle.mainBundle;
    if Bundle = nil then Exit;
    Info := Bundle.infoDictionary;
    if Info = nil then Exit;
    Value := NSString(Info.objectForKey(
      NSString.stringWithUTF8String(PChar('CFBundleShortVersionString'))));
    if Value = nil then Exit;
    Result := string(AnsiString(PAnsiChar(Value.UTF8String)));
    if Result = '' then Result := 'dev';
  finally
    Pool.release;
  end;
end;

{$ELSE}
{$mode objfpc}{$H+}

interface

uses SysUtils, BGRABitmap, BGRABitmapTypes, tzip.platform;

function TzMacSystemIcon(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
function TzMacOpenWithDefaultApp(const APath: string): Boolean;
function TzMacRootVolumeName: string;
function TzMacAppVersion: string;
function TzMacAppsForFile(const APath: string): TZOpenWithApps;
function TzMacOpenFileWith(const APath, AAppPath: string): Boolean;
function TzMacChooseAppForFile(const APath: string): string;
function TzMacRevealFile(const APath: string): Boolean;
function TzMacOpenInNewInstance(const APath: string): Boolean;

implementation

function TzMacSystemIcon(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
begin
  Result := nil;
end;

function TzMacRevealFile(const APath: string): Boolean;
begin
  Result := False;
end;

function TzMacOpenInNewInstance(const APath: string): Boolean;
begin
  Result := False;
end;

function TzMacOpenWithDefaultApp(const APath: string): Boolean;
begin
  Result := False;
end;

function TzMacRootVolumeName: string;
begin
  Result := '/';
end;

function TzMacAppVersion: string;
begin
  Result := 'dev';
end;

function TzMacAppsForFile(const APath: string): TZOpenWithApps;
begin
  Result := nil;
end;

function TzMacOpenFileWith(const APath, AAppPath: string): Boolean;
begin
  Result := False;
end;

function TzMacChooseAppForFile(const APath: string): string;
begin
  Result := '';
end;

{$ENDIF}

end.
