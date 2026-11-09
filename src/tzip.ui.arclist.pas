{ The archive listing control.

  A TTyCustomListView in OwnerData mode -- the SAME control family as the
  filesystem list, which is the point: rows, cell insets, the icon slot and the
  header then come from one renderer, so the two panes cannot drift apart.

  The archive side used to be a TTyTreeView, and that layout pins the image to
  the cell's left edge with no per-cell padding at all (its only knob, Indent, is
  the image SLOT width). Every attempt to give it the filesystem list's white
  space therefore moved the icon without the name, or was undone by the next
  tree-layout change.

  The control knows nothing about archives: it asks a TArcListSource for the row
  count, cell text and image index, so it can be hosted by anything. }
unit tzip.ui.arclist;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ImgList, Controls, Graphics, LCLType,
  BGRABitmap, BGRABitmapTypes,
  tyControls.Types, tyControls.Painter, tyControls.Base, tyControls.Controller,
  tyControls.ScrollBar, tyControls.Columns, tyControls.ImageCollection,
  tyControls.ImageDraw, tyControls.Edit, tyControls.ListView.Layout,
  tyControls.ListView, tzip.ui.zebra;

type
  { What the list needs from whoever owns the data. }
  TArcListSource = class
  public
    function ArcListingCount: Integer; virtual; abstract;
    function ArcCellText(AIndex, AColumn: Integer): string; virtual; abstract;
    { -1 means "this cell has no glyph". }
    function ArcCellImage(AIndex: Integer): Integer; virtual; abstract;
  end;

  { A plain callback record, so the form can hand over three method pointers
    without inheriting from anything or renaming what it already has. }
  TArcListCallbacks = record
    GetCount: function: Integer of object;
    GetText: function(AIndex, AColumn: Integer): string of object;
    GetImage: function(AIndex: Integer): Integer of object;
  end;

  TArcCallbackSource = class(TArcListSource)
  private
    FCB: TArcListCallbacks;
  public
    constructor Create(const ACB: TArcListCallbacks);
    function ArcListingCount: Integer; override;
    function ArcCellText(AIndex, AColumn: Integer): string; override;
    function ArcCellImage(AIndex: Integer): Integer; override;
  end;

  TArcListView = class(TTyCustomListView)
  private
    FSource: TArcListSource;
    procedure SetSource(AValue: TArcListSource);
  protected
    function GetItemCount: Integer; override;
    function GetItemText(AIndex, AColumn: Integer): string; override;
    function GetItemImageIndex(AIndex, AColumn: Integer): Integer; override;
    { Alternating row background; the base only fills selected/hovered rows. }
    procedure RenderItem(P: TTyPainter; AIndex: Integer; const ACell: TRect;
      const AStyle: TTyStyleSet; AStates: TTyStateSet); override;
  public
    property Source: TArcListSource read FSource write SetSource;
    { TTyCustomListView declares these in its PROTECTED section. While this
      class was declared in the same unit as the form, the form could reach them;
      from another unit it cannot, so they are re-published here. }
    property SmallImages;
    property LargeImages;
    property OnItemActivate;
    property OnSelectItem;
    property OnColumnClick;
    property OnKeyDown;
    property OnContextPopup;
    { The drag-out gesture starts in the form's mouse handlers. }
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property PopupMenu;
    property Header;
    property ItemCount;
    property ItemIndex;
    property Selected;
  end;

implementation

constructor TArcCallbackSource.Create(const ACB: TArcListCallbacks);
begin
  inherited Create;
  FCB := ACB;
end;

function TArcCallbackSource.ArcListingCount: Integer;
begin
  if Assigned(FCB.GetCount) then Result := FCB.GetCount() else Result := 0;
end;

function TArcCallbackSource.ArcCellText(AIndex, AColumn: Integer): string;
begin
  if Assigned(FCB.GetText) then Result := FCB.GetText(AIndex, AColumn)
  else Result := '';
end;

function TArcCallbackSource.ArcCellImage(AIndex: Integer): Integer;
begin
  if Assigned(FCB.GetImage) then Result := FCB.GetImage(AIndex) else Result := -1;
end;

{ Zebra rows: a resting TyListViewItem has no fill of its own, so alternating
  rows get --surface-alt before the inherited selection/hover paint. }
procedure TArcListView.RenderItem(P: TTyPainter; AIndex: Integer;
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

procedure TArcListView.SetSource(AValue: TArcListSource);
begin
  if FSource = AValue then Exit;
  FSource := AValue;
  { The row count and the cells both come from the source, so a new one means
    the whole list has to be asked again. }
  if not (csDestroying in ComponentState) then
    Invalidate;
end;

function TArcListView.GetItemCount: Integer;
begin
  if FSource = nil then Exit(0);
  Result := FSource.ArcListingCount;
end;

function TArcListView.GetItemText(AIndex, AColumn: Integer): string;
begin
  if FSource = nil then Exit('');
  Result := FSource.ArcCellText(AIndex, AColumn);
end;

function TArcListView.GetItemImageIndex(AIndex, AColumn: Integer): Integer;
begin
  { The list view asks for an image per CELL; only the name column carries one.
    -1 is a real answer: the row then has no glyph at all. }
  if (FSource = nil) or (AColumn <> 0) then Exit(-1);
  Result := FSource.ArcCellImage(AIndex);
end;

end.
