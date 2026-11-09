program unit_model_progressstats;
{$mode objfpc}{$H+}
{ The busy card must not invent numbers; pin the arithmetic rules. }
uses SysUtils, tzip.progress;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  Check(AGot = AWant, Format('%s: got %d want %d', [AMsg, AGot, AWant]));
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  Check(AGot = AWant, Format('%s: got "%s" want "%s"', [AMsg, AGot, AWant]));
end;

procedure EqQ(AGot, AWant: QWord; const AMsg: string);
begin
  Check(AGot = AWant, Format('%s: got %d want %d', [AMsg, AGot, AWant]));
end;

procedure TestPercent;
begin
  EqInt(TzProgressPercent(0, 0), 0, 'percent: unknown total');
  EqInt(TzProgressPercent(1, 4), 25, 'percent: one quarter');
  EqInt(TzProgressPercent(4, 4), 100, 'percent: complete');
  EqInt(TzProgressPercent(5, 4), 100, 'percent: clamped above');
end;

procedure TestDuration;
begin
  EqStr(TzFormatDurationMs(0), '00:00:00', 'duration: zero');
  EqStr(TzFormatDurationMs(59000), '00:00:59', 'duration: 59s');
  EqStr(TzFormatDurationMs(60000), '00:01:00', 'duration: one minute');
  EqStr(TzFormatDurationMs(3661000), '01:01:01', 'duration: hours');
end;

procedure TestShorten;
begin
  EqStr(TzShortenText('a.txt', 10), 'a.txt', 'shorten: short unchanged');
  EqStr(TzShortenText('abcdef', 4), 'abc…', 'shorten: ellipsis');
  EqStr(TzShortenText('abcdef', 0), 'abcdef', 'shorten: no limit');
end;

procedure TestRateAndEta;
begin
  EqQ(TzProgressRate(100, 1000), 100, 'rate: 100 units in 1s');
  EqQ(TzProgressRate(100, 0), 0, 'rate: no elapsed time');
  EqQ(TzProgressEtaMs(1000, 250, 100), 7500, 'eta: 750 units at 100/s');
  EqQ(TzProgressEtaMs(1000, 250, 0), 0, 'eta: no rate');
  EqQ(TzProgressEtaMs(1000, 1000, 100), 0, 'eta: already done');
  EqQ(TzProgressEtaMs(0, 0, 100), 0, 'eta: unknown total');
end;

begin
  Fails := 0;
  Passes := 0;
  TestPercent;
  TestDuration;
  TestShorten;
  TestRateAndEta;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
