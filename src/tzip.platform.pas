unit tzip.platform;

{ Small platform facade.  The rest of the UI never names a widgetset or an OS
  API: system icons, the platform label and "open with the default application"
  all arrive here.  macOS lives in tzip.platform_macos; other targets get a
  deterministic, dependency-free fallback until their port lands. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Graphics, LCLIntf, BGRABitmap, BGRABitmapTypes;

type
  TZOpenWithApp = record
    Name: string;
    Path: string;
  end;
  TZOpenWithApps = array of TZOpenWithApp;

  { Where TzPlatformIconOnly gets its icons.

    Nil (the normal state) means "ask the platform". A test can install a
    deterministic function instead: the file list, the sidebar tree and the icon
    prefetcher all go through TzPlatformIconOnly, so one install covers every
    consumer and no test has to touch NSWorkspace. }
  TZIconProvider = function(const APath, AExtension: string; ASize: Integer;
    AFolder: Boolean): TBGRABitmap;

{ The installed provider, or nil when the platform answers. }
function TzGetIconProvider: TZIconProvider;
{ Install (or clear, with nil) the icon provider. The window never calls this; it
  exists for tests. }
procedure TzSetIconProvider(AProvider: TZIconProvider);

{ A system icon for a file path or a filename extension.
  APath may be empty for a virtual archive entry, in which case AExtension is
  used and macOS resolves a document icon by UTI/extension.  AFolder selects the
  generic folder icon.  Returns a caller-owned bitmap, or nil on failure. }
function TzSystemIcon(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean = False): TBGRABitmap;

{ The platform icon ONLY, with no fallback drawing: nil when the platform cannot
  produce one. Callers that CACHE the result must use this -- storing the
  fallback would turn a transient failure at startup into every later run. }
function TzPlatformIconOnly(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean = False): TBGRABitmap;

{ Generic, dependency-free fallback used on every non-macOS target (and by
  macOS when NSWorkspace returns nothing). }
function TzFallbackIcon(const AExtension: string; ASize: Integer;
  AFolder: Boolean = False): TBGRABitmap;

function TzPlatformName: string;

{ Installed physical memory in bytes, 0 when unknown. }
function TzPhysicalMemory: QWord;
function TzRootVolumeName: string;

{ Seconds since the last keyboard or mouse event, 1e9 when the platform cannot
  tell. The icon timers use it to keep their blocking lookups out of the user's
  way. }
function TzSecondsSinceLastInput: Double;

{ True when this application is the frontmost one. The icon timers may do their
  blocking work while we are in the background; in the foreground they wait for
  a long idle stretch instead. }
function TzAppIsActive: Boolean;

{ PNG bytes of a bundle's own icon file, read straight out of the .app.

  That file (Contents/Resources/<CFBundleIconFile>.icns) is a plain file: unlike
  a platform icon query it needs no AppKit, no XPC and no main thread, so the
  application sweep can cache a bundle icon without stalling the window. False
  when the bundle has no readable PNG-bearing icon (legacy RLE .icns, or an
  Assets.car with only CFBundleIconName); the caller falls back to the platform
  query, which stays main-thread-only and gated. }
function TzBundleIconPng(const AAppPath: string; AWantedPx: Integer;
  out APng: TBytes): Boolean;

{ The application's version, for the About box.

  It comes from the bundle's CFBundleShortVersionString, so the version is
  written ONCE (packaging/version.txt, injected into Info.plist) and no source
  file carries a second copy. A plain development build has no bundle: 'dev'. }
function TzAppVersion: string;
function TzOpenWithDefaultApp(const APath: string): Boolean;

{ Applications registered for APath, default first.  Empty when the platform
  cannot enumerate them (or nothing claims the type), which is the cue to ask the
  user for an application instead of reporting an error. }
function TzAppsForFile(const APath: string): TZOpenWithApps;
{ Open APath with a specific application bundle. }
function TzOpenFileWithApp(const APath, AAppPath: string): Boolean;
{ What the "Choose an application" panel came back with. }
type
  TZChooseAppResult = (
    caChosen,     { AAppPath holds the bundle the user picked. }
    caCancelled,  { The user dismissed the panel. Nothing went wrong. }
    caFailed      { The panel could not be shown, or the platform has none. }
  );

{ Ask the user to pick an application bundle (Finder's "Other..." panel).
  AAppPath is only meaningful for caChosen. }
function TzChooseAppForFile(const APath: string;
  out AAppPath: string): TZChooseAppResult;

{ Show APath in the OS file manager with the file selected (Finder's "Reveal in
  Finder"). False when the platform cannot, in which case callers fall back to
  opening the containing folder. }
function TzRevealFile(const APath: string): Boolean;

{ Ask the OS to open APath in a NEW instance of this application, so a
  multi-selection can become one window per archive.  macOS: LaunchServices
  (open -n); other targets answer False until they have a story for it.

  Incoming files need no counterpart: the LCL widgetset already delivers a
  Finder "Open With" / drag to TForm.OnDropFiles, which is why the app has one
  code path for both. }
function TzOpenInNewInstance(const APath: string): Boolean;

implementation

{$IFDEF DARWIN}
uses tzip.platform_macos;
{$ENDIF}

var
  { Nil = ask the platform (see TZIconProvider). }
  TZInstalledIconProvider: TZIconProvider = nil;

function TzFallbackIcon(const AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
var
  B: TBGRABitmap;
  C: TBGRAPixel;
  E: string;
begin
  if ASize < 8 then ASize := 16;
  if ASize > 256 then ASize := 256;
  B := TBGRABitmap.Create(ASize, ASize, BGRAPixelTransparent);
  if AFolder then
  begin
    B.FillRoundRectAntialias(ASize div 10, ASize div 4, ASize * 3 div 10, ASize * 5 div 10,
      ASize div 12, ASize div 12, BGRA(196, 148, 54));
    B.FillRoundRectAntialias(ASize div 10, ASize * 5 div 12, ASize * 9 div 10,
      ASize * 9 div 10, ASize div 14, ASize div 14, BGRA(224, 176, 66));
    Exit(B);
  end;
  E := LowerCase(AExtension);
  if (E = 'png') or (E = 'jpg') or (E = 'jpeg') or (E = 'gif') or (E = 'webp') then
    C := BGRA(190, 96, 176)
  else if (E = 'txt') or (E = 'md') or (E = 'pas') or (E = 'c') or (E = 'cpp') or
          (E = 'h') or (E = 'html') or (E = 'json') or (E = 'xml') then
    C := BGRA(72, 128, 200)
  else if (E = 'zip') or (E = '7z') or (E = 'rar') or (E = 'tar') or (E = 'gz') or
          (E = 'bz2') or (E = 'xz') then
    C := BGRA(96, 126, 210)
  else
    C := BGRA(150, 156, 166);
  B.FillPolyAntialias([PointF(ASize div 5, ASize div 12), PointF(ASize * 7 div 10, ASize div 12),
    PointF(ASize * 17 div 20, ASize div 4), PointF(ASize * 17 div 20, ASize * 11 div 12),
    PointF(ASize div 5, ASize * 11 div 12)], C);
  B.FillRectAntialias(ASize div 4, ASize div 2, ASize * 3 div 4, ASize * 9 div 16,
    BGRA(255, 255, 255, 160));
  Result := B;
end;

function TzGetIconProvider: TZIconProvider;
begin
  Result := TZInstalledIconProvider;
end;

procedure TzSetIconProvider(AProvider: TZIconProvider);
begin
  TZInstalledIconProvider := AProvider;
end;

function TzPlatformIconOnly(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
begin
  { One seam for every consumer: the lists, the tree and the prefetcher. }
  if TZInstalledIconProvider <> nil then
    Exit(TZInstalledIconProvider(APath, AExtension, ASize, AFolder));
  {$IFDEF DARWIN}
  Result := TzMacSystemIcon(APath, AExtension, ASize, AFolder);
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

function TzSystemIcon(const APath, AExtension: string; ASize: Integer;
  AFolder: Boolean): TBGRABitmap;
begin
  Result := TzPlatformIconOnly(APath, AExtension, ASize, AFolder);
  if Result = nil then
    Result := TzFallbackIcon(AExtension, ASize, AFolder);
end;

function TzPhysicalMemory: QWord;
begin
  {$IFDEF DARWIN}
  Result := TzMacPhysicalMemory;
  {$ELSE}
    {$IFDEF LINUX}
  Result := TzMacPhysicalMemory;
    {$ELSE}
  Result := 0;
    {$ENDIF}
  {$ENDIF}
end;

function TzSecondsSinceLastInput: Double;
begin
  {$IFDEF DARWIN}
  Result := TzMacSecondsSinceLastInput;
  {$ELSE}
  Result := 1e9;
  {$ENDIF}
end;

function TzAppIsActive: Boolean;
begin
  {$IFDEF DARWIN}
  Result := TzMacAppIsActive;
  {$ELSE}
  Result := True;
  {$ENDIF}
end;

function TzBundleIconPng(const AAppPath: string; AWantedPx: Integer;
  out APng: TBytes): Boolean;
begin
  {$IFDEF DARWIN}
  Result := TzMacBundleIconPng(AAppPath, AWantedPx, APng);
  {$ELSE}
  APng := nil;
  Result := False;
  {$ENDIF}
end;

function TzPlatformName: string;
begin
  {$IFDEF DARWIN}
  Result := 'macOS';
  {$ELSE}
    {$IFDEF MSWINDOWS}
  Result := 'Windows';
    {$ELSE}
      {$IFDEF LINUX}
  Result := 'Linux';
      {$ELSE}
  Result := 'Unix';
      {$ENDIF}
    {$ENDIF}
  {$ENDIF}
end;

function TzOpenWithDefaultApp(const APath: string): Boolean;
begin
  {$IFDEF DARWIN}
  try
    Result := TzMacOpenWithDefaultApp(APath);
  except
    Result := False;
  end;
  {$ELSE}
  try
    Result := OpenDocument(APath);
  except
    Result := False;
  end;
  {$ENDIF}
end;

function TzAppsForFile(const APath: string): TZOpenWithApps;
begin
  Result := nil;
  if APath = '' then Exit;
  {$IFDEF DARWIN}
  try
    Result := TzMacAppsForFile(APath);
  except
    Result := nil;
  end;
  {$ENDIF}
end;

function TzOpenFileWithApp(const APath, AAppPath: string): Boolean;
begin
  Result := False;
  if (APath = '') or (AAppPath = '') then Exit;
  {$IFDEF DARWIN}
  try
    Result := TzMacOpenFileWith(APath, AAppPath);
  except
    Result := False;
  end;
  {$ELSE}
  Result := TzOpenWithDefaultApp(APath);
  {$ENDIF}
end;

function TzChooseAppForFile(const APath: string;
  out AAppPath: string): TZChooseAppResult;
begin
  AAppPath := '';
  {$IFDEF DARWIN}
  try
    Result := TzMacChooseAppForFile(APath, AAppPath);
  except
    { A panel that throws is a failure, not a cancellation. }
    AAppPath := '';
    Result := caFailed;
  end;
  {$ELSE}
  Result := caFailed;
  {$ENDIF}
end;

function TzRootVolumeName: string;
begin
  {$IFDEF DARWIN}
  Result := TzMacRootVolumeName;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := ExtractFileDrive(GetCurrentDir);
  if Result = '' then Result := 'C:';
  {$ENDIF}
  {$IFDEF LINUX}
  Result := '/';
  {$ENDIF}
end;

function TzAppVersion: string;
begin
  Result := 'dev';
  {$IFDEF DARWIN}
  try
    Result := TzMacAppVersion;
  except
    { A version string is cosmetic; never let it take the About box down. }
    Result := 'dev';
  end;
  {$ENDIF}
  if Result = '' then Result := 'dev';
end;

function TzRevealFile(const APath: string): Boolean;
var
  Dir: string;
begin
  Result := False;
  {$IFDEF DARWIN}
  try
    Result := TzMacRevealFile(APath);
  except
    Result := False;
  end;
  {$ENDIF}
  if Result then Exit;
  { No reveal on this platform (or it failed): opening the containing folder is
    the older, weaker behaviour and still better than nothing. }
  Dir := ExcludeTrailingPathDelimiter(ExtractFileDir(APath));
  if (Dir <> '') and DirectoryExists(Dir) then
  begin
    try
      Result := OpenDocument(Dir);
    except
      Result := False;
    end;
  end;
end;

function TzOpenInNewInstance(const APath: string): Boolean;
begin
  Result := False;
  {$IFDEF DARWIN}
  try
    Result := TzMacOpenInNewInstance(APath);
  except
    Result := False;
  end;
  {$ENDIF}
end;

end.
