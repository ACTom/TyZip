program unit_main_about;
{$mode objfpc}{$H+}
{ The About box text is a template: the version arrives at runtime from the
  bundle, so no Pascal source may carry a version number of its own.

  Pinned here: the template has exactly one placeholder, it is in the first line,
  the rest of the text keeps its shape, and the old hard-coded version is gone. }
uses
  SysUtils, tzip.i18n;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

function CountOf(const ASub, AText: string): Integer;
var
  P, N: Integer;
begin
  Result := 0;
  N := 1;
  repeat
    P := Pos(ASub, Copy(AText, N, MaxInt));
    if P = 0 then Break;
    Inc(Result);
    N := N + P + Length(ASub) - 1;
  until N > Length(AText);
end;

procedure TestTemplate;
var
  Text: string;
  Lines: TStringArray;
begin
  { One placeholder, and only one: a second %s would mean a second source. }
  Check(CountOf('%s', rsDlgAboutText) = 1, 'about: exactly one %s placeholder');
  Check(Pos('TyZip %s', rsDlgAboutText) = 1, 'about: the first line is TyZip <version>');

  Text := Format(rsDlgAboutText, ['1.2.3']);
  Lines := Text.Split([LineEnding]);
  EqStr(Lines[0], 'TyZip 1.2.3', 'about: version from the caller, not from the text');
  Check(Length(Lines) >= 5, 'about: the text still has its paragraphs');
  EqStr(Lines[1], '', 'about: blank line after the version');
  EqStr(Lines[2], 'A TyControls archive manager for macOS.', 'about: description kept');
  EqStr(Lines[3], 'Archive engine: official 7-Zip 26.03 dynamic library',
    'about: engine line kept');
  EqStr(Lines[4], 'Built with Lazarus / Free Pascal.', 'about: build line kept');

  { The old hard-coded version must not come back: that was the second source. }
  Check(Pos('TyZip 1.0', rsDlgAboutText) = 0, 'about: no hard-coded version left');
end;

begin
  Fails := 0;
  Passes := 0;
  TestTemplate;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
