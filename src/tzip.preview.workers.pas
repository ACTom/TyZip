{ The two background workers of the preview pane.

  Both were declared and implemented inside tzip.main, where they could only be
  exercised by opening the GUI:

  - TImageLoadThread decodes one image file off the UI thread, refusing a picture
    whose header says it would not fit the preview's pixel budget.
  - TPreviewLoaderThread extracts one archive entry to a temp file off the UI
    thread, because a solid archive can take seconds even for a small entry.

  They own no widget: a lock, their inputs, the result and a done flag. The pane
  keeps the lifecycle rules (retire instead of waiting, reap when finished, free
  the temp file).

  Layer: UI-adjacent (BGRA for decoding). Not headless. }
unit tzip.preview.workers;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, BGRABitmap, BGRABitmapTypes, tzip.api;

type
  { Extracts one entry of an archive to AOutFile. The caller polls TakeResult and
    removes the file when it is superseded.

    AMaxBytes > 0 stops the decoder at that many bytes and treats the prefix as a
    success: the text/unknown preview never has to materialise a 100 MB log entry.
    Images pass 0 (the full entry), because the decoder needs all of it and the
    32 MB size budget already guards that path. }
  TPreviewLoaderThread = class(TThread)
  private
    FLock: TCriticalSection;
    FSourcePath: string;
    FPassword: string;
    FOutFile: string;
    FEntryName: string;
    FEntryIndex: Integer;
    FGeneration: Integer;
    FMaxBytes: QWord;
    FDone: Boolean;
    FResult: Integer;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASourcePath, APassword, AOutFile, AEntryName: string;
      AEntryIndex, AGeneration: Integer; AMaxBytes: QWord = 0);
    destructor Destroy; override;
    function TakeResult(out AResult: Integer; out AError: string;
      out AGeneration: Integer): Boolean;
    property OutFile: string read FOutFile;
    property EntryName: string read FEntryName;
  end;

  { Decodes one image file off the UI thread. The generation number names the
    request, so a result that has been superseded is dropped without touching the
    viewer. ATooLarge means the header size does not fit the preview budget, so
    nothing was decoded. }
  TImageLoadThread = class(TThread)
  private
    FLock: TCriticalSection;
    FPath: string;
    FGeneration: Integer;
    FBitmap: TBGRABitmap;
    FDone: Boolean;
    FFailed: Boolean;
    FTooLarge: Boolean;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string; AGeneration: Integer);
    destructor Destroy; override;
    { Hands the decoded bitmap to the caller once. False while still decoding. }
    function TakeResult(out ABitmap: TBGRABitmap; out AFailed, ATooLarge: Boolean;
      out AError: string): Boolean;
    property Generation: Integer read FGeneration;
  end;

implementation

uses
  tzip.imageinfo;

{ TPreviewLoaderThread }

constructor TPreviewLoaderThread.Create(const ASourcePath, APassword, AOutFile,
  AEntryName: string; AEntryIndex, AGeneration: Integer; AMaxBytes: QWord);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FSourcePath := ASourcePath;
  FPassword := APassword;
  FOutFile := AOutFile;
  FEntryName := AEntryName;
  FEntryIndex := AEntryIndex;
  FGeneration := AGeneration;
  FMaxBytes := AMaxBytes;
  Start;
end;

destructor TPreviewLoaderThread.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TPreviewLoaderThread.Execute;
var
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  A := nil;
  { A request that was cancelled before this thread got the CPU should not do the
    extraction at all. (Once TzExtractOne is running it cannot be interrupted;
    the caller no longer waits for it.) }
  if Terminated then
  begin
    FLock.Enter;
    try
      FResult := TZ7Z_E_CANCEL;
      FError := '';
      FDone := True;
    finally
      FLock.Leave;
    end;
    Exit;
  end;
  try
    try
      R := TzOpenArchive(FSourcePath, FPassword, A, Err);
      if R = TZ7Z_OK then
      begin
        if FMaxBytes > 0 then
          { A prefix is a complete answer here: the viewer only shows this much
            and the file on disk is exactly what it reads. }
          R := TzExtractOnePrefix(A, FEntryIndex, FOutFile, FPassword,
            FMaxBytes, Err)
        else
          R := TzExtractOne(A, FEntryIndex, FOutFile, FPassword, Err);
      end;
    except
      on E: Exception do
      begin
        R := TZ7Z_E_EXTRACT;
        Err := E.Message;
      end;
    end;
  finally
    A.Free;
  end;
  FLock.Enter;
  try
    FResult := R;
    FError := Err;
    FDone := True;
  finally
    FLock.Leave;
  end;
end;

function TPreviewLoaderThread.TakeResult(out AResult: Integer;
  out AError: string; out AGeneration: Integer): Boolean;
begin
  FLock.Enter;
  try
    Result := FDone;
    if Result then
    begin
      AResult := FResult;
      AError := FError;
      AGeneration := FGeneration;
      FDone := False;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TImageLoadThread }

constructor TImageLoadThread.Create(const APath: string; AGeneration: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FPath := APath;
  FGeneration := AGeneration;
  FBitmap := nil;
  FDone := False;
  FFailed := False;
  FTooLarge := False;
  Start;
end;

destructor TImageLoadThread.Destroy;
begin
  if FBitmap <> nil then FBitmap.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TImageLoadThread.Execute;
var
  B: TBGRABitmap;
  Failed, TooLarge: Boolean;
  Err: string;
  Dim: TPoint;
begin
  B := nil;
  Failed := False;
  TooLarge := False;
  Err := '';
  try
    try
      { Read the DECODED size from the file header first. The compressed bytes can
        be tiny -- a flat 30k x 30k PNG is a few hundred KB -- while decoding it
        would allocate gigabytes, and the viewer then copies it again for the
        control. Refusing it here costs a header read and keeps the process
        alive.

        Only a size the header actually reported is judged: formats whose header
        reader is missing still go through the decoder, as they always did. }
      Dim := GetImageSizeInFile(FPath);
      if (Dim.X > 0) and (Dim.Y > 0) and (not PreviewImageFits(Dim.X, Dim.Y)) then
      begin
        Failed := True;
        TooLarge := True;
        Err := 'image too large';
      end
      else
      begin
        B := TBGRABitmap.Create(FPath);
        if (B.Width <= 0) or (B.Height <= 0) then
        begin
          B.Free;
          B := nil;
          Failed := True;
          Err := 'empty image';
        end
        else if not PreviewImageFits(B.Width, B.Height) then
        begin
          { A decoder that reports a different size than its header claimed. }
          B.Free;
          B := nil;
          Failed := True;
          TooLarge := True;
          Err := 'image too large';
        end;
      end;
    except
      on E: Exception do
      begin
        B := nil;
        Failed := True;
        Err := E.Message;
      end;
    end;
  finally
    FLock.Enter;
    try
      FBitmap := B;
      FFailed := Failed;
      FTooLarge := TooLarge;
      FErrorText := Err;
      FDone := True;
    finally
      FLock.Leave;
    end;
  end;
end;

function TImageLoadThread.TakeResult(out ABitmap: TBGRABitmap;
  out AFailed, ATooLarge: Boolean; out AError: string): Boolean;
begin
  ABitmap := nil;
  AFailed := False;
  ATooLarge := False;
  AError := '';
  Result := False;
  FLock.Enter;
  try
    if not FDone then Exit;
    ABitmap := FBitmap;
    FBitmap := nil;
    AFailed := FFailed;
    ATooLarge := FTooLarge;
    AError := FErrorText;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

end.
