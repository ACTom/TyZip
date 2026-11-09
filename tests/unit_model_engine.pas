program unit_model_engine;
{$mode objfpc}{$H+}
{ Split archives in the model layer: a volume, a volume series recognised from
  its siblings, and the update refusal that follows from it.

  Updating one part of a split set rewrites that part alone and leaves the other
  volumes disagreeing with the index, so CanUpdate has to say no for the base
  file as well -- not just for a name ending in ".001". }
uses
  SysUtils, Classes, tzip.api, tzip.engine;

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

function Touch(const APath: string): Boolean;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('x');
    L.SaveToFile(APath);
    Result := FileExists(APath);
  finally
    L.Free;
  end;
end;

procedure DeleteIfExists(const APath: string);
begin
  if FileExists(APath) then DeleteFile(APath);
end;

{ --- name based detection ------------------------------------------------- }

procedure TestNames;
begin
  Check(TzIsSplitArchivePart(Root + '/x.7z.001'), 'split: .001 is a part');
  Check(TzIsSplitArchivePart(Root + '/x.7z.002'), 'split: .002 is a part');
  Check(TzIsSplitArchivePart(Root + '/x.7z.010'), 'split: .010 is a part');
  Check(TzIsSplitArchivePart(Root + '/x.zip.z01'), 'split: .z01 is a part');
  Check(TzIsSplitArchivePart(Root + '/x.zip.z99'), 'split: .z99 is a part');
  { A plain archive name is not a part while no volumes sit beside it. }
  Check(not TzIsSplitArchivePart(Root + '/plain.zip'), 'split: plain zip is not');
  Check(not TzIsSplitArchivePart(Root + '/plain.7z'), 'split: plain 7z is not');
  Check(not TzIsSplitArchivePart(''), 'split: empty path is not');
end;

{ --- sibling detection ---------------------------------------------------- }

procedure TestSiblings;
begin
  DeleteIfExists(Root + '/sib.7z');
  DeleteIfExists(Root + '/sib.7z.001');
  Check(Touch(Root + '/sib.7z'), 'setup: base archive file exists');
  Check(not TzIsSplitArchivePart(Root + '/sib.7z'),
    'siblings: a lone .7z is not split');
  Check(Touch(Root + '/sib.7z.001'), 'setup: first volume exists');
  Check(TzIsSplitArchivePart(Root + '/sib.7z'),
    'siblings: .7z next to .7z.001 is split');
  DeleteIfExists(Root + '/sib.7z.001');

  DeleteIfExists(Root + '/sib2.zip');
  DeleteIfExists(Root + '/sib2.z01');
  Check(Touch(Root + '/sib2.zip'), 'setup: zip base exists');
  Check(not TzIsSplitArchivePart(Root + '/sib2.zip'),
    'siblings: a lone .zip is not split');
  Check(Touch(Root + '/sib2.z01'), 'setup: zip volume exists');
  Check(TzIsSplitArchivePart(Root + '/sib2.zip'),
    'siblings: .zip next to .z01 is split');
  DeleteIfExists(Root + '/sib2.z01');
end;

{ --- CanUpdate ------------------------------------------------------------ }

function MakeZip(const APath: string): Boolean;
var
  L: TStringList;
  Set1: TZInputSet;
  S: TCreateSettings;
  Err: string;
begin
  Result := False;
  L := TStringList.Create;
  try
    L.Text := 'hello' + LineEnding;
    L.SaveToFile(Root + '/src.txt');
    L.Clear;
    L.Add(Root + '/src.txt');
    S := Default(TCreateSettings);
    S.FormatName := 'zip';
    S.Level := 5;
    Set1 := TzCollectInputs(L, '');
    try
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
    L.Free;
  end;
end;

procedure TestCanUpdate;
var
  Ctx: TArchiveContext;
  Err: string;
  R: Integer;
begin
  DeleteIfExists(Root + '/upd.zip');
  DeleteIfExists(Root + '/upd.z01');
  if not MakeZip(Root + '/upd.zip') then
  begin
    Check(False, 'canupdate: setup failed');
    Exit;
  end;

  Ctx := nil;
  R := TzOpenContext(Root + '/upd.zip', 'upd.zip', '', nil, False, '',
    Ctx, Err);
  Check(R = TZ7Z_OK, 'canupdate: the archive opens (' + Err + ')');
  if Ctx = nil then Exit;
  try
    Check(Ctx.CanUpdate, 'canupdate: a plain archive can be updated');
    { A split ZIP keeps its earlier volumes as .z01 beside the last one. }
    Check(Touch(Root + '/upd.z01'), 'setup: a volume appears');
    Check(not Ctx.CanUpdate, 'canupdate: a set with a sibling volume is refused');
  finally
    Ctx.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'tyzip-engine-' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('FAIL cannot load the engine library');
    Halt(2);
  end;

  TestNames;
  TestSiblings;
  TestCanUpdate;

  DeleteIfExists(Root + '/x.7z');
  DeleteIfExists(Root + '/sib.7z');
  DeleteIfExists(Root + '/sib2.zip');
  DeleteIfExists(Root + '/upd.zip');
  DeleteIfExists(Root + '/upd.z01');
  DeleteIfExists(Root + '/src.txt');
  RemoveDir(Root);

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
