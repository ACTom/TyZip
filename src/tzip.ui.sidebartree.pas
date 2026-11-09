{ The filesystem sidebar tree.

  A deliberately small tree built on TTyTreeView, because the stock
  TTyShellTreeView constructor scans TyFsRoots: that enumerates /Volumes and so
  touches mounted network volumes before the user asks for them, which triggers
  the macOS "access network volumes" prompt on launch.

  This tree seeds only the filesystem root and expands one directory at a time,
  on demand. Extracted from tzip.main. }
unit tzip.ui.sidebartree;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  tyControls.Controller, tyControls.TreeView, tyControls.FileSystem;

type
  TFsSidebarTree = class(TTyTreeView)
  private
    FRootPath: string;
    FRootItem: TTyTreeNodeItem;
    FShowHidden: Boolean;
    FLoaded: TStringList;
    FRefreshing: Boolean;
    FOnPathChange: TNotifyEvent;
    procedure ClearNodes;
    procedure Rebuild;
    procedure PopulateItem(AItem: TTyTreeNodeItem);
    function ItemPath(AItem: TTyTreeNodeItem): string;
    function ItemFromNode(ANode: PTyTreeNode): TTyTreeNodeItem;
    function FindChild(AItem: TTyTreeNodeItem; const AName: string): TTyTreeNodeItem;
    procedure TreeExpanding(Sender: TTyCustomTreeView; Node: PTyTreeNode;
      var Allowed: Boolean);
    procedure TreeChanged(Sender: TTyCustomTreeView; Node: PTyTreeNode);
    procedure TreeGetImage(Sender: TTyCustomTreeView; Node: PTyTreeNode;
      AKind: TTyVTImageKind; AColumn: Integer; var AGhosted: Boolean;
      var AImageIndex: Integer);
    procedure SetShowHidden(AValue: Boolean);
    procedure SetRootPath(const AValue: string);
    function GetDirectory: string;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RefreshTree;
    function SelectPath(const APath: string): Boolean;
    property RootPath: string read FRootPath write SetRootPath;
    property ShowHidden: Boolean read FShowHidden write SetShowHidden;
    property Directory: string read GetDirectory;
    property OnPathChange: TNotifyEvent read FOnPathChange write FOnPathChange;
  end;

implementation

constructor TFsSidebarTree.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRootPath := PathDelim;
  FLoaded := TStringList.Create;
  ShowRoot := False;
  { One level of nesting costs this much horizontal room. It is also the icon
    slot width, so it cannot go too small, but 22 pushed deep paths past the
    right edge of a 260 px pane (com.apple.launchservices... was cut off after
    four levels). 14 keeps the hierarchy readable and leaves the names room. }
  Indent := 14;
  OnExpanding := @TreeExpanding;
  { A single-select TTyTreeView reports a click through OnChange (OnSelectionChanged
    is the multi-select notification), so the sidebar must listen here. }
  OnChange := @TreeChanged;
  OnGetImageIndex := @TreeGetImage;
  Rebuild;
end;

destructor TFsSidebarTree.Destroy;
begin
  FLoaded.Free;
  inherited Destroy;
end;

function TFsSidebarTree.ItemPath(AItem: TTyTreeNodeItem): string;
var
  P: string;
begin
  Result := '';
  if AItem = nil then Exit;
  if AItem = FRootItem then Exit(FRootPath);
  P := ItemPath(AItem.Parent);
  if P = '' then P := FRootPath;
  if P = PathDelim then
    Result := P + AItem.Text
  else
    Result := ExcludeTrailingPathDelimiter(P) + PathDelim + AItem.Text;
end;

function TFsSidebarTree.ItemFromNode(ANode: PTyTreeNode): TTyTreeNodeItem;
var
  I: Integer;
begin
  Result := nil;
  if ANode = nil then Exit;
  for I := 0 to Items.Count - 1 do
    if Items[I].Node = ANode then
      Exit(Items[I]);
end;

function TFsSidebarTree.FindChild(AItem: TTyTreeNodeItem;
  const AName: string): TTyTreeNodeItem;
var
  I: Integer;
begin
  Result := nil;
  if AItem = nil then Exit;
  for I := 0 to AItem.Count - 1 do
    if SameText(AItem.Items(I).Text, AName) then
      Exit(AItem.Items(I));
end;

procedure TFsSidebarTree.ClearNodes;
begin
  FLoaded.Clear;
  Items.Clear;
  FRootItem := nil;
end;

procedure TFsSidebarTree.PopulateItem(AItem: TTyTreeNodeItem);
var
  Entries: TTyFsEntryArray;
  Opts: TTyFsObjectTypes;
  I: Integer;
  Child: TTyTreeNodeItem;
begin
  if AItem = nil then Exit;
  if FLoaded.IndexOfObject(AItem) >= 0 then Exit;
  FLoaded.AddObject(ItemPath(AItem), AItem);
  { Remove the placeholder that gives the node its expander. }
  while AItem.Count > 0 do
    Items.DeleteItem(AItem.Items(0));
  Opts := [fotFolders];
  if FShowHidden then Include(Opts, fotHidden);
  Entries := TyFsReadDirectory(ItemPath(AItem), '*', Opts, False);
  TyFsSortEntries(Entries, fskName, True, False);
  for I := 0 to High(Entries) do
  begin
    if not Entries[I].IsDir then Continue;
    Child := Items.AddChild(AItem, Entries[I].Name);
    { A placeholder child means "may have children"; it costs no disk access
      (unlike TyFsHasSubdir) and is replaced by the real listing on expansion. }
    Items.AddChild(Child, '');
  end;
  AItem.Expanded := True;
end;

procedure TFsSidebarTree.Rebuild;
begin
  ClearNodes;
  FRootItem := Items.Add(nil, FRootPath);
  FRootItem.Expanded := True;
  PopulateItem(FRootItem);
end;

procedure TFsSidebarTree.TreeExpanding(Sender: TTyCustomTreeView;
  Node: PTyTreeNode; var Allowed: Boolean);
begin
  Allowed := True;
  PopulateItem(ItemFromNode(Node));
end;

procedure TFsSidebarTree.TreeChanged(Sender: TTyCustomTreeView;
  Node: PTyTreeNode);
begin
  if FRefreshing then Exit;
  if Assigned(FOnPathChange) then FOnPathChange(Self);
end;

procedure TFsSidebarTree.TreeGetImage(Sender: TTyCustomTreeView;
  Node: PTyTreeNode; AKind: TTyVTImageKind; AColumn: Integer;
  var AGhosted: Boolean; var AImageIndex: Integer);
var
  It: TTyTreeNodeItem;
begin
  AImageIndex := -1;
  AGhosted := False;
  { A tree without columns passes AColumn = -1; only real secondary columns should
    suppress the icon. }
  if AColumn > 0 then Exit;
  It := ItemFromNode(Node);
  { BuildIcons registers folder=0, drive=1, file=2, archive=3.  The sidebar only
    needs the first two; asking Images.Names is not available on TCustomImageList. }
  if (It <> nil) and (It = FRootItem) then
  begin
    if (Images <> nil) and (Images.Count > 1) then
      AImageIndex := 1
    else
      AImageIndex := 0;
  end
  else
    AImageIndex := 0;
end;

function TFsSidebarTree.GetDirectory: string;
var
  It: TTyTreeNodeItem;
begin
  if FRootItem = nil then begin Result := FRootPath; Exit; end;
  if Selected = nil then begin Result := FRootPath; Exit; end;
  It := ItemFromNode(Selected);
  if It = nil then Result := FRootPath else Result := ItemPath(It);
end;

procedure TFsSidebarTree.SetShowHidden(AValue: Boolean);
begin
  if FShowHidden = AValue then Exit;
  FShowHidden := AValue;
  RefreshTree;
end;

procedure TFsSidebarTree.SetRootPath(const AValue: string);
var
  P: string;
begin
  P := ExcludeTrailingPathDelimiter(Trim(AValue));
  if P = '' then P := PathDelim;
  if SameText(P, FRootPath) then Exit;
  FRootPath := P;
  RefreshTree;
end;

procedure TFsSidebarTree.RefreshTree;
var
  P: string;
begin
  P := Directory;
  { Rebuild/SelectPath fire selection changes; suppress them so a ShowHidden
    refresh does not recursively navigate the file list. }
  FRefreshing := True;
  try
    Rebuild;
    if (P <> '') and (P <> FRootPath) then SelectPath(P);
  finally
    FRefreshing := False;
  end;
end;

function TFsSidebarTree.SelectPath(const APath: string): Boolean;
var
  Target, PartName: string;
  Parts: TStringList;
  Node: TTyTreeNodeItem;
  I: Integer;
begin
  Result := False;
  Target := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
  if Target = '' then Target := FRootPath;
  if FRootItem = nil then Rebuild;
  if SameText(Target, FRootPath) then
  begin
    PopulateItem(FRootItem);
    Selected := FRootItem.Node;
    Exit(True);
  end;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := PathDelim;
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Target;
    Node := FRootItem;
    PopulateItem(Node);
    for I := 0 to Parts.Count - 1 do
    begin
      PartName := Parts[I];
      if PartName = '' then Continue;
      if FLoaded.IndexOfObject(Node) < 0 then PopulateItem(Node);
      Node := FindChild(Node, PartName);
      if Node = nil then Exit;
      if I < Parts.Count - 1 then
      begin
        PopulateItem(Node);
        Node.Expanded := True;
      end;
    end;
    Selected := Node.Node;
    Result := Selected <> nil;
  finally
    Parts.Free;
  end;
end;

end.
