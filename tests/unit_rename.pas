program unit_rename;
{$mode objfpc}{$H+}
{ Entry rename validation: the checks that must happen BEFORE an archive is
  rewritten, since 7-Zip has no rename and the rewrite cannot be undone. }
uses
  SysUtils, Classes, tzip.rename;

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

function Existing: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := False;
  Result.Add('dir/a.txt');
  Result.Add('dir/b.txt');
  Result.Add('top.txt');
end;

{ --- resolving the new path -------------------------------------------- }

procedure TestResolve;
begin
  { Renaming keeps the entry in its folder. }
  EqStr(ResolvedEntryPath('renamed.txt', 'dir/a.txt', True), 'dir/renamed.txt',
    'resolve: rename stays in the folder');
  { A path is taken from the archive root when the caller did not ask for a move. }
  EqStr(ResolvedEntryPath('other/renamed.txt', 'dir/a.txt', False),
    'other/renamed.txt', 'resolve: path is absolute in the archive');
  { An absolute path names its place outright. }
  EqStr(ResolvedEntryPath('/abs/x.txt', 'dir/a.txt', True), 'abs/x.txt',
    'resolve: absolute overrides the folder');
  { A backslash is normalised to the archive separator. }
  EqStr(ResolvedEntryPath('sub\x.txt', 'dir/a.txt', False), 'sub/x.txt',
    'resolve: backslash becomes a separator');
  { At the top level there is no folder to stay in. }
  EqStr(ResolvedEntryPath('new.txt', 'top.txt', True), 'new.txt',
    'resolve: top level');
  { Surrounding whitespace is not part of the name. }
  EqStr(ResolvedEntryPath('  padded.txt  ', 'dir/a.txt', True), 'dir/padded.txt',
    'resolve: trimmed');
end;

{ --- validation --------------------------------------------------------- }

procedure TestValidation;
var
  E: TStringList;
begin
  E := Existing;
  try
    Check(CheckEntryName('ok.txt', 'dir/a.txt', E) = rpNone, 'check: a fine name');
    Check(CheckEntryName('', 'dir/a.txt', E) = rpEmpty, 'check: empty');
    Check(CheckEntryName('   ', 'dir/a.txt', E) = rpEmpty, 'check: only spaces');
    Check(CheckEntryName('.', 'dir/a.txt', E) = rpDot, 'check: dot');
    Check(CheckEntryName('..', 'dir/a.txt', E) = rpDot, 'check: dot dot');
    Check(CheckEntryName('/x.txt', 'dir/a.txt', E) = rpAbsolute, 'check: leading slash');
    Check(CheckEntryName('x/', 'dir/a.txt', E) = rpTrailingSlash, 'check: trailing slash');

    { Every character the engine or a filesystem refuses. }
    Check(CheckEntryName('a:b.txt', 'dir/a.txt', E) = rpIllegalChars, 'check: colon');
    Check(CheckEntryName('a*.txt', 'dir/a.txt', E) = rpIllegalChars, 'check: star');
    Check(CheckEntryName('a?.txt', 'dir/a.txt', E) = rpIllegalChars, 'check: question');
    Check(CheckEntryName('a"b.txt', 'dir/a.txt', E) = rpIllegalChars, 'check: quote');
    Check(CheckEntryName('a<b.txt', 'dir/a.txt', E) = rpIllegalChars, 'check: angle');

    { A clash with an existing entry is refused, wherever it is. }
    Check(CheckEntryName('top.txt', 'dir/a.txt', E) = rpDuplicate, 'check: duplicate');
    Check(CheckEntryName('TOP.TXT', 'dir/a.txt', E) = rpDuplicate,
      'check: duplicate ignores case');
    Check(CheckEntryName('dir/b.txt', 'dir/a.txt', E) = rpDuplicate,
      'check: duplicate in a folder path');
    { A fresh path is fine. }
    Check(CheckEntryName('other/fresh.txt', 'dir/a.txt', E) = rpNone,
      'check: a fresh path is fine');
    { The name the entry already has is not a clash with itself. }
    Check(CheckEntryName('dir/a.txt', 'dir/a.txt', E) = rpNone,
      'check: unchanged name is fine');
  finally E.Free; end;

  { No list of existing entries still validates the name itself. }
  Check(CheckEntryName('ok.txt', 'dir/a.txt', nil) = rpNone, 'check: nil list');
  Check(CheckEntryName('', 'dir/a.txt', nil) = rpEmpty, 'check: nil list still validates');
end;

procedure TestMessages;
begin
  Check(RenameProblemText(rpNone) = '', 'text: no problem is silent');
  Check(RenameProblemText(rpEmpty) <> '', 'text: empty has a message');
  Check(RenameProblemText(rpIllegalChars) <> '', 'text: illegal has a message');
  Check(RenameProblemText(rpDuplicate) <> '', 'text: duplicate has a message');
  Check(RenameProblemText(rpAbsolute) <> '', 'text: absolute has a message');
  Check(RenameProblemText(rpTrailingSlash) <> '', 'text: trailing slash has a message');
  Check(RenameProblemText(rpDot) <> '', 'text: dot has a message');
end;

begin
  Fails := 0; Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  TestResolve;
  TestValidation;
  TestMessages;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
