program unit_dialogs_opts;
{$mode objfpc}{$H+}
{ The values behind the dialogs, without a window.

  tzip.dialogs is outside the headless suite (it needs the LCL), so the logic it
  used to carry -- format capabilities, preferred and compound extensions, the
  value behind each combo, and the settings merge -- lives in tzip.createopts
  and is asserted here. The two defects this locks down: a preset's level or
  code page was looked up by its NUMBER in a list of localised labels (so it
  never matched), and saving the settings page rebuilt the record from scratch,
  blanking the pane widths the main form owns. }
uses
  Classes, SysUtils, tzip.api, tzip.settings, tzip.createopts;

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

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure EqUInt(AGot, AWant: QWord; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure EqBool(AGot, AWant: Boolean; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %s want %s',
      [AMsg, BoolToStr(AGot, True), BoolToStr(AWant, True)]));
  end;
end;

{ The writable formats exactly as the 7-Zip 26.03 bridge reports them (see
  TzLoadFormats), plus a non-writable one and a hypothetical future writable
  single-stream format. The strings are copied from a real run so the test
  catches a change in what the engine says about itself. }
function FakeFormats: TFormatInfoArray;
begin
  Result := nil;
  SetLength(Result, 9);

  Result[0].Name := '7z';      Result[0].Ext := '7z';
  Result[0].CanUpdate := True;

  Result[1].Name := 'zip';     Result[1].Ext := 'zip z01 zipx jar xpi';
  Result[1].CanUpdate := True;

  Result[2].Name := 'tar';     Result[2].Ext := 'tar ova';
  Result[2].CanUpdate := True;

  Result[3].Name := 'gzip';    Result[3].Ext := 'gz gzip tgz tpz apk';
  Result[3].AddExt := '* * .tar .tar .tar';
  Result[3].CanUpdate := True;

  Result[4].Name := 'bzip2';   Result[4].Ext := 'bz2 bzip2 tbz2 tbz';
  Result[4].AddExt := '* * .tar .tar';
  Result[4].CanUpdate := True;

  Result[5].Name := 'xz';      Result[5].Ext := 'xz txz';
  Result[5].AddExt := '* .tar';
  Result[5].CanUpdate := True;

  Result[6].Name := 'wim';     Result[6].Ext := 'wim swm esd ppkg';
  Result[6].CanUpdate := True;

  Result[7].Name := 'rar';     Result[7].Ext := 'rar r00';
  Result[7].CanUpdate := False;

  { Not writable in 26.03; if a later engine makes it writable, the dialog must
    still not invent a ".tar.zst" name that the create path cannot unwrap. }
  Result[8].Name := 'zstd';    Result[8].Ext := 'zst tzst';
  Result[8].AddExt := '* .tar';
  Result[8].CanUpdate := True;
end;

{ --- format capabilities ------------------------------------------------- }

procedure TestCaps;
var
  C: TFormatCaps;
begin
  C := TzFormatCaps('7z');
  EqBool(C.Known, True, 'caps 7z: known');
  EqBool(C.HasMethod, True, 'caps 7z: method');
  EqBool(C.HasSolid, True, 'caps 7z: solid');
  EqBool(C.HasEncryptNames, True, 'caps 7z: encrypt names');
  EqBool(C.HasEncryptNames and C.HasEncrypt, True, 'caps 7z: encryption');
  EqBool(C.HasVolume, True, 'caps 7z: volume');
  EqBool(C.HasDictionary, True, 'caps 7z: dictionary');
  EqBool(C.SingleStream, False, 'caps 7z: container');

  C := TzFormatCaps('ZIP');
  EqBool(C.Known, True, 'caps zip: name is case insensitive');
  EqBool(C.HasAES, True, 'caps zip: AES');
  EqBool(C.HasCodePage, True, 'caps zip: codepage');
  EqBool(C.HasEncryptNames, False, 'caps zip: no header encryption');
  EqBool(C.HasSolid, False, 'caps zip: no solid');

  C := TzFormatCaps('tar');
  EqBool(C.Known, True, 'caps tar: known');
  EqBool(C.HasLevel or C.HasMethod or C.HasSolid, False, 'caps tar: no compression options');
  EqBool(C.SingleStream, False, 'caps tar: container');

  C := TzFormatCaps('gzip');
  EqBool(C.Known, True, 'caps gzip: known');
  EqBool(C.SingleStream, True, 'caps gzip: single stream');
  EqBool(C.HasLevel, True, 'caps gzip: level');
  EqBool(C.HasMethod, False, 'caps gzip: no method choice');
  EqBool(C.HasSolid, False, 'caps gzip: no solid');

  EqBool(TzFormatCaps('bzip2').SingleStream, True, 'caps bzip2: single stream');
  EqBool(TzFormatCaps('xz').SingleStream, True, 'caps xz: single stream');
  EqBool(TzFormatCaps('wim').HasMethod, True, 'caps wim: method');
  EqBool(TzFormatCaps('wim').HasVolume, False, 'caps wim: no volume');

  { An unknown writable format must be explicit, not silently treated as a
    single stream that needs a tar layer. }
  C := TzFormatCaps('zstd');
  EqBool(C.Known, False, 'caps zstd: not described');
  EqBool(C.SingleStream, False, 'caps zstd: no invented tar layer');
  EqBool(TzFormatCaps('nonsense').Known, False, 'caps unknown: not described');
end;

{ --- extensions ---------------------------------------------------------- }

procedure TestExtensions;
var
  F: TFormatInfoArray;
begin
  F := FakeFormats;

  EqStr(TzPreferredCreateExt('7z', F), '.7z', 'ext 7z');
  EqStr(TzPreferredCreateExt('zip', F), '.zip', 'ext zip');
  EqStr(TzPreferredCreateExt('tar', F), '.tar', 'ext tar');
  EqStr(TzPreferredCreateExt('gzip', F), '.gz', 'ext gzip picks the conventional one');
  EqStr(TzPreferredCreateExt('bzip2', F), '.bz2', 'ext bzip2');
  EqStr(TzPreferredCreateExt('xz', F), '.xz', 'ext xz');
  EqStr(TzPreferredCreateExt('wim', F), '.wim', 'ext wim');
  EqStr(TzPreferredCreateExt('rar', F), '', 'ext rar: not writable');
  EqStr(TzPreferredCreateExt('nonsense', F), '', 'ext unknown');

  EqStr(TzCompoundCreateExt('gzip', F), '.tar.gz', 'compound gzip');
  EqStr(TzCompoundCreateExt('bzip2', F), '.tar.bz2', 'compound bzip2');
  EqStr(TzCompoundCreateExt('xz', F), '.tar.xz', 'compound xz');
  EqStr(TzCompoundCreateExt('7z', F), '', 'compound 7z: container');
  EqStr(TzCompoundCreateExt('tar', F), '', 'compound tar: already a tar');
  EqStr(TzCompoundCreateExt('zstd', F), '', 'compound zstd: unknown format, no invented name');

  EqStr(TzCreateExtForSources('7z', 1, F), '.7z', 'suffix 7z one source');
  EqStr(TzCreateExtForSources('7z', 5, F), '.7z', 'suffix 7z many sources');
  EqStr(TzCreateExtForSources('zip', 3, F), '.zip', 'suffix zip many sources');
  EqStr(TzCreateExtForSources('gzip', 1, F), '.gz', 'suffix gzip one source');
  EqStr(TzCreateExtForSources('gzip', 2, F), '.tar.gz', 'suffix gzip many sources');
  EqStr(TzCreateExtForSources('bzip2', 2, F), '.tar.bz2', 'suffix bzip2 many sources');
  EqStr(TzCreateExtForSources('xz', 3, F), '.tar.xz', 'suffix xz many sources');
  EqStr(TzCreateExtForSources('zstd', 3, F), '.zst', 'suffix zstd: no compound fallback');
  EqStr(TzCreateExtForSources('rar', 3, F), '', 'suffix rar: not writable');

  EqBool(TzIsCompoundTarExt('.tar.gz'), True, 'compound ext .tar.gz');
  EqBool(TzIsCompoundTarExt('.TAR.GZ'), True, 'compound ext is case insensitive');
  EqBool(TzIsCompoundTarExt('.tar.zst'), False, 'compound ext .tar.zst unknown');
end;

{ --- default name for a create from one or several sources ----------------- }

procedure TestDefaultArchiveName;
var
  F: TFormatInfoArray;
  S: TStringList;
begin
  F := FakeFormats;
  S := TStringList.Create;
  try
    S.Add('/tmp/foo/a.txt');
    EqStr(TzDefaultArchiveName(S, '7z', F), 'a.7z',
      'default name: one file keeps its own name');
    S.Clear;
    S.Add('/tmp/foo/photos');
    EqStr(TzDefaultArchiveName(S, '7z', F), 'photos.7z',
      'default name: one folder keeps its own name');
    S.Clear;
    S.Add('/tmp/foo/a.txt');
    S.Add('/tmp/foo/b.txt');
    EqStr(TzDefaultArchiveName(S, '7z', F), 'foo.7z',
      'default name: several files use their folder name');
    S.Clear;
    S.Add('/tmp/foo/a.txt');
    S.Add('/tmp/foo/bar/b.txt');
    EqStr(TzDefaultArchiveName(S, '7z', F), 'foo.7z',
      'default name: shared nearest parent folder');
    S.Clear;
    S.Add('/tmp/foo/a.txt');
    S.Add('/Users/tom/b.txt');
    EqStr(TzDefaultArchiveName(S, '7z', F), 'foo.7z',
      'default name: no shared folder falls back to the first one');
    S.Clear;
    S.Add('/tmp/foo/a.txt');
    S.Add('/tmp/foo/b.txt');
    EqStr(TzDefaultArchiveName(S, 'gzip', F), 'foo.tar.gz',
      'default name: several files into gzip gain the tar layer');
    S.Clear;
    S.Add('/tmp/foo/a.txt');
    EqStr(TzDefaultArchiveName(S, 'gzip', F), 'a.gz',
      'default name: one file into gzip stays single-stream');
  finally
    S.Free;
  end;
end;

procedure TestArchiveName;
var
  F: TFormatInfoArray;
begin
  F := FakeFormats;

  EqStr(TzArchiveNameForCreate('photo', '7z', 1, F),
    'photo.7z', 'name: add missing extension');
  EqStr(TzArchiveNameForCreate('photo.7z', '7z', 1, F),
    'photo.7z', 'name: matching extension kept');
  EqStr(TzArchiveNameForCreate('photo.7Z', '7z', 1, F),
    'photo.7Z', 'name: matching extension keeps its case');
  EqStr(TzArchiveNameForCreate('photo.zip', '7z', 1, F),
    'photo.7z', 'name: extension follows the format');
  EqStr(TzArchiveNameForCreate('photo.tar.gz', 'zip', 1, F),
    'photo.zip', 'name: compound suffix replaced whole, not ".tar.zip"');
  EqStr(TzArchiveNameForCreate('photo.TAR.GZ', 'zip', 1, F),
    'photo.zip', 'name: compound suffix is matched case-insensitively');
  EqStr(TzArchiveNameForCreate('/tmp/out/photo.zip', '7z', 1, F),
    '/tmp/out/photo.7z', 'name: folder kept');
  EqStr(TzArchiveNameForCreate('photo.zip', 'gzip', 1, F),
    'photo.gz', 'name: gzip single source drops the old suffix');
  EqStr(TzArchiveNameForCreate('photo.gz', 'gzip', 2, F),
    'photo.tar.gz', 'name: gzip tree gains the tar layer');
  EqStr(TzArchiveNameForCreate('photo.tar.xz', 'gzip', 2, F),
    'photo.tar.xz', 'name: single-stream compound name left alone');
  EqStr(TzArchiveNameForCreate('photo.tar.gz', 'gzip', 2, F),
    'photo.tar.gz', 'name: same compound name unchanged');
  EqStr(TzArchiveNameForCreate('photo.zip', 'rar', 1, F),
    'photo.zip', 'name: non-writable format unchanged');
  EqStr(TzArchiveNameForCreate('', '7z', 1, F), '', 'name: empty path unchanged');
end;

{ --- combo value mapping ------------------------------------------------- }

procedure TestLevelMapping;
begin
  { The combo lists 0,1,3,5,7,9; the old code did Items.IndexOf(IntToStr(Level))
    against localised labels, so even level 5 never matched. }
  EqInt(TzLevelComboIndex(0), 0, 'level 0 -> Store');
  EqInt(TzLevelComboIndex(1), 1, 'level 1 -> Fastest');
  EqInt(TzLevelComboIndex(3), 2, 'level 3 -> Fast');
  EqInt(TzLevelComboIndex(5), 3, 'level 5 -> Normal');
  EqInt(TzLevelComboIndex(7), 4, 'level 7 -> Maximum');
  EqInt(TzLevelComboIndex(9), 5, 'level 9 -> Ultra');
  EqInt(TzLevelComboIndex(2), 1, 'level 2 -> nearest offered (tie goes lower)');
  EqInt(TzLevelComboIndex(4), 2, 'level 4 -> nearest offered');
  EqInt(TzLevelComboIndex(12), 5, 'level above the table saturates');
  EqInt(TzLevelComboIndex(-1), -1, 'level "not applicable" leaves the combo alone');

  EqInt(TzLevelValue(0), 0, 'level value 0');
  EqInt(TzLevelValue(3), 5, 'level value 3');
  EqInt(TzLevelValue(5), 9, 'level value 9');
  EqInt(TzLevelValue(-1), -1, 'level value out of range');
  EqInt(TzLevelValue(6), -1, 'level value out of range');
end;

procedure TestCodepageMapping;
begin
  EqInt(TzCodepageComboIndex(CodepageAuto), 0, 'codepage auto');
  EqInt(TzCodepageComboIndex(CodepageUtf8), 1, 'codepage UTF-8');
  EqInt(TzCodepageComboIndex(936), 2, 'codepage GBK');
  EqInt(TzCodepageComboIndex(54936), 3, 'codepage GB18030');
  EqInt(TzCodepageComboIndex(932), 4, 'codepage Shift-JIS');
  EqInt(TzCodepageComboIndex(28591), 5, 'codepage Latin-1');
  EqInt(TzCodepageComboIndex(950), -1, 'codepage not offered');
  EqUInt(TzCodepageValue(0), 0, 'codepage value auto');
  EqUInt(TzCodepageValue(5), 28591, 'codepage value Latin-1');
  EqUInt(TzCodepageValue(-1), 0, 'codepage value out of range');
  EqUInt(TzCodepageValue(6), 0, 'codepage value out of range');
end;

procedure TestVolumeMapping;
var
  I: Integer;
begin
  Check(Length(CreateVolumeLabels) = Length(CreateVolumeSizes),
    'volume labels and values have the same length');
  EqStr(CreateVolumeLabels[1], '100 MB', 'volume label 100 MB');
  EqStr(CreateVolumeLabels[6], '50 GB', 'volume label 50 GB');

  EqUInt(TzVolumeValue(0), 0, 'volume 0 = single file');
  EqUInt(TzVolumeValue(1), 100 * QWord(1024) * 1024, 'volume 100 MB');
  EqUInt(TzVolumeValue(4), 4 * QWord(1024) * 1024 * 1024, 'volume 4 GB');
  EqUInt(TzVolumeValue(6), 50 * QWord(1024) * 1024 * 1024, 'volume 50 GB');
  EqUInt(TzVolumeValue(-1), 0, 'volume out of range');
  EqUInt(TzVolumeValue(7), 0, 'volume out of range');

  { The preset path used to match the value against the combo TEXT via
    TzFormatSize, which renders "100.0 MB" against the label "100 MB" -- so a
    stored volume was never restored. }
  for I := 0 to High(CreateVolumeSizes) do
  begin
    EqInt(TzVolumeComboIndex(CreateVolumeSizes[I]), I,
      Format('volume round trip index %d', [I]));
    EqUInt(TzVolumeValue(TzVolumeComboIndex(CreateVolumeSizes[I])),
      CreateVolumeSizes[I], Format('volume round trip value %d', [I]));
  end;
  EqInt(TzVolumeComboIndex(42), -1, 'volume unknown size');
end;

procedure TestDictMapping;
begin
  EqInt(TzDictComboIndex(0), -1, 'dict size 0 means engine default, no combo entry');
  EqUInt(TzDictPresetBytes(0), QWord(1024) * 1024, 'dict index 0 is 1 MB');
  EqUInt(TzDictPresetBytes(6), QWord(64) * 1024 * 1024, 'dict index 6 is 64 MB');
  EqInt(TzDictComboIndex(QWord(64) * 1024 * 1024), 6, 'dict 64 MB maps back');
  EqInt(TzDictComboIndex(QWord(3) * 1024 * 1024), -1, 'dict size not offered');
  EqStr(TzDictPresetText(6), '64 MB', 'dict text 64 MB');
  EqStr(TzDictPresetText(10), '1 GB', 'dict text 1 GB');
  EqStr(TzDictPresetText(-1), '', 'dict text out of range');
  EqUInt(TzDictPresetBytes(11), 0, 'dict bytes out of range');
end;


{ --- exhaustive tables -------------------------------------------------- }
{ The spot checks above document individual decisions; the matrices below
  compare the whole table against an independently written expectation, so a
  row that is added, removed or reordered without touching the dialog fails
  here. }

type
  { Every capability flag the create dialog reacts to, one row per writable
    format. Written out by hand: this is the expected product behaviour, not a
    copy of the implementation table. }
  TCapsExpect = record
    Name: string;
    Method, Level, Solid, Encrypt, EncryptNames, AES, CodePage, Volume,
      Dict, Word, OneStream: Boolean;
  end;

const
  CapsExpect: array[0..6] of TCapsExpect = (
    (Name: '7z'; Method: True; Level: True; Solid: True; Encrypt: True;
     EncryptNames: True; AES: False; CodePage: False; Volume: True;
     Dict: True; Word: True; OneStream: False),
    (Name: 'zip'; Method: True; Level: True; Solid: False; Encrypt: True;
     EncryptNames: False; AES: True; CodePage: True; Volume: True;
     Dict: True; Word: True; OneStream: False),
    (Name: 'tar'; Method: False; Level: False; Solid: False; Encrypt: False;
     EncryptNames: False; AES: False; CodePage: False; Volume: False;
     Dict: False; Word: False; OneStream: False),
    (Name: 'gzip'; Method: False; Level: True; Solid: False; Encrypt: False;
     EncryptNames: False; AES: False; CodePage: False; Volume: False;
     Dict: False; Word: False; OneStream: True),
    (Name: 'bzip2'; Method: False; Level: True; Solid: False; Encrypt: False;
     EncryptNames: False; AES: False; CodePage: False; Volume: False;
     Dict: False; Word: False; OneStream: True),
    (Name: 'xz'; Method: False; Level: True; Solid: False; Encrypt: False;
     EncryptNames: False; AES: False; CodePage: False; Volume: False;
     Dict: False; Word: False; OneStream: True),
    (Name: 'wim'; Method: True; Level: True; Solid: False; Encrypt: False;
     EncryptNames: False; AES: False; CodePage: False; Volume: False;
     Dict: False; Word: False; OneStream: False)
  );

  { The extension each format is created with, and the ".tar." layer its
    single-stream variants need for a tree. }
  ExtExpect: array[0..6] of string =
    ('.7z', '.zip', '.tar', '.gz', '.bz2', '.xz', '.wim');
  CompoundExpect: array[0..6] of string =
    ('', '', '', '.tar.gz', '.tar.bz2', '.tar.xz', '');

  { Nearest offered compression level for every level a preset may hold. The
    combo rows are 0,1,3,5,7,9; a stored 2/4/6/8 has to land on the closest row
    instead of being dropped. -1 means "no level" and is checked separately. }
  LevelIndexExpect: array[0..12] of Integer =
    (0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5, 5);

procedure TestCapsMatrix;
var
  I: Integer;
  C: TFormatCaps;
  E: TCapsExpect;
begin
  Check(Length(CapsExpect) = Length(CreateFormatOrder),
    'caps matrix has one row per create format');
  for I := 0 to High(CapsExpect) do
  begin
    E := CapsExpect[I];
    EqStr(CreateFormatOrder[I], E.Name, Format('caps matrix order %d', [I]));
    C := TzFormatCaps(E.Name);
    Check(C.Known, E.Name + ': described');
    EqBool(C.HasMethod, E.Method, E.Name + ': method');
    EqBool(C.HasLevel, E.Level, E.Name + ': level');
    EqBool(C.HasSolid, E.Solid, E.Name + ': solid');
    EqBool(C.HasEncrypt, E.Encrypt, E.Name + ': password');
    EqBool(C.HasEncryptNames, E.EncryptNames, E.Name + ': file-name encryption');
    EqBool(C.HasAES, E.AES, E.Name + ': zip AES');
    EqBool(C.HasCodePage, E.CodePage, E.Name + ': name encoding');
    EqBool(C.HasVolume, E.Volume, E.Name + ': split volumes');
    EqBool(C.HasDictionary, E.Dict, E.Name + ': dictionary');
    EqBool(C.HasWordSize, E.Word, E.Name + ': word size');
    EqBool(C.SingleStream, E.OneStream, E.Name + ': single stream');
  end;

  { The capability table must not describe a format the engine cannot write. }
  Check(TzFormatCaps('rar').Known = False, 'caps: a read-only format is not offered');
end;

procedure TestExtensionMatrix;
var
  I: Integer;
  F: TFormatInfoArray;
  Name, Compound: string;
begin
  F := FakeFormats;
  for I := 0 to High(CreateFormatOrder) do
  begin
    Name := CreateFormatOrder[I];
    EqStr(TzPreferredCreateExt(Name, F), ExtExpect[I],
      Name + ': write extension');
    EqStr(TzCompoundCreateExt(Name, F), CompoundExpect[I],
      Name + ': compound extension');
    EqStr(TzCreateExtForSources(Name, 1, F), ExtExpect[I],
      Name + ': one source keeps the plain extension');

    Compound := CompoundExpect[I];
    if Compound <> '' then
    begin
      EqStr(TzCreateExtForSources(Name, 2, F), Compound,
        Name + ': two sources get the tar layer');
      EqStr(TzCreateExtForSources(Name, 5, F), Compound,
        Name + ': many sources get the tar layer');
      { The compound name is exactly the tar layer in front of the format's
        own extension, never a second table entry to keep in step. }
      EqStr(Compound, '.tar' + ExtExpect[I], Name + ': compound is tar plus extension');
    end
    else
    begin
      EqStr(TzCreateExtForSources(Name, 2, F), ExtExpect[I],
        Name + ': several sources keep the container extension');
      EqStr(TzCreateExtForSources(Name, 5, F), ExtExpect[I],
        Name + ': many sources keep the container extension');
    end;
  end;
end;

procedure TestNameMatrix;
var
  I: Integer;
  F: TFormatInfoArray;
  Name, Want: string;
begin
  F := FakeFormats;
  for I := 0 to High(CreateFormatOrder) do
  begin
    Name := CreateFormatOrder[I];
    EqStr(TzArchiveNameForCreate('photo.dat', Name, 1, F),
      'photo' + ExtExpect[I], Name + ': single source renamed to the format');
    Want := TzCreateExtForSources(Name, 2, F);
    EqStr(TzArchiveNameForCreate('photo.dat', Name, 2, F),
      'photo' + Want, Name + ': tree renamed to the format');
  end;

  { The name is rebuilt from a suffix table, not by appending to whatever the
    user typed: an existing ".tar.gz" must not survive as ".tar.zip". }
  EqStr(TzArchiveNameForCreate('photo.tar.bz2', 'tar', 1, F),
    'photo.tar', 'name: the container wins over the old compressor');
  EqStr(TzArchiveNameForCreate('photo.cpio.zst', 'xz', 1, F),
    'photo.cpio.xz', 'name: an foreign wrapper suffix is replaced, the base kept');
end;

procedure TestLevelMatrix;
var
  I, Level: Integer;
begin
  for Level := 0 to High(LevelIndexExpect) do
    EqInt(TzLevelComboIndex(Level), LevelIndexExpect[Level],
      Format('level %d maps to the nearest offered row', [Level]));
  EqInt(TzLevelComboIndex(-1), -1, 'level -1 (not applicable) leaves the row alone');
  EqInt(TzLevelComboIndex(-5), -1, 'a negative level leaves the row alone');

  for I := 0 to High(CreateLevels) do
  begin
    EqInt(TzLevelValue(I), CreateLevels[I], Format('level row %d value', [I]));
    EqInt(TzLevelComboIndex(TzLevelValue(I)), I,
      Format('level row %d round trip', [I]));
  end;
  for I := 1 to High(CreateLevels) do
    Check(CreateLevels[I] > CreateLevels[I - 1],
      Format('level rows are strictly ascending at %d', [I]));
end;

procedure TestCodepageMatrix;
var
  I, J: Integer;
begin
  for I := 0 to High(CreateCodepages) do
  begin
    EqUInt(TzCodepageValue(I), CreateCodepages[I], Format('codepage row %d value', [I]));
    EqInt(TzCodepageComboIndex(CreateCodepages[I]), I,
      Format('codepage row %d round trip', [I]));
  end;
  { A repeated value would make one row unreachable; distinctness is what lets
    the preset path find the row from the stored number at all. }
  for I := 0 to High(CreateCodepages) do
    for J := I + 1 to High(CreateCodepages) do
      Check(CreateCodepages[I] <> CreateCodepages[J],
        Format('codepage rows %d and %d differ', [I, J]));
  EqUInt(CreateCodepages[0], CodepageAuto, 'codepage row 0 means auto');
  EqUInt(CreateCodepages[1], CodepageUtf8, 'codepage row 1 is UTF-8');

  { Encodings the dialog does not offer must not be silently mapped to a row. }
  EqInt(TzCodepageComboIndex(437), -1, 'codepage DOS-437 is not offered');
  EqInt(TzCodepageComboIndex(950), -1, 'codepage Big5 is not offered');
  EqInt(TzCodepageComboIndex(1252), -1, 'codepage Windows-1252 is not offered');
  EqInt(TzCodepageComboIndex(28592), -1, 'codepage ISO-8859-2 is not offered');
end;

procedure TestTableShape;
var
  I: Integer;
begin
  Check(Length(CreateVolumeSizes) = Length(CreateVolumeLabels),
    'volume values and labels have one row each');
  Check(Length(CreateVolumeSizes) = 7, 'volume table has the seven documented rows');
  EqStr(CreateVolumeLabels[0], '', 'volume row 0 has no label: the dialog uses its own');
  for I := 1 to High(CreateVolumeSizes) do
  begin
    Check(CreateVolumeSizes[I] > CreateVolumeSizes[I - 1],
      Format('volume sizes are strictly ascending at %d', [I]));
    Check(CreateVolumeLabels[I] <> '', Format('volume label %d is not empty', [I]));
    EqUInt(CreateVolumeSizes[I] mod (1024 * 1024), 0,
      Format('volume size %d is a whole number of MiB', [I]));
  end;
  EqInt(TzVolumeComboIndex(0), 0, 'volume 0 finds the single-file row');

  Check(Length(CreateDictSizes) = 11, 'dictionary table has eleven rows');
  for I := 0 to High(CreateDictSizes) do
  begin
    Check(CreateDictSizes[I] > 0, Format('dictionary row %d is positive', [I]));
    if I > 0 then
      Check(CreateDictSizes[I] > CreateDictSizes[I - 1],
        Format('dictionary sizes ascend at %d', [I]));
    EqUInt(TzDictPresetBytes(I), QWord(CreateDictSizes[I]) * 1024 * 1024,
      Format('dictionary row %d bytes', [I]));
    Check(TzDictPresetText(I) <> '', Format('dictionary row %d has a label', [I]));
    EqInt(TzDictComboIndex(TzDictPresetBytes(I)), I,
      Format('dictionary row %d round trip', [I]));
  end;
end;

{ --- settings merge ------------------------------------------------------ }

function BaseSettings: TAppSettings;
begin
  Result := Default(TAppSettings);
  Result.ThemeName := 'default';
  Result.Mode := '';
  Result.Language := 'en';
  Result.ShowSidebar := True;
  Result.ShowPreview := True;
  Result.SidebarWidth := 333;
  Result.PreviewWidth := 444;
  Result.LastArchiveFormat := 'zip';
end;

procedure TestClampWidths;
begin
  EqInt(TzClampSidebarWidth(0), 160, 'sidebar width 0 is clamped up');
  EqInt(TzClampSidebarWidth(-40), 160, 'sidebar width negative is clamped up');
  EqInt(TzClampSidebarWidth(300), 300, 'sidebar valid width kept');
  EqInt(TzClampSidebarWidth(10000), 600, 'sidebar width clamped down');
  EqInt(TzClampSidebarWidth(160), 160, 'sidebar min is legal');
  EqInt(TzClampSidebarWidth(600), 600, 'sidebar max is legal');

  EqInt(TzClampPreviewWidth(0), 160, 'preview width 0 is clamped up');
  EqInt(TzClampPreviewWidth(444), 444, 'preview valid width kept');
  EqInt(TzClampPreviewWidth(5000), 900, 'preview width clamped down');
end;

{ The P1: saving the settings page replaced the whole record with defaults, so
  SidebarWidth/PreviewWidth became 0 and were persisted as 0. The dialog-owned
  fields must come from the dialog, everything else from the loaded record. }
procedure TestSettingsMerge;
var
  Base, Edited, Merged: TAppSettings;
begin
  Base := BaseSettings;
  Base.ShowHidden := False;
  Base.FoldersFirst := True;
  Base.ConfirmDelete := True;
  Base.OpenAfterExtract := False;
  Base.DefaultExtractDir := '/old';

  Edited := Default(TAppSettings);
  Edited.ThemeName := 'nord';
  Edited.Mode := 'dark';
  Edited.Language := 'zh_CN';
  Edited.ShowHidden := True;
  Edited.FoldersFirst := False;
  Edited.ConfirmDelete := False;
  Edited.OpenAfterExtract := True;
  Edited.DefaultExtractDir := '/new';
  { A dialog record built from defaults carries zero/False for everything it
    does not edit; those must not win. }

  Merged := TzApplyDialogSettings(Base, Edited);
  EqStr(Merged.ThemeName, 'nord', 'merge: theme from dialog');
  EqStr(Merged.Mode, 'dark', 'merge: mode from dialog');
  EqStr(Merged.Language, 'zh_CN', 'merge: language from dialog');
  EqBool(Merged.ShowHidden, True, 'merge: show hidden from dialog');
  EqBool(Merged.FoldersFirst, False, 'merge: folders first from dialog');
  EqBool(Merged.ConfirmDelete, False, 'merge: confirm delete from dialog');
  EqBool(Merged.OpenAfterExtract, True, 'merge: open after extract from dialog');
  EqStr(Merged.DefaultExtractDir, '/new', 'merge: extract dir from dialog');

  EqInt(Merged.SidebarWidth, 333, 'merge: sidebar width survives the dialog');
  EqInt(Merged.PreviewWidth, 444, 'merge: preview width survives the dialog');
  EqBool(Merged.ShowSidebar, True, 'merge: sidebar visibility survives the dialog');
  EqBool(Merged.ShowPreview, True, 'merge: preview visibility survives the dialog');
  EqStr(Merged.LastArchiveFormat, 'zip', 'merge: last format survives the dialog');

  { Widths read from a damaged or legacy preferences file are repaired on save
    instead of being written back as 0 or 100000. }
  Base := BaseSettings;
  Base.SidebarWidth := 0;
  Base.PreviewWidth := 999999;
  Merged := TzApplyDialogSettings(Base, Edited);
  EqInt(Merged.SidebarWidth, 160, 'merge: zero sidebar width repaired');
  EqInt(Merged.PreviewWidth, 900, 'merge: huge preview width repaired');
end;

procedure Run;
begin
  TestCaps;
  TestExtensions;
  TestArchiveName;
  TestDefaultArchiveName;
  TestLevelMapping;
  TestCodepageMapping;
  TestVolumeMapping;
  TestDictMapping;
  TestCapsMatrix;
  TestExtensionMatrix;
  TestNameMatrix;
  TestLevelMatrix;
  TestCodepageMatrix;
  TestTableShape;
  TestClampWidths;
  TestSettingsMerge;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails > 0 then Halt(1);
end;

begin
  Run;
end.
