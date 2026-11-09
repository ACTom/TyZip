{ Searching inside an archive.

  The listing's filter box narrows the CURRENT folder. This is the other thing:
  one query over the whole archive, across every folder, by name or by content.

  The matching rules live here so they can be tested without an archive; reading
  entry contents is left to the caller, which owns the engine. }
unit tzip.search;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, RegExpr;

type
  TSearchScope = (
    ssName,     { Match against the entry's path inside the archive. }
    ssContent,  { Match against the entry's bytes, as text. }
    ssBoth
  );

  { How the query text is compared. }
  TSearchMode = (
    smSubstring,  { The query appears anywhere (case-insensitive by default). }
    smWildcard,   { '*' and '?' glob, anchored at both ends. }
    smRegex       { Lua-style pattern, as RegExpr understands it. }
  );

  TSearchOptions = record
    Query: string;
    Scope: TSearchScope;
    Mode: TSearchMode;
    CaseSensitive: Boolean;
    { Skip entries bigger than this when searching content: a 2 GB file is not
      something to grep in a GUI, and reading it would look like a hang. }
    MaxContentBytes: QWord;
  end;

  TSearchHit = record
    Index: Integer;    { Entry index, so the caller can select it. }
    Path: string;      { Full path inside the archive. }
    Size: QWord;
  end;
  TSearchHitArray = array of TSearchHit;

function DefaultSearchOptions(const AQuery: string): TSearchOptions;

{ Does APath (the entry's path inside the archive) match the query? Only
  meaningful for ssName and ssBoth. }
function NameMatches(const APath: string; const AOptions: TSearchOptions): Boolean;

{ Does the entry's text content match? Only meaningful for ssContent and ssBoth.
  A nil AText never matches. }
function ContentMatches(AText: TStrings; const AOptions: TSearchOptions): Boolean;

{ Whole-entry decision, used by the caller while walking the archive. }
function EntryMatches(const APath: string; AText: TStrings;
  const AOptions: TSearchOptions): Boolean;

{ True when the entry is too big to read for a content search. }
function TooBigToSearch(ASize: QWord; const AOptions: TSearchOptions): Boolean;

{ Glob match with '*' and '?', anchored at both ends. Case sensitivity is the
  caller's choice, so it is a parameter rather than a read of the options. }
function GlobMatch(const APattern, AText: string; ACaseSensitive: Boolean): Boolean;

{ One query, prepared once.

  The one-shot functions above create a matcher for a single call, which is what
  a test or a one-off check wants. A whole-archive search creates ONE matcher and
  asks it about every entry: compiling the same regular expression for every
  entry was minutes of work on a large archive. }
type
  TSearchMatcher = class
private
  FOptions: TSearchOptions;
  FLowerQuery: string;
  FRegex: TRegExpr;
  FRegexValid: Boolean;
public
  constructor Create(const AOptions: TSearchOptions);
  destructor Destroy; override;
  function NameMatches(const APath: string): Boolean;
  function ContentMatches(AText: TStrings): Boolean;
end;

implementation

function DefaultSearchOptions(const AQuery: string): TSearchOptions;
begin
  Result := Default(TSearchOptions);
  Result.Query := AQuery;
  Result.Scope := ssName;
  Result.Mode := smSubstring;
  Result.CaseSensitive := False;
  { 32 MB: comfortably more than a source file or a log, far below the size at
    which scanning one would stall the UI. }
  Result.MaxContentBytes := 32 * QWORD(1024) * 1024;
end;

function GlobMatch(const APattern, AText: string; ACaseSensitive: Boolean): Boolean;
var
  Pat, Text: string;

  { Recursive matcher: '*' consumes any run, '?' exactly one character. Written
    out rather than translated to a regex so a literal '.' or '$' in a file name
    is not read as pattern syntax. It walks the NORMALISED copies, so case
    handling happens once, up front. }
  function Match(const AP, AT: Integer): Boolean;
  begin
    if AP > Length(Pat) then Exit(AT > Length(Text));
    case Pat[AP] of
      '*':
        begin
          { Try every split point; the first that matches wins. }
          Result := Match(AP + 1, AT);
          if Result then Exit;
          if AT <= Length(Text) then Result := Match(AP, AT + 1);
        end;
      '?':
        Result := (AT <= Length(Text)) and Match(AP + 1, AT + 1);
    else
      Result := (AT <= Length(Text)) and
        (Pat[AP] = Text[AT]) and Match(AP + 1, AT + 1);
    end;
  end;

begin
  if ACaseSensitive then
  begin
    Pat := APattern;
    Text := AText;
  end
  else
  begin
    Pat := LowerCase(APattern);
    Text := LowerCase(AText);
  end;
  Result := Match(1, 1);
end;

constructor TSearchMatcher.Create(const AOptions: TSearchOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FLowerQuery := LowerCase(AOptions.Query);
  { Compiling once is the whole point of this class; an invalid pattern is a
    non-match, not an exception that reaches the UI. }
  if (AOptions.Query <> '') and (AOptions.Mode = smRegex) then
  begin
    FRegex := TRegExpr.Create;
    try
      FRegex.Expression := AOptions.Query;
      FRegex.ModifierI := not AOptions.CaseSensitive;
      FRegexValid := True;
    except
      FRegexValid := False;
    end;
  end;
end;

destructor TSearchMatcher.Destroy;
begin
  FRegex.Free;
  inherited Destroy;
end;

function TSearchMatcher.NameMatches(const APath: string): Boolean;
begin
  Result := False;
  if FOptions.Query = '' then Exit;
  case FOptions.Mode of
    smSubstring:
      if FOptions.CaseSensitive then
        Result := Pos(FOptions.Query, APath) > 0
      else
        Result := Pos(FLowerQuery, LowerCase(APath)) > 0;
    smWildcard:
      { GlobMatch normalises case itself, so the cached lowercase query is not
        used here. }
      Result := GlobMatch(FOptions.Query, APath, FOptions.CaseSensitive);
    smRegex:
      if FRegexValid and (FRegex <> nil) then
        try
          Result := FRegex.Exec(APath);
        except
          { A half-typed pattern must not raise into the UI. }
          Result := False;
        end;
  end;
end;

function TSearchMatcher.ContentMatches(AText: TStrings): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (AText = nil) or (FOptions.Query = '') then Exit;
  for I := 0 to AText.Count - 1 do
    if NameMatches(AText[I]) then Exit(True);
end;

function NameMatches(const APath: string; const AOptions: TSearchOptions): Boolean;
var
  Matcher: TSearchMatcher;
begin
  Matcher := TSearchMatcher.Create(AOptions);
  try
    Result := Matcher.NameMatches(APath);
  finally
    Matcher.Free;
  end;
end;

function ContentMatches(AText: TStrings; const AOptions: TSearchOptions): Boolean;
var
  Matcher: TSearchMatcher;
begin
  Matcher := TSearchMatcher.Create(AOptions);
  try
    Result := Matcher.ContentMatches(AText);
  finally
    Matcher.Free;
  end;
end;

function EntryMatches(const APath: string; AText: TStrings;
  const AOptions: TSearchOptions): Boolean;
begin
  Result := False;
  if AOptions.Query = '' then Exit;
  case AOptions.Scope of
    ssName: Result := NameMatches(APath, AOptions);
    ssContent: Result := ContentMatches(AText, AOptions);
    ssBoth: Result := NameMatches(APath, AOptions) or ContentMatches(AText, AOptions);
  end;
end;

function TooBigToSearch(ASize: QWord; const AOptions: TSearchOptions): Boolean;
begin
  Result := (AOptions.MaxContentBytes > 0) and
    (ASize > AOptions.MaxContentBytes);
end;

end.
