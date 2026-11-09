{ Which archive entries a drag out of the window should carry.

  The archive listing selects ROWS, and a selected folder row does not mean one
  entry: the drag has to carry the folder plus everything under it, and a file
  whose parent folder is also selected must not become a second root. This unit
  turns the selected archive paths into those roots without a window, so the
  expansion can be tested (the Cocoa promise code only writes what it is told). }
unit tzip.dragout;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, tzip.engine;

type
  { One item Finder will receive from the drag: a file, or a folder with its
    whole subtree. Indices are the archive entries to extract. }
  TDragOutRoot = record
    EntryIndex: Integer;
    EntryName: string;   { path inside the archive, '/'-separated }
    BaseName: string;    { the name Finder shows and writes }
    IsDir: Boolean;
    Size: QWord;         { uncompressed bytes of a file, or of a folder's files }
    Indices: TLongWordArray;
  end;
  TDragOutRoots = array of TDragOutRoot;

{ The drag roots for the selected archive paths. A path whose ancestor is also
  selected is folded into that ancestor; unknown paths are ignored; the order is
  the selection's. }
function TzDragOutRoots(const AEntries: TArchiveEntries;
  const ARootNames: array of string): TDragOutRoots;

{ The last segment of an archive path: "docs/a.txt" -> "a.txt". }
function TzDragOutBaseName(const AName: string): string;

implementation

function TzDragOutBaseName(const AName: string): string;
var
  P: Integer;
begin
  Result := AName;
  P := LastDelimiter('/', Result);
  if P > 0 then Result := Copy(Result, P + 1, Length(Result) - P);
end;

function EntryNameUnder(const AName, ARoot: string): Boolean;
begin
  Result := SameText(AName, ARoot) or
    (Copy(AName, 1, Length(ARoot) + 1) = ARoot + '/');
end;

function TzDragOutRoots(const AEntries: TArchiveEntries;
  const ARootNames: array of string): TDragOutRoots;
var
  I, J, K, Root: Integer;
  Name: string;
  IsAncestor: Boolean;
  E: TArchiveEntry;
begin
  Result := nil;
  for I := 0 to High(ARootNames) do
  begin
    Name := ARootNames[I];
    if Name = '' then Continue;
    Root := -1;
    for J := 0 to High(AEntries) do
      if SameText(AEntries[J].Name, Name) then
      begin
        Root := J;
        Break;
      end;
    if Root < 0 then Continue;

    { A selected file inside a selected folder is not a second root. }
    IsAncestor := False;
    for K := 0 to High(ARootNames) do
    begin
      if (K = I) or (ARootNames[K] = '') or (ARootNames[K] = Name) then Continue;
      if EntryNameUnder(Name, ARootNames[K]) then
      begin
        IsAncestor := True;
        Break;
      end;
    end;
    if IsAncestor then Continue;

    E := AEntries[Root];
    SetLength(Result, Length(Result) + 1);
    with Result[High(Result)] do
    begin
      EntryIndex := Root;
      EntryName := E.Name;
      BaseName := TzDragOutBaseName(E.Name);
      IsDir := E.IsDir;
      Size := 0;
      Indices := nil;
      if E.IsDir then
      begin
        for J := 0 to High(AEntries) do
          if EntryNameUnder(AEntries[J].Name, E.Name) then
          begin
            SetLength(Indices, Length(Indices) + 1);
            Indices[High(Indices)] := LongWord(J);
            if not AEntries[J].IsDir then Inc(Size, AEntries[J].Size);
          end;
      end
      else
      begin
        SetLength(Indices, 1);
        Indices[0] := LongWord(Root);
        Size := E.Size;
      end;
    end;
  end;
end;

end.
