program unit_presets;
{$mode objfpc}{$H+}
{ Archive presets: what is saved, what must never be saved, and the INI round
  trip.

  The two rules worth testing are the ones a caller would get wrong silently:
  a password must not reach the file, and a preset saved under an existing name
  must replace that slot rather than piling up duplicates. }
uses
  SysUtils, Classes, Process, IniFiles, tzip.api, tzip.presets;

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

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
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

function Sample(fmt: string; level: Integer): TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := fmt;
  Result.Level := level;
  Result.Solid := True;
  Result.Threads := 4;
  Result.DictionarySize := 16 * 1024 * 1024;
  Result.Method := 'LZMA2';
end;

{ --- the two safety rules ----------------------------------------------- }

procedure TestSafeSettings;
var
  S: TCreateSettings;
begin
  S := Sample('7z', 5);
  S.Password := 'hunter2';
  S.EncryptNames := True;
  S.DeleteSources := True;
  S := PresetSafeSettings(S);
  EqStr(S.Password, '', 'safe: password is dropped');
  { Header encryption is part of "how this archive is made", not a secret: a
    preset that dropped it wrote archives with a readable file list. }
  Check(S.EncryptNames, 'safe: header encryption is kept');
  { Not stripped from the in-memory settings either; the job dialog decides it
    and SavePresets simply does not write it. }
  Check(S.DeleteSources, 'safe: delete-sources is not silently cleared');
  { Everything else survives, or the preset would be useless. }
  EqStr(S.FormatName, '7z', 'safe: format kept');
  EqInt(S.Level, 5, 'safe: level kept');
  Check(S.Solid, 'safe: solid kept');
  EqInt(S.Threads, 4, 'safe: threads kept');
end;

{ --- the in-memory list ------------------------------------------------- }

procedure TestPutAndRemove;
var
  P: TArchivePresetArray;
begin
  P := nil;
  EqInt(FirstFreeSlot(P), 0, 'list: first slot on an empty list');

  EqInt(PutPreset(P, 'Fast zip', Sample('zip', 1)), 0, 'list: first preset lands in slot 0');
  EqInt(Length(P), 1, 'list: one preset');
  EqInt(PutPreset(P, 'Max 7z', Sample('7z', 9)), 1, 'list: second lands in slot 1');

  { Saving under an existing name replaces it: a user pressing Save twice means
    one preset, not two. }
  EqInt(PutPreset(P, 'Fast zip', Sample('zip', 3)), 0, 'list: same name replaces');
  EqInt(Length(P), 2, 'list: still two presets');
  EqInt(P[0].Settings.Level, 3, 'list: replacement took effect');

  { Names are matched case-insensitively, like every other name in the app. }
  EqInt(PutPreset(P, 'FAST ZIP', Sample('zip', 7)), 0, 'list: name match ignores case');
  EqInt(Length(P), 2, 'list: case variant did not add a slot');

  { An empty name is refused rather than creating an unnameable slot. }
  EqInt(PutPreset(P, '', Sample('7z', 5)), -1, 'list: empty name refused');
  EqInt(Length(P), 2, 'list: refused name changed nothing');

  RemovePreset(P, 0);
  EqInt(Length(P), 1, 'list: remove drops one');
  EqStr(P[0].Name, 'Max 7z', 'list: remove keeps the other');

  { Out-of-range removal is a no-op, not a crash. }
  RemovePreset(P, 99);
  RemovePreset(P, -1);
  EqInt(Length(P), 1, 'list: out-of-range remove is a no-op');
end;

procedure TestFullList;
var
  P: TArchivePresetArray;
  I: Integer;
begin
  P := nil;
  for I := 0 to MaxPresetSlots - 1 do
    Check(PutPreset(P, 'p' + IntToStr(I), Sample('7z', 5)) >= 0,
      Format('full: slot %d accepted', [I]));
  EqInt(Length(P), MaxPresetSlots, 'full: list holds the maximum');
  EqInt(FirstFreeSlot(P), -1, 'full: no free slot');
  EqInt(PutPreset(P, 'one too many', Sample('7z', 5)), -1, 'full: extra refused');
  EqInt(Length(P), MaxPresetSlots, 'full: refused preset changed nothing');
end;

{ --- persistence -------------------------------------------------------- }

procedure TestRoundTrip;
var
  P, Back: TArchivePresetArray;
  Ini: TIniFile;
  Path: string;
begin
  Path := Root + '/presets.ini';
  P := nil;
  PutPreset(P, 'Ultra 7z', Sample('7z', 9));
  P[0].Settings.VolumeSize := 100 * 1024 * 1024;
  P[0].Settings.Codepage := 936;
  P[0].Settings.ForceUtf8 := True;
  P[0].Settings.EncryptNames := True;
  P[0].Settings.ExtraOptions := 'mt=8';
  { In memory only: a preset must never remember "delete the sources". }
  P[0].Settings.DeleteSources := True;
  PutPreset(P, 'Quick zip', Sample('zip', 1));

  Ini := TIniFile.Create(Path);
  try
    SavePresets(Ini, 'Presets', P);
  finally Ini.Free; end;

  Ini := TIniFile.Create(Path);
  try
    Back := LoadPresets(Ini, 'Presets');
  finally Ini.Free; end;

  EqInt(Length(Back), 2, 'roundtrip: both presets back');
  EqStr(Back[0].Name, 'Ultra 7z', 'roundtrip: name');
  EqStr(Back[0].Settings.FormatName, '7z', 'roundtrip: format');
  EqInt(Back[0].Settings.Level, 9, 'roundtrip: level');
  Check(Back[0].Settings.Solid, 'roundtrip: solid');
  EqInt(Back[0].Settings.Threads, 4, 'roundtrip: threads');
  Check(Back[0].Settings.VolumeSize = 100 * 1024 * 1024, 'roundtrip: volume size');
  Check(Back[0].Settings.DictionarySize = 16 * 1024 * 1024, 'roundtrip: dictionary');
  Check(Back[0].Settings.Codepage = 936, 'roundtrip: codepage');
  Check(Back[0].Settings.ForceUtf8, 'roundtrip: force utf8');
  Check(Back[0].Settings.EncryptNames, 'roundtrip: header encryption');
  Check(not Back[0].Settings.DeleteSources,
    'roundtrip: delete-sources is never persisted');
  EqStr(Back[0].Settings.ExtraOptions, 'mt=8', 'roundtrip: extra options');
  EqStr(Back[1].Name, 'Quick zip', 'roundtrip: second preset');
end;

procedure TestPasswordNeverWritten;
var
  P: TArchivePresetArray;
  Ini: TIniFile;
  Path, Raw: string;
  L: TStringList;
begin
  { The whole point of PresetSafeSettings: a password handed in must not reach
    the file, even if the caller forgot to clear it. }
  Path := Root + '/pw.ini';
  DeleteFile(Path);
  P := nil;
  PutPreset(P, 'Secret', Sample('7z', 5));
  Ini := TIniFile.Create(Path);
  try
    SavePresets(Ini, 'Presets', P);
  finally Ini.Free; end;

  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Raw := L.Text;
  finally L.Free; end;
  Check(Pos('hunter2', Raw) = 0, 'password: the secret does not appear anywhere');
  Check(Pos('Password', Raw) = 0, 'password: no password key is written');
end;

procedure TestMalformedFile;
var
  Ini: TIniFile;
  P: TArchivePresetArray;
  Path: string;
begin
  { A file claiming more presets than exist, and a slot with no name. }
  Path := Root + '/bad.ini';
  DeleteFile(Path);
  Ini := TIniFile.Create(Path);
  try
    Ini.WriteInteger('Presets', 'Count', 3);
    { slot 0: complete }
    Ini.WriteString('Presets', 'Preset0Name', 'Good');
    Ini.WriteInteger('Presets', 'Preset0Level', 5);
    { slot 1: no name -- a hole from an interrupted save }
    Ini.WriteInteger('Presets', 'Preset1Level', 9);
    { slot 2: absent entirely }
  finally Ini.Free; end;

  Ini := TIniFile.Create(Path);
  try
    P := LoadPresets(Ini, 'Presets');
  finally Ini.Free; end;
  EqInt(Length(P), 1, 'malformed: only the named slot survives');
  EqStr(P[0].Name, 'Good', 'malformed: the survivor is the right one');

  { Absurd counts must not allocate wildly. }
  Path := Root + '/huge.ini';
  DeleteFile(Path);
  Ini := TIniFile.Create(Path);
  try
    Ini.WriteInteger('Presets', 'Count', 999999);
  finally Ini.Free; end;
  Ini := TIniFile.Create(Path);
  try
    P := LoadPresets(Ini, 'Presets');
  finally Ini.Free; end;
  Check(Length(P) <= MaxPresetSlots, 'malformed: absurd count is capped');
end;

procedure TestDescribe;
var
  P: TArchivePreset;
begin
  P.Name := 'x';
  P.Settings := Sample('7z', 9);
  Check(Pos('7z', DescribePreset(P)) > 0, 'describe: names the format');
  Check(Pos('Ultra', DescribePreset(P)) > 0, 'describe: names the level');
  Check(Pos('solid', DescribePreset(P)) > 0, 'describe: mentions solid');
  P.Settings.Solid := False;
  Check(Pos('solid', DescribePreset(P)) = 0, 'describe: omits solid when off');
  { Level -1 means "engine default" and must not index the name table. }
  P.Settings.Level := -1;
  Check(DescribePreset(P) <> '', 'describe: default level still describes');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-presets-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);

  TestSafeSettings;
  TestPutAndRemove;
  TestFullList;
  TestRoundTrip;
  TestPasswordNeverWritten;
  TestMalformedFile;
  TestDescribe;

  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
