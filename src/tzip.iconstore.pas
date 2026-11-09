{ Which icon slot a file type or an application bundle owns, and what still has
  to be asked for.

  The window keeps the image list; this keeps the bookkeeping around it: the
  suffix-to-slot and bundle-key-to-slot tables, the FIFO of file types waiting to
  be resolved, the aged entries waiting to be re-checked, the "already re-checked
  this run" set and the bundles met outside the two cached application folders.

  It used to be five TStringLists living in TMainForm, each with its own rules
  embedded in the methods around it: sorted or not, case-sensitive or not,
  duplicates ignored or not, and a failed lookup could be remembered as slot -1
  (which every later request then read as "resolved"). Those rules are the state,
  so they live with it.

  Layer: controller. No LCL, no bitmap, no platform call. }
unit tzip.iconstore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tzip.iconkeys;

type
  TZIconStore = class
  private
    FExt: TStringList;        { suffix -> image slot }
    FApp: TStringList;        { cache key -> image slot }
    FPending: TStringList;    { suffixes to resolve, FIFO }
    FChecks: TStringList;     { aged suffixes to re-ask, FIFO }
    FSeen: TStringList;       { suffixes re-asked in this run }
    FAppPending: TStringList; { bundle paths to resolve on demand, FIFO }
    function Normalize(const AExt: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    { The suffix -> slot table handed to the file list, which reads it for the
      icons of files without a special handler. Do not hold on to it. }
    property ExtMap: TStringList read FExt;

    { --- file types ---------------------------------------------------- }

    function ExtKnown(const AExt: string): Boolean;
    { The image slot for AExt, or -1 when there is none (or a failed lookup was
      never allowed to become one). }
    function ExtIndex(const AExt: string): Integer;
    procedure SetExtIndex(const AExt: string; AIndex: Integer);
    { Forget a failed lookup so the next request tries again. }
    procedure ClearExtIndex(const AExt: string);

    { Ask for AExt unless it is known or already queued. False when nothing was
      queued. }
    function QueueExt(const AExt: string): Boolean;
    { The next file type to resolve, checks before pending; '' when idle. }
    function TakeNextExt: string;
    function HasExtWork: Boolean;

    { --- aged entries -------------------------------------------------- }

    { Queue an aged cache entry for a background re-check, once per run. }
    procedure AddCheck(const AExt: string);
    { Take the next aged entry, or '' when none is waiting. }
    function TakeCheck: string;
    { Mark AExt as re-checked this run. False when it already was. }
    function MarkChecked(const AExt: string): Boolean;

    { --- application bundles ------------------------------------------- }

    function AppIndex(const AKey: string): Integer;
    function AppKnown(const AKey: string): Boolean;
    procedure SetAppIndex(const AKey: string; AIndex: Integer);
    { How many bundle icons are known, for "did anything arrive" checks. }
    function AppCount: Integer;

    { Remember a bundle that needs its icon resolved on demand, once. }
    function QueueAppPath(const APath: string): Boolean;
    function TakeAppPath: string;
    function HasAppWork: Boolean;
    function AppPendingCount: Integer;
  end;

implementation

constructor TZIconStore.Create;
begin
  inherited Create;
  FExt := TStringList.Create;
  FExt.CaseSensitive := False;
  FExt.Sorted := True;
  FExt.Duplicates := dupIgnore;
  FApp := TStringList.Create;
  FApp.CaseSensitive := False;
  FApp.Sorted := True;
  FApp.Duplicates := dupIgnore;
  { A FIFO queue must NOT be sorted: deleting the first entry of a sorted
    TStringList raises "Operation not allowed on sorted list". }
  FPending := TStringList.Create;
  FPending.CaseSensitive := False;
  FPending.Duplicates := dupIgnore;
  FChecks := TStringList.Create;
  FChecks.CaseSensitive := False;
  FChecks.Duplicates := dupIgnore;
  FSeen := TStringList.Create;
  FSeen.CaseSensitive := False;
  FSeen.Sorted := True;
  FSeen.Duplicates := dupIgnore;
  FAppPending := TStringList.Create;
  FAppPending.CaseSensitive := False;
  FAppPending.Duplicates := dupIgnore;
end;

destructor TZIconStore.Destroy;
begin
  FAppPending.Free;
  FSeen.Free;
  FChecks.Free;
  FPending.Free;
  FApp.Free;
  FExt.Free;
  inherited Destroy;
end;

function TZIconStore.Normalize(const AExt: string): string;
begin
  Result := IconKeyName(AExt);
end;

function TZIconStore.ExtKnown(const AExt: string): Boolean;
var
  E: string;
begin
  E := Normalize(AExt);
  Result := (E <> '') and (FExt.IndexOfName(E) >= 0);
end;

function TZIconStore.ExtIndex(const AExt: string): Integer;
var
  E: string;
  I: Integer;
begin
  Result := -1;
  E := Normalize(AExt);
  if E = '' then Exit;
  I := FExt.IndexOfName(E);
  if I < 0 then Exit;
  Result := StrToIntDef(FExt.ValueFromIndex[I], -1);
end;

procedure TZIconStore.SetExtIndex(const AExt: string; AIndex: Integer);
var
  E: string;
  I: Integer;
  WasSorted: Boolean;
begin
  E := Normalize(AExt);
  { A failure is not knowledge: storing -1 made QueueExt treat the type as
    resolved for the rest of the session. }
  if (E = '') or (AIndex < 0) then Exit;
  I := FExt.IndexOfName(E);
  if I < 0 then
  begin
    FExt.Add(E + '=' + IntToStr(AIndex));
    Exit;
  end;
  { Writing by index on a sorted TStringList is refused by FPC even when the row
    was just found by name; drop the sort, rewrite, restore it. }
  WasSorted := FExt.Sorted;
  FExt.Sorted := False;
  try
    FExt[I] := E + '=' + IntToStr(AIndex);
  finally
    FExt.Sorted := WasSorted;
  end;
end;

procedure TZIconStore.ClearExtIndex(const AExt: string);
var
  E: string;
  I: Integer;
begin
  E := Normalize(AExt);
  if E = '' then Exit;
  I := FExt.IndexOfName(E);
  if I >= 0 then FExt.Delete(I);
end;

function TZIconStore.QueueExt(const AExt: string): Boolean;
var
  E: string;
begin
  Result := False;
  E := Normalize(AExt);
  if E = '' then Exit;
  if ExtKnown(E) then Exit;
  if FPending.IndexOf(E) >= 0 then Exit;
  FPending.Add(E);
  Result := True;
end;

function TZIconStore.TakeNextExt: string;
begin
  Result := '';
  if FChecks.Count > 0 then
  begin
    Result := FChecks[0];
    FChecks.Delete(0);
    Exit;
  end;
  if FPending.Count > 0 then
  begin
    Result := FPending[0];
    FPending.Delete(0);
  end;
end;

function TZIconStore.HasExtWork: Boolean;
begin
  Result := (FChecks.Count > 0) or (FPending.Count > 0);
end;

procedure TZIconStore.AddCheck(const AExt: string);
var
  E: string;
begin
  E := Normalize(AExt);
  if E = '' then Exit;
  if FSeen.IndexOf(E) >= 0 then Exit;
  if FChecks.IndexOf(E) >= 0 then Exit;
  FChecks.Add(E);
end;

function TZIconStore.TakeCheck: string;
begin
  Result := '';
  if FChecks.Count = 0 then Exit;
  Result := FChecks[0];
  FChecks.Delete(0);
end;

function TZIconStore.MarkChecked(const AExt: string): Boolean;
var
  E: string;
begin
  Result := False;
  E := Normalize(AExt);
  if E = '' then Exit;
  if FSeen.IndexOf(E) >= 0 then Exit;
  FSeen.Add(E);
  Result := True;
end;

function TZIconStore.AppIndex(const AKey: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if AKey = '' then Exit;
  I := FApp.IndexOfName(AKey);
  if I < 0 then Exit;
  Result := StrToIntDef(FApp.ValueFromIndex[I], -1);
end;

function TZIconStore.AppKnown(const AKey: string): Boolean;
begin
  Result := AppIndex(AKey) >= 0;
end;

procedure TZIconStore.SetAppIndex(const AKey: string; AIndex: Integer);
var
  I: Integer;
  WasSorted: Boolean;
begin
  if (AKey = '') or (AIndex < 0) then Exit;
  I := FApp.IndexOfName(AKey);
  if I < 0 then
  begin
    FApp.Add(AKey + '=' + IntToStr(AIndex));
    Exit;
  end;
  WasSorted := FApp.Sorted;
  FApp.Sorted := False;
  try
    FApp[I] := AKey + '=' + IntToStr(AIndex);
  finally
    FApp.Sorted := WasSorted;
  end;
end;

function TZIconStore.AppCount: Integer;
begin
  Result := FApp.Count;
end;

function TZIconStore.QueueAppPath(const APath: string): Boolean;
begin
  Result := False;
  if APath = '' then Exit;
  if FAppPending.IndexOf(APath) >= 0 then Exit;
  FAppPending.Add(APath);
  Result := True;
end;

function TZIconStore.TakeAppPath: string;
begin
  Result := '';
  if FAppPending.Count = 0 then Exit;
  Result := FAppPending[0];
  FAppPending.Delete(0);
end;

function TZIconStore.HasAppWork: Boolean;
begin
  Result := FAppPending.Count > 0;
end;

function TZIconStore.AppPendingCount: Integer;
begin
  Result := FAppPending.Count;
end;

end.
