{ Editing an entry with an external application, then writing it back.

  Double-clicking an entry extracts it to a temporary file and opens it. That
  has always worked; what it never did was notice that the file had changed and
  offer to put it back. This unit decides what counts as a change, so the
  decision can be tested without launching an editor.

  The rules that matter:

  - The file is only offered for write-back if its modification time moved past
    the moment it was extracted. An editor that opens and closes without saving
    must not trigger a rewrite, and neither must a viewer that touches the file.
  - An entry whose size or mtime is unchanged is NOT a change, even if the
    timestamp moved by a second or two: many editors touch on save and some
    filesystems round timestamps. }
unit tzip.editwrite;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { One entry that was extracted for editing. }
  TEditSession = record
    { Where the entry was extracted to. }
    TempPath: string;
    { Its path inside the archive. }
    EntryPath: string;
    { The archive it came from. }
    ArchivePath: string;
    { When the extraction finished. A modification at or before this is the
      act of extracting, not of editing. }
    ExtractedAt: TDateTime;
    { Size at extraction time, so a rewrite that happens to keep the timestamp
      can still be recognised as a change when the size moved. }
    OriginalSize: Int64;
  end;

{ True when APath looks edited since the session was created.

  A missing file is not an edit -- the user may have deleted the temporary copy,
  and there is then nothing to write back. }
function FileWasEdited(const ASession: TEditSession; out AReason: string): Boolean;

{ Build the session for an entry just extracted. Returns a session with an
  empty TempPath when the file does not exist. }
function StartEditSession(const AArchivePath, AEntryPath, ATempPath: string;
  AExtractedAt: TDateTime): TEditSession;

implementation

function StartEditSession(const AArchivePath, AEntryPath, ATempPath: string;
  AExtractedAt: TDateTime): TEditSession;
var
  SR: TSearchRec;
begin
  Result := Default(TEditSession);
  Result.ArchivePath := AArchivePath;
  Result.EntryPath := AEntryPath;
  Result.ExtractedAt := AExtractedAt;
  if ATempPath = '' then Exit;
  if not FileExists(ATempPath) then Exit;
  Result.TempPath := ATempPath;
  if FindFirst(ATempPath, faAnyFile, SR) = 0 then
  begin
    Result.OriginalSize := SR.Size;
    FindClose(SR);
  end;
end;

function FileWasEdited(const ASession: TEditSession; out AReason: string): Boolean;
var
  SR: TSearchRec;
  Found: Boolean;
  Modified: TDateTime;
begin
  Result := False;
  AReason := '';
  if ASession.TempPath = '' then
  begin
    AReason := 'no temp file';
    Exit;
  end;
  if not FileExists(ASession.TempPath) then
  begin
    { Deleting the temporary copy is not an edit to write back. }
    AReason := 'temp file is gone';
    Exit;
  end;
  Found := FindFirst(ASession.TempPath, faAnyFile, SR) = 0;
  if not Found then
  begin
    AReason := 'cannot stat temp file';
    Exit;
  end;
  try
    { A size change is the clearest signal and does not depend on timestamp
      resolution, so it is checked first. }
    if SR.Size <> ASession.OriginalSize then
    begin
      AReason := Format('size %d -> %d', [ASession.OriginalSize, SR.Size]);
      Exit(True);
    end;
    { TimeStamp is the TSearchRec's own conversion (and the one with the
      higher-resolution find data when the platform provides it). }
    Modified := SR.TimeStamp;
    { A whole second of slack: the extraction time is taken with millisecond
      precision but FAT and some network shares store whole seconds, so a file
      that was merely extracted can otherwise look edited. }
    if Modified > ASession.ExtractedAt + (1 / SecsPerDay) then
    begin
      AReason := Format('mtime %s > %s',
        [DateTimeToStr(Modified), DateTimeToStr(ASession.ExtractedAt)]);
      Exit(True);
    end;
    AReason := 'unchanged';
  finally
    FindClose(SR);
  end;
end;

end.
