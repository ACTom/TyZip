unit tzip.formats;
{ The one table of archive extensions and their behaviour.

  Extension knowledge used to live in six unrelated places -- the compound
  .tar.gz test, the wrapper test, the "inner suffix" of an unwrapped stream, the
  pure-compression test, the compound CREATE test and the archive-name list --
  and they drifted: ".tar.zst" could be READ but not WRITTEN, while the create
  dialog offered that extension anyway. Everything now comes from ONE row per
  extension, and a row says explicitly whether it can be read, created, and
  whether it wraps another archive.

  The table is immutable after unit initialisation, so any thread may read it. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  { One row of the format table. Ext is lower case and has no leading dot;
    longer extensions win over their prefixes (".tar.gz" over "gz"). }
  TFormatEntry = record
    Ext: string;
    { The extension names an archive TyZip recognises (icon, "open as archive"). }
    ArchiveFile: Boolean;
    { A single-stream compression: its bytes have no directory tree. }
    PureCompression: Boolean;
    { A compound name: "<stem>.tar.<compression>" or an alias like ".tgz". }
    Compound: Boolean;
    { For a compound row: the extension the archive INSIDE carries ('.tar'). }
    InnerExt: string;
    { TyZip can CREATE this kind of file (engine write support). }
    Writable: Boolean;
    { Opening a document by double-click means the user's application, not
      TyZip's archive view (Office/OpenDocument files are ZIP containers). }
    Document: Boolean;
  end;

  TFormatEntryArray = array of TFormatEntry;

{ The row whose extension matches AName's (the longest one), or a zero row when
  nothing matches. AName may be a path or a bare file name. }
function TzFormatForName(const AName: string): TFormatEntry;

{ The whole table, for tests and for a UI that wants to list what is known. }
function TzFormatCount: Integer;
function TzFormatAt(AIndex: Integer): TFormatEntry;

{ Read side: a compound wrapper ("x.tar.gz", "x.tgz", "x.tar.zst"). }
function TzIsReadableWrapperName(const AName: string): Boolean;
{ Write side: a compound wrapper TyZip can CREATE. Deliberately narrower than
  the read side: it names exactly the compound forms whose outer compression
  the engine can write. }
function TzIsCompoundTarName(const AName: string): Boolean;

{ A single-stream compression (".gz", ".zst", ...). }
function TzIsPureCompressionName(const AName: string): Boolean;

{ Office/OpenDocument containers: archives internally, documents to the user. }
function TzIsDocumentName(const AName: string): Boolean;

{ Append every extension the table knows about to AList (lower case, no dots). }
procedure TzAppendArchiveExtensions(AList: TStringList);

{ The name the stream inside a compressed file holds: "x.tar.gz" -> "x.tar",
  "x.tgz" -> "x.tar", "x.gz" -> "x", "data.zst" -> "data.tar". }
function TzCompressedInnerName(const APath, ADisplayName: string): string;

{ The suffix the unwrapped stream carries: ".tar" for "x.tar.gz", the container
  extension for "x.cpio.zst" (".cpio"), ".tar" when there is nothing to go on. }
function TzStreamInnerSuffix(const AName: string): string;

implementation

var
  GFormats: TFormatEntryArray;

procedure Add(const AExt: string; AArchiveFile, APureCompression, ACompound,
  ADocument, AWritable: Boolean; const AInnerExt: string = '');
var
  N: Integer;
begin
  N := Length(GFormats);
  SetLength(GFormats, N + 1);
  GFormats[N].Ext := AExt;
  GFormats[N].ArchiveFile := AArchiveFile;
  GFormats[N].PureCompression := APureCompression;
  GFormats[N].Compound := ACompound;
  GFormats[N].InnerExt := AInnerExt;
  GFormats[N].Writable := AWritable;
  GFormats[N].Document := ADocument;
end;

procedure BuildTable;

  procedure AddArchive(const AExt: string; AWritable: Boolean = False);
  begin
    Add(AExt, True, False, False, False, AWritable);
  end;

  { A compound row: readable always, writable only when the outer compression is
    one the engine can create. }
  procedure AddCompound(const AExt, AInnerExt: string; AWritable: Boolean);
  begin
    Add(AExt, True, False, True, False, AWritable, AInnerExt);
  end;

  { A single-stream compression row. Its stored stream is unnamed, so the inner
    name is derived from the container's own name. }
  procedure AddCompression(const AExt: string; AWritable: Boolean = False);
  begin
    Add(AExt, True, True, False, False, AWritable);
  end;

begin
  { Containers and plain archives. Writable marks engine create support
    (7z/zip/tar/wim plus the single-stream compressors below). }
  AddArchive('7z', True);
  AddArchive('zip', True);
  AddArchive('rar');
  AddArchive('tar', True);
  AddArchive('wim', True);
  AddArchive('cab');
  AddArchive('iso');
  AddArchive('dmg');
  AddArchive('arj');
  AddArchive('lzh');
  AddArchive('lha');
  AddArchive('cpio');
  AddArchive('rpm');
  AddArchive('deb');
  AddArchive('apk');
  AddArchive('jar');
  AddArchive('war');
  AddArchive('ear');
  AddArchive('whl');
  AddArchive('xpi');
  AddArchive('msi');
  AddArchive('img');
  { Numeric volume parts: recognised as archives of a split set. }
  AddArchive('001');
  AddArchive('002');

  { Single-stream compressors. The read side understands all of them; only the
    ones the engine can write are Writable. gz/bz2/xz are written both as a
    plain stream and (through the compound rows below) as a ".tar" wrapper. }
  AddCompression('gz', True);
  AddCompression('bz2', True);
  AddCompression('xz', True);
  AddCompression('zst');
  AddCompression('lzma');
  AddCompression('lz');
  AddCompression('z');

  { Compound "<stem>.tar.<compression>" and the short aliases. The read side
    accepts every one of them; the write side only those whose outer
    compression the engine can write -- which is why ".tar.zst" and ".tar.lzma"
    are readable but not offered for creation. }
  AddCompound('tar.gz', '.tar', True);
  AddCompound('tgz', '.tar', True);
  AddCompound('tar.bz2', '.tar', True);
  AddCompound('tbz2', '.tar', True);
  AddCompound('tar.xz', '.tar', True);
  AddCompound('txz', '.tar', True);
  AddCompound('tar.zst', '.tar', False);
  AddCompound('tzst', '.tar', False);
  AddCompound('tar.lzma', '.tar', False);
  AddCompound('tlz', '.tar', False);

  { Office/OpenDocument containers: TyZip can show their contents (they are ZIP
    files) but a double click opens them in their application. }
  Add('doc', True, False, False, True, False);
  Add('dot', True, False, False, True, False);
  Add('xls', True, False, False, True, False);
  Add('xlt', True, False, False, True, False);
  Add('ppt', True, False, False, True, False);
  Add('pot', True, False, False, True, False);
  Add('pps', True, False, False, True, False);
  Add('docx', True, False, False, True, False);
  Add('docm', True, False, False, True, False);
  Add('dotx', True, False, False, True, False);
  Add('dotm', True, False, False, True, False);
  Add('xlsx', True, False, False, True, False);
  Add('xlsm', True, False, False, True, False);
  Add('xltx', True, False, False, True, False);
  Add('xltm', True, False, False, True, False);
  Add('pptx', True, False, False, True, False);
  Add('pptm', True, False, False, True, False);
  Add('potx', True, False, False, True, False);
  Add('potm', True, False, False, True, False);
  Add('ppsx', True, False, False, True, False);
  Add('ppsm', True, False, False, True, False);
  Add('odt', True, False, False, True, False);
  Add('ods', True, False, False, True, False);
  Add('odp', True, False, False, True, False);
  Add('odg', True, False, False, True, False);
  Add('epub', True, False, False, True, False);
end;

function TzFormatForName(const AName: string): TFormatEntry;
var
  Name, Suffix: string;
  I: Integer;
begin
  Result := Default(TFormatEntry);
  if AName = '' then Exit;
  Name := LowerCase(AName);
  for I := 0 to High(GFormats) do
    if GFormats[I].Ext <> '' then
    begin
      Suffix := '.' + GFormats[I].Ext;
      if (Length(Name) > Length(Suffix)) and
         (Copy(Name, Length(Name) - Length(Suffix) + 1, Length(Suffix)) = Suffix) then
      begin
        { Longer extensions win: ".tar.gz" is checked after "gz" would be walked
          over, so keep looking for a longer match. }
        if (Result.Ext = '') or (Length(GFormats[I].Ext) > Length(Result.Ext)) then
          Result := GFormats[I];
      end;
    end;
end;

function TzFormatCount: Integer;
begin
  Result := Length(GFormats);
end;

function TzFormatAt(AIndex: Integer): TFormatEntry;
begin
  if (AIndex >= 0) and (AIndex < Length(GFormats)) then
    Result := GFormats[AIndex]
  else
    Result := Default(TFormatEntry);
end;

function TzIsReadableWrapperName(const AName: string): Boolean;
begin
  Result := TzFormatForName(AName).Compound;
end;

function TzIsCompoundTarName(const AName: string): Boolean;
var
  E: TFormatEntry;
begin
  E := TzFormatForName(AName);
  Result := E.Compound and E.Writable;
end;

function TzIsPureCompressionName(const AName: string): Boolean;
begin
  Result := TzFormatForName(AName).PureCompression;
end;

function TzIsDocumentName(const AName: string): Boolean;
begin
  Result := TzFormatForName(AName).Document;
end;

procedure TzAppendArchiveExtensions(AList: TStringList);
var
  I: Integer;
begin
  if AList = nil then Exit;
  for I := 0 to High(GFormats) do
    if GFormats[I].ArchiveFile and (AList.IndexOf(GFormats[I].Ext) < 0) then
      AList.Add(GFormats[I].Ext);
end;

function TzCompressedInnerName(const APath, ADisplayName: string): string;
var
  N, D, Base: string;
  Entry: TFormatEntry;
  I: Integer;
begin
  N := ExtractFileName(APath);
  { Prefer a name that carries an extension. A caller may pass the folder an
    archive was opened from ("Downloads") as the first value; the display name
    is the second candidate. }
  if (N = '') or (ExtractFileExt(N) = '') then
  begin
    D := ExtractFileName(ADisplayName);
    if (D <> '') and (ExtractFileExt(D) <> '') then
      N := D
    else if N = '' then
      N := D;
  end;
  if N = '' then Exit('data');

  Entry := TzFormatForName(N);
  if Entry.Compound and (Entry.InnerExt <> '') then
  begin
    { "x.tar.gz" -> "x.tar"; the short alias "x.tgz" -> "x.tar". }
    I := LastDelimiter('.', N);
    if I > 1 then
    begin
      Base := Copy(N, 1, I - 1);
      if (Length(Base) >= Length(Entry.InnerExt)) and
         SameText(Copy(Base, Length(Base) - Length(Entry.InnerExt) + 1,
           Length(Entry.InnerExt)), Entry.InnerExt) then
        Exit(Base);
      Exit(Base + Entry.InnerExt);
    end;
  end;
  if Entry.PureCompression then
  begin
    I := LastDelimiter('.', N);
    if I > 1 then Exit(Copy(N, 1, I - 1));
  end;
  { Not a compression name at all: the name is already what the user should
    see (a plain ".7z" stream keeps its own name). }
  Result := N;
end;

function TzStreamInnerSuffix(const AName: string): string;
var
  N: string;
  I: Integer;
begin
  { The stream inside a compression wrapper is ALREADY DECOMPRESSED when 7-Zip
    hands it over: extracting entry 0 of "x.tar.zst" yields a tar, not zstd
    data. The suffix must therefore drop the compression extension -- keeping it
    produced a ".tar.zst" full of tar bytes that failed to open. A container
    extension in front (".cpio" in "x.cpio.zst") stays. }
  N := LowerCase(ExtractFileName(AName));
  I := LastDelimiter('.', N);
  if (I <= 1) or (I >= Length(N)) then Exit('.tar');
  N := Copy(N, 1, I - 1);
  I := LastDelimiter('.', N);
  if (I > 1) and (I < Length(N)) then
    Result := Copy(N, I, MaxInt)
  else
    Result := '.tar';
end;

initialization
  BuildTable;

end.
