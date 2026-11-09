program api_backend_p0;
{$mode objfpc}{$H+}
{$codepage utf8}
{ Regression tests for the P0 defects in backend/tz7z.cpp (ticket 03).

  Each test names the defect it guards:

  * concurrent first use of the engine format table (unsynchronised g_Formats,
    and the function-local static behind tz7z_format_name),
  * the PROPVARIANT retry path in SetCommonProperties (shallow copy cleared and
    then reused), exercised with a BSTR-valued option plus a rejected extra,
  * ZIP end-of-central-directory scanning when the comment itself contains the
    PK\x05\x06 signature (the old scan picked the last match anywhere in the
    tail and truncated the archive at it),
  * create-before-delete: a failed create must leave the existing archive (and
    no half-written zero-byte replacement) in place,
  * the comment path on a non-ZIP archive: rewriting a 7z must not fail just
    because the caller also supplied a comment. }

uses
  cthreads, SysUtils, Classes, tzip.api;

var
  Fails, Passes: Integer;
  Root: string;

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

function ReadAllText(const APath: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(APath);
    Result := L.Text;
  finally L.Free; end;
end;

procedure WriteText(const APath, AText: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally L.Free; end;
end;

{ --- concurrent first load of the format table ------------------------- }

type
  TLoadThread = class(TThread)
  public
    Count: Integer;
    Failure: string;
    procedure Execute; override;
  end;

var
  StartGate: LongInt = 0;

procedure TLoadThread.Execute;
var
  Formats: TFormatInfoArray;
begin
  { Wait for the other threads so every call lands inside the first load. }
  while InterlockedCompareExchange(StartGate, 0, 0) = 0 do
    Sleep(0);
  try
    Formats := TzLoadFormats;
    Count := Length(Formats);
  except
    on E: Exception do
    begin
      Count := -1;
      Failure := E.Message;
    end;
  end;
end;

procedure TestConcurrentFormatTable;
const
  N = 16;
var
  Threads: array[0..N - 1] of TLoadThread;
  I, OkCount: Integer;
  Detail: string;
begin
  StartGate := 0;
  for I := 0 to N - 1 do
    Threads[I] := TLoadThread.Create(True);
  for I := 0 to N - 1 do
    Threads[I].Start;
  Sleep(50);
  InterlockedExchange(StartGate, 1);
  OkCount := 0;
  Detail := '';
  for I := 0 to N - 1 do
  begin
    Threads[I].WaitFor;
    if Threads[I].Count > 0 then
      Inc(OkCount)
    else
      Detail := Detail + Format(' thread%d=count%d err=[%s]',
        [I, Threads[I].Count, Threads[I].Failure]);
    Threads[I].Free;
  end;
  Check(OkCount = N, Format(
    'concurrent first load of the format table: %d/%d threads saw a non-empty table%s',
    [OkCount, N, Detail]));
end;

{ --- helpers ----------------------------------------------------------- }

type
  TInput = record
    DiskU: RawByteString;
    ArcU: RawByteString;
    Rec: TZ7ZInput;
  end;

procedure SetInput(var AInput: TInput; const ADisk, AArc: string; AIsDir: Boolean);
begin
  AInput.DiskU := UTF8Encode(ADisk);
  AInput.ArcU := UTF8Encode(AArc);
  AInput.Rec.DiskPath := PAnsiChar(AInput.DiskU);
  AInput.Rec.ArcPath := PAnsiChar(AInput.ArcU);
  AInput.Rec.IsDir := Ord(AIsDir);
end;

function OpenAndCount(const APath: string; out ACount: Integer; out AErr: string): Boolean;
var
  A: TTzArchive;
begin
  Result := False;
  ACount := -1;
  A := nil;
  if TzOpenArchive(APath, '', A, AErr) = TZ7Z_OK then
  try
    ACount := A.Count;
    Result := True;
  finally
    A.Free;
  end;
end;

function ExtractEntryText(const APath: string; const AOutDir: string;
  out AText: string; out AErr: string): Boolean;
var
  A: TTzArchive;
  R: Integer;
begin
  Result := False;
  AText := '';
  A := nil;
  R := TzOpenArchive(APath, '', A, AErr);
  if R <> TZ7Z_OK then
    Exit;
  try
    if A.Count < 1 then
    begin
      AErr := 'archive has no entries';
      Exit;
    end;
    ForceDirectories(AOutDir);
    R := TzExtract(A, [], AOutDir, '', AErr);
    if R <> TZ7Z_OK then
      Exit;
  finally
    A.Free;
  end;
  if not FileExists(AOutDir + '/payload.txt') then
  begin
    AErr := 'payload.txt was not extracted';
    Exit;
  end;
  AText := ReadAllText(AOutDir + '/payload.txt');
  Result := True;
end;

function CreateZip(const APath, AContent: string; out AErr: string): Integer;
var
  Inp: TInput;
  S: TCreateSettings;
begin
  WriteText(Root + '/payload-src.txt', AContent);
  SetInput(Inp, Root + '/payload-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 5;
  S.Method := 'Deflate';
  S.ForceUtf8 := True;
  Result := TzCreate(APath, S, [Inp.Rec], AErr);
end;

{ --- P0: PROPVARIANT retry path ---------------------------------------- }

procedure TestExtraOptionsRetry;
var
  Inp: TInput;
  S: TCreateSettings;
  R: Integer;
  Err, Z, Dest, Text: string;
begin
  Z := Root + '/extra.7z';
  Dest := Root + '/extra-out';
  WriteText(Root + '/extra-src.txt', 'retry-path');
  SetInput(Inp, Root + '/extra-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 5;
  S.Method := 'LZMA2';   { a BSTR-valued option: this is what makes the old
                          shallow-copy retry free and then reuse the BSTR }
  S.Threads := 0;
  { The raw escape hatch is rejected by the handler, so SetProperties fails and
    the retry-without-extra path runs. }
  S.ExtraOptions := 'this-is-not-a-property=99';
  R := TzCreate(Z, S, [Inp.Rec], Err);
  Check(R = TZ7Z_OK, Format('extra options: create survives a rejected extra (%d, %s)', [R, Err]));
  Check(FileExists(Z), 'extra options: the archive was written');
  if R = TZ7Z_OK then
  begin
    Check(ExtractEntryText(Z, Dest, Text, Err),
      'extra options: the archive built by the retry extracts (' + Err + ')');
    EqStr(Trim(Text), 'retry-path', 'extra options: the extracted payload is intact');
  end;
end;

{ --- P0: ZIP comment written when the comment contains PK\x05\x06 ------ }

procedure TestCommentWithEocdSignature;
var
  S: TCreateSettings;
  R: Integer;
  Err, Z, Comment, Text, Dest: string;
  A: TTzArchive;
  Count: Integer;
begin
  Z := Root + '/sig-comment.zip';
  Dest := Root + '/sig-comment-out';
  R := CreateZip(Z, 'comment-target', Err);
  Check(R = TZ7Z_OK, 'comment signature: setup zip (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;

  { The comment itself contains the end-of-central-directory signature. The old
    writer scanned backwards for the LAST signature in the tail, found this one,
    and truncated the real record. }
  Comment := 'before' + #$50#$4B#$05#$06 + 'after';
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 5;
  S.ForceUtf8 := True;
  R := TzModify(Z, '', S, [], [], Err, nil, Comment, True);
  Check(R = TZ7Z_OK, Format('comment signature: modify stores the comment (%d, %s)', [R, Err]));

  A := nil;
  if TzOpenArchive(Z, '', A, Err) = TZ7Z_OK then
  try
    EqStr(A.Comment, Comment, 'comment signature: the comment round-trips');
    Count := A.Count;
  finally
    A.Free;
  end
  else
  begin
    Count := -1;
    Check(False, 'comment signature: the archive still opens (' + Err + ')');
  end;
  Check(Count = 1, Format('comment signature: the entry count survived (%d)', [Count]));
  Check(ExtractEntryText(Z, Dest, Text, Err),
    'comment signature: the payload still extracts (' + Err + ')');
  EqStr(Trim(Text), 'comment-target', 'comment signature: the payload is intact');
end;

{ --- P0: a failed create must not destroy the previous archive ---------- }

function CreateThatMustFail(const APath: string; out AErr: string): Integer;
var
  Inp: TInput;
  S: TCreateSettings;
begin
  WriteText(Root + '/fail-src.txt', 'replacement');
  SetInput(Inp, Root + '/fail-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := 'zip';
  S.Level := 5;
  { An encoder name the handler does not know: UpdateItems fails. The old code
    had already unlinked the target, so the user's archive was gone. }
  S.Method := 'NoSuchMethod';
  Result := TzCreate(APath, S, [Inp.Rec], AErr);
end;

procedure TestCreateFailureKeepsArchive;
var
  R: Integer;
  Err, Z, Text, Dest, Fresh: string;
  Count: Integer;
begin
  Z := Root + '/keep.zip';
  Dest := Root + '/keep-out';
  Fresh := Root + '/fresh-fail.zip';
  DeleteFile(Fresh);
  R := CreateZip(Z, 'original-payload', Err);
  Check(R = TZ7Z_OK, 'create failure: setup archive (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;

  R := CreateThatMustFail(Z, Err);
  Check(R <> TZ7Z_OK, Format('create failure: the bad create really failed (%d, %s)', [R, Err]));
  Check(FileExists(Z), 'create failure: the original archive still exists');
  Check(OpenAndCount(Z, Count, Err), 'create failure: the original archive still opens (' + Err + ')');
  Check(Count = 1, Format('create failure: the original still has its entry (%d)', [Count]));
  Check(ExtractEntryText(Z, Dest, Text, Err),
    'create failure: the original payload extracts (' + Err + ')');
  EqStr(Trim(Text), 'original-payload', 'create failure: the original payload is intact');

  R := CreateThatMustFail(Fresh, Err);
  Check(R <> TZ7Z_OK, 'create failure: the bad create on a fresh path failed');
  Check(not FileExists(Fresh), 'create failure: no zero-byte archive is left behind');
end;

{ --- P0: a comment request must not fail a non-ZIP rewrite ------------- }

procedure TestModifyCommentOnSevenZip;
var
  Inp: TInput;
  S: TCreateSettings;
  R: Integer;
  Err, Z, Dest, Text: string;
  A: TTzArchive;
  Comment: string;
begin
  Z := Root + '/comment-7z.7z';
  Dest := Root + '/comment-7z-out';
  WriteText(Root + '/seven-src.txt', 'seven-payload');
  SetInput(Inp, Root + '/seven-src.txt', 'payload.txt', False);
  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := 5;
  R := TzCreate(Z, S, [Inp.Rec], Err);
  Check(R = TZ7Z_OK, '7z comment: setup archive (' + Err + ')');
  if R <> TZ7Z_OK then
    Exit;

  S := Default(TCreateSettings);
  S.FormatName := '7z';
  S.Level := -1;
  { Before the fix this rewrote the archive, then failed to patch a ZIP comment
    into it and returned E_FORMAT, leaving the user with an error for an
    operation that had already replaced the file. }
  R := TzModify(Z, '', S, [], [], Err, nil, 'hello', True);
  Check(R = TZ7Z_OK, Format('7z comment: modify succeeds and ignores the comment (%d, %s)', [R, Err]));

  A := nil;
  if TzOpenArchive(Z, '', A, Err) = TZ7Z_OK then
  try
    Comment := A.Comment;
    EqStr(Comment, '', '7z comment: the unsupported comment is not invented');
  finally
    A.Free;
  end
  else
    Check(False, '7z comment: the rewritten archive still opens (' + Err + ')');
  Check(ExtractEntryText(Z, Dest, Text, Err),
    '7z comment: the rewritten archive extracts (' + Err + ')');
  EqStr(Trim(Text), 'seven-payload', '7z comment: the payload is intact');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-backend-p0-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  { Must be the first API call: the race is in the very first load. }
  WriteLn('-- concurrent first load of the format table');
  TestConcurrentFormatTable;

  WriteLn('-- extra options retry / PROPVARIANT ownership');
  TestExtraOptionsRetry;

  WriteLn('-- ZIP comment containing an EOCD signature');
  TestCommentWithEocdSignature;

  WriteLn('-- failed create keeps the previous archive');
  TestCreateFailureKeepsArchive;

  WriteLn('-- comment request on a 7z rewrite');
  TestModifyCommentOnSevenZip;

  ExecuteProcess('/bin/rm', ['-rf', Root]);
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
