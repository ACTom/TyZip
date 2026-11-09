program api_model_listbypath;
{$mode objfpc}{$H+}
{ Listing a whole archive from its path, for a worker that must not touch the
  UI's context.

  Pinned here: every entry becomes one row (no ".." row), rows are sorted by
  path, entry indexes point back at the archive, a compound .tar.gz is opened
  through its wrapper, a refused progress tick cancels without a partial
  listing, and jkList takes this path when it has a path but no snapshot. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.engine, tzip.jobs;

var
  Fails, Passes: Integer;
  Root: string;

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

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally
    L.Free;
  end;
end;

function MakeArchive(const APath, AFormat: string): Boolean;
var
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
begin
  Result := False;
  ForceDirectories(Root + '/src/sub');
  WriteText(Root + '/src/alpha.txt', 'alpha' + LineEnding);
  WriteText(Root + '/src/beta.txt', 'beta' + LineEnding);
  WriteText(Root + '/src/sub/gamma.txt', 'gamma' + LineEnding);
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    Disk.Add(Root + '/src/alpha.txt');
    Arc.Add('alpha.txt');
    Disk.Add(Root + '/src/beta.txt');
    Arc.Add('beta.txt');
    Disk.Add(Root + '/src/sub/gamma.txt');
    Arc.Add('sub/gamma.txt');
    Set1 := TzCollectInputsMapped(Disk, Arc);
    try
      S := Default(TCreateSettings);
      S.FormatName := AFormat;
      S.Level := 1;
      S.ForceUtf8 := True;
      if TzCreateArchive(APath, S, Set1.Recs, Err) <> TZ7Z_OK then
      begin
        WriteLn('setup: cannot create ', APath, ': ', Err);
        Exit;
      end;
    finally
      TzInputSetFree(Set1);
    end;
    Result := FileExists(APath);
  finally
    Arc.Free;
    Disk.Free;
  end;
end;

type
  TRefuseSink = class(TZ7ZProgressSink)
  public
    Ticks: Integer;
    function Tick(Completed, Total: QWord): Boolean; override;
  end;

function TRefuseSink.Tick(Completed, Total: QWord): Boolean;
begin
  Inc(Ticks);
  Result := False;
end;

procedure CheckSorted(const AListing: TListing; const AMsg: string);
var
  I: Integer;
begin
  for I := 1 to High(AListing) do
    if AListing[I - 1].FullPath > AListing[I].FullPath then
    begin
      Check(False, AMsg + ': rows are sorted by path');
      Exit;
    end;
  Check(True, AMsg + ': rows are sorted by path');
end;

procedure TestNormal;
var
  R: Integer;
  Listing: TListing;
  AllEntries: Boolean;
  I: Integer;
begin
  R := TzListArchiveByPath(Root + '/plain.7z', '', Listing);
  Check(R = TZ7Z_OK, 'plain: succeeds');
  EqInt(Length(Listing), 3, 'plain: every entry is a row');
  CheckSorted(Listing, 'plain');
  AllEntries := True;
  for I := 0 to High(Listing) do
  begin
    if Listing[I].IsParent then AllEntries := False;
    if Listing[I].EntryIndex < 0 then AllEntries := False;
    if Listing[I].FullPath = '' then AllEntries := False;
  end;
  Check(AllEntries, 'plain: real rows only, with entry indexes');
end;

procedure TestCompound;
var
  R: Integer;
  Listing: TListing;
begin
  R := TzListArchiveByPath(Root + '/nested.tar.gz', '', Listing);
  Check(R = TZ7Z_OK, 'tar.gz: succeeds');
  EqInt(Length(Listing), 3, 'tar.gz: the inner tar entries are listed');
  CheckSorted(Listing, 'tar.gz');
  if Length(Listing) = 3 then
    Check(Listing[0].FullPath = 'alpha.txt', 'tar.gz: first path');
end;

procedure TestMissing;
var
  R: Integer;
  Listing: TListing;
begin
  R := TzListArchiveByPath(Root + '/absent.7z', '', Listing);
  Check(R <> TZ7Z_OK, 'missing: a missing archive fails');
  EqInt(Length(Listing), 0, 'missing: no listing is delivered');
end;

procedure TestCancel;
var
  R: Integer;
  Listing: TListing;
  Sink: TRefuseSink;
begin
  Sink := TRefuseSink.Create;
  try
    R := TzListArchiveByPath(Root + '/plain.7z', '', Listing, Sink);
    EqInt(R, TZ7Z_E_CANCEL, 'cancel: reported as cancelled');
    EqInt(Length(Listing), 0, 'cancel: no partial listing');
    Check(Sink.Ticks >= 1, 'cancel: the sink was asked');
  finally
    Sink.Free;
  end;
end;

procedure TestJobPathBranch;
var
  J: TZJob;
  R: Integer;
  Err: string;
begin
  J := TZJob.Create(jkList);
  try
    J.Path := Root + '/plain.7z';
    J.Password := '';
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'job: a result is reported');
    EqInt(R, TZ7Z_OK, 'job: listing by path succeeds (' + Err + ')');
    EqInt(Length(J.Listing), 3, 'job: every entry is listed');
    CheckSorted(J.Listing, 'job');
  finally
    J.Free;
  end;
end;

procedure TestJobPathCancel;
var
  J: TZJob;
  R: Integer;
  Err: string;
begin
  J := TZJob.Create(jkList);
  try
    J.Path := Root + '/plain.7z';
    J.RequestCancel;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'job cancel: a result is reported');
    EqInt(R, TZ7Z_E_CANCEL, 'job cancel: cancelled');
    EqInt(Length(J.Listing), 0, 'job cancel: no listing');
  finally
    J.Free;
  end;
end;

var
  PlainOk, NestedOk: Boolean;
begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-listpath-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  Check(TzLoadLibrary(''), 'setup: the engine library loads');

  PlainOk := MakeArchive(Root + '/plain.7z', '7z');
  NestedOk := MakeArchive(Root + '/nested.tar.gz', 'gzip');
  if not PlainOk then Check(False, 'setup: plain archive');
  if not NestedOk then Check(False, 'setup: tar.gz archive');
  if PlainOk then
  begin
    TestNormal;
    TestMissing;
    TestCancel;
    TestJobPathBranch;
    TestJobPathCancel;
  end;
  if NestedOk then TestCompound;

  if FileExists(Root + '/plain.7z') then DeleteFile(Root + '/plain.7z');
  if FileExists(Root + '/nested.tar.gz') then DeleteFile(Root + '/nested.tar.gz');
  if FileExists(Root + '/src/alpha.txt') then DeleteFile(Root + '/src/alpha.txt');
  if FileExists(Root + '/src/beta.txt') then DeleteFile(Root + '/src/beta.txt');
  if FileExists(Root + '/src/sub/gamma.txt') then DeleteFile(Root + '/src/sub/gamma.txt');
  RemoveDir(Root + '/src/sub');
  RemoveDir(Root + '/src');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
