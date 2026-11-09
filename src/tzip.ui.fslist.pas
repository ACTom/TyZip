{ The filesystem listing control.

  A TTyShellListView subclass that feeds it the platform's icon list instead of
  the built-in five-glyph set, queues unknown suffixes for background resolution
  instead of blocking the paint loop on NSWorkspace, and adds the synthetic
  ".." row at index 0.

  Extracted from tzip.main. Note the re-published properties at the end of the
  class: TTyCustomListView declares most of its knobs in the PROTECTED section,
  which the form could reach while both lived in one unit and cannot from here. }
unit tzip.ui.fslist;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics,
  tyControls.Types, tyControls.Painter, tyControls.Controller,
  tyControls.ShellListView, tyControls.ListView,
  tyControls.ImageCollection, tyControls.FileSystem,
  tzip.ui.zebra;

type
  TZipIconNeedEvent = procedure(Sender: TObject; const AExt: string) of object;

  { ASet IsDir so the host can tell a bundle from a folder without stat-ing it
    again. Result -1 means "not mine"; the list then uses the suffix. }
  TZipEntryIconEvent = function(Sender: TObject; const AName: string;
    AIsDir: Boolean; out AImageIndex: Integer): Boolean of object;

  TZipShellListView = class(TTyShellListView)
  public
    IconImages: TTyVirtualImageList;
    IconCollection: TTyImageCollection;
    { lowercase suffix -> image index, so a folder full of files only asks the
      platform for each distinct type once (including the generic-file answer). }
    IconCache: TStringList;
    { A missing suffix is queued through this event instead of blocking the paint
      loop on NSWorkspace. The host resolves it on a background thread and repaints
      when the result arrives. }
    OnNeedIcon: TZipIconNeedEvent;
    { The synthetic ".." row at index 0 is activated through this event. }
    OnParentActivate: TNotifyEvent;
    { Ask the host for an icon this list cannot derive from the suffix. Used for
      an .app, which is a directory on disk but an application to the user: its
      icon belongs to that bundle, so only the host can resolve the path. }
    OnEntryIcon: TZipEntryIconEvent;
    function EnsureIcon(const AName, AExt: string; AFolder: Boolean): Integer;
    { ScrollIntoView puts the row in view on BOTH axes. The name column is wide,
      so restoring the selection to an archive's row after coming back from it
      parked the horizontal bar at the far right -- the columns should stay put.
      Uses only public members of the list (ScrollOffsetX / HScrollBar), so no
      change to TyControls is needed. }
    procedure ScrollIntoViewKeepingColumns(AIndex: Integer);
    function FileAt(AIndex: Integer): string; reintroduce;
    function SelectedFile: string; reintroduce;
    function DataSelCount: Integer;
  protected
    function GetItemCount: Integer; override;
    function GetItemText(AIndex, AColumn: Integer): string; override;
    function GetItemImageIndex(AIndex, AColumn: Integer): Integer; override;
    function GetItemGroup(AItemIndex: Integer): Integer; override;
    function CompareItems(AItemA, AItemB: Integer): Integer; override;
    procedure DoItemActivate(AIndex: Integer); override;
    procedure CommitEdit(AIndex: Integer; const AText: string); override;
    { Alternating row background; the base only fills selected/hovered rows. }
    procedure RenderItem(P: TTyPainter; AIndex: Integer; const ACell: TRect;
      const AStyle: TTyStyleSet; AStates: TTyStateSet); override;
  public
    { Re-published: see the unit comment. }
    property SmallImages;
    property LargeImages;
    property Header;
    property ItemCount;
    property ItemIndex;
    property Selected;
    property OnSelectItem;
    property OnColumnClick;
    property OnKeyDown;
  end;

implementation

procedure TZipShellListView.ScrollIntoViewKeepingColumns(AIndex: Integer);
var
  OldX: Integer;
begin
  OldX := ScrollOffsetX;
  ScrollIntoView(AIndex);
  if (HScrollBar <> nil) and (ScrollOffsetX <> OldX) then
    HScrollBar.Position := OldX;
end;

{ Zebra rows: a resting TyListViewItem has no fill of its own, so alternating
  rows get --surface-alt before the inherited selection/hover paint. }
procedure TZipShellListView.RenderItem(P: TTyPainter; AIndex: Integer;
  const ACell: TRect; const AStyle: TTyStyleSet; AStates: TTyStateSet);
var
  Fill: TTyFill;
  DisplayPos: Integer;
begin
  { AIndex is the ITEM index; sorting makes it differ from the visible row. }
  DisplayPos := ItemToDisplay(AIndex);
  if TzZebraRow(AIndex, DisplayPos) and not (tysSelected in AStates) and
     (ActiveController <> nil) then
  begin
    Fill := Default(TTyFill);
    Fill.Kind := tfkSolid;
    Fill.Color := ActiveController.Model.ResolveColorToken('--surface-alt', clWhite);
    P.FillBackground(ACell, Fill, 0);
  end;
  inherited RenderItem(P, AIndex, ACell, AStyle, AStates);
end;

function TZipShellListView.EnsureIcon(const AName, AExt: string;
  AFolder: Boolean): Integer;
var
  E: string;
  C: Integer;
begin
  E := LowerCase(Trim(AExt));
  while (E <> '') and (E[1] = '.') do Delete(E, 1, 1);
  if (IconCache <> nil) then
  begin
    C := IconCache.IndexOfName(E);
    if C >= 0 then
    begin
      Result := StrToIntDef(IconCache.ValueFromIndex[C], -1);
      { The disk cache can name a slot that this run's image list does not have
        (the app was built with a longer glyph table, or the entry is for a
        suffix whose bitmap failed to load). Ask for it again instead of handing
        the list an out-of-range index. }
      if Result >= 0 then Exit;
    end;
  end;
  { Never call NSWorkspace from a paint. Ask the host to resolve this suffix on
    its timer and paint the generic (or the cached) glyph meanwhile. }
  if Assigned(OnNeedIcon) then OnNeedIcon(Self, E);
  { A cached bitmap that is already in this run's image list can be shown while
    the background check runs, so the list does not start blank and then pop. }
  Result := IconImages.Names.IndexOf('file:' + E);
  if Result < 0 then Result := IconImages.Names.IndexOf('file');
  if Result < 0 then Result := 0;
end;

function TZipShellListView.GetItemCount: Integer;
begin
  { Row 0 is the synthetic ".." entry; the real directory entries start at 1. }
  Result := Length(Entries) + 1;
end;

function TZipShellListView.FileAt(AIndex: Integer): string;
begin
  if (AIndex <= 0) or (AIndex > High(Entries) + 1) then Exit('');
  Result := Entries[AIndex - 1].FullPath;
end;

function TZipShellListView.SelectedFile: string;
begin
  Result := FileAt(ItemIndex);
end;

function TZipShellListView.DataSelCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to GetItemCount - 1 do
    if Selected[I] then Inc(Result);
end;

function TZipShellListView.GetItemText(AIndex, AColumn: Integer): string;
begin
  if AIndex = 0 then
  begin
    if AColumn = 0 then Result := '..' else Result := '';
    Exit;
  end;
  Result := inherited GetItemText(AIndex - 1, AColumn);
end;

function TZipShellListView.GetItemGroup(AItemIndex: Integer): Integer;
begin
  if AItemIndex = 0 then Exit(-1);
  Result := inherited GetItemGroup(AItemIndex - 1);
end;

function TZipShellListView.CompareItems(AItemA, AItemB: Integer): Integer;
begin
  { Keep the parent entry pinned above every real entry, including under an
    ascending or descending sort. }
  if AItemA = 0 then
  begin
    if AItemB = 0 then Result := 0 else Result := -1;
    Exit;
  end;
  if AItemB = 0 then Exit(1);
  Result := inherited CompareItems(AItemA - 1, AItemB - 1);
end;

procedure TZipShellListView.DoItemActivate(AIndex: Integer);
begin
  if AIndex = 0 then
  begin
    if Assigned(OnParentActivate) then OnParentActivate(Self);
    Exit;
  end;
  inherited DoItemActivate(AIndex - 1);
end;

procedure TZipShellListView.CommitEdit(AIndex: Integer; const AText: string);
begin
  if AIndex = 0 then Exit;
  inherited CommitEdit(AIndex - 1, AText);
end;

function TZipShellListView.GetItemImageIndex(AIndex, AColumn: Integer): Integer;
var
  E: string;
  Ent: TTyFsEntry;
begin
  if AColumn > 0 then Exit(-1);
  if (IconImages = nil) or (AIndex < 0) or (AIndex > Length(Entries)) then Exit(-1);
  if AIndex = 0 then
  begin
    Result := IconImages.Names.IndexOf('folder');
    if Result < 0 then Result := 0;
    Exit;
  end;
  Ent := Entries[AIndex - 1];
  { The host gets first refusal: an .app needs its own icon, which only the
    host's cache can resolve. The full path goes over, because a bundle's icon is
    keyed by where it lives. }
  if Assigned(OnEntryIcon) then
    if OnEntryIcon(Self, Ent.FullPath, Ent.IsDir, Result) then Exit;
  if Ent.IsDir then
  begin
    Result := IconImages.Names.IndexOf('folder');
    if Result < 0 then Result := 0;
    Exit;
  end;
  E := LowerCase(ExtractFileExt(Ent.Name));
  while (E <> '') and (E[1] = '.') do Delete(E, 1, 1);
  if E <> '' then
    Result := EnsureIcon('file:' + E, E, False)
  else
    Result := IconImages.Names.IndexOf('file');
  if Result < 0 then Result := IconImages.Names.IndexOf('file');
  if Result < 0 then Result := 0;
end;


end.
