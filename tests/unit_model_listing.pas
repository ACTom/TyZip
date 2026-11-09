program unit_model_listing;
{$mode objfpc}{$H+}
{ The listing the UI draws: one level of an archive as the user sees it.

  TzListEntries turns the flat entry array into rows -- folders first, each
  folder carrying the totals of everything below it, every column populated from
  its entry -- and honours the filter and the sort order. TzSelectedIndices is
  the other direction: which archive indices a selection in that listing means,
  with folders expanded and the synthetic ".." row ignored.

  The listing tests build the entry array directly, so a failure names the row
  logic rather than archive creation. The selection tests use a small real zip so
  the entry indices are the engine's own. }
uses
  SysUtils, Classes, tzip.api, tzip.engine;

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

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure EqQ(AGot, AWant: QWord; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, Int64(AGot), Int64(AWant)]));
  end;
end;

{ "name;name;name" for a listing, so an order failure is readable. }
function RowNames(const AListing: TListing): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AListing) do
    Result := Result + AListing[I].Name + ';';
end;

function RowByName(const AListing: TListing; const AName: string): TListingItem;
var
  I: Integer;
begin
  Result := Default(TListingItem);
  for I := 0 to High(AListing) do
    if AListing[I].Name = AName then Exit(AListing[I]);
end;

function SampleEntries: TArchiveEntries;
begin
  { docs/ holds two files, sub/ holds one archive and one encrypted file,
    empty/ holds nothing, and two loose files sit at the root. }
  SetLength(Result, 8);

  Result[0] := Default(TArchiveEntry);
  Result[0].Name := 'docs';
  Result[0].IsDir := True;
  Result[0].Index := 0;
  Result[0].MTime := 100;
  Result[0].Attrib := $41ED;

  Result[1] := Default(TArchiveEntry);
  Result[1].Name := 'docs/a.txt';
  Result[1].Size := 100;
  Result[1].PackedSize := 40;
  Result[1].MTime := 200;
  Result[1].CTime := 201;
  Result[1].ATime := 202;
  Result[1].CRC := $11111111;
  Result[1].Attrib := $81A4;
  Result[1].Method := 'Deflate';
  Result[1].Comment := 'first';
  Result[1].NumStreams := 1;
  Result[1].Index := 1;

  Result[2] := Default(TArchiveEntry);
  Result[2].Name := 'docs/b.txt';
  Result[2].Size := 300;
  Result[2].PackedSize := 60;
  Result[2].MTime := 150;
  Result[2].CRC := $22222222;
  Result[2].Index := 2;

  Result[3] := Default(TArchiveEntry);
  Result[3].Name := 'empty';
  Result[3].IsDir := True;
  Result[3].Index := 3;
  Result[3].MTime := 500;

  Result[4] := Default(TArchiveEntry);
  Result[4].Name := 'root.txt';
  Result[4].Size := 50;
  Result[4].PackedSize := 10;
  Result[4].MTime := 300;
  Result[4].CTime := 301;
  Result[4].ATime := 302;
  Result[4].CRC := $33333333;
  Result[4].Attrib := $81A4;
  Result[4].Method := 'Store';
  Result[4].Comment := 'root comment';
  Result[4].NumStreams := 2;
  Result[4].Index := 4;

  Result[5] := Default(TArchiveEntry);
  Result[5].Name := 'sub';
  Result[5].IsDir := True;
  Result[5].Index := 5;
  Result[5].MTime := 50;

  Result[6] := Default(TArchiveEntry);
  Result[6].Name := 'sub/c.zip';
  Result[6].Size := 400;
  Result[6].PackedSize := 200;
  Result[6].MTime := 50;
  Result[6].Index := 6;

  Result[7] := Default(TArchiveEntry);
  Result[7].Name := 'sub/d.bin';
  Result[7].Size := 200;
  Result[7].PackedSize := 20;
  Result[7].MTime := 400;
  Result[7].Encrypted := True;
  Result[7].Index := 7;
end;

{ --- one level, folders first ------------------------------------------- }

procedure TestRootListing;
var
  E: TArchiveEntries;
  L: TListing;
  It: TListingItem;
  I: Integer;
begin
  E := SampleEntries;
  L := TzListEntries(E, '', '', ascName, False);

  EqInt(Length(L), 4, 'root: folders and loose files, not their contents');
  EqStr(RowNames(L), 'docs;empty;sub;root.txt;',
    'root: folders first, then files, each group by name');

  It := RowByName(L, 'docs');
  Check(It.IsDir, 'root: docs is a folder row');
  EqStr(It.FullPath, 'docs', 'root: folder full path');
  EqQ(It.Size, 400, 'root: docs size is the sum of everything below it');
  EqQ(It.PackedSize, 100, 'root: docs packed size is the sum below it');
  { The archive has a real directory entry for docs, so the row points at it. }
  EqInt(It.EntryIndex, 0, 'root: the folder row points at its directory entry');
  Check(not It.IsParent, 'root: TzListEntries never makes a ".." row');

  It := RowByName(L, 'empty');
  Check(It.IsDir, 'root: empty is a folder row');
  EqQ(It.Size, 0, 'root: an empty folder has no size');
  EqInt(It.EntryIndex, 3, 'root: empty folder entry index');

  It := RowByName(L, 'sub');
  Check(It.IsDir, 'root: sub is a folder row');
  EqQ(It.Size, 600, 'root: sub size');
  EqQ(It.PackedSize, 220, 'root: sub packed size');

  { Every column of the one loose file comes from its entry. }
  It := RowByName(L, 'root.txt');
  Check(not It.IsDir, 'root: root.txt is a file row');
  EqStr(It.FullPath, 'root.txt', 'row: full path');
  Check(not It.IsArchive, 'row: a .txt is not an archive');
  Check(not It.Encrypted, 'row: not encrypted');
  Check(not It.IsAnti, 'row: not an anti-item');
  Check(not It.IsParent, 'row: not a parent row');
  EqQ(It.Size, 50, 'row: size');
  EqQ(It.PackedSize, 10, 'row: packed size');
  EqQ(It.MTime, 300, 'row: modified time');
  EqQ(It.CTime, 301, 'row: created time');
  EqQ(It.ATime, 302, 'row: accessed time');
  EqQ(It.CRC, $33333333, 'row: crc');
  EqQ(It.Attrib, $81A4, 'row: attributes');
  EqInt(It.EntryIndex, 4, 'row: entry index');
  EqInt(It.NumStreams, 2, 'row: stream count');
  EqStr(It.Method, 'Store', 'row: method');
  EqStr(It.Comment, 'root comment', 'row: comment');

  for I := 0 to High(L) do
    Check(not L[I].IsParent, 'root: no row is a synthetic parent row');
end;

{ --- a subfolder, its archive and its encrypted entry ------------------- }

procedure TestSubListing;
var
  E: TArchiveEntries;
  L: TListing;
  It: TListingItem;
begin
  E := SampleEntries;
  L := TzListEntries(E, 'sub', '', ascName, False);
  EqInt(Length(L), 2, 'sub: only the folders files');
  EqStr(RowNames(L), 'c.zip;d.bin;', 'sub: sorted by name');

  It := RowByName(L, 'c.zip');
  Check(It.IsArchive, 'sub: a .zip entry is marked as an archive');
  Check(not It.Encrypted, 'sub: c.zip is not encrypted');
  EqStr(It.FullPath, 'sub/c.zip', 'sub: full path carries the folder');

  It := RowByName(L, 'd.bin');
  Check(It.Encrypted, 'sub: the encrypted entry is marked');
  EqInt(It.EntryIndex, 7, 'sub: entry index');

  { A folder that does not exist in the archive lists nothing. }
  L := TzListEntries(E, 'nope', '', ascName, False);
  EqInt(Length(L), 0, 'sub: an unknown folder is empty');
end;

{ --- sorting and filtering ---------------------------------------------- }

procedure TestSorting;
var
  E: TArchiveEntries;
  L: TListing;
begin
  E := SampleEntries;

  { Ascending size: the folder group first, smallest first inside each group. }
  L := TzListEntries(E, '', '', ascSize, False);
  EqStr(RowNames(L), 'empty;docs;sub;root.txt;',
    'sort: size ascending, folders still first');

  { Descending reverses both the key and the name tie-break inside a group. }
  L := TzListEntries(E, '', '', ascName, True);
  EqStr(RowNames(L), 'sub;empty;docs;root.txt;',
    'sort: descending names, folders still first');

  { Modified time: the folder group is still first, then each group's own key. }
  L := TzListEntries(E, '', '', ascModified, False);
  EqStr(RowNames(L), 'sub;docs;empty;root.txt;',
    'sort: modified ascending, folders still first');

  { Filtering is a substring match over the names in THIS folder. }
  L := TzListEntries(E, '', 'sub', ascName, False);
  EqStr(RowNames(L), 'sub;', 'filter: only matching names');
  L := TzListEntries(E, '', 'root', ascName, False);
  EqStr(RowNames(L), 'root.txt;', 'filter: file names match');
  L := TzListEntries(E, '', 'nothing-matches-this', ascName, False);
  EqInt(Length(L), 0, 'filter: no match is an empty listing');

  { No entries at all is an empty listing, not a crash. }
  SetLength(E, 0);
  L := TzListEntries(E, '', '', ascName, False);
  EqInt(Length(L), 0, 'empty: no entries is no rows');
end;

{ --- selection -> archive indices --------------------------------------- }

function WriteText(const APath, AText: string): Boolean;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
    Result := True;
  finally
    L.Free;
  end;
end;

function MakeSelectionZip(const APath: string): Boolean;
var
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
  R: Integer;

  procedure Add(const AName: string);
  begin
    Disk.Add(Root + '/' + AName);
    Arc.Add(AName);
  end;

begin
  ForceDirectories(Root + '/sub/deep');
  WriteText(Root + '/a.txt', 'a');
  WriteText(Root + '/sub/b.txt', 'b');
  WriteText(Root + '/sub/c.txt', 'c');
  WriteText(Root + '/sub/deep/d.txt', 'd');
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    Add('a.txt');
    Add('sub/b.txt');
    Add('sub/c.txt');
    Add('sub/deep/d.txt');
    Set1 := TzCollectInputsMapped(Disk, Arc);
    try
      S := Default(TCreateSettings);
      S.FormatName := 'zip';
      S.Level := 5;
      R := TzCreateArchive(APath, S, Set1.Recs, Err);
    finally
      TzInputSetFree(Set1);
    end;
    Check(R = TZ7Z_OK, 'setup: selection archive (' + Err + ')');
    Result := R = TZ7Z_OK;
  finally
    Arc.Free;
    Disk.Free;
  end;
end;

function Row(const AName: string; AIsDir: Boolean; AIndex: Integer): TListingItem;
begin
  Result := Default(TListingItem);
  Result.Name := AName;
  Result.FullPath := AName;
  Result.IsDir := AIsDir;
  Result.EntryIndex := AIndex;
end;

function SameIndices(const AGot: TLongWordArray;
  const AWant: array of LongWord): Boolean;
var
  I: Integer;
begin
  Result := Length(AGot) = Length(AWant);
  if not Result then Exit;
  for I := 0 to High(AGot) do
    if AGot[I] <> AWant[I] then Exit(False);
end;

function IndicesText(const AIndices: TLongWordArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AIndices) do
    Result := Result + IntToStr(AIndices[I]) + ',';
end;

procedure TestSelectedIndices;
var
  Ctx: TArchiveContext;
  Err, Path: string;
  R, IdxA, IdxB, IdxC, IdxD: Integer;
  Listing: TListing;
  Selected: array of Boolean;
begin
  Path := Root + '/sel.zip';
  DeleteFile(Path);
  if not MakeSelectionZip(Path) then Exit;
  Ctx := nil;
  R := TzOpenContext(Path, 'sel.zip', '', nil, False, '', Ctx, Err);
  Check(R = TZ7Z_OK, 'select: the archive opens (' + Err + ')');
  if Ctx = nil then Exit;
  try
    IdxA := -1;
    IdxB := -1;
    IdxC := -1;
    IdxD := -1;
    for R := 0 to High(Ctx.Entries) do
    begin
      if Ctx.Entries[R].Name = 'a.txt' then IdxA := R;
      if Ctx.Entries[R].Name = 'sub/b.txt' then IdxB := R;
      if Ctx.Entries[R].Name = 'sub/c.txt' then IdxC := R;
      if Ctx.Entries[R].Name = 'sub/deep/d.txt' then IdxD := R;
    end;
    Check(IdxA >= 0, 'select: a.txt exists');
    Check((IdxB >= 0) and (IdxC >= 0) and (IdxD >= 0), 'select: sub entries exist');

    { Row 0 is the UI's synthetic ".." row, row 1 a folder, row 2 a file, and
      the last two carry impossible indices a defensive caller might pass. }
    SetLength(Listing, 5);
    Listing[0] := Row('..', True, -1);
    Listing[0].IsParent := True;
    Listing[1] := Row('sub', True, IdxB);
    Listing[2] := Row('a.txt', False, IdxA);
    Listing[3] := Row('ghost.txt', False, 9999);
    Listing[4] := Row('negative.txt', False, -1);

    SetLength(Selected, 5);
    Selected[0] := True;
    Selected[1] := True;
    Selected[2] := True;
    Selected[3] := True;
    Selected[4] := True;
    R := 0;
    { Selection: parent row ignored, folder expanded, file taken, bad indices
      ignored. The result is ascending and has no duplicates. }
    Check(SameIndices(TzSelectedIndices(Ctx, Listing, Selected),
      [LongWord(IdxA), LongWord(IdxB), LongWord(IdxC), LongWord(IdxD)]),
      'select: folder expansion and bad indices');

    { Selecting a folder AND one of its children must not duplicate the child. }
    Selected[0] := False;
    Selected[1] := True;
    Selected[2] := True;
    Selected[3] := True;
    Selected[4] := True;
    Check(SameIndices(TzSelectedIndices(Ctx, Listing, Selected),
      [LongWord(IdxA), LongWord(IdxB), LongWord(IdxC), LongWord(IdxD)]),
      'select: no duplicate from folder plus child');

    { Nothing selected is nothing extracted. }
    for R := 0 to High(Selected) do Selected[R] := False;
    Check(Length(TzSelectedIndices(Ctx, Listing, Selected)) = 0,
      'select: nothing selected -> empty');

    { A short selection array must not read past its end. }
    SetLength(Selected, 2);
    Selected[0] := False;
    Selected[1] := True;
    Check(SameIndices(TzSelectedIndices(Ctx, Listing, Selected),
      [LongWord(IdxB), LongWord(IdxC), LongWord(IdxD)]),
      'select: a short selection array only considers its rows');
  finally
    Ctx.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-listing-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  TestRootListing;
  TestSubListing;
  TestSorting;
  TestSelectedIndices;

  ExecuteProcess('/bin/rm', ['-rf', Root]);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
