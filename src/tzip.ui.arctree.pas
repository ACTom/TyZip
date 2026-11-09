{ Which tree notification means "the user moved to another folder".

  TyControls' TTyTreeView has two selection events with different contracts, and
  picking the wrong one is a silent defect -- the tree highlight moves, the rest
  of the window does nothing:

  - OnChange is the general "the current/selected node changed" notification. It
    fires for a mouse click, for an arrow-key move and for a programmatic
    `Selected := node`.
  - OnSelectionChanged only fires for multi-select gestures ("fired once per
    gesture when multi-select set changes", TyControls.TreeView). A plain
    single-select tree never fires it.

  The window's archive tree is single-select, so its navigation has to hang off
  OnChange. It used to listen to OnSelectionChanged only, which made every click
  on a folder row silent: the folder was highlighted and the archive listing did
  not switch. Keeping the binding in one named function (rather than one event
  assignment in the form) lets the headless tree test check the contract against
  a real TTyTreeView. }
unit tzip.ui.arctree;

{$mode objfpc}{$H+}

interface

uses
  tyControls.TreeView;

type
  { "The tree's current node moved to ANode." ANode is nil when the selection
    was cleared. }
  TTzTreeMovedEvent = procedure(Sender: TTyCustomTreeView;
    ANode: PTyTreeNode) of object;

{ Call AHandler for every move of ATree's current node, whether the user clicked,
  used the keyboard or the code selected a node. }
procedure TzBindTreeMoved(ATree: TTyTreeView; AHandler: TTzTreeMovedEvent);

implementation

procedure TzBindTreeMoved(ATree: TTyTreeView; AHandler: TTzTreeMovedEvent);
begin
  if (ATree = nil) or (AHandler = nil) then Exit;
  { OnChange, not OnSelectionChanged: that is the event a single-select tree
    fires for clicks, keys and programmatic moves (see the unit comment). }
  ATree.OnChange := AHandler;
end;

end.
