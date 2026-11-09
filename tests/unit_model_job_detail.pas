program unit_model_job_detail;
{$mode objfpc}{$H+}
{ The busy card reads TZJob.SnapshotDetail, not the bridge sink directly.
  Pin that the job layer really copies the ABI-v4 item data into its locked
  snapshot: phase, item count, current name and a plausible item index. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.api.bind, tzip.engine, tzip.jobs;

var
  Fails, Passes: Integer;
  Root: string;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure WriteBlob(const APath: string; ASize: Integer);
var
  F: TFileStream;
  Buf: array[0..65535] of Byte;
  Left: Integer;
  I: Integer;
begin
  for I := Low(Buf) to High(Buf) do Buf[I] := Byte((I * 31) and $FF);
  F := TFileStream.Create(APath, fmCreate);
  try
    Left := ASize;
    while Left > 0 do
    begin
      if Left >= SizeOf(Buf) then
      begin
        F.WriteBuffer(Buf, SizeOf(Buf));
        Dec(Left, SizeOf(Buf));
      end
      else
      begin
        F.WriteBuffer(Buf, Left);
        Left := 0;
      end;
    end;
  finally
    F.Free;
  end;
end;

function Settings: TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := 'zip';
  Result.Level := 1;
end;

procedure TestSnapshotDetail;
var
  J: TZJob;
  Src: TStringList;
  Info: TZJobProgressDetail;
  Done, Total: QWord;
  Detail, Err: string;
  I, R: Integer;
  Found: Boolean;
  OutPath: string;
begin
  OutPath := Root + '/detail.zip';
  Src := TStringList.Create;
  ForceDirectories(Root + '/src');
  for I := 0 to 7 do
  begin
    WriteBlob(Root + '/src/d' + IntToStr(I) + '.bin', 4 * 1024 * 1024);
    Src.Add(Root + '/src/d' + IntToStr(I) + '.bin');
  end;
  J := TZJob.Create(jkCreate);
  try
    J.Path := OutPath;
    J.Sources := Src;
    J.Settings := Settings;
    J.Start;
    Found := False;
    for I := 1 to 1000 do
    begin
      if not J.Snapshot(Done, Total, Detail) then Break;
      if J.SnapshotDetail(Info) and (Info.ItemCount > 0) and (Info.ItemName <> '') then
      begin
        Found := True;
        Break;
      end;
      Sleep(5);
    end;
    Check(Found, 'detail: a snapshot with an item name is observable');
    if Found then
    begin
      Check(Info.Phase = TZ7Z_PH_CREATE, 'detail: phase is create');
      Check(Info.ItemCount = 8, 'detail: item count is the input count');
      Check(Info.ItemIndex < Info.ItemCount, 'detail: item index is in range');
      Check(Info.ItemName <> '', 'detail: current name is copied');
    end;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'detail: job reports a result');
    Check(R = TZ7Z_OK, 'detail: job completes (' + Err + ')');
  finally
    J.Free;
  end;
end;

procedure Cleanup;
var
  I: Integer;
begin
  for I := 0 to 7 do
    DeleteFile(Root + '/src/d' + IntToStr(I) + '.bin');
  RemoveDir(Root + '/src');
  DeleteFile(Root + '/detail.zip');
  RemoveDir(Root);
end;

begin
  Fails := 0;
  Passes := 0;
  if not TzLoadLibrary('') then
  begin
    WriteLn('FAIL setup: the engine library loads: ', TzEngineMissingError);
    Halt(1);
  end;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'tyzip-job-detail-' + IntToStr(GetProcessID);
  ForceDirectories(Root);
  try
    TestSnapshotDetail;
  finally
    Cleanup;
  end;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
