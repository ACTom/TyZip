program unit_model_payload;
{$mode objfpc}{$H+}
{ TZJob's per-kind payload records and the compatibility properties in front of
  them.

  Each kind stores only its own inputs; reading them back must give what was
  written; Clone must copy the active payload whole (including a fresh copy of
  the owned source list); and changing Kind must discard the old payload so no
  value or object leaks into the new kind. }
uses
  cthreads, SysUtils, Classes, tzip.api, tzip.engine, tzip.jobs, tzip.search;

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

procedure EqSettings(const A, B: TCreateSettings; const AMsg: string);
begin
  Check(SameText(A.FormatName, B.FormatName) and (A.Level = B.Level) and
    SameText(A.Method, B.Method) and (A.Solid = B.Solid) and
    (A.Threads = B.Threads) and (A.Password = B.Password) and
    (A.EncryptNames = B.EncryptNames) and (A.VolumeSize = B.VolumeSize) and
    (A.DictionarySize = B.DictionarySize) and (A.WordSize = B.WordSize) and
    SameText(A.MatchFinder, B.MatchFinder) and (A.NumPasses = B.NumPasses) and
    (A.Codepage = B.Codepage) and (A.ForceUtf8 = B.ForceUtf8) and
    SameText(A.ExtraOptions, B.ExtraOptions), AMsg);
end;

function SampleSettings: TCreateSettings;
begin
  Result := Default(TCreateSettings);
  Result.FormatName := '7z';
  Result.Level := 9;
  Result.Method := 'LZMA2';
  Result.Solid := True;
  Result.Threads := 4;
  Result.Password := 'pw';
  Result.EncryptNames := True;
  Result.VolumeSize := 1024;
  Result.DictionarySize := 4096;
  Result.WordSize := 32;
  Result.MatchFinder := 'bt4';
  Result.NumPasses := 3;
  Result.Codepage := 936;
  Result.ForceUtf8 := True;
  Result.ExtraOptions := 'mt=8';
end;

function SourceList: TStringList;
begin
  Result := TStringList.Create;
  Result.Add('/src/one.txt');
  Result.Add('/src/two.txt');
end;

{ --- open --------------------------------------------------------------- }

procedure TestOpen;
var
  J, C: TZJob;
  Ctx: TArchiveContext;
begin
  Ctx := TArchiveContext.Create(nil, 'parent.7z', '/tmp/parent.7z', nil, False, '');
  J := TZJob.Create(jkOpen);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.DisplayName := 'b.7z';
    J.Password := 'pw';
    J.Parent := Ctx;
    J.IsNested := True;
    J.OpenedFromFs := '/a/b.7z';
    EqStr(J.Path, '/a/b.7z', 'open: path');
    EqStr(J.Password, 'pw', 'open: password');
    Check(J.Parent = Ctx, 'open: parent context');
    Check(J.IsNested, 'open: nested flag');
    EqStr(J.OpenedFromFs, '/a/b.7z', 'open: opened-from');
    C := J.Clone;
    EqStr(C.Path, '/a/b.7z', 'open clone: path');
    EqStr(C.DisplayName, 'b.7z', 'open clone: display name');
    Check(C.Parent = Ctx, 'open clone: parent context');
    Check(C.IsNested, 'open clone: nested flag');
    EqStr(C.OpenedFromFs, '/a/b.7z', 'open clone: opened-from');
  finally
    C.Free;
    J.Free;
    Ctx.Free;
  end;
end;

{ --- list --------------------------------------------------------------- }

procedure TestList;
var
  J, C: TZJob;
  Ctx: TArchiveContext;
  Entries: TArchiveEntries;
  R: Integer;
  Err: string;
begin
  Ctx := TArchiveContext.Create(nil, 'ctx.7z', '/tmp/ctx.7z', nil, False, '');
  SetLength(Entries, 2);
  Entries[0] := Default(TArchiveEntry);
  Entries[0].Name := 'a.txt';
  Entries[0].Index := 0;
  Entries[1] := Default(TArchiveEntry);
  Entries[1].Name := 'b.txt';
  Entries[1].Index := 1;
  J := TZJob.Create(jkList);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.CtxRef := Ctx;
    J.InnerPath := 'sub';
    J.Filter := '.txt';
    J.SortCol := ascSize;
    J.SortDesc := True;
    J.SetEntries(Entries);
    EqStr(J.InnerPath, 'sub', 'list: inner path');
    EqStr(J.Filter, '.txt', 'list: filter');
    Check(J.SortCol = ascSize, 'list: sort column');
    Check(J.SortDesc, 'list: sort direction');
    Check(J.CtxRef = Ctx, 'list: context identity');
    C := J.Clone;
    EqStr(C.Path, '/a/b.7z', 'list clone: path');
    EqStr(C.InnerPath, 'sub', 'list clone: inner path');
    EqStr(C.Filter, '.txt', 'list clone: filter');
    Check(C.SortCol = ascSize, 'list clone: sort column');
    Check(C.SortDesc, 'list clone: sort direction');
    Check(C.CtxRef = Ctx, 'list clone: context identity');
    { The entry snapshot travels with the payload: a clone lists the same
      entries without the caller re-supplying them (root folder, so the
      'sub' filter for the original is not applied to the clone's run). }
    C.InnerPath := '';
    C.Start;
    C.WaitFor;
    Check(C.TakeResult(R, Err), 'list clone: produces a result');
    EqInt(R, TZ7Z_OK, 'list clone: listing succeeds');
    EqInt(Length(C.Listing), 2, 'list clone: both entries listed');
  finally
    C.Free;
    J.Free;
    Ctx.Free;
  end;
end;

{ --- extract / test ----------------------------------------------------- }

procedure TestExtract;
var
  J, C: TZJob;
  Idx: TLongWordArray;
begin
  SetLength(Idx, 2);
  Idx[0] := 3;
  Idx[1] := 9;
  J := TZJob.Create(jkExtract);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.Password := 'pw';
    J.Dest := '/out';
    J.Indices := Idx;
    EqStr(J.Path, '/a/b.7z', 'extract: path');
    EqStr(J.Dest, '/out', 'extract: dest');
    EqInt(Length(J.Indices), 2, 'extract: indices length');
    EqInt(J.Indices[1], 9, 'extract: indices content');
    C := J.Clone;
    EqStr(C.Dest, '/out', 'extract clone: dest');
    EqInt(Length(C.Indices), 2, 'extract clone: indices length');
    EqInt(C.Indices[0], 3, 'extract clone: indices content');
  finally
    C.Free;
    J.Free;
  end;
end;

procedure TestTest;
var
  J, C: TZJob;
  Idx: TLongWordArray;
begin
  SetLength(Idx, 1);
  Idx[0] := 2;
  J := TZJob.Create(jkTest);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.Indices := Idx;
    EqInt(Length(J.Indices), 1, 'test: indices length');
    C := J.Clone;
    EqInt(Length(C.Indices), 1, 'test clone: indices length');
    EqInt(C.Indices[0], 2, 'test clone: indices content');
  finally
    C.Free;
    J.Free;
  end;
end;

{ --- single-entry extraction -------------------------------------------- }

procedure TestExtractOne;
var
  J, C: TZJob;
begin
  J := TZJob.Create(jkExtractOne);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.EntryIndex := 7;
    J.OutFile := '/tmp/entry.txt';
    EqInt(J.EntryIndex, 7, 'extract-one: entry index');
    EqStr(J.OutFile, '/tmp/entry.txt', 'extract-one: out file');
    C := J.Clone;
    EqInt(C.EntryIndex, 7, 'extract-one clone: entry index');
    EqStr(C.OutFile, '/tmp/entry.txt', 'extract-one clone: out file');
  finally
    C.Free;
    J.Free;
  end;
end;

{ --- create ------------------------------------------------------------- }

procedure TestCreate;
var
  J, C: TZJob;
  S: TCreateSettings;
begin
  S := SampleSettings;
  J := TZJob.Create(jkCreate);
  C := nil;
  try
    J.Path := '/out/new.7z';
    J.ArcPrefix := 'root';
    J.Sources := SourceList;
    J.Settings := S;
    EqStr(J.ArcPrefix, 'root', 'create: arc prefix');
    Check(J.Sources <> nil, 'create: sources');
    EqInt(J.Sources.Count, 2, 'create: sources content');
    EqSettings(J.Settings, S, 'create: settings');
    C := J.Clone;
    Check(C.Sources <> nil, 'create clone: sources');
    Check(C.Sources <> J.Sources, 'create clone: sources are copied');
    EqInt(C.Sources.Count, 2, 'create clone: source count');
    EqStr(C.Sources[1], '/src/two.txt', 'create clone: source content');
    EqSettings(C.Settings, S, 'create clone: settings');
    EqStr(C.ArcPrefix, 'root', 'create clone: arc prefix');
    { The clone owns its list: freeing the clone must not touch the original. }
    C.Free;
    C := nil;
    EqInt(J.Sources.Count, 2, 'create: original list survives a clone free');
  finally
    C.Free;
    J.Free;
  end;
end;

{ --- modify ------------------------------------------------------------- }

procedure TestModify;
var
  J, C: TZJob;
  S: TCreateSettings;
  Rem: TLongWordArray;
begin
  S := SampleSettings;
  SetLength(Rem, 1);
  Rem[0] := 4;
  J := TZJob.Create(jkModify);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.ArcPrefix := 'p';
    J.Sources := SourceList;
    J.RemoveIndices := Rem;
    J.NewComment := 'a comment';
    J.SetComment := True;
    J.Settings := S;
    EqStr(J.NewComment, 'a comment', 'modify: comment');
    Check(J.SetComment, 'modify: comment flag');
    EqInt(Length(J.RemoveIndices), 1, 'modify: remove indices');
    C := J.Clone;
    EqStr(C.NewComment, 'a comment', 'modify clone: comment');
    Check(C.SetComment, 'modify clone: comment flag');
    EqInt(Length(C.RemoveIndices), 1, 'modify clone: remove indices');
    Check(C.Sources <> J.Sources, 'modify clone: sources are copied');
    EqInt(C.Sources.Count, 2, 'modify clone: source count');
    EqSettings(C.Settings, S, 'modify clone: settings');
  finally
    C.Free;
    J.Free;
  end;
end;

{ --- rename / convert --------------------------------------------------- }

procedure TestRename;
var
  J, C: TZJob;
  S: TCreateSettings;
begin
  S := SampleSettings;
  J := TZJob.Create(jkRename);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.RenameIndex := 5;
    J.RenameFrom := 'old.txt';
    J.RenameTo := 'new.txt';
    J.NewComment := 'c';
    J.SetComment := True;
    J.Settings := S;
    EqInt(J.RenameIndex, 5, 'rename: index');
    EqStr(J.RenameTo, 'new.txt', 'rename: target');
    C := J.Clone;
    EqInt(C.RenameIndex, 5, 'rename clone: index');
    EqStr(C.RenameFrom, 'old.txt', 'rename clone: from');
    EqStr(C.RenameTo, 'new.txt', 'rename clone: target');
    EqStr(C.NewComment, 'c', 'rename clone: comment');
    Check(C.SetComment, 'rename clone: comment flag');
    EqSettings(C.Settings, S, 'rename clone: settings');
  finally
    C.Free;
    J.Free;
  end;
end;

procedure TestConvert;
var
  J, C: TZJob;
  S: TCreateSettings;
begin
  S := SampleSettings;
  J := TZJob.Create(jkConvert);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.Dest := '/a/b.zip';
    J.Settings := S;
    EqStr(J.Dest, '/a/b.zip', 'convert: dest');
    C := J.Clone;
    EqStr(C.Dest, '/a/b.zip', 'convert clone: dest');
    EqSettings(C.Settings, S, 'convert clone: settings');
  finally
    C.Free;
    J.Free;
  end;
end;

{ --- search ------------------------------------------------------------- }

procedure TestSearch;
var
  J, C: TZJob;
  O: TSearchOptions;
begin
  O := DefaultSearchOptions('needle');
  O.Scope := ssBoth;
  O.Mode := smWildcard;
  O.CaseSensitive := True;
  J := TZJob.Create(jkSearch);
  C := nil;
  try
    J.Path := '/a/b.7z';
    J.DisplayName := 'b.7z';
    J.Password := 'pw';
    J.Options := O;
    EqStr(J.Path, '/a/b.7z', 'search: path');
    EqStr(J.Options.Query, 'needle', 'search: query');
    Check(J.Options.Scope = ssBoth, 'search: scope');
    Check(J.Options.Mode = smWildcard, 'search: mode');
    Check(J.Options.CaseSensitive, 'search: case sensitivity');
    C := J.Clone;
    EqStr(C.Path, '/a/b.7z', 'search clone: path');
    EqStr(C.Options.Query, 'needle', 'search clone: query');
    Check(C.Options.Scope = ssBoth, 'search clone: scope');
    Check(C.Options.CaseSensitive, 'search clone: case sensitivity');
  finally
    C.Free;
    J.Free;
  end;
end;

{ --- switching kind must not leak the old payload ----------------------- }

procedure TestKindSwitch;
var
  J: TZJob;
begin
  J := TZJob.Create(jkRename);
  try
    J.RenameIndex := 3;
    J.RenameTo := 'x.txt';
    J.NewComment := 'old';
    J.Kind := jkExtract;
    EqStr(J.RenameTo, '', 'switch: rename target does not cross kinds');
    EqStr(J.NewComment, '', 'switch: rename comment does not cross kinds');
    EqStr(J.Path, '', 'switch: path of the old kind is gone');
    { The old flat contract is kept: reads on a kind that does not own the
      field answer from the sentinel scratch, not from the old payload. }
    EqInt(J.RenameIndex, -1, 'switch: a different kind has no rename index');
    J.Kind := jkRename;
    EqInt(J.RenameIndex, -1, 'switch: a fresh rename starts at -1');
    EqStr(J.RenameTo, '', 'switch: a fresh rename has no target');
    J.Kind := jkExtractOne;
    EqInt(J.EntryIndex, -1, 'switch: a fresh extract-one starts at -1');
  finally
    J.Free;
  end;
end;

procedure TestKindSwitchReleasesSources;
var
  J: TZJob;
begin
  J := TZJob.Create(jkCreate);
  try
    J.Sources := SourceList;
    Check(J.Sources <> nil, 'switch: create has sources');
    J.Kind := jkConvert;
    Check(J.Sources = nil, 'switch: sources released with the old payload');
    EqStr(J.Path, '', 'switch: create path does not cross kinds');
  finally
    J.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  TestOpen;
  TestList;
  TestExtract;
  TestTest;
  TestExtractOne;
  TestCreate;
  TestModify;
  TestRename;
  TestConvert;
  TestSearch;
  TestKindSwitch;
  TestKindSwitchReleasesSources;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
