{ Startup timing marks, off unless TYZIP_TIMING is set.

  Startup latency is a product property: "a tool should be there when you click
  it". These marks make the phases visible without a profiler and without
  slowing the normal run. }
unit tzip.timing;

{$mode objfpc}{$H+}

interface

{ Write "[timing] <name> <ms since unit initialization>" to stderr when
  TYZIP_TIMING is set. The clock starts during this unit's initialization, so the
  first mark also covers dynamic loading and earlier initialization sections. }
procedure TzMark(const AName: string);

implementation

uses
  SysUtils;

var
  GEnabled: Integer = -1;
  { Set during unit initialization, so the first mark also measures dynamic
    loading, C runtime start-up and every initialization section before it. }
  GStart: QWord = 0;

procedure TzMark(const AName: string);
begin
  if GEnabled < 0 then
  begin
    if GetEnvironmentVariable('TYZIP_TIMING') <> '' then
      GEnabled := 1
    else
      GEnabled := 0;
  end;
  if GEnabled = 0 then Exit;
  WriteLn(ErrOutput, Format('[timing] %-30s %6d ms',
    [AName, GetTickCount64 - GStart]));
  Flush(ErrOutput);
end;

initialization
  GStart := GetTickCount64;

end.
