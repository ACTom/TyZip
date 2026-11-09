program tree_selection_events;
{$mode objfpc}{$H+}
{ The archive tree's navigation contract.

  Picking a folder in the archive tree must move the archive listing, so the
  window has to listen to the notification a single-select TTyTreeView actually
  sends. TyControls sends OnChange for clicks, arrow-key moves and programmatic
  `Selected := node`; OnSelectionChanged is multi-select-only. The window used to
  listen to OnSelectionChanged alone -- the folder got highlighted, the listing
  did not move.

  A real TTyTreeView is built here (no window is shown), the binding function the
  window uses is applied to it, and the move is simulated the way MouseDown
  performs it (FocusedNode := node, which selects through SetSelected), so this
  covers both the control's contract and tzip.ui.arctree's binding. }

uses
  SysUtils, Classes, Forms, Controls, Interfaces, tyControls.TreeView,
  tzip.ui.arctree;

type
  { Event handlers are methods; this collects what the binding reported. }
  TBinder = class
  public
    Moved: Integer;
    LastMovedNode: PTyTreeNode;
    procedure TreeMoved(Sender: TTyCustomTreeView; ANode: PTyTreeNode);
  end;

var
  Passes, Fails: Integer;
  Form: TForm;
  Tree: TTyTreeView;
  Root, Alpha, Beta: TTyTreeNodeItem;
  Binder: TBinder;

procedure TBinder.TreeMoved(Sender: TTyCustomTreeView; ANode: PTyTreeNode);
begin
  Inc(Moved);
  LastMovedNode := ANode;
end;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure BuildTree;
begin
  Form := TForm.CreateNew(nil);
  Form.SetBounds(0, 0, 400, 300);
  Tree := TTyTreeView.Create(Form);
  Tree.Parent := Form;
  Tree.Align := alClient;
  Root := Tree.Items.Add(nil, 'probe.zip');
  Root.Expanded := True;
  Alpha := Tree.Items.AddChild(Root, 'alpha');
  Beta := Tree.Items.AddChild(Root, 'beta');
end;

begin
  Passes := 0;
  Fails := 0;
  Binder := TBinder.Create;
  Application.Initialize;
  BuildTree;
  try
    TzBindTreeMoved(Tree, @Binder.TreeMoved);
    Check(Binder.Moved = 0, 'nothing is reported before the current node moves');

    { The single-select click path: TTyCustomTreeView.MouseDown sets FocusedNode,
      which selects the node through SetSelected. }
    Tree.FocusedNode := Alpha.Node;
    Check(Binder.Moved = 1, 'a click on a folder row reports one move');
    Check(Binder.LastMovedNode = Alpha.Node, 'the move names the folder that was clicked');

    { Arrow keys walk the same path, so the same binding covers the keyboard. }
    Tree.FocusedNode := Beta.Node;
    Check(Binder.Moved = 2, 'a second move reports again');
    Check(Binder.LastMovedNode = Beta.Node, 'the second move names beta');

    { What SyncArchiveTreeSelection does when the listing navigates by itself;
      the window guards the re-entry separately, not in this binding. }
    Tree.Selected := Alpha.Node;
    Check(Binder.Moved = 3, 'a programmatic Selected move reports as well');
    Check(Binder.LastMovedNode = Alpha.Node, 'the programmatic move names alpha');
  finally
    Form.Free;
    Binder.Free;
  end;
  WriteLn(Format('== tree_selection_events: %d passed, %d failed', [Passes, Fails]));
  if Fails > 0 then Halt(1);
end.
