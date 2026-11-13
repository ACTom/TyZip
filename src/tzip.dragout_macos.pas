{ Dragging archive entries OUT of TyZip to Finder, as file promises.

  Finder asks for each promised file only when the user drops it, so dragging a
  multi-gigabyte entry starts instantly and the extraction runs in the promise
  delegate instead of freezing the list. The destination side (Finder) shows its
  normal copy progress; TyZip never writes to the destination itself except
  through the promise URL it is handed.

  macOS specifics:
  - NSDraggingSession is the only way out of an application; LCL has no API for
    it, so the drag is started from the archive list's NSView.
  - A file promise is told where to write by writePromiseToURL:completionHandler:.
    FPC has no block-call syntax, so the completion block is invoked through its
    documented 64-bit layout (isa, flags, reserved, invoke) with the block itself
    as the first argument.
  - A folder promise extracts the subtree beside the destination first and
    renames it into place, keeping the copy on the destination's volume. }
unit tzip.dragout_macos;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}
{$modeswitch objectivec2}

interface

uses
  Classes, SysUtils, CocoaAll, tzip.api, tzip.engine, tzip.dragout;

type
  { One item the drag carries. The promise delegate re-opens the archive by path
    in its worker, so the request must be self-contained (the window may finish
    another job while the copy runs). }
  TDragOutRequest = record
    ArchivePath: string;
    Password: string;
    Root: TDragOutRoot;
    { The ZIP name code page the listing was decoded with; the promise thread
      opens the archive itself, so it must decode names the same way or a
      dragged folder's children come out mojibake. 0 = engine default. }
    NameCodepage: LongWord;
  end;
  TDragOutRequests = array of TDragOutRequest;

{ Start dragging ARequests out of AView. AEvent must be the mouse-dragged event
  that started the gesture (AppKit attaches the session to it). }
procedure TzStartArchiveDragOut(AView: NSView; AEvent: NSEvent;
  const ARequests: TDragOutRequests);

implementation

{ ---------------------------------------------------------------------------
  Objective-C declarations AppKit has but CocoaAll does not bind
  --------------------------------------------------------------------------- }

type
  NSFilePromiseProvider = objcclass external (NSObject)
  public
    function initWithFileType_delegate(fileType: NSString; delegate: NSObject): id;
      message 'initWithFileType:delegate:';
    function fileType: NSString; message 'fileType';
    function delegate: NSObject; message 'delegate';
  end;

  NSFilePromiseProviderDelegateProtocol = objcprotocol external
    name 'NSFilePromiseProviderDelegate' (NSObjectProtocol)
  required
    procedure filePromiseProvider_writePromiseToURL_completionHandler(
      provider: NSFilePromiseProvider; url: NSURL;
      completionHandler: OpaqueCBlock);
      message 'filePromiseProvider:writePromiseToURL:completionHandler:';
  optional
    function filePromiseProvider_fileNameForType(provider: NSFilePromiseProvider;
      fileType: NSString): NSString;
      message 'filePromiseProvider:fileNameForType:';
  end;

  { A block's first three fields are the same on every 64-bit macOS ABI; invoke
    is called with the block itself as the hidden first argument. }
  TBlockLiteral = record
    Isa: Pointer;
    Flags: LongInt;
    Reserved: LongInt;
    Invoke: Pointer;
  end;
  PBlockLiteral = ^TBlockLiteral;
  TBlockInvokeProc = procedure(ABlock: Pointer; AError: Pointer); cdecl;

function Q(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(AnsiString(S)));
end;

procedure CallCompletion(ACompletion: Pointer; AError: Pointer);
var
  B: PBlockLiteral;
begin
  if ACompletion = nil then Exit;
  B := PBlockLiteral(ACompletion);
  if B^.Invoke = nil then Exit;
  TBlockInvokeProc(B^.Invoke)(ACompletion, AError);
end;

function MakeError: NSError;
begin
  Result := NSError.errorWithDomain_code_userInfo(Q('TyZip'), 1, nil);
end;

{ ---------------------------------------------------------------------------
  Shared state (one drag session per window)
  --------------------------------------------------------------------------- }

var
  GDelegate: NSObject = nil;
  GSource: id = nil;
  { Pointers, not objcclass elements: FPC 3.2.3 crashes generating a global
    managed array of class types. } 
  GProviders: array of Pointer = nil;
  GRequests: TDragOutRequests = nil;
  GPending: Integer = 0;
  GEnded: Boolean = False;
  { True while a drag session is alive. Pending writes must not gate a later
    gesture: Finder may hold the completion block for the whole copy. }
  GActive: Boolean = False;
  { Folders are dragged as staged real files (Finder takes no folder promise);
    their copies live until the next drag or app quit. }
  GStaged: TStringList = nil;

function ProviderIndex(AProvider: NSFilePromiseProvider): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(GProviders) do
    if GProviders[I] = Pointer(AProvider) then Exit(I);
end;

function RequestOf(AProvider: NSFilePromiseProvider): Integer;
begin
  Result := ProviderIndex(AProvider);
end;

procedure DeleteTree(const APath: string);
var
  SR: TSearchRec;
  P: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      P := IncludeTrailingPathDelimiter(APath) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then DeleteTree(P)
      else DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(APath);
end;

{ Extract one promise into the URL Finder chose. Returns '' on success or a
  human-readable error for the completion block. }
function ExtractPromise(const AReq: TDragOutRequest; const ADest: string): string;
var
  Arc: TTzArchive;
  R: Integer;
  Tmp, RootPath: string;
  E: string;
begin
  Result := '';
  Arc := nil;
  R := TzOpenArchive(AReq.ArchivePath, AReq.Password, Arc, E, nil,
    AReq.NameCodepage);
  if R <> TZ7Z_OK then Exit(E);
  try
    if AReq.Root.IsDir then
    begin
      { Extract beside the destination so the final rename stays on one volume. }
      Tmp := IncludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(ADest))) +
        '.tyzip-promise-' + IntToStr(GetProcessID) + '-' +
        IntToHex(GetTickCount64, 8);
      ForceDirectories(Tmp);
      try
        R := TzExtract(Arc, AReq.Root.Indices, Tmp, AReq.Password, E);
        if R <> TZ7Z_OK then Exit(E);
        RootPath := IncludeTrailingPathDelimiter(Tmp) +
          StringReplace(ExcludeTrailingPathDelimiter(AReq.Root.EntryName), '/',
            PathDelim, [rfReplaceAll]);
        if not DirectoryExists(RootPath) then Exit('extracted folder is missing');
        if FileExists(ADest) or DirectoryExists(ADest) then
          Exit('destination already exists');
        if not RenameFile(RootPath, ADest) then
          Exit('cannot move the extracted folder into place');
      finally
        if DirectoryExists(Tmp) then DeleteTree(Tmp);
      end;
    end
    else
    begin
      ForceDirectories(ExtractFileDir(ADest));
      R := TzExtractOne(Arc, AReq.Root.EntryIndex, ADest, AReq.Password, E);
      if R <> TZ7Z_OK then Exit(E);
    end;
  finally
    Arc.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  The worker behind one promise
  --------------------------------------------------------------------------- }

type
  TPromiseWrite = class(TThread)
  private
    { Snapshot, not an index into the shared request array: the user may start
      another drag before this extraction finishes. }
    FRequest: TDragOutRequest;
    FDest: string;
    FCompletion: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARequest: TDragOutRequest; const ADest: string;
      ACompletion: Pointer);
  end;

constructor TPromiseWrite.Create(const ARequest: TDragOutRequest;
  const ADest: string; ACompletion: Pointer);
begin
  inherited Create(True);
  FRequest := ARequest;
  FDest := ADest;
  FCompletion := ACompletion;
  FreeOnTerminate := True;
end;

procedure TPromiseWrite.Execute;
var
  Err: string;
  ErrorObj: NSError;
begin
  Err := ExtractPromise(FRequest, FDest);
  { Release the counter before the completion block: Finder may hold that block
    until its copy finishes, which used to block every later drag. }
  InterLockedDecrement(GPending);
  if Err = '' then
    CallCompletion(FCompletion, nil)
  else
  begin
    ErrorObj := MakeError;
    CallCompletion(FCompletion, Pointer(ErrorObj));
  end;
end;

{ ---------------------------------------------------------------------------
  Promise delegate and drag source
  --------------------------------------------------------------------------- }

type
  TTyPromiseDelegate = objcclass(NSObject, NSFilePromiseProviderDelegateProtocol)
  public
    function filePromiseProvider_fileNameForType(provider: NSFilePromiseProvider;
      fileType: NSString): NSString;
      message 'filePromiseProvider:fileNameForType:';
    procedure filePromiseProvider_writePromiseToURL_completionHandler(
      provider: NSFilePromiseProvider; url: NSURL;
      completionHandler: OpaqueCBlock);
      message 'filePromiseProvider:writePromiseToURL:completionHandler:';
  end;

  TTyDragSource = objcclass(NSObject, NSDraggingSourceProtocol)
  public
    function draggingSession_sourceOperationMaskForDraggingContext(
      session: NSDraggingSession; context: NSDraggingContext): NSDragOperation;
      message 'draggingSession:sourceOperationMaskForDraggingContext:';
    procedure draggingSession_endedAtPoint_operation(
      session: NSDraggingSession; screenPoint: NSPoint;
      operation: NSDragOperation);
      message 'draggingSession:endedAtPoint:operation:';
  end;

function TTyPromiseDelegate.filePromiseProvider_fileNameForType(
  provider: NSFilePromiseProvider; fileType: NSString): NSString;
var
  I: Integer;
begin
  I := RequestOf(provider);
  if I < 0 then Exit(nil);
  Result := Q(GRequests[I].Root.BaseName);
end;

procedure TTyPromiseDelegate.filePromiseProvider_writePromiseToURL_completionHandler(
  provider: NSFilePromiseProvider; url: NSURL; completionHandler: OpaqueCBlock);
var
  I: Integer;
  Dest: NSString;
  T: TPromiseWrite;
begin
  I := RequestOf(provider);
  if (I < 0) or (url = nil) then
  begin
    CallCompletion(completionHandler, Pointer(MakeError));
    Exit;
  end;
  Dest := url.path;
  if (Dest = nil) or (Dest.length = 0) then
  begin
    CallCompletion(completionHandler, Pointer(MakeError));
    Exit;
  end;
  InterLockedIncrement(GPending);
  T := TPromiseWrite.Create(GRequests[I], string(Dest.UTF8String),
    completionHandler);
  T.Start;
end;

function TTyDragSource.draggingSession_sourceOperationMaskForDraggingContext(
  session: NSDraggingSession; context: NSDraggingContext): NSDragOperation;
begin
  { Copy only: a drag out of an archive must never be read as a move that
    removes the entry from it. }
  Result := NSDragOperationCopy;
end;

procedure TTyDragSource.draggingSession_endedAtPoint_operation(
  session: NSDraggingSession; screenPoint: NSPoint; operation: NSDragOperation);
begin
  GEnded := True;
  GActive := False;
end;

procedure ReleaseDragState;
var
  I: Integer;
begin
  if GStaged <> nil then
  begin
    for I := 0 to GStaged.Count - 1 do
      if DirectoryExists(GStaged[I]) then DeleteTree(GStaged[I]);
    GStaged.Clear;
  end;
  for I := 0 to High(GProviders) do
    if GProviders[I] <> nil then NSFilePromiseProvider(GProviders[I]).release;
  GProviders := nil;
  if GDelegate <> nil then
  begin
    GDelegate.release;
    GDelegate := nil;
  end;
  if GSource <> nil then
  begin
    NSObject(GSource).release;
    GSource := nil;
  end;
  GRequests := nil;
  GPending := 0;
  GEnded := False;
end;

procedure TzStartArchiveDragOut(AView: NSView; AEvent: NSEvent;
  const ARequests: TDragOutRequests);
var
  Items: NSMutableArray;
  Item: NSDraggingItem;
  Provider: NSFilePromiseProvider;
  Image: NSImage;
  I: Integer;
  FileType: NSString;
  Session: NSDraggingSession;
  Staged, StagedBase, Err: string;
  URL: NSURL;
begin
  if (AView = nil) or (AEvent = nil) or (Length(ARequests) = 0) then Exit;
  { One drag at a time. A pending write is allowed here: once it has started
    extracting it no longer reads the shared state. }
  if GActive then Exit;

  ReleaseDragState;
  if GStaged = nil then GStaged := TStringList.Create;
  GDelegate := NSObject(TTyPromiseDelegate.alloc.init);
  GSource := TTyDragSource.alloc.init;
  SetLength(GProviders, Length(ARequests));
  SetLength(GRequests, Length(ARequests));
  for I := 0 to High(ARequests) do
    GRequests[I] := ARequests[I];

  Items := NSMutableArray.alloc.init;
  try
    for I := 0 to High(ARequests) do
    begin
      if ARequests[I].Root.IsDir then
      begin
        { Finder does not ask for a folder promise, so stage the subtree on
          disk and drag a real directory URL. Files stay lazy promises. }
        { Unique parent, but the dragged URL must keep the entry's own name,
          or Finder copies a folder called "TyZip-staged-...". }
        StagedBase := IncludeTrailingPathDelimiter(GetTempDir(False)) +
          'TyZip-staged-' + IntToStr(GetProcessID) + '-' +
          IntToHex(GetTickCount64, 8);
        Staged := IncludeTrailingPathDelimiter(StagedBase) +
          ARequests[I].Root.BaseName;
        Err := ExtractPromise(ARequests[I], Staged);
        if Err <> '' then
        begin
          Exit;
        end;
        GStaged.Add(StagedBase);
        URL := NSURL.fileURLWithPath(Q(Staged));
        Item := NSDraggingItem.alloc.initWithPasteboardWriter(
          NSPasteboardWritingProtocol(URL));
        Image := NSWorkspace.sharedWorkspace.iconForFile(URL.path);
        Item.setDraggingFrame_contents(NSMakeRect(8 + I * 20, 8 + I * 20, 48, 48),
          Image);
        Items.addObject(Item);
        Item.release;
        { URL came from fileURLWithPath: it is autoreleased; releasing it here
          over-released it and AppKit crashed later with an access violation. }
      end
      else
      begin
        FileType := Q('public.data');
        Provider := NSFilePromiseProvider.alloc;
        Provider := Provider.initWithFileType_delegate(FileType,
          NSObject(GDelegate));
        if Provider = nil then Continue;
        GProviders[I] := Pointer(Provider);
        Item := NSDraggingItem.alloc.initWithPasteboardWriter(
          NSPasteboardWritingProtocol(Provider));
        Image := NSWorkspace.sharedWorkspace.iconForFileType(FileType);
        Item.setDraggingFrame_contents(NSMakeRect(8 + I * 20, 8 + I * 20, 48, 48),
          Image);
        Items.addObject(Item);
        Item.release;
      end;
    end;
    if Items.count = 0 then Exit;
    Session := AView.beginDraggingSessionWithItems_event_source(Items, AEvent,
      NSDraggingSourceProtocol(GSource));
    if Session = nil then Exit;
    GActive := True;
  finally
    Items.release;
  end;
end;

finalization
  ReleaseDragState;
  FreeAndNil(GStaged);

end.
