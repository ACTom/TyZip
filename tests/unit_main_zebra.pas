program unit_main_zebra;
{$mode objfpc}{$H+}
{ Sorting reorders item indices, but the alternating background belongs to the
  visible row.  The old parity used the item index, so a sorted list showed two
  same-coloured rows in a row. }
uses SysUtils, tzip.ui.zebra;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure TestDisplayParity;
var
  ItemOrder: array[0..2] of Integer = (5, 1, 3);
  Pos: Integer;
begin
  { Items 5,1,3 are displayed at rows 0,1,2 after sorting. }
  for Pos := 0 to 2 do
    Check(TzZebraRow(ItemOrder[Pos], Pos) = Odd(Pos),
      Format('zebra: display row %d decides parity', [Pos]));
  Check(not TzZebraRow(5, 0), 'zebra: item 5 at display row 0 is white');
  Check(TzZebraRow(5, 1), 'zebra: item 5 at display row 1 is shaded');
  { A row whose map is not ready yet still paints deterministically. }
  Check(not TzZebraRow(0, -1), 'zebra: fallback even item is white');
  Check(TzZebraRow(1, -1), 'zebra: fallback odd item is shaded');
end;

begin
  Fails := 0;
  Passes := 0;
  TestDisplayParity;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
