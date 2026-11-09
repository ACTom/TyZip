{ Parsing what the user typed into the path bar.

  The path bar accepts an absolute path, a path relative to the folder being
  shown, and a leading "~" for the home directory. The last one needed its own
  parsing: FPC's ExpandFileName knows nothing about "~" (there is no home
  directory concept in the RTL), so "~/Downloads" was treated as a folder called
  "~" under the current directory and reported as missing. } 
unit tzip.navpaths;

{$mode objfpc}{$H+}

interface

{ APath with a leading "~" or "~/", or "~<separator>", replaced by the user's home
  directory. "~" alone becomes the home directory without a trailing separator.

  Anything else is returned exactly as it was: in particular "~otheruser" is NOT
  expanded, because resolving another account's home needs the password database
  and the path bar is for the current user. }
function TzExpandUserPath(const APath: string): string;

type
  { Which kind of control has the keyboard focus when a window-level shortcut
    arrives. The window's Esc/Backspace/Delete/Enter handling is a LIST gesture:
    if it fires while the user is typing, Backspace deletes archive entries and
    Escape leaves the archive from inside the path editor or the filter box. The
    window maps "what is focused" to one of these; the decision itself lives here
    so the table can be tested without a window. }
  TNavFocusKind = (
    nfNone,       { nothing focused yet (during startup) }
    nfListing,    { the file listing or the archive listing }
    nfTree,       { a sidebar tree }
    nfTextInput,  { an edit box, memo or combo box: the user is typing }
    nfOther       { a button, the toolbar, the window itself }
  );

{ True when a window-level navigation shortcut may run for this focus kind.
  Only the two listings and the trees: everywhere else the keystroke belongs to
  whatever is focused. }
function NavigationShortcutAllowed(AFocus: TNavFocusKind): Boolean;

implementation

uses
  SysUtils;

function TzExpandUserPath(const APath: string): string;
var
  Home: string;
begin
  Result := APath;
  if (APath = '') or (APath[1] <> '~') then Exit;
  Home := IncludeTrailingPathDelimiter(GetUserDir);
  if Length(APath) = 1 then
  begin
    Result := ExcludeTrailingPathDelimiter(Home);
    Exit;
  end;
  { Both separators: the path bar normalises '\' to '/' after this, and a user
    pasting a Windows-style path should not get a folder called "~". }
  if APath[2] in ['/', '\'] then
    Result := Home + Copy(APath, 3, MaxInt);
end;

function NavigationShortcutAllowed(AFocus: TNavFocusKind): Boolean;
begin
  { The shortcut belongs to a list you are standing in. An edit box owns its own
    Backspace/Escape, a button owns Enter, and the window itself is not a place
    the user "is" -- keeping the gate narrow is what stops "type a filter, press
    Backspace" from navigating up instead. }
  Result := AFocus in [nfListing, nfTree];
end;

end.
