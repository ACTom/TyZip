program api_model_searchjob;
{$mode objfpc}{$H+}
{ Searching a whole archive as background work.

  tzip.engine gains TzSearchArchive: it opens its own context, walks the
  entries, reports one progress tick per entry and stops when the sink says so.
  A cancelled search delivers no partial listing, because a half-walked result
  applied to the UI silently drops hits. The job kind jkSearch only puts that
  function behind the existing worker pipeline. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.engine, tzip.jobs, tzip.search;

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

function MakeZip(const APath: string): Boolean;
var
  L, Disk, Arc: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
begin
  Result := False;
  ForceDirectories(Root + '/src/sub');
  WriteText(Root + '/src/notes.txt', 'the needle is here' + LineEnding);
  WriteText(Root + '/src/other.txt', 'nothing to see' + LineEnding);
  WriteText(Root + '/src/sub/deep.txt', 'another needle inside' + LineEnding);
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  L := TStringList.Create;
  try
    Disk.Add(Root + '/src/notes.txt');
    Arc.Add('notes.txt');
    Disk.Add(Root + '/src/other.txt');
    Arc.Add('other.txt');
    Disk.Add(Root + '/src/sub/deep.txt');
    Arc.Add('sub/deep.txt');
    Set1 := TzCollectInputsMapped(Disk, Arc);
    try
      S := Default(TCreateSettings);
      S.FormatName := 'zip';
      S.Level := 5;
      S.ForceUtf8 := True;
      if TzCreateArchive(APath, S, Set1.Recs, Err) <> TZ7Z_OK then
      begin
        WriteLn('setup: cannot create the archive: ', Err);
        Exit;
      end;
    finally
      TzInputSetFree(Set1);
    end;
    Result := FileExists(APath);
  finally
    L.Free;
    Arc.Free;
    Disk.Free;
  end;
end;

function SearchOptions(const AQuery: string; AScope: TSearchScope): TSearchOptions;
begin
  Result := DefaultSearchOptions(AQuery);
  Result.Scope := AScope;
end;

type
  { Counts ticks and can refuse the first one to simulate a cancel. }
  TCountSink = class(TZ7ZProgressSink)
  public
    Ticks: Integer;
    CancelAt: Integer;   { 0 = never }
    function Tick(Completed, Total: QWord): Boolean; override;
  end;

function TCountSink.Tick(Completed, Total: QWord): Boolean;
begin
  Inc(Ticks);
  Result := (CancelAt = 0) or (Ticks < CancelAt);
end;

function SearchTempDirCount: Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-search-*',
    faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then Inc(Result);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ --- the engine function ------------------------------------------------ }

procedure TestEngineSearch;
var
  R: Integer;
  Listing: TListing;
  Sink: TCountSink;
  TempsBefore, TempsAfter: Integer;
begin
  { Names only: the word lives in the contents, not in a name. }
  R := TzSearchArchive(Root + '/search.zip', '', SearchOptions('needle', ssName),
    Listing);
  Check(R = TZ7Z_OK, 'engine name: succeeds');
  EqInt(Length(Listing), 0, 'engine name: no entry is called needle');

  { Contents are read through the engine, one temp directory per search. }
  TempsBefore := SearchTempDirCount;
  Sink := TCountSink.Create;
  try
    R := TzSearchArchive(Root + '/search.zip', '',
      SearchOptions('needle', ssContent), Listing, Sink);
    Check(R = TZ7Z_OK, 'engine content: succeeds');
    EqInt(Length(Listing), 2, 'engine content: both matching files');
    Check((Length(Listing) = 2) and (Listing[0].FullPath < Listing[1].FullPath),
      'engine content: results are ordered by path');
    Check((Length(Listing) > 0) and (Listing[0].EntryIndex >= 0),
      'engine content: hits carry an entry index');
    Check(Sink.Ticks >= 3, 'engine content: one tick per entry');
  finally
    Sink.Free;
  end;
  TempsAfter := SearchTempDirCount;
  EqInt(TempsAfter, TempsBefore, 'engine content: the temp directory is removed');

  R := TzSearchArchive(Root + '/search.zip', '',
    SearchOptions('notes', ssBoth), Listing);
  EqInt(Length(Listing), 1, 'engine both: name hit');
  if Length(Listing) = 1 then
    Check(Listing[0].Name = 'notes.txt', 'engine both: the right entry');

  R := TzSearchArchive(Root + '/search.zip', '',
    SearchOptions('absent-word', ssBoth), Listing);
  Check(R = TZ7Z_OK, 'engine both: a miss still succeeds');
  EqInt(Length(Listing), 0, 'engine both: a miss is a miss');

  R := TzSearchArchive(Root + '/search.zip', '', SearchOptions('', ssBoth), Listing);
  Check(R = TZ7Z_OK, 'engine both: an empty query succeeds');
  EqInt(Length(Listing), 0, 'engine both: empty query matches nothing');

  { A path that is not an archive fails like any open. }
  R := TzSearchArchive(Root + '/does-not-exist.zip', '',
    SearchOptions('needle', ssBoth), Listing);
  Check(R <> TZ7Z_OK, 'engine: a missing archive fails');
end;

procedure TestEngineCancel;
var
  R: Integer;
  Listing: TListing;
  Sink: TCountSink;
begin
  Sink := TCountSink.Create;
  try
    Sink.CancelAt := 2;
    R := TzSearchArchive(Root + '/search.zip', '',
      SearchOptions('needle', ssBoth), Listing, Sink);
    EqInt(R, TZ7Z_E_CANCEL, 'cancel: reported as cancelled');
    EqInt(Length(Listing), 0, 'cancel: no partial listing is delivered');
    EqInt(Sink.Ticks, 2, 'cancel: the walk stops at the refusing tick');
  finally
    Sink.Free;
  end;
end;

{ --- the job kind ------------------------------------------------------- }

procedure TestJobSearch;
var
  J: TZJob;
  R: Integer;
  Err: string;
  O: TSearchOptions;
begin
  O := SearchOptions('needle', ssContent);
  J := TZJob.Create(jkSearch);
  try
    J.Path := Root + '/search.zip';
    J.DisplayName := 'search.zip';
    J.Password := '';
    J.Options := O;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'job: a result is reported');
    EqInt(R, TZ7Z_OK, 'job: the search succeeds');
    EqInt(Length(J.Listing), 2, 'job: both entries are listed');
    Check(O.Query = J.Options.Query, 'job: the payload kept the query');
    Check(J.Options.Scope = ssContent, 'job: the payload kept the scope');
  finally
    J.Free;
  end;
end;

procedure TestJobCancel;
var
  J: TZJob;
  R: Integer;
  Err: string;
begin
  { Cancel before Start: the very first tick refuses, so the engine stops and
    the job reports a cancel rather than an empty successful search. }
  J := TZJob.Create(jkSearch);
  try
    J.Path := Root + '/search.zip';
    J.Options := SearchOptions('needle', ssBoth);
    J.RequestCancel;
    J.Start;
    J.WaitFor;
    Check(J.TakeResult(R, Err), 'job cancel: a result is reported');
    EqInt(R, TZ7Z_E_CANCEL, 'job cancel: reported as cancelled');
    EqInt(Length(J.Listing), 0, 'job cancel: no partial listing escapes');
  finally
    J.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-searchjob-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  Check(TzLoadLibrary(''), 'setup: the engine library loads');

  if not MakeZip(Root + '/search.zip') then
  begin
    Check(False, 'setup: the sample archive could not be made');
  end
  else
  begin
    TestEngineSearch;
    TestEngineCancel;
    TestJobSearch;
    TestJobCancel;
  end;

  if FileExists(Root + '/search.zip') then DeleteFile(Root + '/search.zip');
  if FileExists(Root + '/src/notes.txt') then DeleteFile(Root + '/src/notes.txt');
  if FileExists(Root + '/src/other.txt') then DeleteFile(Root + '/src/other.txt');
  if FileExists(Root + '/src/sub/deep.txt') then DeleteFile(Root + '/src/sub/deep.txt');
  RemoveDir(Root + '/src/sub');
  RemoveDir(Root + '/src');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
