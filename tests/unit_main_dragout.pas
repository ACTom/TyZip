program unit_main_dragout;
{$mode objfpc}{$H+}
{ Which entries a drag out of the archive window carries.

  The listing selects rows, not entries: a selected folder must bring its whole
  subtree, and a file inside a selected folder must not be dragged twice. } 
uses
  SysUtils, tzip.engine, tzip.dragout;

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

procedure EqInt(const AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

function Entry(const AName: string; AIsDir: Boolean; ASize: QWord): TArchiveEntry;
begin
  Result := Default(TArchiveEntry);
  Result.Name := AName;
  Result.IsDir := AIsDir;
  Result.Size := ASize;
end;

var
  E: TArchiveEntries;
  R: TDragOutRoots;

procedure TestBaseName;
begin
  EqStr(TzDragOutBaseName('docs/a.txt'), 'a.txt', 'base: nested file');
  EqStr(TzDragOutBaseName('a.txt'), 'a.txt', 'base: bare name');
  EqStr(TzDragOutBaseName(''), '', 'base: empty');
end;

procedure TestFileRoots;
begin
  R := TzDragOutRoots(E, ['docs/a.txt', 'other.txt']);
  EqInt(Length(R), 2, 'files: two roots');
  if Length(R) = 2 then
  begin
    EqStr(R[0].BaseName, 'a.txt', 'files: first base name');
    EqStr(R[1].BaseName, 'other.txt', 'files: second base name');
    EqInt(Length(R[0].Indices), 1, 'files: one index each');
    Check(not R[0].IsDir, 'files: not a folder');
    Check(R[0].Size = 10, 'files: size kept');
  end;
end;

procedure TestFolderRoot;
begin
  R := TzDragOutRoots(E, ['docs']);
  EqInt(Length(R), 1, 'folder: one root');
  if Length(R) = 1 then
  begin
    Check(R[0].IsDir, 'folder: is a folder');
    EqStr(R[0].BaseName, 'docs', 'folder: base name');
    EqInt(Length(R[0].Indices), 3, 'folder: folder and its subtree');
    Check(R[0].Size = 30, 'folder: subtree size');
  end;
  { A file inside the selected folder folds into it. }
  R := TzDragOutRoots(E, ['docs', 'docs/a.txt']);
  EqInt(Length(R), 1, 'folder: child does not become a second root');
  { Selection order is preserved. }
  R := TzDragOutRoots(E, ['other.txt', 'docs']);
  EqInt(Length(R), 2, 'order: two roots');
  if Length(R) = 2 then
  begin
    EqStr(R[0].BaseName, 'other.txt', 'order: first');
    EqStr(R[1].BaseName, 'docs', 'order: second');
  end;
end;

procedure TestUnknownAndEmpty;
begin
  R := TzDragOutRoots(E, []);
  EqInt(Length(R), 0, 'empty: no roots');
  R := TzDragOutRoots(E, ['missing.txt']);
  EqInt(Length(R), 0, 'unknown: ignored');
end;

begin
  Fails := 0;
  Passes := 0;
  SetLength(E, 5);
  E[0] := Entry('docs', True, 0);
  E[1] := Entry('docs/a.txt', False, 10);
  E[2] := Entry('docs/sub/b.bin', False, 20);
  E[3] := Entry('other.txt', False, 5);
  E[4] := Entry('x.zip', False, 7);

  TestBaseName;
  TestFileRoots;
  TestFolderRoot;
  TestUnknownAndEmpty;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
