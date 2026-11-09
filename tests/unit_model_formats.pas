program unit_model_formats;
{$mode objfpc}{$H+}
{ The single format table: one row per extension, and both directions agree.

  ".tar.zst" could be opened but not created; the create dialog still offered
  it. That kind of hole was possible because the read list, the write list, the
  pure-compression list and the document list were separate copies. These tests
  pin the table itself, the read side, the write side, and the invariant that a
  compound form is writable only when its outer compression is. }
uses
  SysUtils, Classes, tzip.formats, tzip.engine;

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

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant]));
  end;
end;

{ --- the table itself ---------------------------------------------------- }

procedure TestTableShape;
var
  I, J: Integer;
  A, B: TFormatEntry;
begin
  Check(TzFormatCount > 20, 'table: a format table exists');
  for I := 0 to TzFormatCount - 1 do
  begin
    A := TzFormatAt(I);
    Check(A.Ext <> '', Format('table: row %d has an extension', [I]));
    Check(A.Ext = LowerCase(A.Ext),
      Format('table: row %d extension is lower case (%s)', [I, A.Ext]));
    for J := I + 1 to TzFormatCount - 1 do
    begin
      B := TzFormatAt(J);
      Check(not SameText(A.Ext, B.Ext),
        Format('table: extension %s appears once', [A.Ext]));
    end;
    Check(not (A.Compound and A.PureCompression),
      Format('table: %s is not both compound and a raw stream', [A.Ext]));
    if A.Compound then
    begin
      Check(A.InnerExt <> '', Format('table: %s names the inner extension', [A.Ext]));
      Check(A.ArchiveFile, Format('table: %s is recognised as an archive', [A.Ext]));
      Check(A.InnerExt = '.tar', Format('table: %s wraps a tar', [A.Ext]));
    end;
  end;
end;

{ --- longest match ------------------------------------------------------- }

procedure TestLookup;
begin
  EqStr(TzFormatForName('x.7z').Ext, '7z', 'lookup: plain archive');
  EqStr(TzFormatForName('/a/b/x.zip').Ext, 'zip', 'lookup: a path works too');
  EqStr(TzFormatForName('x.tar.gz').Ext, 'tar.gz',
    'lookup: the compound extension wins over "gz"');
  EqStr(TzFormatForName('x.gz').Ext, 'gz', 'lookup: the bare compression');
  EqStr(TzFormatForName('X.TAR.GZ').Ext, 'tar.gz', 'lookup: case-insensitive');
  EqStr(TzFormatForName('x.unknown').Ext, '', 'lookup: an unknown extension');
  EqStr(TzFormatForName('').Ext, '', 'lookup: an empty name');
end;

{ --- read side ----------------------------------------------------------- }

procedure TestReadSide;
const
  Wrappers: array[0..9] of string = ('tar.gz', 'tgz', 'tar.bz2', 'tbz2',
    'tar.xz', 'txz', 'tar.zst', 'tzst', 'tar.lzma', 'tlz');
  Pure: array[0..6] of string = ('gz', 'bz2', 'xz', 'zst', 'lzma', 'lz', 'z');
var
  I: Integer;
begin
  for I := 0 to High(Wrappers) do
  begin
    Check(TzIsReadableWrapperName('file.' + Wrappers[I]),
      Format('read: .%s is a wrapper', [Wrappers[I]]));
    Check(not TzIsPureCompressionName('file.' + Wrappers[I]),
      Format('read: .%s is not a raw stream', [Wrappers[I]]));
  end;
  for I := 0 to High(Pure) do
  begin
    Check(TzIsPureCompressionName('file.' + Pure[I]),
      Format('read: .%s is a raw stream', [Pure[I]]));
    Check(not TzIsReadableWrapperName('file.' + Pure[I]),
      Format('read: .%s alone is not a wrapper', [Pure[I]]));
  end;
  Check(not TzIsReadableWrapperName('file.zip'), 'read: .zip is not a wrapper');
  Check(not TzIsPureCompressionName('file.zip'), 'read: .zip is not a raw stream');
end;

{ --- write side ---------------------------------------------------------- }

procedure TestWriteSide;
const
  Creatable: array[0..5] of string = ('tar.gz', 'tgz', 'tar.bz2', 'tbz2',
    'tar.xz', 'txz');
  ReadOnly: array[0..3] of string = ('tar.zst', 'tzst', 'tar.lzma', 'tlz');
var
  I: Integer;
begin
  for I := 0 to High(Creatable) do
    Check(TzIsCompoundTarName('file.' + Creatable[I]),
      Format('write: .%s can be created', [Creatable[I]]));
  { Readable but not creatable: the table says so instead of the two sides
    disagreeing silently. }
  for I := 0 to High(ReadOnly) do
  begin
    Check(TzIsReadableWrapperName('file.' + ReadOnly[I]),
      Format('write: .%s is still readable', [ReadOnly[I]]));
    Check(not TzIsCompoundTarName('file.' + ReadOnly[I]),
      Format('write: .%s is not offered for creation', [ReadOnly[I]]));
  end;
  Check(not TzIsCompoundTarName('file.gz'),
    'write: a bare .gz is not a compound name');
end;

{ --- the invariant between the two sides -------------------------------- }

procedure TestSymmetryInvariant;
var
  I: Integer;
  E, Outer: TFormatEntry;
  OuterExt: string;
begin
  for I := 0 to TzFormatCount - 1 do
  begin
    E := TzFormatAt(I);
    if not E.Compound then Continue;
    { The outer compression of a compound row is whatever follows its last
      dot; for a compound row to be writable, that compression alone must be
      writable. }
    OuterExt := ExtractFileExt('x.' + E.Ext);
    Outer := TzFormatForName('x' + OuterExt);
    Check(Outer.Ext <> '', Format('invariant: %s has a known outer format', [E.Ext]));
    Check(E.Writable = Outer.Writable,
      Format('invariant: %s writable=%s matches outer %s writable=%s',
        [E.Ext, BoolToStr(E.Writable, True), Outer.Ext,
         BoolToStr(Outer.Writable, True)]));
  end;
end;

{ --- document containers ------------------------------------------------- }

procedure TestDocuments;
begin
  Check(TzIsDocumentName('report.docx'), 'documents: .docx');
  Check(TzIsDocumentName('sheet.xlsx'), 'documents: .xlsx');
  Check(TzIsDocumentName('slides.odp'), 'documents: .odp');
  Check(TzIsDocumentName('book.epub'), 'documents: .epub');
  Check(not TzIsDocumentName('archive.zip'), 'documents: .zip is not a document');
  Check(not TzIsDocumentName('notes.txt'), 'documents: .txt is not a document');
end;

{ --- names derived from these suffixes ---------------------------------- }

procedure TestInnerNames;
begin
  EqStr(TzCompressedInnerName('x.tar.gz', ''), 'x.tar',
    'inner name: compound keeps the tar');
  EqStr(TzCompressedInnerName('x.tgz', ''), 'x.tar',
    'inner name: the alias expands to .tar');
  EqStr(TzCompressedInnerName('x.gz', ''), 'x',
    'inner name: a raw stream loses its compression suffix');
  EqStr(TzCompressedInnerName('data.zst', ''), 'data',
    'inner name: bare stream keeps the stem');
  EqStr(TzCompressedInnerName('x.cpio.zst', ''), 'x.cpio',
    'inner name: the container extension survives');
  { A caller may pass the folder the file was opened from as the first value. }
  EqStr(TzCompressedInnerName('/a/b/', 'x.7z'), 'x.7z',
    'inner name: falls back to a name that has an extension');

  EqStr(TzStreamInnerSuffix('x.tar.gz'), '.tar',
    'inner suffix: the decompressed stream is a tar');
  EqStr(TzStreamInnerSuffix('x.cpio.zst'), '.cpio',
    'inner suffix: a container extension in front stays');
  EqStr(TzStreamInnerSuffix('x.zip.zst'), '.zip',
    'inner suffix: a wrapped zip keeps its type');
  EqStr(TzStreamInnerSuffix('data.zst'), '.tar',
    'inner suffix: a bare stream defaults to tar');
end;

{ --- the engine's own entry points use the table ------------------------ }

procedure TestEngineEntryPoints;
var
  Names: TStringList;
begin
  Check(TzIsArchiveName('x.tar.zst'), 'engine: .tar.zst is recognised as an archive');
  Check(TzIsArchiveName('x.gz'), 'engine: .gz is recognised');
  Check(TzIsArchiveName('x.docm'), 'engine: a document container is an archive');
  Check(not TzIsArchiveName('x.txt'), 'engine: .txt is not an archive');
  Check(TzIsDocumentName('x.docx'), 'engine: documents come from the same table');
  Check(not TzIsDocumentName('x.zip'), 'engine: .zip is not a document');

  Names := TStringList.Create;
  try
    TzAppendArchiveExtensions(Names);
    Check(Names.IndexOf('7z') >= 0, 'extensions: a plain archive is listed');
    Check(Names.IndexOf('tar.zst') >= 0, 'extensions: a compound is listed');
    Check(Names.IndexOf('docx') >= 0, 'extensions: a document container is listed');
    Check(Names.IndexOf('gz') >= 0, 'extensions: a raw stream is listed');
  finally
    Names.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  TestTableShape;
  TestLookup;
  TestReadSide;
  TestWriteSide;
  TestSymmetryInvariant;
  TestDocuments;
  TestInnerNames;
  TestEngineEntryPoints;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
