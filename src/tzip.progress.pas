unit tzip.progress;
{ Pure progress arithmetic for the busy card.

  The card must never invent numbers: an unknown total means no percentage, and
  an unknown rate means no remaining-time estimate.  Keeping the arithmetic
  here (instead of inside the form) makes those rules testable without LCL. }
{$mode objfpc}{$H+}

interface

{ 0 when ATotal is 0; clamped to 0..100. }
function TzProgressPercent(ADone, ATotal: QWord): Integer;

{ Milliseconds as H:MM:SS (hours may exceed 99 on absurdly long jobs). }
function TzFormatDurationMs(AMs: QWord): string;

{ Units per second, rounded down. 0 when the elapsed time is unknown/zero. }
function TzProgressRate(ADone: QWord; AElapsedMs: QWord): QWord;

{ Estimated milliseconds left: (ATotal-ADone) / ARate. 0 when the estimate
  cannot be made (already done, total unknown, or rate 0). }
function TzProgressEtaMs(ATotal, ADone, ARate: QWord): QWord;

{ Ellipsis at AMax characters (including the ellipsis); UTF-8 is not split
  because names are displayed, not used as paths. }
function TzShortenText(const AText: string; AMax: Integer): string;

implementation

uses SysUtils;

function TzProgressPercent(ADone, ATotal: QWord): Integer;
begin
  if ATotal = 0 then Exit(0);
  if ADone >= ATotal then Exit(100);
  Result := Integer((ADone * 100) div ATotal);
end;

function TzFormatDurationMs(AMs: QWord): string;
var
  Secs, H, M, S: QWord;
begin
  Secs := AMs div 1000;
  H := Secs div 3600;
  M := (Secs div 60) mod 60;
  S := Secs mod 60;
  Result := Format('%.2d:%.2d:%.2d', [H, M, S]);
end;

function TzProgressRate(ADone: QWord; AElapsedMs: QWord): QWord;
begin
  if AElapsedMs = 0 then Exit(0);
  Result := (ADone * 1000) div AElapsedMs;
end;

function TzProgressEtaMs(ATotal, ADone, ARate: QWord): QWord;
begin
  if (ATotal = 0) or (ADone >= ATotal) or (ARate = 0) then Exit(0);
  Result := ((ATotal - ADone) * 1000) div ARate;
end;

function TzShortenText(const AText: string; AMax: Integer): string;
begin
  if (AMax <= 0) or (Length(AText) <= AMax) then
    Exit(AText);
  Result := Copy(AText, 1, AMax - 1) + '…';
end;

end.
