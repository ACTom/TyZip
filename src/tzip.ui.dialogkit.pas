{ Builders for the contents of a themed dialog.

  Every dialog in TyZip is a TTyDialog whose content lives inside an alClient
  body panel; these functions create that panel and the controls that go into
  it, with the boilerplate (Parent, position, size, style class) applied. They
  were private helpers at the bottom of tzip.dialogs until that unit grew past
  1400 lines and the dialogs were split by purpose.

  Sizes are device pixels: callers pass Px(...) values from the dialog. }
unit tzip.ui.dialogkit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls,
  tyControls.Panel, tyControls.Button, tyControls.TyLabel, tyControls.Edit,
  tyControls.ComboBox, tyControls.CheckBox,
  tyControls.Dialogs;

const
  { Shared layout metrics, in logical pixels. Every dialog multiplies these
    through TTyDialog.Px, so a change here re-proportions all of them at once. }
  cPad = 16;          { dialog body padding }
  cGap = 8;           { gap between a label/value pair or a control and its neighbour }
  cLabelH = 20;
  cEditH = 28;
  cCheckH = 24;
  cComboH = 28;
  cBodyBtnH = 30;

{ The alClient body panel a dialog's content is parented to. Transparent, so the
  dialog's own themed surface shows through -- the same class the TTyDialog
  button bar uses. }
function NewBody(ADlg: TTyDialog): TTyPanel;

function NewLabel(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth, AHeight: Integer): TTyLabel;

function NewEdit(AParent: TWinControl; ALeft, ATop, AWidth, AHeight: Integer): TTyEdit;

{ A drop-down list; ItemIndex is set by the caller, who also has to normalise it
  because assigning ItemIndex does not fire OnChange. }
function NewCombo(AParent: TWinControl; ALeft, ATop, AWidth, AHeight: Integer): TTyComboBox;

function NewCheckBox(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth, AHeight: Integer): TTyCheckBox;

{ A button that lives in the dialog BODY (e.g. a "Choose..." browse button);
  bottom-bar buttons go through TTyDialog.AddButton instead. }
function NewBodyButton(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth, AHeight: Integer; AHandler: TNotifyEvent): TTyButton;

implementation

function NewBody(ADlg: TTyDialog): TTyPanel;
begin
  Result := TTyPanel.Create(ADlg);
  Result.Parent := ADlg;
  Result.Name := 'Body';
  Result.Align := alClient;
  Result.Caption := '';
  Result.StyleClass := 'ghost';
end;

function NewLabel(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth, AHeight: Integer): TTyLabel;
begin
  Result := TTyLabel.Create(AParent);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

function NewEdit(AParent: TWinControl; ALeft, ATop, AWidth, AHeight: Integer): TTyEdit;
begin
  Result := TTyEdit.Create(AParent);
  Result.Parent := AParent;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

function NewCombo(AParent: TWinControl; ALeft, ATop, AWidth, AHeight: Integer): TTyComboBox;
begin
  Result := TTyComboBox.Create(AParent);
  Result.Parent := AParent;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Height := AHeight;
  Result.Style := csDropDownList;
end;

function NewCheckBox(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth, AHeight: Integer): TTyCheckBox;
begin
  Result := TTyCheckBox.Create(AParent);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

function NewBodyButton(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth, AHeight: Integer; AHandler: TNotifyEvent): TTyButton;
begin
  Result := TTyButton.Create(AParent);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Height := AHeight;
  Result.OnClick := AHandler;
end;

end.
