program api_model_prefix;
{$mode objfpc}{$H+}
{ The ABI v3 limited extraction the preview needs: a big archive entry is read
  as a prefix on disk, so a 100 MB text file costs 2 MB, not a full temporary
  copy.

  Pinned here: max_bytes 0 means "no limit", a limit smaller than the entry
  writes exactly the limit and still succeeds, a limit larger than the entry
  writes the whole entry, and bad arguments are refused with TZ7Z_E_ARG before
  anything is written. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.engine;

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

procedure EqInt64(AGot, AWant: Int64; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

{ A 3 MB text file: big enough that a 64 KB prefix and a 2 MB prefix are
  distinguishable, small enough to keep the test fast. }
procedure WriteBigText(const APath: string; ASize: Int64);
var
  F: TFileStream;
  Block: AnsiString;
  Left: Int64;
  N: Integer;
begin
  Block := '0123456789abcdef' + LineEnding;
  F := TFileStream.Create(APath, fmCreate);
  try
    Left := ASize;
    while Left > 0 do
    begin
      N := Length(Block);
      if N > Left then N := Left;
      F.WriteBuffer(Block[1], N);
      Dec(Left, N);
    end;
  finally
    F.Free;
  end;
end;

function MakeZip(const APath: string): Boolean;
var
  Disk, Arc: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
begin
  Result := False;
  ForceDirectories(Root + '/src');
  WriteBigText(Root + '/src/big.txt', 3 * Int64(1024) * 1024);
  Disk := TStringList.Create;
  Arc := TStringList.Create;
  try
    Disk.Add(Root + '/src/big.txt');
    Arc.Add('big.txt');
    Set1 := TzCollectInputsMapped(Disk, Arc);
    try
      S := Default(TCreateSettings);
      S.FormatName := '7z';
      S.Level := 1;
      S.ForceUtf8 := True;
      if TzCreateArchive(APath, S, Set1.Recs, Err) <> TZ7Z_OK then
      begin
        WriteLn('setup: cannot create the archive: ', Err);
        Exit;
      end;
    finally
      TzInputSetFree(Set1);
    end;
    Result := FileExists(APath);
  finally
    Arc.Free;
    Disk.Free;
  end;
end;

function FileSize(const APath: string): Int64;
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmOpenRead);
  try
    Result := F.Size;
  finally
    F.Free;
  end;
end;

{ Compare the first AN bytes of two files, so a prefix is not just the right
  size but the right bytes. }
function SamePrefix(const A, B: string; AN: Integer): Boolean;
var
  FA, FB: TFileStream;
  I: Integer;
begin
  Result := False;
  FA := TFileStream.Create(A, fmOpenRead);
  try
    FB := TFileStream.Create(B, fmOpenRead);
    try
      for I := 0 to AN - 1 do
        if FA.ReadByte <> FB.ReadByte then Exit;
      Result := True;
    finally
      FB.Free;
    end;
  finally
    FA.Free;
  end;
end;

procedure TestPrefix(A: TTzArchive; const ASourceDir: string);
var
  R: Integer;
  Err, Out1, Out2: string;
begin
  Out1 := Root + '/prefix-64k.txt';
  Out2 := Root + '/prefix-2m.txt';
  { 64 KB: the decoder stops early and reports success. }
  R := TzExtractOnePrefix(A, 0, Out1, '', 64 * 1024, Err);
  EqInt(R, TZ7Z_OK, 'prefix 64k: succeeds (' + Err + ')');
  EqInt64(FileSize(Out1), 64 * 1024, 'prefix 64k: exact size');
  Check(SamePrefix(Root + '/src/big.txt', Out1, 64 * 1024),
    'prefix 64k: the bytes are the start of the entry');

  { 2 MB: the preview limit. }
  R := TzExtractOnePrefix(A, 0, Out2, '', 2 * Int64(1024) * 1024, Err);
  EqInt(R, TZ7Z_OK, 'prefix 2m: succeeds (' + Err + ')');
  EqInt64(FileSize(Out2), 2 * Int64(1024) * 1024, 'prefix 2m: exact size');
  Check(SamePrefix(Root + '/src/big.txt', Out2, 2 * 1024 * 1024),
    'prefix 2m: the bytes are the start of the entry');

  { 0 = no limit: the whole entry. }
  DeleteFile(Out1);
  R := TzExtractOnePrefix(A, 0, Out1, '', 0, Err);
  EqInt(R, TZ7Z_OK, 'prefix unlimited: succeeds (' + Err + ')');
  EqInt64(FileSize(Out1), 3 * Int64(1024) * 1024, 'prefix unlimited: full size');

  { A limit larger than the entry writes the whole entry, not zero padding. }
  DeleteFile(Out2);
  R := TzExtractOnePrefix(A, 0, Out2, '', 10 * Int64(1024) * 1024, Err);
  EqInt(R, TZ7Z_OK, 'prefix over-limit: succeeds (' + Err + ')');
  EqInt64(FileSize(Out2), 3 * Int64(1024) * 1024, 'prefix over-limit: full size');
end;

procedure TestArgErrors(A: TTzArchive);
var
  R: Integer;
  Err, Out1: string;
begin
  Out1 := Root + '/prefix-bad.txt';
  DeleteFile(Out1);

  { A negative index is the caller's bug; nothing may be written. }
  R := TzExtractOnePrefix(A, -1, Out1, '', 1024, Err);
  EqInt(R, TZ7Z_E_ARG, 'arg: negative index');
  Check(not FileExists(Out1), 'arg: negative index writes nothing');

  { Out of range: the engine checks before creating parents or the file. }
  R := TzExtractOnePrefix(A, 99, Out1, '', 1024, Err);
  EqInt(R, TZ7Z_E_ARG, 'arg: out-of-range index (' + Err + ')');
  Check(not FileExists(Out1), 'arg: out-of-range index writes nothing');

  { An empty output path cannot mean anything. }
  R := TzExtractOnePrefix(A, 0, '', '', 1024, Err);
  EqInt(R, TZ7Z_E_ARG, 'arg: empty output path');

  { A nil archive is refused by the facade instead of dereferenced. }
  R := TzExtractOnePrefix(nil, 0, Out1, '', 1024, Err);
  EqInt(R, TZ7Z_E_ARG, 'arg: nil archive');
end;

var
  A: TTzArchive;
  Err: string;
  R: Integer;
begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-prefix-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  Check(TzLoadLibrary(''), 'setup: the engine library loads');

  if not MakeZip(Root + '/big.7z') then
    Check(False, 'setup: the sample archive could not be made')
  else
  begin
    A := nil;
    R := TzOpenArchive(Root + '/big.7z', '', A, Err);
    Check(R = TZ7Z_OK, 'setup: the archive opens (' + Err + ')');
    if A <> nil then
    try
      TestPrefix(A, Root + '/src');
      TestArgErrors(A);
    finally
      A.Free;
    end;
  end;

  if FileExists(Root + '/prefix-64k.txt') then DeleteFile(Root + '/prefix-64k.txt');
  if FileExists(Root + '/prefix-2m.txt') then DeleteFile(Root + '/prefix-2m.txt');
  if FileExists(Root + '/prefix-bad.txt') then DeleteFile(Root + '/prefix-bad.txt');
  if FileExists(Root + '/big.7z') then DeleteFile(Root + '/big.7z');
  if FileExists(Root + '/src/big.txt') then DeleteFile(Root + '/src/big.txt');
  RemoveDir(Root + '/src');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
