unit tzip.ui.focus;
{$mode objfpc}{$H+}
{ Asking a control for focus, safely.

  Focus is cosmetic: it makes the next click or arrow key land in the right
  place, and nothing about opening, navigating or a background job depends on
  it. It must therefore never fail a task.

  The LCL API for "can this control take focus?" is TWinControl.CanSetFocus, not
  CanFocus: CanFocus deliberately walks the parent chain only up to (excluding)
  the form, so a control of a HIDDEN form still answers True, and SetFocus then
  reaches TCustomForm.SetFocus and raises EInvalidOperation
  '[TCustomForm.SetFocus] <name>:<class> Cannot focus.' That is exactly what a
  cold-start Finder service hit: the service hides the main window, opens the
  archive it just created, and the archive listing asked for focus.

  CanSetFocus answers False for a hidden or disabled window; the exception
  handler covers the remaining race (the window losing focusability between the
  check and the call, e.g. a modal dialog opening in the same turn). }

interface

uses
  Classes, Controls;

{ Give AControl the keyboard focus when its window can take it. Returns True when
  SetFocus was attempted on a focusable control. Never raises. }
function TzFocusIfPossible(AControl: TWinControl): Boolean;

implementation

function TzFocusIfPossible(AControl: TWinControl): Boolean;
begin
  Result := False;
  if AControl = nil then Exit;
  if not AControl.CanSetFocus then Exit;
  try
    AControl.SetFocus;
    Result := True;
  except
    { focus is cosmetic; never let it break a job or navigation }
    Result := False;
  end;
end;

end.
