program unit_search;
{$mode objfpc}{$H+}
{ Archive search matching rules: glob, substring, regex, scope and the size
  guard. Reading contents happens in the caller; everything decidable without
  an archive is here. }
uses
  SysUtils, Classes, tzip.search;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

function Opt(q: string; scope: TSearchScope; mode: TSearchMode;
  cs: Boolean = False): TSearchOptions;
begin
  Result := DefaultSearchOptions(q);
  Result.Scope := scope;
  Result.Mode := mode;
  Result.CaseSensitive := cs;
end;

function Lines(const s: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Text := s;
end;

{ --- glob --------------------------------------------------------------- }

procedure TestGlob;
begin
  Check(GlobMatch('*.txt', 'a.txt', False), 'glob: star suffix');
  Check(GlobMatch('*.txt', 'deep/a.txt', False), 'glob: star crosses a slash');
  Check(not GlobMatch('*.txt', 'a.md', False), 'glob: star rejects other suffix');
  Check(GlobMatch('a?c', 'abc', False), 'glob: question mark');
  Check(not GlobMatch('a?c', 'ac', False), 'glob: question mark needs a char');
  Check(GlobMatch('*', 'anything', False), 'glob: bare star matches all');
  Check(GlobMatch('exact', 'exact', False), 'glob: literal');
  Check(not GlobMatch('exact', 'exactly', False), 'glob: anchored at the end');
  Check(not GlobMatch('xact', 'exact', False), 'glob: anchored at the start');
  { Case handling is the caller's choice. }
  Check(GlobMatch('*.TXT', 'a.txt', False), 'glob: case-insensitive by default');
  Check(not GlobMatch('*.TXT', 'a.txt', True), 'glob: case-sensitive when asked');
  { Metacharacters of other pattern languages are literal here. }
  Check(GlobMatch('a.b', 'a.b', False), 'glob: dot is literal');
  Check(not GlobMatch('a.b', 'axb', False), 'glob: dot does not match anything');
end;

{ --- name matching ------------------------------------------------------ }

procedure TestName;
begin
  Check(NameMatches('dir/readme.md', Opt('README', ssName, smSubstring)),
    'name: substring ignores case');
  Check(not NameMatches('dir/readme.md', Opt('README', ssName, smSubstring, True)),
    'name: case-sensitive rejects');
  Check(NameMatches('dir/readme.md', Opt('*.md', ssName, smWildcard)),
    'name: wildcard');
  Check(not NameMatches('dir/readme.txt', Opt('*.md', ssName, smWildcard)),
    'name: wildcard rejects');
  { An empty query matches nothing: otherwise a cleared box would "find" every
    entry. }
  Check(not NameMatches('anything', Opt('', ssName, smSubstring)),
    'name: empty query matches nothing');
  { Regex is available for people who want it. }
  Check(NameMatches('a1.txt', Opt('^a\d+\.txt$', ssName, smRegex)),
    'name: regex');
  Check(not NameMatches('b1.txt', Opt('^a\d+\.txt$', ssName, smRegex)),
    'name: regex rejects');
  Check(NameMatches('ABC.txt', Opt('^abc', ssName, smRegex)),
    'name: regex case-insensitive by default');
  { A malformed pattern must be a non-match, not an exception. }
  Check(not NameMatches('x', Opt('[unclosed', ssName, smRegex)),
    'name: bad regex does not raise');
end;

{ --- content matching --------------------------------------------------- }

procedure TestContent;
var
  T: TStringList;
begin
  T := Lines('alpha' + LineEnding + 'beta gamma');
  try
    Check(ContentMatches(T, Opt('gamma', ssContent, smSubstring)),
      'content: substring on a line');
    Check(ContentMatches(T, Opt('GAMMA', ssContent, smSubstring)),
      'content: case-insensitive');
    Check(not ContentMatches(T, Opt('delta', ssContent, smSubstring)),
      'content: absent text');
    Check(ContentMatches(T, Opt('*gamma*', ssContent, smWildcard)),
      'content: wildcard on a line');
    { nil content cannot match, which is what a caller passes for a binary or
      unreadable entry. }
    Check(not ContentMatches(nil, Opt('alpha', ssContent, smSubstring)),
      'content: nil never matches');
  finally T.Free; end;
end;

{ --- whole-entry decision ----------------------------------------------- }

procedure TestEntry;
var
  T: TStringList;
begin
  T := Lines('needle in here');
  try
    { Name-only scope must not look at the content. }
    Check(not EntryMatches('other.txt', T, Opt('needle', ssName, smSubstring)),
      'entry: name scope ignores content');
    Check(EntryMatches('other.txt', T, Opt('needle', ssContent, smSubstring)),
      'entry: content scope uses content');
    { Either one is enough in "both". }
    Check(EntryMatches('needle.txt', T, Opt('needle', ssBoth, smSubstring)),
      'entry: both matches the name');
    Check(EntryMatches('other.txt', T, Opt('needle', ssBoth, smSubstring)),
      'entry: both matches the content');
    Check(not EntryMatches('other.txt', T, Opt('absent', ssBoth, smSubstring)),
      'entry: both rejects a miss');
  finally T.Free; end;
end;

{ --- size guard --------------------------------------------------------- }

procedure TestSizeGuard;
var
  O: TSearchOptions;
begin
  O := DefaultSearchOptions('x');
  Check(O.MaxContentBytes > 0, 'size: there is a limit by default');
  Check(not TooBigToSearch(1024, O), 'size: a small file is fine');
  Check(TooBigToSearch(O.MaxContentBytes + 1, O), 'size: over the limit is refused');
  Check(not TooBigToSearch(O.MaxContentBytes, O), 'size: exactly at the limit is fine');
  { 0 means "no limit", which a caller might choose for a scripted search. }
  O.MaxContentBytes := 0;
  Check(not TooBigToSearch(High(QWord) div 2, O), 'size: zero disables the limit');
end;

{ --- the prepared matcher ----------------------------------------------- }

procedure TestMatcher;
var
  O: TSearchOptions;
  M: TSearchMatcher;
  T: TStringList;
begin
  O := Opt('*.txt', ssName, smWildcard);
  M := TSearchMatcher.Create(O);
  try
    Check(M.NameMatches('a.txt'), 'matcher: wildcard hit');
    Check(not M.NameMatches('a.md'), 'matcher: wildcard miss');
  finally M.Free; end;

  { One regex compiled once, asked about many entries, must give the same
    answers as the one-shot wrapper -- the whole point is that it is prepared. }
  O := Opt('^a\d+\.txt$', ssName, smRegex);
  M := TSearchMatcher.Create(O);
  try
    Check(M.NameMatches('a12.txt'), 'matcher: regex hit');
    Check(not M.NameMatches('b12.txt'), 'matcher: regex miss');
    Check(M.NameMatches('a1.txt') = NameMatches('a1.txt', O),
      'matcher: same answer as the one-shot function');
    Check(M.NameMatches('zzz.txt') = NameMatches('zzz.txt', O),
      'matcher: same answer on a miss');
  finally M.Free; end;

  { An invalid pattern is a non-match, not an exception, in both kinds of query. }
  M := TSearchMatcher.Create(Opt('[unclosed', ssContent, smRegex));
  try
    Check(not M.NameMatches('x'), 'matcher: bad regex does not raise');
    T := Lines('x');
    try
      Check(not M.ContentMatches(T), 'matcher: bad regex content does not raise');
    finally T.Free; end;
  finally M.Free; end;

  M := TSearchMatcher.Create(Opt('NEEDLE', ssContent, smSubstring));
  try
    T := Lines('a line' + LineEnding + 'with a needle inside');
    try
      Check(M.ContentMatches(T), 'matcher: content hit');
    finally T.Free; end;
    T := Lines('nothing here');
    try
      Check(not M.ContentMatches(T), 'matcher: content miss');
    finally T.Free; end;
    Check(not M.ContentMatches(nil), 'matcher: nil content never matches');
  finally M.Free; end;
end;

procedure TestDefaults;
var
  O: TSearchOptions;
begin
  O := DefaultSearchOptions('find me');
  Check(O.Query = 'find me', 'default: query kept');
  Check(O.Scope = ssName, 'default: searches names first');
  Check(O.Mode = smSubstring, 'default: plain substring');
  Check(not O.CaseSensitive, 'default: case-insensitive');
end;

begin
  Fails := 0; Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  TestGlob;
  TestName;
  TestContent;
  TestEntry;
  TestSizeGuard;
  TestDefaults;
  TestMatcher;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
