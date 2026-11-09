program api_progress_sink;
{$mode objfpc}{$H+}
{ ABI v4 detailed progress through the real bridge.

  Pins the contract the UI will consume:
    - create/extract emit ITEM and ITEM_DONE events with the UTF-8 entry name;
    - the old Tick still fires through the default Progress implementation;
    - SetRatioInfo is surfaced as packed_known;
    - a refusing sink cancels the operation.

  The bridge must not depend on LCL; this test only uses tzip.api. }
uses
  SysUtils, Classes, tzip.api, tzip.api.bind, tzip.engine;

var
  Fails, Passes: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

procedure WriteText(const APath, AText: string);
var L: TStringList;
begin
  L := TStringList.Create;
  try L.Text := AText; L.SaveToFile(APath); finally L.Free; end;
end;

type
  TProbeSink = class(TZ7ZProgressSink)
  public
    TickCalls, OpenTicks, ItemCalls, DoneCalls: Integer;
    Refuse: Boolean;
    PackedSeen: Boolean;
    Phases: Integer;
    Names: TStringList;
    constructor Create;
    destructor Destroy; override;
    function Tick(Completed, Total: QWord): Boolean; override;
    function Progress(const AInfo: tzip.api.TZ7ZProgressInfo): Boolean; override;
  end;

constructor TProbeSink.Create;
begin
  inherited Create;
  Names := TStringList.Create;
end;

destructor TProbeSink.Destroy;
begin
  Names.Free;
  inherited Destroy;
end;

function TProbeSink.Tick(Completed, Total: QWord): Boolean;
begin
  Inc(TickCalls);
  Result := not Refuse;
end;

function TProbeSink.Progress(const AInfo: tzip.api.TZ7ZProgressInfo): Boolean;
begin
  if AInfo.Phase = 0 then Inc(OpenTicks)
  else Phases := AInfo.Phase;
  case AInfo.Event of
    tzip.api.bind.TZ7Z_EV_ITEM:
      begin
        Inc(ItemCalls);
        if AInfo.Name <> '' then Names.Add(AInfo.Name);
      end;
    tzip.api.bind.TZ7Z_EV_ITEM_DONE:
      Inc(DoneCalls);
  end;
  if AInfo.PackedKnown then PackedSeen := True;
  if Refuse then Exit(False);
  Result := inherited Progress(AInfo);
end;

function MakeInputs(out AList: TStringList): TZInputSet;
var
  I: Integer;
begin
  ForceDirectories(Root + '/src');
  AList := TStringList.Create;
  for I := 0 to 1 do
  begin
    WriteText(Root + '/src/f' + IntToStr(I) + '.txt',
      'payload ' + IntToStr(I) + LineEnding + StringOfChar('x', 4096));
    AList.Add(Root + '/src/f' + IntToStr(I) + '.txt');
  end;
  Result := TzCollectInputs(AList, '');
end;

function Settings: TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := 'zip';
  Result.Level := 1;
end;

procedure TestCreateExtract;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  A: TTzArchive;
  Err, Zip: string;
  CreateSink, ExtractSink, OpenSink: TProbeSink;
  R: Integer;
begin
  Zip := Root + '/progress.zip';
  L := nil;
  Set1 := MakeInputs(L);
  try
    S := Settings;
    CreateSink := TProbeSink.Create;
    try
      R := TzCreate(Zip, S, Set1.Recs, Err, CreateSink);
      EqInt(R, TZ7Z_OK, 'create succeeds (' + Err + ')');
      Check(FileExists(Zip), 'create: archive exists');
      Check(CreateSink.TickCalls > 0, 'create: legacy Tick still fires');
      Check(CreateSink.ItemCalls >= 2, 'create: item events for both files');
      Check(CreateSink.DoneCalls >= 2, 'create: item-done events for both files');
      Check(CreateSink.Names.IndexOf('f0.txt') >= 0, 'create: first item name');
      Check(CreateSink.Names.IndexOf('f1.txt') >= 0, 'create: second item name');
      Check(CreateSink.PackedSeen, 'create: SetRatioInfo surfaced as packed bytes');
    finally CreateSink.Free; end;
  finally
    TzInputSetFree(Set1);
    L.Free;
  end;

  A := nil;
  OpenSink := TProbeSink.Create;
  try
    R := TzOpenArchive(Zip, '', A, Err, OpenSink);
    EqInt(R, TZ7Z_OK, 'open succeeds (' + Err + ')');
    Check(A <> nil, 'open: archive handle');
    Check(OpenSink.OpenTicks > 0, 'open: handler reports header progress');
    if OpenSink.ItemCalls > 0 then
      Check(OpenSink.Phases = tzip.api.bind.TZ7Z_PH_OPEN,
        'open: item events carry the open phase');
  finally
    A.Free;
    OpenSink.Free;
  end;

  A := nil;
  if TzOpenArchive(Zip, '', A, Err) <> TZ7Z_OK then
  begin
    Check(False, 'extract setup: open failed');
    Exit;
  end;
  ExtractSink := TProbeSink.Create;
  try
    ForceDirectories(Root + '/out');
    R := TzExtract(A, [], Root + '/out', '', Err, ExtractSink);
    EqInt(R, TZ7Z_OK, 'extract succeeds (' + Err + ')');
    Check(ExtractSink.ItemCalls >= 2, 'extract: item events for both files');
    Check(ExtractSink.DoneCalls >= 2, 'extract: item-done events for both files');
    Check(ExtractSink.Names.IndexOf('f0.txt') >= 0, 'extract: first item name');
    Check(ExtractSink.Names.IndexOf('f1.txt') >= 0, 'extract: second item name');
    Check(FileExists(Root + '/out/f0.txt'), 'extract: first file written');
    Check(FileExists(Root + '/out/f1.txt'), 'extract: second file written');
  finally
    ExtractSink.Free;
    A.Free;
  end;
end;

procedure TestRefusingSinkCancels;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err, Zip: string;
  Sink: TProbeSink;
  R: Integer;
begin
  Zip := Root + '/cancelled.zip';
  L := nil;
  Set1 := MakeInputs(L);
  try
    S := Settings;
    Sink := TProbeSink.Create;
    try
      Sink.Refuse := True;
      R := TzCreate(Zip, S, Set1.Recs, Err, Sink);
      EqInt(R, TZ7Z_E_CANCEL, 'cancel: refusing sink cancels the create');
      Check(Sink.ItemCalls + Sink.TickCalls > 0, 'cancel: the sink was consulted');
    finally Sink.Free; end;
  finally
    TzInputSetFree(Set1);
    L.Free;
  end;
end;

procedure Cleanup;
begin
  if DirectoryExists(Root) then
  begin
    DeleteFile(Root + '/progress.zip');
    DeleteFile(Root + '/cancelled.zip');
    DeleteFile(Root + '/src/f0.txt');
    DeleteFile(Root + '/src/f1.txt');
    DeleteFile(Root + '/out/f0.txt');
    DeleteFile(Root + '/out/f1.txt');
    RemoveDir(Root + '/out');
    RemoveDir(Root + '/src');
    RemoveDir(Root);
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL setup: engine library loads: ', TzEngineMissingError);
    Halt(1);
  end;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'tyzip-progress-sink-' + IntToStr(GetProcessID);
  ForceDirectories(Root);
  try
    TestCreateExtract;
    TestRefusingSinkCancels;
  finally
    Cleanup;
  end;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
