program unit_main_paths;
{$mode objfpc}{$H+}
{ What the path bar does with a leading "~".

  FPC's ExpandFileName does not expand it, so "~/Downloads" used to be treated as
  a folder called "~" under the current directory and reported missing. }
uses
  SysUtils, tzip.navpaths;

var
  Fails, Passes: Integer;
  Home: string;

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

procedure TestHome;
begin
  Home := IncludeTrailingPathDelimiter(GetUserDir);
  EqStr(TzExpandUserPath('~/Downloads'), Home + 'Downloads', 'home: ~/name');
  EqStr(TzExpandUserPath('~/'), Home, 'home: bare ~/');
  EqStr(TzExpandUserPath('~'), ExcludeTrailingPathDelimiter(Home), 'home: bare ~');
  EqStr(TzExpandUserPath('~' + PathDelim + 'a' + PathDelim + 'b'),
    IncludeTrailingPathDelimiter(Home) + 'a' + PathDelim + 'b', 'home: nested');
  { A backslash is tolerated as the second character: the path bar normalises it
    after this. }
  EqStr(TzExpandUserPath('~\Documents'), Home + 'Documents', 'home: backslash');
end;

procedure TestUntouched;
begin
  { Not home-relative: returned exactly as it came in. }
  EqStr(TzExpandUserPath('/tmp/x'), '/tmp/x', 'untouched: absolute');
  EqStr(TzExpandUserPath('relative/path'), 'relative/path', 'untouched: relative');
  EqStr(TzExpandUserPath(''), '', 'untouched: empty');
  { "~user" needs the password database; the path bar is for the current user, so
    it is left alone and the caller reports it as not found. }
  EqStr(TzExpandUserPath('~otheruser/x'), '~otheruser/x', 'untouched: other user');
  { A tilde that is not the first character is part of the name. }
  EqStr(TzExpandUserPath('/tmp/a~b'), '/tmp/a~b', 'untouched: tilde inside');
end;

procedure TestNavigationShortcuts;
begin
  { The window-level Esc/Backspace/Delete/Enter belong to a list the user stands
    in. Anywhere else the keystroke belongs to whatever is focused. }
  Check(NavigationShortcutAllowed(nfListing), 'shortcuts: a listing owns them');
  Check(NavigationShortcutAllowed(nfTree), 'shortcuts: a tree owns them');
  Check(not NavigationShortcutAllowed(nfTextInput),
    'shortcuts: an edit box keeps Backspace and Escape');
  Check(not NavigationShortcutAllowed(nfOther),
    'shortcuts: a button keeps Enter');
  Check(not NavigationShortcutAllowed(nfNone),
    'shortcuts: nothing focused yet means nothing to navigate');
end;

begin
  Fails := 0; Passes := 0;
  TestHome;
  TestUntouched;
  TestNavigationShortcuts;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.