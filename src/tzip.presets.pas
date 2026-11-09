{ Reusable archive-creation presets.

  A preset is a named TCreateSettings: someone who always makes "7z, ultra,
  solid, 16 MB dictionary" should not rebuild that from the dialog every time.

  Two rules are enforced here rather than left to the caller:

  - Passwords are NOT part of a preset. A preset is written to the settings file
    in plain text; storing a password there would put it on disk without the
    user ever asking for that. Every OTHER field is kept, including
    "encrypt file names": a preset whose header encryption silently turned off
    would leak the file list of archives made with it.
  - A preset is stored as the same INI keys the dialog already writes, so an
    added setting keeps working for presets saved by an older build.

  "Delete the source files" is deliberately NOT written to the file -- replaying
  that decision days later could destroy files the user meant to keep -- but it
  is not stripped from the in-memory settings either: that is a decision for the
  job dialog, not something a save may change behind the user's back. }
unit tzip.presets;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles,
  tzip.api;

const
  { Room for more without a format change: the dialog shows MaxPresetSlots. }
  MaxPresetSlots = 16;

type
  TArchivePreset = record
    Name: string;
    Settings: TCreateSettings;
  end;
  TArchivePresetArray = array of TArchivePreset;

{ The INI file presets live in: the same one as the rest of the settings, under
  their own section, so a user has one file to back up or delete. }
function PresetsIniPath: string;

{ Read the presets from their usual place. Never raises: an unreadable file
  just means there are none. }
function LoadPresetsFromApp: TArchivePresetArray;

{ Write APresets to their usual place. Returns False when the file could not be
  written -- a read-only home costs presets, not a crash. }
function SavePresetsToApp(const APresets: TArchivePresetArray): Boolean;

{ Settings with the fields a preset must not carry cleared. }
function PresetSafeSettings(const ASettings: TCreateSettings): TCreateSettings;

{ Save APresets into ASection of AIni. Slots beyond MaxPresetSlots are dropped. }
procedure SavePresets(AIni: TCustomIniFile; const ASection: string;
  const APresets: TArchivePresetArray);

{ Read the presets back, skipping malformed slots rather than failing. }
function LoadPresets(AIni: TCustomIniFile; const ASection: string): TArchivePresetArray;

{ The first slot index that is empty, or -1 when the list is full. }
function FirstFreeSlot(const APresets: TArchivePresetArray): Integer;

{ Add or replace the preset called AName. Returns the index it landed in. }
function PutPreset(var APresets: TArchivePresetArray;
  const AName: string; const ASettings: TCreateSettings): Integer;

{ Remove the slot at AIndex, shifting the rest up. }
procedure RemovePreset(var APresets: TArchivePresetArray; AIndex: Integer);

{ One-line description for the dialog's list: "7z · Ultra · solid". }
function DescribePreset(const APreset: TArchivePreset): string;

implementation

uses
  tzip.i18n;

const
  PresetSection = 'Presets';

function PresetsIniPath: string;
begin
  Result := TzConfigDir + 'TyZip.ini';
end;

function LoadPresetsFromApp: TArchivePresetArray;
var
  Ini: TIniFile;
begin
  Result := nil;
  try
    if not FileExists(PresetsIniPath) then Exit;
    Ini := TIniFile.Create(PresetsIniPath);
    try
      Result := LoadPresets(Ini, PresetSection);
    finally
      Ini.Free;
    end;
  except
    Result := nil;
  end;
end;

function SavePresetsToApp(const APresets: TArchivePresetArray): Boolean;
var
  Ini: TIniFile;
begin
  Result := False;
  try
    ForceDirectories(ExtractFileDir(PresetsIniPath));
    Ini := TIniFile.Create(PresetsIniPath);
    try
      SavePresets(Ini, PresetSection, APresets);
      Result := True;
    finally
      Ini.Free;
    end;
  except
    Result := False;
  end;
end;

function PresetSafeSettings(const ASettings: TCreateSettings): TCreateSettings;
begin
  Result := ASettings;
  { The ONLY field a preset must not carry: a preset is stored in a plain-text
    INI, and a password in it would be on disk without the user ever choosing
    "remember this".
    Header encryption used to be cleared here as well, which quietly made
    "7z + password + encrypt file names" presets write archives with a readable
    file list. DeleteSources is left alone too: the job dialog decides it per
    run and SavePresets simply does not persist it (see SavePresets). }
  Result.Password := '';
end;

function SlotKey(const ASlot: Integer; const ASuffix: string): string;
begin
  Result := Format('Preset%d%s', [ASlot, ASuffix]);
end;

procedure SavePresets(AIni: TCustomIniFile; const ASection: string;
  const APresets: TArchivePresetArray);
var
  I, N: Integer;
  S: TCreateSettings;
begin
  if AIni = nil then Exit;
  N := Length(APresets);
  if N > MaxPresetSlots then N := MaxPresetSlots;
  AIni.WriteInteger(ASection, 'Count', N);
  for I := 0 to N - 1 do
  begin
    S := PresetSafeSettings(APresets[I].Settings);
    AIni.WriteString(ASection, SlotKey(I, 'Name'), APresets[I].Name);
    AIni.WriteString(ASection, SlotKey(I, 'Format'), S.FormatName);
    AIni.WriteInteger(ASection, SlotKey(I, 'Level'), S.Level);
    AIni.WriteString(ASection, SlotKey(I, 'Method'), S.Method);
    AIni.WriteBool(ASection, SlotKey(I, 'Solid'), S.Solid);
    { Without this key a preset could not keep "encrypt file names" across a
      restart, which is the setting that keeps a password-protected archive's
      file list unreadable. }
    AIni.WriteBool(ASection, SlotKey(I, 'EncryptNames'), S.EncryptNames);
    AIni.WriteInteger(ASection, SlotKey(I, 'Threads'), S.Threads);
    AIni.WriteInt64(ASection, SlotKey(I, 'Volume'), Int64(S.VolumeSize));
    AIni.WriteInt64(ASection, SlotKey(I, 'Dict'), Int64(S.DictionarySize));
    AIni.WriteInteger(ASection, SlotKey(I, 'Word'), S.WordSize);
    AIni.WriteString(ASection, SlotKey(I, 'MF'), S.MatchFinder);
    AIni.WriteInteger(ASection, SlotKey(I, 'Passes'), S.NumPasses);
    AIni.WriteInt64(ASection, SlotKey(I, 'Codepage'), Int64(S.Codepage));
    AIni.WriteBool(ASection, SlotKey(I, 'ForceUtf8'), S.ForceUtf8);
    AIni.WriteString(ASection, SlotKey(I, 'Extra'), S.ExtraOptions);
  end;
end;

function LoadPresets(AIni: TCustomIniFile; const ASection: string): TArchivePresetArray;
var
  I, N: Integer;
  P: TArchivePreset;
begin
  Result := nil;
  if AIni = nil then Exit;
  N := AIni.ReadInteger(ASection, 'Count', 0);
  if N < 0 then N := 0;
  if N > MaxPresetSlots then N := MaxPresetSlots;
  for I := 0 to N - 1 do
  begin
    P.Name := AIni.ReadString(ASection, SlotKey(I, 'Name'), '');
    { A slot with no name is a hole left by an interrupted save; skip it rather
      than showing an unnameable entry. }
    if P.Name = '' then Continue;
    P.Settings := Default(TCreateSettings);
    P.Settings.FormatName := AIni.ReadString(ASection, SlotKey(I, 'Format'), '7z');
    P.Settings.Level := AIni.ReadInteger(ASection, SlotKey(I, 'Level'), 5);
    P.Settings.Method := AIni.ReadString(ASection, SlotKey(I, 'Method'), '');
    P.Settings.Solid := AIni.ReadBool(ASection, SlotKey(I, 'Solid'), False);
    P.Settings.EncryptNames := AIni.ReadBool(ASection, SlotKey(I, 'EncryptNames'), False);
    { DeleteSources is intentionally not read back: it is a per-job decision,
      and a preset must never turn "delete my sources" on by itself. }
    P.Settings.Threads := AIni.ReadInteger(ASection, SlotKey(I, 'Threads'), 0);
    P.Settings.VolumeSize := QWord(AIni.ReadInt64(ASection, SlotKey(I, 'Volume'), 0));
    P.Settings.DictionarySize := QWord(AIni.ReadInt64(ASection, SlotKey(I, 'Dict'), 0));
    P.Settings.WordSize := AIni.ReadInteger(ASection, SlotKey(I, 'Word'), 0);
    P.Settings.MatchFinder := AIni.ReadString(ASection, SlotKey(I, 'MF'), '');
    P.Settings.NumPasses := AIni.ReadInteger(ASection, SlotKey(I, 'Passes'), 0);
    P.Settings.Codepage := LongWord(AIni.ReadInt64(ASection, SlotKey(I, 'Codepage'), 0));
    P.Settings.ForceUtf8 := AIni.ReadBool(ASection, SlotKey(I, 'ForceUtf8'), False);
    P.Settings.ExtraOptions := AIni.ReadString(ASection, SlotKey(I, 'Extra'), '');
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := P;
  end;
end;

function FirstFreeSlot(const APresets: TArchivePresetArray): Integer;
begin
  if Length(APresets) >= MaxPresetSlots then Exit(-1);
  Result := Length(APresets);
end;

function PutPreset(var APresets: TArchivePresetArray;
  const AName: string; const ASettings: TCreateSettings): Integer;
var
  I: Integer;
begin
  Result := -1;
  if AName = '' then Exit;
  { Saving under an existing name replaces that slot, which is what a user means
    by saving again rather than ending up with two identical entries. }
  for I := 0 to High(APresets) do
    if SameText(APresets[I].Name, AName) then
    begin
      APresets[I].Settings := PresetSafeSettings(ASettings);
      Exit(I);
    end;
  if Length(APresets) >= MaxPresetSlots then Exit(-1);
  SetLength(APresets, Length(APresets) + 1);
  Result := High(APresets);
  APresets[Result].Name := AName;
  APresets[Result].Settings := PresetSafeSettings(ASettings);
end;

procedure RemovePreset(var APresets: TArchivePresetArray; AIndex: Integer);
var
  I: Integer;
begin
  if (AIndex < 0) or (AIndex > High(APresets)) then Exit;
  for I := AIndex to High(APresets) - 1 do
    APresets[I] := APresets[I + 1];
  SetLength(APresets, Length(APresets) - 1);
end;

function DescribePreset(const APreset: TArchivePreset): string;
const
  LevelNames: array[0..9] of string = ('Store', 'Fastest', 'Fast', 'Fast',
    'Normal', 'Normal', 'Normal', 'Maximum', 'Maximum', 'Ultra');
var
  Lvl: Integer;
begin
  Result := APreset.Settings.FormatName;
  if Result = '' then Result := '?';
  Lvl := APreset.Settings.Level;
  if Lvl < 0 then Exit;
  if Lvl > 9 then Lvl := 9;
  Result := Result + ' · ' + LevelNames[Lvl];
  if APreset.Settings.Solid then Result := Result + ' · solid';
end;

end.
