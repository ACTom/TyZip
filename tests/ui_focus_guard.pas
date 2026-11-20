program ui_focus_guard;
{$mode objfpc}{$H+}
{ Asking a control for focus must never be able to fail a task.

  LCL's TWinControl.CanFocus deliberately skips the parent form when it walks the
  parent chain, so a control of a HIDDEN form still reports True; calling
  SetFocus on it then reaches TCustomForm.SetFocus, which raises
  EInvalidOperation '[TCustomForm.SetFocus] MainForm:TMainForm Cannot focus.'
  -- the dialog a cold-start Finder "compress" service showed: the service hides
  the window, the created archive is opened, and the listing asks for focus.

  TzFocusIfPossible is the one place that asks, so the window not being able to
  take focus is a no-op instead of an exception. No window is shown here. }

uses
  SysUtils, Classes, Interfaces, Forms, Controls, StdCtrls, tzip.ui.focus;

var
  Passes, Fails: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure TestHiddenWindow;
var
  Form: TForm;
  Edit: TEdit;
begin
  { A window that was never shown, like the main form of a service run. }
  Form := TForm.CreateNew(nil);
  try
    Form.SetBounds(0, 0, 320, 200);
    Form.Enabled := True;
    Edit := TEdit.Create(Form);
    Edit.Parent := Form;
    Edit.Visible := True;
    Edit.Enabled := True;

    Check(not Form.Visible, 'the fixture window is hidden');
    Check(Edit.CanFocus,
      'CanFocus alone is True for a control of a hidden window (why it is not used)');
    Check(not Edit.CanSetFocus,
      'CanSetFocus refuses a control of a hidden window');
    Check(not TzFocusIfPossible(Edit),
      'no focus is asked for on a hidden window');
  finally
    Form.Free;
  end;
end;

procedure TestDisabledControl;
var
  Form: TForm;
  Edit: TEdit;
begin
  Form := TForm.CreateNew(nil);
  try
    Form.SetBounds(0, 0, 320, 200);
    Edit := TEdit.Create(Form);
    Edit.Parent := Form;
    Edit.Visible := True;
    Edit.Enabled := False;
    Check(not TzFocusIfPossible(Edit),
      'a disabled control is not asked for focus');
  finally
    Form.Free;
  end;
end;

begin
  Passes := 0;
  Fails := 0;
  Application.Initialize;

  TestHiddenWindow;
  TestDisabledControl;
  Check(not TzFocusIfPossible(nil), 'no control, no focus');

  WriteLn(Format('== ui_focus_guard: %d passed, %d failed', [Passes, Fails]));
  if Fails > 0 then Halt(1);
end.
