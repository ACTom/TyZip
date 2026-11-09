program unit_pure;
{$mode objfpc}{$H+}
{ Pure logic with no archive I/O: name classification and path arithmetic.

  These look small but every one of them decides user-visible behaviour -- a
  wrong answer means a document opens in 7-Zip instead of Word, or the breadcrumb
  shows the wrong folder. They are also the cheapest tests to run, so they are
  covered exhaustively rather than by example. }
uses
  SysUtils, tzip.api, tzip.engine;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure Eq(AGot, AWant: string; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg, ': got [', AGot, '] want [', AWant, ']');
  end;
end;

procedure EqBool(AGot, AWant: Boolean; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg, ': got ', AGot, ' want ', AWant);
  end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg, ': got ', AGot, ' want ', AWant);
  end;
end;

{ --- TzIsArchiveName ---------------------------------------------------- }

procedure TestIsArchiveName;
begin
  { Containers we can open. }
  EqBool(TzIsArchiveName('a.7z'), True, 'archive: .7z');
  EqBool(TzIsArchiveName('a.zip'), True, 'archive: .zip');
  EqBool(TzIsArchiveName('a.rar'), True, 'archive: .rar');
  EqBool(TzIsArchiveName('a.tar'), True, 'archive: .tar');
  EqBool(TzIsArchiveName('a.gz'), True, 'archive: .gz');
  EqBool(TzIsArchiveName('a.tar.gz'), True, 'archive: .tar.gz');
  EqBool(TzIsArchiveName('a.bz2'), True, 'archive: .bz2');
  EqBool(TzIsArchiveName('a.xz'), True, 'archive: .xz');
  EqBool(TzIsArchiveName('a.zst'), True, 'archive: .zst');
  EqBool(TzIsArchiveName('a.cpio'), True, 'archive: .cpio');
  EqBool(TzIsArchiveName('a.rpm'), True, 'archive: .rpm');
  EqBool(TzIsArchiveName('a.deb'), True, 'archive: .deb');
  EqBool(TzIsArchiveName('a.iso'), True, 'archive: .iso');
  EqBool(TzIsArchiveName('a.cab'), True, 'archive: .cab');
  EqBool(TzIsArchiveName('a.jar'), True, 'archive: .jar');
  EqBool(TzIsArchiveName('a.wim'), True, 'archive: .wim');

  { Case must not matter. }
  EqBool(TzIsArchiveName('A.7Z'), True, 'archive: uppercase extension');
  EqBool(TzIsArchiveName('A.ZiP'), True, 'archive: mixed-case extension');

  { Ordinary files are not archives. }
  EqBool(TzIsArchiveName('a.txt'), False, 'archive: .txt is not');
  EqBool(TzIsArchiveName('a.png'), False, 'archive: .png is not');
  EqBool(TzIsArchiveName('a.pas'), False, 'archive: .pas is not');
  EqBool(TzIsArchiveName('a'), False, 'archive: no extension');
  EqBool(TzIsArchiveName(''), False, 'archive: empty name');
  EqBool(TzIsArchiveName('.7z'), False, 'archive: leading dot is a dotfile, not an extension');
end;

{ --- TzIsDocumentName --------------------------------------------------- }

procedure TestIsDocumentName;
begin
  { ZIP-based documents: archives internally, documents to the user. }
  EqBool(TzIsDocumentName('a.docx'), True, 'doc: .docx');
  EqBool(TzIsDocumentName('a.xlsx'), True, 'doc: .xlsx');
  EqBool(TzIsDocumentName('a.pptx'), True, 'doc: .pptx');
  EqBool(TzIsDocumentName('a.odt'), True, 'doc: .odt');
  EqBool(TzIsDocumentName('a.ods'), True, 'doc: .ods');
  EqBool(TzIsDocumentName('a.odp'), True, 'doc: .odp');
  EqBool(TzIsDocumentName('a.epub'), True, 'doc: .epub');
  EqBool(TzIsDocumentName('a.docm'), True, 'doc: .docm');
  EqBool(TzIsDocumentName('a.xlsm'), True, 'doc: .xlsm');

  { Real archives and plain files are not documents. }
  EqBool(TzIsDocumentName('a.zip'), False, 'doc: .zip is not');
  EqBool(TzIsDocumentName('a.7z'), False, 'doc: .7z is not');
  EqBool(TzIsDocumentName('a.txt'), False, 'doc: .txt is not');
  EqBool(TzIsDocumentName('a.pdf'), False, 'doc: .pdf is not');
  EqBool(TzIsDocumentName(''), False, 'doc: empty');

  { A document name is also an archive name: the two answers are independent. }
  EqBool(TzIsArchiveName('a.docx'), True, 'doc: .docx is still an archive name');
end;

{ --- TzNormalizeArcPath ------------------------------------------------- }

procedure TestNormalizeArcPath;
begin
  Eq(TzNormalizeArcPath('a/b'), 'a/b', 'norm: plain');
  Eq(TzNormalizeArcPath('/a/b'), 'a/b', 'norm: leading slash stripped');
  Eq(TzNormalizeArcPath('///a//b'), 'a/b', 'norm: duplicate slashes');
  Eq(TzNormalizeArcPath('a\b'), 'a/b', 'norm: backslash to slash');
  Eq(TzNormalizeArcPath('a/b/'), 'a/b', 'norm: trailing slash stripped');
  Eq(TzNormalizeArcPath('./a/b'), 'a/b', 'norm: leading ./ stripped');
  Eq(TzNormalizeArcPath(''), '', 'norm: empty stays empty');
  Eq(TzNormalizeArcPath('.'), '', 'norm: single dot becomes empty');
  Eq(TzNormalizeArcPath('..'), '', 'norm: double dot becomes empty');
  Eq(TzNormalizeArcPath('../evil'), '', 'norm: leading traversal is dropped');
  Eq(TzNormalizeArcPath('a/../b'), 'a/../b', 'norm: interior .. is left alone');
  Eq(TzNormalizeArcPath('a//b//c'), 'a/b/c', 'norm: many duplicates');
end;

{ --- TzParentArcPath / TzArcBaseName ------------------------------------ }

procedure TestPathArithmetic;
begin
  Eq(TzParentArcPath('a/b/c.txt'), 'a/b', 'parent: nested file');
  Eq(TzParentArcPath('a/c.txt'), 'a', 'parent: one level');
  Eq(TzParentArcPath('c.txt'), '', 'parent: top level is empty');
  Eq(TzParentArcPath(''), '', 'parent: empty');

  Eq(TzArcBaseName('a/b/c.txt'), 'c.txt', 'basename: nested');
  Eq(TzArcBaseName('c.txt'), 'c.txt', 'basename: top level');
  Eq(TzArcBaseName('a/b/'), 'b', 'basename: trailing slash');
  Eq(TzArcBaseName(''), '', 'basename: empty');
  Eq(TzArcBaseName('a'), 'a', 'basename: single segment');
end;

{ --- TzSafeEntryFileName ------------------------------------------------ }

procedure TestSafeEntryFileName;
begin
  { The regression that prompted this: a CJK name used to become one
    underscore per UTF-8 byte, so the file the system opened was called
    "____________.pptx" instead of the name the user clicked. }
  Eq(TzSafeEntryFileName('中文演示.pptx'), '中文演示.pptx',
    'safe name: CJK preserved');
  Eq(TzSafeEntryFileName('01A17AD8BF19中文.pptx'), '01A17AD8BF19中文.pptx',
    'safe name: hex prefix with CJK preserved');
  Eq(TzSafeEntryFileName('日本語.txt'), '日本語.txt', 'safe name: Japanese');
  Eq(TzSafeEntryFileName('한국어.txt'), '한국어.txt', 'safe name: Korean');
  Eq(TzSafeEntryFileName('emoji 😀.png'), 'emoji 😀.png', 'safe name: emoji');

  { Spaces are legal and users see them; they must survive. }
  Eq(TzSafeEntryFileName('report v2 final.pdf'), 'report v2 final.pdf',
    'safe name: spaces preserved');

  { Directory parts never reach the temp file. }
  Eq(TzSafeEntryFileName('a/b/c.txt'), 'c.txt', 'safe name: directory stripped');
  Eq(TzSafeEntryFileName('../../etc/passwd'), 'passwd',
    'safe name: traversal stripped');

  { Bytes that are genuinely dangerous are still replaced. }
  Eq(TzSafeEntryFileName('a:b.txt'), 'a_b.txt', 'safe name: colon replaced');
  Eq(TzSafeEntryFileName('a|b.txt'), 'a_b.txt', 'safe name: pipe replaced');
  Eq(TzSafeEntryFileName('a*b?.txt'), 'a_b_.txt',
    'safe name: glob characters replaced');

  { A trailing dot or space is rejected by NTFS. }
  Eq(TzSafeEntryFileName('name.'), 'name', 'safe name: trailing dot dropped');
  Eq(TzSafeEntryFileName('name '), 'name', 'safe name: trailing space dropped');

  { Degenerate inputs still yield a usable file name. }
  Eq(TzSafeEntryFileName(''), 'entry.bin', 'safe name: empty falls back');
  Eq(TzSafeEntryFileName('.'), 'entry.bin', 'safe name: single dot falls back');
  Eq(TzSafeEntryFileName('..'), 'entry.bin', 'safe name: double dot falls back');
  Eq(TzSafeEntryFileName('...'), 'entry.bin', 'safe name: dots fall back');
end;

{ --- TzIsSplitArchivePart ------------------------------------------------ }

{ Writing into one part of a split set rewrites only that file and leaves the
  rest pointing at bytes that have moved. The dialog refuses that, so the test
  pins which names count as "part of a set". }
procedure TestSplitArchivePart;
begin
  Check(TzIsSplitArchivePart('archive.7z.001'), 'split: .001 is a part');
  Check(TzIsSplitArchivePart('archive.7z.002'), 'split: .002 is a part');
  Check(TzIsSplitArchivePart('archive.zip.001'), 'split: zip .001');
  Check(TzIsSplitArchivePart('/tmp/a/b.7z.001'), 'split: path with dirs');

  Check(not TzIsSplitArchivePart('archive.7z'), 'split: a plain archive is not');
  Check(not TzIsSplitArchivePart('archive.zip'), 'split: a plain zip is not');
  Check(not TzIsSplitArchivePart(''), 'split: empty is not');
  Check(not TzIsSplitArchivePart('notes.001.txt'), 'split: .001 must be the extension');
end;

{ --- TzFormatSize ------------------------------------------------------- }

procedure TestFormatSize;
begin
  { Thresholds are what the memory label shows the user. }
  Eq(TzFormatSize(0), '0 B', 'size: zero');
  Eq(TzFormatSize(512), '512 B', 'size: bytes');
  Check(Pos('KB', TzFormatSize(2048)) > 0, 'size: kilobytes unit');
  Check(Pos('MB', TzFormatSize(5 * 1024 * 1024)) > 0, 'size: megabytes unit');
  Check(Pos('GB', TzFormatSize(QWord(3) * 1024 * 1024 * 1024)) > 0,
    'size: gigabytes unit');
  Check(Pos('TB', TzFormatSize(QWord(2) * 1024 * 1024 * 1024 * 1024)) > 0,
    'size: terabytes unit');
  { Never empty, whatever the input. }
  Check(TzFormatSize(1) <> '', 'size: one byte is not empty');
end;

{ --- TzErrorText -------------------------------------------------------- }

procedure TestErrorText;
begin
  { Every code the API returns must map to something a user can read. }
  Check(TzErrorText(0) <> '', 'error: OK has text');
  Check(TzErrorText(-1) <> '', 'error: generic has text');
  Check(TzErrorText(-6) <> '', 'error: format has text');
  Check(TzErrorText(-7) <> '', 'error: create has text');
  Check(TzErrorText(-10) <> '', 'error: IO has text');
end;

{ --- format list -------------------------------------------------------- }

procedure TestFormatList;
var
  F: TFormatInfoArray;
  I, Writables: Integer;
  HasWim, HasGz: Boolean;
begin
  F := TzLoadFormats;
  Check(Length(F) > 10, 'formats: engine reports a full list');
  Writables := 0;
  HasWim := False;
  HasGz := False;
  for I := 0 to High(F) do
  begin
    Check(F[I].Name <> '', 'formats: every entry is named');
    if F[I].CanUpdate then Inc(Writables);
    if SameText(F[I].Name, 'wim') and F[I].CanUpdate then HasWim := True;
    if SameText(F[I].Name, 'gzip') and F[I].CanUpdate then HasGz := True;
  end;
  { Exactly the seven the create dialog offers. }
  EqInt(Writables, 7, 'formats: seven writable formats');
  Check(HasWim, 'formats: wim is writable');
  Check(HasGz, 'formats: gzip is writable');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  { These functions need the format table, which comes from the engine. }
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('cannot load engine');
    Halt(2);
  end;

  TestIsArchiveName;
  TestIsDocumentName;
  TestNormalizeArcPath;
  TestPathArithmetic;
  TestSafeEntryFileName;
  TestSplitArchivePart;
  TestFormatSize;
  TestErrorText;
  TestFormatList;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
