{ Where the window is, where it was, and how that is drawn as a breadcrumb.

  TMainForm used to keep the back/forward stacks as two dynamic arrays of a record
  and rebuild the breadcrumb by splitting paths inline in the middle of event
  handlers. Both are pure bookkeeping: no widget is touched while deciding what
  the previous location was, or what the trail from the volume root to the open
  archive should read. Keeping them here means the rules (a pushed state never
  repeats, forward history dies on a new branch, a crumb knows what following it
  means) can be tested without a window.

  Layer: controller. Uses the engine's context type to name an archive location,
  never LCL and never tzip.main. }
unit tzip.navstate;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tzip.engine;

type
  TNavKind = (nkFiles, nkArchive);

  { One place the window can be. The context is borrowed, not owned: the window
    keeps its own lifetime list of contexts. }
  TNavState = record
    Kind: TNavKind;
    FsPath: string;
    Ctx: TArchiveContext;
    Inner: string;
  end;
  TNavStateArray = array of TNavState;

  TNavHistory = class
  private
    FBack: TNavStateArray;
    FForward: TNavStateArray;
    class function SameNav(const A, B: TNavState): Boolean; static;
  public
    { Record where the window is now, before moving away. A new location ends the
      forward branch. Pushing the same place twice is a no-op. }
    procedure PushBack(const ACurrent: TNavState);
    function CanGoBack: Boolean;
    function CanGoForward: Boolean;
    { Move one step back/forward. ACurrent is stored on the opposite stack. }
    function Back(const ACurrent: TNavState; out AState: TNavState): Boolean;
    function Forward(const ACurrent: TNavState; out AState: TNavState): Boolean;
    procedure Clear;
    { The stacks, oldest first. Read by the window when it frees contexts at
      teardown. }
    function BackStates: TNavStateArray;
    function ForwardStates: TNavStateArray;
    function BackCount: Integer;
    function ForwardCount: Integer;
  end;

type
  { What following a breadcrumb means. The window maps this to an action; the
    builder never encodes it as a string. }
  TCrumbKind = (
    ckFs,      { a folder on disk: Path }
    ckArchive, { the Nth archive in the open chain: ArchiveIndex }
    ckInner    { a folder inside the current archive: Path }
  );
  TCrumb = record
    Text: string;
    Kind: TCrumbKind;
    Path: string;
    ArchiveIndex: Integer;
  end;
  TCrumbArray = array of TCrumb;
  TNavNameArray = array of string;

{ The trail for a filesystem location: the volume root, then one crumb per path
  segment. ADisplayRoot is the name shown for the volume ("MacOS" on macOS). }
function FsBreadcrumbs(const ADisplayRoot, AFsPath: string): TCrumbArray;

{ The trail for an open archive: the folder it was opened from, then one crumb per
  archive in the chain (outermost first), then one per folder inside the current
  archive. }
function ArchiveBreadcrumbs(const ADisplayRoot, AOpenedFromFs: string;
  const AChainNames: TNavNameArray; const AInnerPath: string): TCrumbArray;

{ The path bar text for the current location, as the breadcrumb double-click
  offers it for editing. }
function BreadcrumbPathText(const AFsPath, AOpenedFromFs: string;
  const AChainNames: TNavNameArray; const AInnerPath: string): string;

implementation

{ TNavHistory }

class function TNavHistory.SameNav(const A, B: TNavState): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Ctx = B.Ctx) and
    SameText(A.FsPath, B.FsPath) and (A.Inner = B.Inner);
end;

procedure TNavHistory.PushBack(const ACurrent: TNavState);
var
  N: Integer;
begin
  N := Length(FBack);
  if (N > 0) and SameNav(FBack[N - 1], ACurrent) then Exit;
  SetLength(FBack, N + 1);
  FBack[N] := ACurrent;
  { A new branch: the old forward trail is unreachable. }
  SetLength(FForward, 0);
end;

function TNavHistory.CanGoBack: Boolean;
begin
  Result := Length(FBack) > 0;
end;

function TNavHistory.CanGoForward: Boolean;
begin
  Result := Length(FForward) > 0;
end;

function TNavHistory.Back(const ACurrent: TNavState;
  out AState: TNavState): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := Length(FBack);
  if N = 0 then Exit;
  AState := FBack[N - 1];
  SetLength(FBack, N - 1);
  SetLength(FForward, Length(FForward) + 1);
  FForward[High(FForward)] := ACurrent;
  Result := True;
end;

function TNavHistory.Forward(const ACurrent: TNavState;
  out AState: TNavState): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := Length(FForward);
  if N = 0 then Exit;
  AState := FForward[N - 1];
  SetLength(FForward, N - 1);
  SetLength(FBack, Length(FBack) + 1);
  FBack[High(FBack)] := ACurrent;
  Result := True;
end;

procedure TNavHistory.Clear;
begin
  SetLength(FBack, 0);
  SetLength(FForward, 0);
end;

function TNavHistory.BackStates: TNavStateArray;
begin
  Result := Copy(FBack);
end;

function TNavHistory.ForwardStates: TNavStateArray;
begin
  Result := Copy(FForward);
end;

function TNavHistory.BackCount: Integer;
begin
  Result := Length(FBack);
end;

function TNavHistory.ForwardCount: Integer;
begin
  Result := Length(FForward);
end;

{ Breadcrumbs }

procedure AddCrumb(var ACrumbs: TCrumbArray; const AText: string;
  AKind: TCrumbKind; const APath: string; AArchiveIndex: Integer = -1);
var
  N: Integer;
begin
  N := Length(ACrumbs);
  SetLength(ACrumbs, N + 1);
  ACrumbs[N].Text := AText;
  ACrumbs[N].Kind := AKind;
  ACrumbs[N].Path := APath;
  ACrumbs[N].ArchiveIndex := AArchiveIndex;
end;

{ Append one crumb per non-empty segment of APath, accumulating the path so each
  crumb carries the absolute location it stands for. }
procedure AddPathCrumbs(var ACrumbs: TCrumbArray; const APath: string;
  AKind: TCrumbKind);
var
  Parts: TStringList;
  I: Integer;
  P: string;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := APath;
    P := '';
    for I := 0 to Parts.Count - 1 do
      if Parts[I] <> '' then
      begin
        P := P + '/' + Parts[I];
        AddCrumb(ACrumbs, Parts[I], AKind, P);
      end;
  finally
    Parts.Free;
  end;
end;

function FsBreadcrumbs(const ADisplayRoot, AFsPath: string): TCrumbArray;
begin
  Result := nil;
  AddCrumb(Result, ADisplayRoot, ckFs, '/');
  AddPathCrumbs(Result, AFsPath, ckFs);
end;

function ArchiveBreadcrumbs(const ADisplayRoot, AOpenedFromFs: string;
  const AChainNames: TNavNameArray; const AInnerPath: string): TCrumbArray;
var
  Base: string;
  I: Integer;
begin
  Result := nil;
  Base := ExcludeTrailingPathDelimiter(AOpenedFromFs);
  if Base = '' then Base := '/';
  AddCrumb(Result, ADisplayRoot, ckFs, '/');
  AddPathCrumbs(Result, Base, ckFs);
  for I := 0 to High(AChainNames) do
    AddCrumb(Result, AChainNames[I], ckArchive, '', I);
  AddPathCrumbs(Result, AInnerPath, ckInner);
end;

function BreadcrumbPathText(const AFsPath, AOpenedFromFs: string;
  const AChainNames: TNavNameArray; const AInnerPath: string): string;
var
  Base: string;
  I: Integer;
begin
  { No archives open: the path bar simply shows the folder. }
  if Length(AChainNames) = 0 then
  begin
    if AFsPath = '' then Exit('/');
    Exit(AFsPath);
  end;
  Base := ExcludeTrailingPathDelimiter(AOpenedFromFs);
  if Base = '' then Base := '/';
  Result := Base;
  for I := 0 to High(AChainNames) do
    if Result = '/' then
      Result := Result + AChainNames[I]
    else
      Result := IncludeTrailingPathDelimiter(Result) + AChainNames[I];
  if AInnerPath <> '' then
    Result := IncludeTrailingPathDelimiter(
      IncludeTrailingPathDelimiter(Result) + AInnerPath);
  if Result = '' then Result := '/';
end;

end.
