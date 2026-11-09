program unit_main_arcpath;
{$mode objfpc}{$H+}
{ Archive-internal names: normalising a path, joining a folder with a child, and
  turning selected listing ROWS into entry names.

  The bug this pins: "Copy Path" used an entry's EntryIndex as a row number, so a
  sorted, filtered or searched listing copied whatever item happened to sit at
  that row. Row and index are different numbers and must never be mixed. }
uses
  SysUtils, tzip.arcpath;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

procedure TestNormalize;
begin
  EqStr(ArcPathNormalize(''), '', 'normalize: empty');
  EqStr(ArcPathNormalize('a.txt'), 'a.txt', 'normalize: a bare name');
  EqStr(ArcPathNormalize('docs/a.txt'), 'docs/a.txt', 'normalize: nested');
  EqStr(ArcPathNormalize('/docs/a.txt'), 'docs/a.txt', 'normalize: leading slash');
  EqStr(ArcPathNormalize('docs//a.txt'), 'docs/a.txt', 'normalize: doubled separator');
  EqStr(ArcPathNormalize('docs/a.txt/'), 'docs/a.txt', 'normalize: trailing slash');
  EqStr(ArcPathNormalize('  docs/a.txt  '), 'docs/a.txt', 'normalize: trimmed');
  EqStr(ArcPathNormalize('docs\a.txt'), 'docs/a.txt', 'normalize: backslashes');
  EqStr(ArcPathNormalize('./docs/a.txt'), 'docs/a.txt', 'normalize: leading dot segment');
end;

procedure TestChildPath;
begin
  { The regression: the prefix used to be concatenated without a separator, so a
    drop into "docs" produced "docsfile.txt" and the conflict check never saw the
    entry that was already there. }
  EqStr(ArcChildPath('docs', 'file.txt'), 'docs/file.txt', 'child: folder plus name');
  EqStr(ArcChildPath('docs/', 'file.txt'), 'docs/file.txt',
    'child: trailing separator is not doubled');
  EqStr(ArcChildPath('', 'file.txt'), 'file.txt', 'child: archive root');
  EqStr(ArcChildPath('', 'sub/file.txt'), 'sub/file.txt', 'child: root with a path');
  EqStr(ArcChildPath('a/b', 'c.txt'), 'a/b/c.txt', 'child: deep folder');
  EqStr(ArcChildPath('docs', ''), 'docs', 'child: no name keeps the folder');
  EqStr(ArcChildPath('', ''), '', 'child: both empty');
  EqStr(ArcChildPath(' docs ', ' file.txt '), 'docs/file.txt', 'child: trims both sides');
  EqStr(ArcChildPath('/docs', '/file.txt'), 'docs/file.txt',
    'child: boundaries are normalised');
end;

procedure TestPickedRows;
var
  R: TStringArray;
  Sel: array[0..3] of Boolean;
begin
  { Sorted listing: the row order is NOT the archive order. Only the selected
    rows matter, and their names come from the same row. }
  Sel[0] := False;   { ".." }
  Sel[1] := True;    { zebra.txt, archive index 7 }
  Sel[2] := False;   { apple.txt, archive index 1 }
  Sel[3] := True;    { cat.txt,  archive index 3 }
  R := PickedRowNames(['', 'zebra.txt', 'apple.txt', 'cat.txt'], Sel);
  Check(Length(R) = 2, 'rows: two selected names');
  if Length(R) = 2 then
  begin
    EqStr(R[0], 'zebra.txt', 'rows: first selected row, in row order');
    EqStr(R[1], 'cat.txt', 'rows: second selected row');
  end;

  { Nothing selected, and the parent row is never a path. }
  Sel[0] := False; Sel[1] := False; Sel[2] := False; Sel[3] := False;
  Check(Length(PickedRowNames(['', 'a'], Sel)) = 0, 'rows: empty selection');

  { A search result row whose full path differs from its display name: the row's
    own name is what the caller asked to copy. }
  Sel[0] := True;
  R := PickedRowNames(['deep/found.txt'], Sel);
  Check(Length(R) = 1, 'rows: one match');
  if Length(R) = 1 then EqStr(R[0], 'deep/found.txt', 'rows: the row name is used');

  { A selection array shorter than the listing: rows beyond it are not selected. }
  R := PickedRowNames(['a', 'b', 'c'], [True]);
  Check(Length(R) = 1, 'rows: short selection array');
end;

begin
  Fails := 0; Passes := 0;
  TestNormalize;
  TestChildPath;
  TestPickedRows;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
