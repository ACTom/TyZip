program unit_model_openprogress;
{$mode objfpc}{$H+}
{ Opening an archive is a determinate operation once 7-Zip has parsed the
  header: the entry count is known before the per-entry metadata walk starts.
  This pins the contract the busy card relies on:
    - the sink sees a monotone 1..N walk whose total is the final entry count;
    - a refused tick cancels the open and hands back no context.

  Before the sink existed, TZJobExecutor.OpenJob called SetProgress(0, 0), so
  even a 10k-entry archive showed an indeterminate spinner while the worker
  read every entry. }
uses
  SysUtils, Classes, tzip.api, tzip.engine;

var
  Fails, Passes: Integer;
  Root: string;
  I: Integer;

const
  TestFiles = 300;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

type
  TProbeSink = class(TZ7ZProgressSink)
  public
    Calls: Integer;
    LastDone, LastTotal: QWord;
    RefuseAt: Integer;
    Monotone: Boolean;
    function Tick(Completed, Total: QWord): Boolean; override;
  end;

function TProbeSink.Tick(Completed, Total: QWord): Boolean;
begin
  Inc(Calls);
  if (Calls > 1) and ((Completed <= LastDone) or (Total <> LastTotal)) then
    Monotone := False;
  if (Calls = 1) and (Total = 0) then Monotone := False;
  LastDone := Completed;
  LastTotal := Total;
  Result := (RefuseAt = 0) or (Calls < RefuseAt);
end;

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally
    L.Free;
  end;
end;

{ Ten entries is enough to exercise the loop and the final tick; the point is
  the contract, not the size. }
function MakeArchive: string;
var
  I: Integer;
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
begin
  Result := Root + '/openprogress.zip';
  DeleteFile(Result);
  L := TStringList.Create;
  try
    for I := 0 to TestFiles - 1 do
    begin
      WriteText(Root + '/in/f' + IntToStr(I) + '.txt', 'payload ' + IntToStr(I));
      L.Add(Root + '/in/f' + IntToStr(I) + '.txt');
    end;
    S := Default(TCreateSettings);
    S.FormatName := 'zip';
    S.Level := 1;
    Set1 := TzCollectInputs(L, '');
    try
      if TzCreateArchive(Result, S, Set1.Recs, Err) <> TZ7Z_OK then
      begin
        WriteLn('setup: create failed: ', Err);
        Result := '';
      end;
    finally
      TzInputSetFree(Set1);
    end;
  finally
    L.Free;
  end;
end;

procedure TestProgressReachesTotal;
var
  Ctx: TArchiveContext;
  Sink: TProbeSink;
  Err: string;
  Path: string;
  R: Integer;
begin
  Path := MakeArchive;
  if Path = '' then
  begin
    Check(False, 'progress: setup failed');
    Exit;
  end;
  Ctx := nil;
  Sink := TProbeSink.Create;
  try
    Sink.Monotone := True;
    R := TzOpenContext(Path, 'openprogress.zip', '', nil, False, Path, Ctx, Err, Sink);
    EqInt(R, TZ7Z_OK, 'progress: open succeeds');
    Check(Ctx <> nil, 'progress: context returned');
    if Ctx <> nil then
      EqInt(Sink.LastTotal, Length(Ctx.Entries), 'progress: total is the entry count');
    EqInt(Integer(Sink.LastDone), Integer(Sink.LastTotal), 'progress: ends at 100%');
    Check(Sink.Calls > 0, 'progress: sink was called');
    Check(Sink.Calls < Length(Ctx.Entries),
      'progress: updates are throttled, not one per entry');
    Check(Sink.Monotone, 'progress: monotone completed, constant total');
  finally
    Ctx.Free;
    Sink.Free;
  end;
end;

procedure TestCancelDuringEnumeration;
var
  Ctx: TArchiveContext;
  Sink: TProbeSink;
  Err: string;
  Path: string;
  R: Integer;
begin
  Path := MakeArchive;
  if Path = '' then
  begin
    Check(False, 'cancel: setup failed');
    Exit;
  end;
  Ctx := nil;
  Sink := TProbeSink.Create;
  try
    Sink.RefuseAt := 1;
    R := TzOpenContext(Path, 'openprogress.zip', '', nil, False, Path, Ctx, Err, Sink);
    EqInt(R, TZ7Z_E_CANCEL, 'cancel: refused tick returns TZ7Z_E_CANCEL');
    Check(Ctx = nil, 'cancel: no half-built context escapes');
    EqInt(Sink.Calls, 1, 'cancel: stops at the refused tick');
  finally
    Ctx.Free;
    Sink.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL setup: the engine library loads');
    Halt(1);
  end;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'tyzip-openprogress-' + IntToStr(GetProcessID);
  ForceDirectories(Root);
  try
    TestProgressReachesTotal;
    TestCancelDuringEnumeration;
  finally
    if DirectoryExists(Root) then
    begin
      DeleteFile(Root + '/openprogress.zip');
      for I := 0 to TestFiles - 1 do
        DeleteFile(Root + '/in/f' + IntToStr(I) + '.txt');
      RemoveDir(Root + '/in');
      RemoveDir(Root);
    end;
  end;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
