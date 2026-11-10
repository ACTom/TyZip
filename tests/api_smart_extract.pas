program api_smart_extract;
{$mode objfpc}{$H+}
{ Smart extraction of a wrapper archive, and the staged-tree commit.

  A .tar.gz documented by api_formats extracts to ONE bare .tar file. Smart
  extraction must not do that: it lists and extracts through the inner tar and
  finally strips the single top-level folder while committing the staged tree.
  Everything here uses real archives on disk, no mocks. }
uses
  SysUtils, Classes, Process, tzip.api, tzip.engine, tzip.extract;

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

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant]));
  end;
end;

procedure DelTree(const P: string);
begin
  if P = '' then Exit;
  ExecuteProcess('/bin/rm', ['-rf', P]);
end;

function ReadText(const P: string): string;
var
  S: TStringList;
begin
  Result := '';
  if not FileExists(P) then Exit;
  S := TStringList.Create;
  try
    S.LoadFromFile(P);
    Result := S.Text;
  finally S.Free; end;
end;

procedure WriteText(const P, AText: string);
var
  S: TStringList;
begin
  ForceDirectories(ExtractFileDir(P));
  S := TStringList.Create;
  try
    S.Text := AText;
    S.SaveToFile(P);
  finally S.Free; end;
end;

function MakeSettings(const AFmt: string): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := AFmt;
  Result.Level := 5;
end;

{ The wrapper every test works on: photos.tar.gz holding photos/a.txt and
  photos/sub/b.txt. Built through the same input collector the UI uses. }
function BuildWrapper(out AArchive: string): Boolean;
var
  S: TCreateSettings;
  Src: TStringList;
  Set1: TZInputSet;
  Err: string;
begin
  Result := False;
  AArchive := Root + '/photos.tar.gz';
  WriteText(Root + '/src/photos/a.txt', 'alpha');
  WriteText(Root + '/src/photos/sub/b.txt', 'beta');
  Src := TStringList.Create;
  Set1 := Default(TZInputSet);
  try
    Src.Add(Root + '/src/photos');
    Set1 := TzCollectInputs(Src, '');
    S := MakeSettings('gzip');
    Err := '';
    Result := TzCreateArchive(AArchive, S, Set1.Recs, Err) = TZ7Z_OK;
    if not Result then
      WriteLn('FAIL fixture: gzip archive (', Err, ')');
  finally
    TzInputSetFree(Set1);
    Src.Free;
  end;
end;

{ List the wrapper the way the batch flow does, and hand back entries plus the
  engine indices they came from. }
function ListWrapper(const AArchive: string; out AEntries: TExtractEntryArray;
  out AIndices: TLongWordArray): Boolean;
var
  Listing: TListing;
  I: Integer;
begin
  Result := TzListArchiveByPath(AArchive, '', Listing) = TZ7Z_OK;
  SetLength(AEntries, Length(Listing));
  SetLength(AIndices, Length(Listing));
  for I := 0 to High(Listing) do
  begin
    AEntries[I].Name := Listing[I].Name;
    AEntries[I].IsDir := Listing[I].IsDir;
    AIndices[I] := Listing[I].EntryIndex;
  end;
  Result := Result and (Length(Listing) > 0);
end;

procedure TestWrapperExtractsInnerTree;
var
  Archive, Staging, Final, Err: string;
  Entries: TExtractEntryArray;
  Indices: TLongWordArray;
  Plan: TSmartPlan;
begin
  if not BuildWrapper(Archive) then Exit;
  Check(ListWrapper(Archive, Entries, Indices), 'wrapper: list through the inner tar');

  Plan := TzSmartPlan(Archive, Root + '/out', Entries);
  Check(Plan.Layout = slStripOneRoot, 'wrapper: one root folder strips');
  EqStr(Plan.Root, 'photos', 'wrapper: root is the tar folder');

  Staging := Root + '/staging';
  DelTree(Staging);
  ForceDirectories(Staging);
  Err := '';
  Check(TzExtractInContext(Archive, '', Indices, Staging, Err) = TZ7Z_OK,
    'wrapper: context extraction succeeds (' + Err + ')');
  Check(FileExists(Staging + '/photos/a.txt'),
    'wrapper: the inner tar tree is extracted');
  Check(FileExists(Staging + '/photos/sub/b.txt'),
    'wrapper: nested file inside the tar');
  { The whole point: no bare .tar file lands instead of the tree. }
  Check(not FileExists(Staging + '/photos.tar'),
    'wrapper: no bare .tar file');
  Check(not FileExists(Staging + '/' + ExtractFileName(Archive)),
    'wrapper: the wrapper itself was not unpacked as one stream');

  Final := Root + '/final';
  DelTree(Final);
  Check(TzCommitStagedTree(Staging, Final, Plan.Root, True),
    'wrapper: commit the staged tree');
  EqStr(Trim(ReadText(Final + '/a.txt')), 'alpha', 'wrapper: flattened file');
  EqStr(Trim(ReadText(Final + '/sub/b.txt')), 'beta',
    'wrapper: flattened nested file');
  Check(not DirectoryExists(Final + '/photos'),
    'wrapper: the stripped root folder is gone');
end;

procedure TestCommitRules;
var
  Staging, Dest: string;
begin
  { Replace is explicit: the caller resolved "overwrite" before extracting. }
  Staging := Root + '/stage-replace';
  Dest := Root + '/dest-replace';
  DelTree(Staging);
  DelTree(Dest);
  WriteText(Staging + '/a.txt', 'new');
  WriteText(Dest + '/a.txt', 'old');
  Check(TzCommitStagedTree(Staging, Dest, '', True), 'commit: replace succeeds');
  EqStr(Trim(ReadText(Dest + '/a.txt')), 'new', 'commit: existing file replaced');

  { Without replace, a collision fails instead of silently replacing. }
  Staging := Root + '/stage-keep';
  Dest := Root + '/dest-keep';
  DelTree(Staging);
  DelTree(Dest);
  WriteText(Staging + '/a.txt', 'new');
  WriteText(Dest + '/a.txt', 'old');
  Check(not TzCommitStagedTree(Staging, Dest, '', False),
    'commit: collision without replace fails');
  EqStr(Trim(ReadText(Dest + '/a.txt')), 'old', 'commit: existing file preserved');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL engine library');
    Halt(2);
  end;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-smart-' +
    IntToStr(GetProcessID);
  DelTree(Root);
  ForceDirectories(Root);

  TestWrapperExtractsInnerTree;
  TestCommitRules;

  DelTree(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
