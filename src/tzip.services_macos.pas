{ Finder integration: the Services menu entries declared in Info.plist.

  Finder hands a service the user's selection as a pasteboard. TyZip turns it
  into POSIX paths and hands them to the main window, which owns the engine and
  the progress UI.

  Two details worth stating:

  - The selection is read from NSFilenamesPboardType first, with public.file-url
    as a fallback. public.file-url can be a file REFERENCE URL
    (file:///.file/id=...), whose path is not a usable file name; treating it as
    a path produced the create dialog's "/id=6571367.7z" (ticket 36).
  - The reply is sent even when nothing was found, because a service that never
    replies leaves Finder's menu item spinning until it times out. }
unit tzip.services_macos;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

interface

uses
  Classes, SysUtils, CocoaAll;

type
  { What Finder asked for. One entry per NSServices item in Info.plist; the
    selector names there must match the messages below exactly. }
  TServiceRequest = (
    srCompressDialog,   { "Add to Archive…"  -- opens the create dialog }
    srExtractDialog,    { "Extract…"          -- opens the extract dialog }
    srExtractHere,      { "Extract Here"      -- next to the archive }
    srExtractToFolder,  { "Extract to <name>/" -- into a folder named after it }
    srSmartExtract,     { "Smart Extract"     -- layout decided by the archive }
    srCompressHere,     { "Add to <name>.7z"  -- default format, no dialog }
    srCompressEach      { "Add Each to a Separate Archive" }
  );

  { Called on the main thread with the selected paths. Returns a short reply
    string for Finder, or '' for none. }
  TServiceHandler = function(ARequest: TServiceRequest;
    APaths: TStrings): string of object;

{ Install the service provider. Harmless when called twice. }
procedure TzInstallServices(AHandler: TServiceHandler);

{ True when the provider is installed, so the caller can report it. }
function TzServicesInstalled: Boolean;

{ The Finder selection as POSIX file paths. Exposed so a regression test can
  hand in a pasteboard built to look like Finder's; RunService uses the same
  conversion. Caller frees the list. }
function TzServicePathsFromPasteboard(pboard: NSPasteboard): TStringList;

implementation

uses
  LCLType, Forms;

type
  TTyServiceProvider = objcclass(NSObject)
  public
    procedure svcCompressDialog(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'compressDialog:userData:error:';
    procedure svcExtractDialog(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'extractDialog:userData:error:';
    procedure svcExtractHere(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'extractHere:userData:error:';
    procedure svcExtractToFolder(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'extractToFolder:userData:error:';
    procedure svcSmartExtract(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'smartExtract:userData:error:';
    procedure svcCompressHere(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'compressHere:userData:error:';
    procedure svcCompressEach(pboard: NSPasteboard; userData: NSString;
      error: NSError); message 'compressEach:userData:error:';
  end;

var
  GProvider: TTyServiceProvider = nil;
  GHandler: TServiceHandler = nil;

function TzServicePathsFromPasteboard(pboard: NSPasteboard): TStringList;
var
  Names: NSArray;
  Items: NSArray;
  I: NSUInteger;
  Item: NSPasteboardItem;
  S, P: NSString;
  U: NSURL;
  Path: string;
begin
  Result := TStringList.Create;
  if pboard = nil then Exit;

  { Finder puts the selected POSIX paths on the service pasteboard as the
    legacy filenames property list. Read it first: public.file-url can hold a
    file REFERENCE URL (file:///.file/id=...), whose path is not a usable file
    name. Using it made the create dialog default to "/id=6571367.7z" (ticket
    36). }
  Names := NSArray(pboard.propertyListForType(
    NSString.stringWithUTF8String('NSFilenamesPboardType')));
  if Names <> nil then
    for I := 0 to Names.count - 1 do
    begin
      S := NSString(Names.objectAtIndex(I));
      if S <> nil then
        Result.Add(string(S.UTF8String));
    end;
  if Result.Count > 0 then Exit;

  { Fallback for pasteboards that only carry file URLs: resolve each to a POSIX
    path. A reference URL has no usable path and is skipped rather than being
    mistaken for one. }
  Items := pboard.pasteboardItems;
  if Items = nil then Exit;
  for I := 0 to Items.count - 1 do
  begin
    Item := NSPasteboardItem(Items.objectAtIndex(I));
    if Item = nil then Continue;
    S := Item.stringForType(NSString.stringWithUTF8String('public.file-url'));
    if S = nil then Continue;
    U := NSURL.URLWithString(S);
    if U = nil then Continue;
    P := U.path;
    if (P = nil) or (P.length = 0) then Continue;
    Path := string(P.UTF8String);
    if Pos('/.file/id=', Path) = 1 then Continue;
    Result.Add(Path);
  end;
end;

function RunService(ARequest: TServiceRequest; pboard: NSPasteboard): NSString;
var
  Paths: TStringList;
  Reply: string;
begin
  Reply := '';
  if Assigned(GHandler) then
  begin
    Paths := TzServicePathsFromPasteboard(pboard);
    try
      Reply := GHandler(ARequest, Paths);
    finally
      Paths.Free;
    end;
  end;
  { An empty reply still has to be a valid NSString, hence '' rather than nil. }
  Result := NSString.stringWithUTF8String(PChar(AnsiString(Reply)));
end;

function ReplyToPasteboard(const AReply: NSString): NSPasteboard;
begin
  Result := NSPasteboard.generalPasteboard;
  if Result <> nil then
  begin
    Result.clearContents;
    if AReply <> nil then
      Result.setString_forType(AReply, NSPasteboardTypeString);
  end;
end;

function ServiceProvider: TTyServiceProvider;
begin
  if GProvider = nil then
  begin
    GProvider := TTyServiceProvider.alloc;
    GProvider := GProvider.init;
    { Registered as a provider rather than through the application delegate:
      this is the documented route for a service that only answers messages. }
    NSApp.setServicesProvider(GProvider);
  end;
  Result := GProvider;
end;

procedure TTyServiceProvider.svcCompressDialog(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srCompressDialog, pboard));
end;

procedure TTyServiceProvider.svcExtractDialog(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srExtractDialog, pboard));
end;

procedure TTyServiceProvider.svcExtractHere(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srExtractHere, pboard));
end;

procedure TTyServiceProvider.svcExtractToFolder(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srExtractToFolder, pboard));
end;

procedure TTyServiceProvider.svcSmartExtract(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srSmartExtract, pboard));
end;

procedure TTyServiceProvider.svcCompressHere(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srCompressHere, pboard));
end;

procedure TTyServiceProvider.svcCompressEach(pboard: NSPasteboard;
  userData: NSString; error: NSError);
begin
  ReplyToPasteboard(RunService(srCompressEach, pboard));
end;

procedure TzInstallServices(AHandler: TServiceHandler);
begin
  GHandler := AHandler;
  ServiceProvider;
end;

function TzServicesInstalled: Boolean;
begin
  Result := GProvider <> nil;
end;

initialization
finalization
  { NSApp outlives this unit's finalization, so the provider is left for the
    runtime to reclaim; releasing it here would leave a dangling services
    provider during application teardown. }
  GProvider := nil;

end.
