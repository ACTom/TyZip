program api_model_search;
{$mode objfpc}{$H+}
{ Content search through the real engine: the dialog has always offered
  "Contents" and "Names and contents", but the model layer only ever matched
  names, so those choices silently returned nothing. A search result must also
  stay sorted by path. }
uses
  SysUtils, Classes, tzip.api, tzip.engine, tzip.search;

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

procedure TestSearch;
var
  Ctx: TArchiveContext;
  Err, Name: string;
  R: Integer;
  Listing: TListing;
begin
  DeleteFile(Root + '/search.zip');
  if not MakeZip(Root + '/search.zip') then
  begin
    Check(False, 'search: setup failed');
    Exit;
  end;
  Ctx := nil;
  R := TzOpenContext(Root + '/search.zip', 'search.zip', '', nil, False, '',
    Ctx, Err);
  Check(R = TZ7Z_OK, 'search: the archive opens (' + Err + ')');
  if Ctx = nil then Exit;
  try
    { Names only: the word lives in the contents, not in a name. }
    Listing := TzSearchListing(Ctx, SearchOptions('needle', ssName));
    EqInt(Length(Listing), 0, 'name scope: no entry is called needle');

    { Contents: both files whose text carries the word are found. }
    Listing := TzSearchListing(Ctx, SearchOptions('needle', ssContent));
    EqInt(Length(Listing), 2, 'content scope: both matching files');
    Check((Length(Listing) = 2) and (Listing[0].FullPath < Listing[1].FullPath),
      'content scope: results are ordered by path');
    Check((Length(Listing) > 0) and (Listing[0].EntryIndex >= 0),
      'content scope: hits carry an entry index');

    { "Names and contents" is the union, and must not report duplicates. }
    Listing := TzSearchListing(Ctx, SearchOptions('notes', ssBoth));
    EqInt(Length(Listing), 1, 'both scope: name hit');
    if Length(Listing) = 1 then
    begin
      Name := Listing[0].Name;
      Check(Name = 'notes.txt', 'both scope: the right entry');
    end;
    Listing := TzSearchListing(Ctx, SearchOptions('needle', ssBoth));
    EqInt(Length(Listing), 2, 'both scope: content hits');

    { A query that matches nothing anywhere. }
    Listing := TzSearchListing(Ctx, SearchOptions('absent-word', ssBoth));
    EqInt(Length(Listing), 0, 'both scope: a miss is a miss');

    { An empty query finds nothing rather than everything. }
    Listing := TzSearchListing(Ctx, SearchOptions('', ssBoth));
    EqInt(Length(Listing), 0, 'both scope: empty query matches nothing');
  finally
    Ctx.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-search-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  TestSearch;

  if FileExists(Root + '/search.zip') then DeleteFile(Root + '/search.zip');
  if FileExists(Root + '/src/notes.txt') then DeleteFile(Root + '/src/notes.txt');
  if FileExists(Root + '/src/other.txt') then DeleteFile(Root + '/src/other.txt');
  if FileExists(Root + '/src/sub/deep.txt') then DeleteFile(Root + '/src/sub/deep.txt');
  if DirectoryExists(Root + '/src/sub') then RemoveDir(Root + '/src/sub');
  if DirectoryExists(Root + '/src') then RemoveDir(Root + '/src');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
