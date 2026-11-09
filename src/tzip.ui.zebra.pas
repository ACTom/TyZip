unit tzip.ui.zebra;
{ Which rows get the alternating background.

  The list painter hands RenderItem an ITEM index but a cell rect for a DISPLAY
  position.  After a sort those two spaces differ, so parity must be taken from
  the display position; falling back to the item index only for an invalid map
  keeps a transient row paintable during a rebuild.  Kept LCL-free so the
  mapping rule is testable without constructing a control. }
{$mode objfpc}{$H+}

interface

function TzZebraRow(AItemIndex, ADisplayPosition: Integer): Boolean;

implementation

function TzZebraRow(AItemIndex, ADisplayPosition: Integer): Boolean;
begin
  if ADisplayPosition >= 0 then
    Result := Odd(ADisplayPosition)
  else
    Result := Odd(AItemIndex);
end;

end.
