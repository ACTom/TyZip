unit tzip.preview.syntax;

{ Highlighters for the preview pane that SynEdit itself does not ship.

  Stock SynEdit only highlights a handful of languages: there is nothing for
  Markdown, C/C++, YAML, TOML, Rust or Go, and a preview of such a file must not
  read as flat text. Three scanners cover the gap without another library:

  * TZGeneralSyntax -- one C-like/script-like tokeniser driven by a spec (line
    and block comments, string forms, numbers and a keyword table). It serves
    C/C++, Java, C#, JavaScript/TypeScript, Go, Rust, Python, Ruby, Lua, Swift,
    Kotlin, PHP, SQL shells, JSON and TOML.
  * TZMarkdownSyntax -- fenced code blocks, headings, emphasis, links, lists and
    (optionally) GFM tables/strikethrough and YAML front matter.
  * TZYamlSyntax -- keys, quoted scalars, anchors/aliases/tags and block
    scalars, whose indented body is part of the string.

  The preview is read-only, so a highlighter is built for a selection, used for
  the text shown, and freed. Colours are applied by tzip.preview: it reads the
  attribute Caption of every attribute it tints, so the scanners carry no
  palette of their own.

  Scanners work on bytes. All syntax -- keywords and punctuation -- is ASCII and
  therefore a single byte in UTF-8 as well as in the legacy code pages the
  preview decodes, so a multi-byte character is simply part of an identifier or
  a text run and can never be split by a token boundary.

  Multi-line state: SynEdit asks a highlighter for the state at the end of a
  line (GetRange) and gives it back (SetRange) before scanning a later line, so
  that a /* comment */ or a ``` fence started earlier still colours correctly
  when the reader scrolls into the middle of it. Each scanner returns a small
  fixed-size snapshot of its state. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Graphics,
  SynEditTypes, SynEditHighlighter;

const
  { Token kinds. The order is the order of the attributes created in each
    scanner's Create, so a kind doubles as an attribute index. }
  ztkComment    = 0;   { comment }
  ztkKeyword    = 1;   { reserved word }
  ztkString     = 2;   { string literal }
  ztkNumber     = 3;   { number literal }
  ztkSymbol     = 4;   { operator / punctuation }
  ztkProp       = 5;   { property name: JSON/TOML/YAML key, C# type }
  ztkConstant   = 6;   { constant: true/false/null, entities }
  ztkBuiltin    = 7;   { builtin type or predeclared name }
  ztkIdentifier = 8;   { identifier / plain text }
  ztkDirective  = 9;   { preprocessor directive, SQL variable }
  ztkReference  = 10;  { Markdown link target, YAML anchor/alias/tag }
  ztkHeading    = 11;  { Markdown heading text, list marker }
  ztkEscape     = 12;  { backslash escape }
  ztkStrike     = 13;  { struck-through Markdown text }
  ztkEmphasis   = 14;  { Markdown *emphasis* markers and text }
  ztkCode       = 15;  { Markdown `inline code` and fenced blocks }

  ZSyntaxTokenKindCount = 16;

type
  { Lexical behaviour of a language. Filled in by the language table. }
  TZScanOptions = record
    LineComments: array of string;   { '//', '#', '--', ';' }
    LineCommentColFloor: array of Integer;  { 1-based column a comment must
                                              start at/before, 0 = anywhere }
    BlockComment: Boolean;           { /* ... */ }
    SingleQuote: Boolean;            { '...' string }
    DoubleQuote: Boolean;            { "..." string }
    ThirdQuote: Boolean;             { ''' / """ also open block strings }
    Backtick: Boolean;               { `...` string or template }
    RawPrefix: Boolean;              { Rust r#"..."# }
    PercentLiteral: Boolean;         { Ruby %w[...] }
    Heredoc: Boolean;                { Ruby <<~EOS }
    Escape: Char;                    { escape character, #0 = none }
    Preprocessor: Boolean;           { #include/#ifdef... at line start }
  end;

  TZMarkdownOptions = record
    YAMLFrontMatter: Boolean;
    Tables: Boolean;
    Strikethrough: Boolean;
  end;

  TZTokenProc = procedure(AContext: TObject; AOffs, ALen, AKind: Integer) of object;

  { Common plumbing of TSynCustomHighlighter: token bookkeeping for
    GetTokenEx/GetTokenPos/GetTokenLen, the Next loop, and the range slot. }
  TZCustomSyn = class(TSynCustomHighlighter)
  private
    FTokenStart: Integer;   { start of the token last reported }
    FTokenLen: Integer;
    FTokenPos: Integer;
    FKind: Integer;
    FScan: Integer;         { position the next ScanToken must start at }
  protected
    procedure AddKindAttr(AKind: Integer; const ACaption: string);
    procedure SetToken(AOffs, ALen, AKind: Integer); inline;
    { Reset the scanner for the line now in CurrentLineText. }
    procedure PrepareLine; virtual;
    { Emit the single token that starts at AOffs (and stop there). }
    procedure ScanToken(AOffs: Integer; AContext: TObject;
      AToken: TZTokenProc); virtual; abstract;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetLine(const NewValue: String; LineNumber: Integer); override;
    procedure Next; override;
    function GetEol: Boolean; override;
    procedure GetTokenEx(out TokenStart: PChar; out TokenLength: integer); override;
    function GetToken: string; override;
    function GetTokenPos: Integer; override;
    function GetTokenLen: Integer; override;
    function GetTokenKind: Integer; override;
    function GetDefaultAttribute(Index: integer): TSynHighlighterAttributes; override;
  end;

  TZGeneralSyntax = class(TZCustomSyn)
  private
    FOptions: TZScanOptions;
    FKeywords: TStringList;      { word -> kind, sorted }
    FCaseSensitive: Boolean;
    FBareEqualKeys: Boolean;
    FBareColonKeys: Boolean;
    FLangName: string;
    FInBlock: Boolean;           { a /* */ comment continues onto this line }
    FBlockDepth: Integer;
    FBlockString: string;        { ''' or """ opening a string that continues }
    FInHeredoc: Boolean;         { previous line opened <<~EOS }
    function Lookup(const AWord: string; out AKind: Integer): Boolean;
    function LinePropEnd(AStart: Integer): Integer;  { 'key:' extent, 0 if none }
  protected
    procedure ResetRange; override;
    procedure SetRange(Value: Pointer); override;
    function GetRange: Pointer; override;
    procedure PrepareLine; override;
    procedure ScanToken(AOffs: Integer; AContext: TObject;
      AToken: TZTokenProc); override;
  public
    constructor Create(AOwner: TComponent; const ALangName: string); reintroduce;
    destructor Destroy; override;
    function GetInstanceLanguageName: string; override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    { True for languages whose keys are written "key = value" (TOML): a bare
      word followed by '=' is then a property name, not an identifier. }
    property BareEqualKeys: Boolean read FBareEqualKeys write FBareEqualKeys;
    { True for YAML-style keys, "key: value". }
    property BareColonKeys: Boolean read FBareColonKeys write FBareColonKeys;
    { Set the lexical rules and case sensitivity once, before attaching. }
    procedure Configure(const AOptions: TZScanOptions; ACaseSensitive: Boolean);
    { Adjust the options before Configure (e.g. to add a second comment
      marker); writing through this property does not touch the keywords. }
    property Options: TZScanOptions read FOptions write FOptions;
    property CaseSensitive: Boolean read FCaseSensitive write FCaseSensitive;
    { Add one word: 'word' is a keyword, 'word=5' a property name, 'word=6' a
      constant and so on. A later entry for the same word wins, so a language
      can override a word it shares with the common pool. }
    procedure AddWord(const AWord: string);
  end;

  TZMarkdownSyntax = class(TZCustomSyn)
  private
    FOptions: TZMarkdownOptions;
    FInFence: Boolean;           { the line is inside ``` ... ``` }
    FInFrontMatter: Boolean;
    FHeading: Boolean;           { the line is a # heading }
    FHeadingStart: Integer;      { 0-based index of its text }
    FCodeLine: Boolean;          { the whole line is code (fence or its body) }
    procedure ScanInline(var AStart: Integer; const AEnd: Integer;
      AContext: TObject; AToken: TZTokenProc);
  protected
    procedure ResetRange; override;
    procedure SetRange(Value: Pointer); override;
    function GetRange: Pointer; override;
    procedure PrepareLine; override;
    procedure ScanToken(AOffs: Integer; AContext: TObject;
      AToken: TZTokenProc); override;
  public
    constructor Create(AOwner: TComponent); override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    property Options: TZMarkdownOptions read FOptions write FOptions;
    { Convenience writers, so the language table reads as three assignments. }
    property YAMLFrontMatter: Boolean
      read FOptions.YAMLFrontMatter write FOptions.YAMLFrontMatter;
    property Tables: Boolean read FOptions.Tables write FOptions.Tables;
    property Strikethrough: Boolean
      read FOptions.Strikethrough write FOptions.Strikethrough;
  end;

  TZYamlSyntax = class(TZCustomSyn)
  private
    FBlockIndent: Integer;       { indentation of an open block scalar, -1 none }
    FFlow: Integer;              { bracket depth carried across lines }
  protected
    procedure ResetRange; override;
    procedure SetRange(Value: Pointer); override;
    function GetRange: Pointer; override;
    procedure PrepareLine; override;
    procedure ScanToken(AOffs: Integer; AContext: TObject;
      AToken: TZTokenProc); override;
  public
    constructor Create(AOwner: TComponent); override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
  end;

implementation

const
  { Quote characters by code: a literal run of three quotes is hard to
    read (and to keep correct) in Pascal source. }
  Q1S = #39;
  Q1D = #34;
  Q3S = #39#39#39;
  Q3D = #34#34#34;

function IsIdentStart(C: Byte): Boolean; inline;
begin
  Result := Char(C) in ['a'..'z', 'A'..'Z', '_', '$', '@'];
end;

function IsIdentChar(C: Byte): Boolean; inline;
begin
  Result := Char(C) in ['a'..'z', 'A'..'Z', '0'..'9', '_', '$', '@'];
end;

function IsDigit(C: Byte): Boolean; inline;
begin
  Result := Char(C) in ['0'..'9'];
end;

function IsSpace(C: Byte): Boolean; inline;
begin
  Result := Char(C) in [' ', #9, #11, #12, #13];
end;

function StartsWith(const S: string; APos: Integer; const AWhat: string): Boolean; inline;
begin
  Result := Copy(S, APos + 1, Length(AWhat)) = AWhat;
end;

{ ---------------------------------------------------------------------------
  TZCustomSyn
  --------------------------------------------------------------------------- }

constructor TZCustomSyn.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTokenStart := 0;
  FTokenLen := 0;
  FTokenPos := 0;
  FKind := ztkIdentifier;
end;

procedure TZCustomSyn.AddKindAttr(AKind: Integer; const ACaption: string);
begin
  { The caption is also the stored name; tzip.preview's RoleOf reads it. }
  AddAttribute(TSynHighlighterAttributes.Create(ACaption, ACaption));
end;

procedure TZCustomSyn.SetToken(AOffs, ALen, AKind: Integer);
begin
  FTokenStart := AOffs;
  FTokenPos := AOffs;
  FTokenLen := ALen;
  FKind := AKind;
  { The scan resumes after the token, whatever the scanner reports next. A
    zero-length report (a scanner that consumed nothing) must not move it, or
    Next would restart at the token that was just painted. }
  if ALen > 0 then FScan := AOffs + ALen;
end;

procedure TZCustomSyn.PrepareLine;
begin
  { Subclasses classify the line; the base needs nothing. }
end;

procedure TZCustomSyn.SetLine(const NewValue: String; LineNumber: Integer);
begin
  inherited SetLine(NewValue, LineNumber);
  FTokenStart := 0;
  FTokenLen := 0;
  FTokenPos := 0;
  FScan := 0;
  FKind := ztkIdentifier;
  PrepareLine;
  { SynEdit's contract: the first token is available right after SetLine (the
    stock highlighters call Next from their own SetLine for the same reason). }
  Next;
end;

procedure TZCustomSyn.Next;
var
  Pos_: Integer;
begin
  FTokenLen := 0;
  Pos_ := FScan;
  FTokenStart := Pos_;
  FTokenPos := Pos_;
  if Pos_ >= Length(CurrentLineText) then
  begin
    { The null token at the end of the line: GetEol answers True for it, which
      is how SynEdit knows the line is finished (SynEdit's own highlighters end
      on tkNull the same way). }
    FKind := ztkIdentifier;
    Exit;
  end;
  ScanToken(Pos_, Self, nil);
  if FTokenLen <= 0 then
    { A scanner that reports nothing must still make progress, or SynEdit
      paints the same token forever. }
    SetToken(Pos_, 1, ztkIdentifier);
end;

function TZCustomSyn.GetEol: Boolean;
begin
  { True when the CURRENT token is the end-of-line marker, not when the scanner
    has run out of input: Next() moves to the null token and stops there. }
  Result := (FTokenLen = 0) and (FTokenStart >= Length(CurrentLineText));
end;

procedure TZCustomSyn.GetTokenEx(out TokenStart: PChar;
  out TokenLength: integer);
begin
  TokenStart := PChar(Pointer(CurrentLineText)) + FTokenStart;
  TokenLength := FTokenLen;
end;

function TZCustomSyn.GetToken: string;
begin
  Result := Copy(CurrentLineText, FTokenStart + 1, FTokenLen);
end;

function TZCustomSyn.GetTokenPos: Integer;
begin
  Result := FTokenPos;
end;

function TZCustomSyn.GetTokenLen: Integer;
begin
  Result := FTokenLen;
end;

function TZCustomSyn.GetTokenKind: Integer;
begin
  Result := FKind;
end;

function TZCustomSyn.GetDefaultAttribute(Index: integer): TSynHighlighterAttributes;
begin
  case Index of
    SYN_ATTR_COMMENT: Result := Attribute[ztkComment];
    SYN_ATTR_KEYWORD: Result := Attribute[ztkKeyword];
    SYN_ATTR_STRING: Result := Attribute[ztkString];
    SYN_ATTR_SYMBOL: Result := Attribute[ztkSymbol];
    SYN_ATTR_NUMBER: Result := Attribute[ztkNumber];
    SYN_ATTR_DIRECTIVE: Result := Attribute[ztkDirective];
  else
    Result := Attribute[ztkIdentifier];
  end;
end;

{ ---------------------------------------------------------------------------
  TZGeneralSyntax
  --------------------------------------------------------------------------- }

constructor TZGeneralSyntax.Create(AOwner: TComponent; const ALangName: string);
begin
  inherited Create(AOwner);
  FLangName := ALangName;
  FKeywords := TStringList.Create;
  FKeywords.Sorted := True;
  FKeywords.Duplicates := dupAccept;
  FCaseSensitive := True;
  AddKindAttr(ztkComment, 'Comment');
  AddKindAttr(ztkKeyword, 'Keyword');
  AddKindAttr(ztkString, 'String');
  AddKindAttr(ztkNumber, 'Number');
  AddKindAttr(ztkSymbol, 'Symbol');
  AddKindAttr(ztkProp, 'Property');
  AddKindAttr(ztkConstant, 'Constant');
  AddKindAttr(ztkBuiltin, 'Builtin');
  AddKindAttr(ztkIdentifier, 'Identifier');
  AddKindAttr(ztkDirective, 'Directive');
  AddKindAttr(ztkReference, 'Reference');
  AddKindAttr(ztkHeading, 'Heading');
  AddKindAttr(ztkEscape, 'Escape');
  AddKindAttr(ztkStrike, 'Strike');
  AddKindAttr(ztkEmphasis, 'Emphasis');
  AddKindAttr(ztkCode, 'Code');
end;

destructor TZGeneralSyntax.Destroy;
begin
  FKeywords.Free;
  inherited Destroy;
end;

function TZGeneralSyntax.GetInstanceLanguageName: string;
begin
  Result := FLangName;
end;

procedure TZGeneralSyntax.Configure(const AOptions: TZScanOptions;
  ACaseSensitive: Boolean);
var
  I: Integer;
begin
  FOptions := AOptions;
  FCaseSensitive := ACaseSensitive;
  for I := 0 to FKeywords.Count - 1 do
    if not FCaseSensitive then
      FKeywords[I] := UpperCase(FKeywords[I]);
  FKeywords.Sort;
end;

function TZGeneralSyntax.Lookup(const AWord: string; out AKind: Integer): Boolean;
var
  Idx, I: Integer;
  Key: string;
begin
  Key := AWord;
  if not FCaseSensitive then Key := UpperCase(Key);
  Result := FKeywords.Find(Key, Idx);
  if Result then
  begin
    { Duplicates are allowed so a language can override a shared pool word
      (true=6 after true, mut after a bare identifier); the LAST entry wins,
      which is what AddWord relies on. }
    I := Idx;
    while (I + 1 < FKeywords.Count) and (FKeywords[I + 1] = Key) do Inc(I);
    AKind := PtrInt(FKeywords.Objects[I]);
  end
  else
    AKind := ztkIdentifier;
end;

procedure TZGeneralSyntax.AddWord(const AWord: string);
var
  P, K: Integer;
  Key: string;
begin
  if AWord = '' then Exit;
  Key := AWord;
  K := ztkKeyword;
  P := Pos('=', Key);
  if P > 0 then
  begin
    K := StrToIntDef(Copy(Key, P + 1, MaxInt), ztkKeyword);
    Key := Copy(Key, 1, P - 1);
  end;
  if not FCaseSensitive then Key := UpperCase(Key);
  { Keep the list sorted so Lookup stays a binary search; dupAccept keeps the
    pool word and the override, and Lookup takes the later one. }
  if FKeywords.Sorted then
    FKeywords.AddObject(Key, TObject(PtrInt(K)))
  else
  begin
    FKeywords.Sorted := True;
    FKeywords.AddObject(Key, TObject(PtrInt(K)));
  end;
end;

procedure TZGeneralSyntax.ResetRange;
begin
  FInBlock := False;
  FBlockDepth := 0;
  FBlockString := '';
  FInHeredoc := False;
end;

function TZGeneralSyntax.GetRange: Pointer;
begin
  { SynEdit compares the range by pointer identity and treats nil as "same as
    before", so every state needs a stable, non-nil representation. }
  if FInBlock then
    Result := Pointer(PtrInt(1 + FBlockDepth))
  else if FBlockString = Q3S then
    Result := Pointer(PtrInt(100))
  else if FBlockString = '"""' then
    Result := Pointer(PtrInt(101))
  else if FInHeredoc then
    Result := Pointer(PtrInt(200))
  else
    Result := Pointer(PtrInt(0));
  { Pointer(0) is nil, which the base class treats as "no change" -- exactly
    what "no open state" means, so it is fine. }
end;

procedure TZGeneralSyntax.SetRange(Value: Pointer);
var
  V: PtrInt;
begin
  V := PtrInt(Value);
  FInBlock := False;
  FBlockDepth := 0;
  FBlockString := '';
  FInHeredoc := False;
  if (V >= 1) and (V < 100) then
  begin
    FInBlock := True;
    FBlockDepth := V - 1;
  end
  else if V = 100 then
    FBlockString := Q3S
  else if V = 101 then
    FBlockString := '"""'
  else if V = 200 then
    FInHeredoc := True;
end;

procedure TZGeneralSyntax.PrepareLine;
begin
  { Nothing: the cross-line state is read by ScanToken. }
end;

function TZGeneralSyntax.LinePropEnd(AStart: Integer): Integer;
{ If the content at AStart looks like "key:" (after indentation, an optional
  '-' list dash and optional quotes), returns the 1-based index of the end of
  the key; otherwise 0. Used for YAML/TOML-style bare keys. }
var
  S: string;
  N, P, Q: Integer;
begin
  Result := 0;
  S := CurrentLineText;
  N := Length(S);
  P := AStart;
  while (P < N) and IsSpace(Ord(S[P + 1])) do Inc(P);
  if (P < N) and (S[P + 1] = '-') and (P + 1 >= N) or
     ((P < N) and (S[P + 1] = '-') and ((P + 1 = N) or IsSpace(Ord(S[P + 2])))) then
  begin
    Inc(P);
    while (P < N) and IsSpace(Ord(S[P + 1])) do Inc(P);
  end;
  if P >= N then Exit;
  if (S[P + 1] = '"') or (S[P + 1] = '''') then
  begin
    Q := P + 2;
    while (Q < N) and (S[Q + 1] <> S[P + 1]) do Inc(Q);
    if (Q >= N) or (Q + 1 > N) or (S[Q + 2] <> ':') then Exit;
    Exit(Q + 1);
  end;
  if not IsIdentStart(Ord(S[P + 1])) then Exit;
  Q := P + 1;
  while (Q < N) and IsIdentChar(Ord(S[Q + 1])) do Inc(Q);
  { allow dots and dashes inside a key: build.cache-size }
  while (Q < N) and ((S[Q + 1] = '.') or (S[Q + 1] = '-')) and (Q + 1 < N) and
        IsIdentChar(Ord(S[Q + 2])) do
  begin
    Inc(Q);
    while (Q < N) and IsIdentChar(Ord(S[Q + 1])) do Inc(Q);
  end;
  if (Q < N) and (S[Q + 1] = ':') then
    Result := Q;
end;

procedure TZGeneralSyntax.ScanToken(AOffs: Integer; AContext: TObject;
  AToken: TZTokenProc);
var
  S: string;
  N, P, Q, D, I, J, K: Integer;
  C: Byte;
  W, Closer: string;
  Kind: Integer;

  procedure Emit(AKind, AFrom, ALen: Integer);
  begin
    SetToken(AFrom, ALen, AKind);
    if AToken <> nil then AToken(AContext, AFrom, ALen, AKind);
  end;

  function IsLineCommentAt(APos: Integer; out ALength: Integer): Boolean;
  var
    J: Integer;
  begin
    Result := False;
    ALength := 0;
    for J := 0 to High(FOptions.LineComments) do
      if (FOptions.LineComments[J] <> '') and
         StartsWith(S, APos, FOptions.LineComments[J]) then
      begin
        { A floor of 2 means "only at the start of the line" (1-based column
          1); a floor of 0 means anywhere. }
        if (J <= High(FOptions.LineCommentColFloor)) and
           (FOptions.LineCommentColFloor[J] > 1) and
           (APos + 1 >= FOptions.LineCommentColFloor[J]) then
          Continue;
        ALength := Length(FOptions.LineComments[J]);
        Result := True;
        Exit;
      end;
  end;

  { FInBlock: a /* */ comment is already open when the line starts.
    AStartHere is true when P points at the opening /* that starts the comment;
    counting that same opener as a nested /* left the depth at 2 and the first
    */ only brought it back to 1, so the rest of the file stayed a comment. }
  procedure FinishBlock(AStartHere: Boolean = False);
  var
    D: Integer;
  begin
    D := P;
    if AStartHere then Inc(D, 2);
    while (D < N) and (FBlockDepth > 0) do
    begin
      if StartsWith(S, D, '*/') then
      begin
        Inc(D, 2);
        Dec(FBlockDepth);
      end
      else if StartsWith(S, D, '/*') then
      begin
        Inc(D, 2);
        Inc(FBlockDepth);
      end
      else
        Inc(D);
    end;
    FInBlock := FBlockDepth > 0;
    Emit(ztkComment, P, D - P);
    if not FInBlock then P := D;
  end;

begin
  S := CurrentLineText;
  N := Length(S);
  P := AOffs;
  if P >= N then Exit;
  C := Ord(S[P + 1]);

  { continues from the previous line }
  if FInBlock then
  begin
    FinishBlock;
    Exit;
  end;
  if FBlockString <> '' then
  begin
    Closer := FBlockString;
    Q := P;
    while Q <= N - 3 do
    begin
      if StartsWith(S, Q, Closer) then
      begin
        Inc(Q, 3);
        FBlockString := '';
        Emit(ztkString, P, Q - P);
        Exit;
      end;
      Inc(Q);
    end;
    Emit(ztkString, P, N - P);
    Exit;
  end;
  if FInHeredoc then
  begin
    FInHeredoc := False;
    Emit(ztkString, P, N - P);
    Exit;
  end;

  { A preprocessor directive starts with '#' as the first non-blank
    character.  Paint '#word' as one directive token, then let the rest of the
    line scan normally (strings/comments inside a #define still work).  Without
    this every directive word was coloured by the keyword table: #else red,
    #include blue, #endif default. }
  if FOptions.Preprocessor and (C = Ord('#')) then
  begin
    I := 0;
    while (I < P) and ((S[I + 1] = ' ') or (S[I + 1] = #9)) do Inc(I);
    if I = P then
    begin
      Q := P + 1;
      while (Q < N) and ((S[Q + 1] = ' ') or (S[Q + 1] = #9)) do Inc(Q);
      D := Q;
      while (D < N) and IsIdentChar(Ord(S[D + 1])) do Inc(D);
      if D = Q then D := P + 1;
      Emit(ztkDirective, P, D - P);
      Exit;
    end;
  end;

  { whitespace }
  if IsSpace(C) then
  begin
    Q := P + 1;
    while (Q < N) and IsSpace(Ord(S[Q + 1])) do Inc(Q);
    Emit(ztkIdentifier, P, Q - P);
    Exit;
  end;

  { line comment }
  if IsLineCommentAt(P, K) then
  begin
    Emit(ztkComment, P, N - P);
    Exit;
  end;

  { block comment }
  if FOptions.BlockComment and StartsWith(S, P, '/*') then
  begin
    FInBlock := True;
    FBlockDepth := 1;
    FinishBlock(True);
    Exit;
  end;

  { ''' or """ block string }
  if FOptions.ThirdQuote and ((StartsWith(S, P, Q3S)) or
     (StartsWith(S, P, Q3D))) then
  begin
    Closer := Copy(S, P + 1, 3);
    Q := P + 3;
    while Q <= N - 3 do
    begin
      if StartsWith(S, Q, Closer) then
      begin
        Inc(Q, 3);
        Emit(ztkString, P, Q - P);
        Exit;
      end;
      Inc(Q);
    end;
    FBlockString := Closer;
    Emit(ztkString, P, N - P);
    Exit;
  end;

  { Rust raw string r"..." / r#"..."#; b"..." falls through to strings }
  if FOptions.RawPrefix and (C = Ord('r')) then
  begin
    Q := P + 1;
    I := 0;
    while (Q < N) and (S[Q + 1] = '#') do
    begin
      Inc(Q);
      Inc(I);
    end;
    if (Q < N) and (S[Q + 1] = '"') then
    begin
      Inc(Q);
      while Q < N do
      begin
        if S[Q + 1] = '"' then
        begin
          D := Q + 1;
          J := 0;
          while (D < N) and (S[D + 1] = '#') do
          begin
            Inc(D);
            Inc(J);
          end;
          if J >= I then
          begin
            Q := D;
            Break;
          end;
        end;
        Inc(Q);
      end;
      if Q > N then Q := N;
      Emit(ztkString, P, Q - P);
      Exit;
    end;
  end;

  { ordinary strings, including doubled-quote escapes }
  if ((C = Ord('"')) and FOptions.DoubleQuote) or
     ((C = Ord('''')) and FOptions.SingleQuote) or
     ((C = Ord('`')) and FOptions.Backtick) then
  begin
    Q := P + 1;
    while Q < N do
    begin
      if (FOptions.Escape <> #0) and (S[Q + 1] = FOptions.Escape) then
      begin
        Inc(Q, 2);
        Continue;
      end;
      if S[Q + 1] = Char(C) then
      begin
        Inc(Q);
        if (Q < N) and (S[Q + 1] = Char(C)) and (Char(C) <> '`') then
        begin
          Inc(Q);
          Continue;
        end;
        Break;
      end;
      Inc(Q);
    end;
    if Q > N then Q := N;
    { A quoted key: "name": in JSON/TOML/YAML, 'name': in TOML. It is the name
      of a property, not a value, and reading it as a string is the usual
      reason JSON loses its keys. }
    if (Q < N) and (S[Q + 1] = ':') and (Char(C) <> '`') then
    begin
      Emit(ztkProp, P, Q - P);
      Exit;
    end;
    Emit(ztkString, P, Q - P);
    Exit;
  end;

  { Ruby percent literals }
  if FOptions.PercentLiteral and (C = Ord('%')) and (P + 2 < N) and
     (S[P + 2] in ['w', 'q', 'Q', 'i', 'I', 'r', 'W', 'x', 's']) then
  begin
    case S[P + 3] of
      '[': C := Ord(']');
      #123: C := Ord(#125);
      '(': C := Ord(')');
      '<': C := Ord('>');
      '/': C := Ord('/');
      '|': C := Ord('|');
      '!': C := Ord('!');
    else
      C := 0;
    end;
    if C <> 0 then
    begin
      Q := P + 3;
      while Q < N do
      begin
        if Ord(S[Q + 1]) = C then
        begin
          Inc(Q);
          Break;
        end;
        Inc(Q);
      end;
      Emit(ztkString, P, Q - P);
      Exit;
    end;
  end;

  { Ruby heredoc: <<~EOS / <<-EOS / <<EOS, body on the following lines }
  if FOptions.Heredoc and StartsWith(S, P, '<<') and (not StartsWith(S, P, '<<=')) then
  begin
    Q := P + 2;
    while (Q < N) and (S[Q + 1] in ['~', '-']) do Inc(Q);
    if (Q < N) and (S[Q + 1] in ['"', '''']) then
    begin
      C := Ord(S[Q + 1]);
      Inc(Q);
      while (Q < N) and (S[Q + 1] <> Char(C)) do Inc(Q);
      if Q < N then Inc(Q);
      Emit(ztkString, P, Q - P);
    end
    else
    begin
      I := Q;
      while (Q < N) and (Char(Ord(S[Q + 1])) in ['a'..'z', 'A'..'Z', '_', '0'..'9']) do
        Inc(Q);
      if Q > I then
      begin
        FInHeredoc := True;
        Emit(ztkString, P, Q - P);
        Exit;
      end;
    end;
    Exit;
  end;

  { numbers }
  if IsDigit(C) then
  begin
    Q := P + 1;
    while (Q < N) and (Char(Ord(S[Q + 1])) in ['0'..'9', 'a'..'f', 'A'..'F',
           'x', 'X', 'o', 'O', '_']) do
      Inc(Q);
    if (Q < N) and (S[Q + 1] = '.') and (Q + 1 < N) and (S[Q + 2] <> '.') then
    begin
      Inc(Q);
      while (Q < N) and IsDigit(Ord(S[Q + 1])) do Inc(Q);
    end;
    if (Q < N) and (S[Q + 1] in ['e', 'E']) then
    begin
      Inc(Q);
      if (Q < N) and (S[Q + 1] in ['+', '-']) then Inc(Q);
      while (Q < N) and IsDigit(Ord(S[Q + 1])) do Inc(Q);
    end;
    while (Q < N) and (Char(Ord(S[Q + 1])) in ['u', 'U', 'l', 'L', 'f', 'F', 'i', 'n']) and
          (Copy(S, Q, 1) <> '') and (not IsDigit(Ord(S[Q]))) and
          (not (Char(Ord(S[Q])) in ['a'..'f', 'A'..'F'])) do
      Inc(Q);
    Emit(ztkNumber, P, Q - P);
    Exit;
  end;

  { identifier, keyword, or a bare key before ':' }
  if IsIdentStart(C) then
  begin
    Q := P + 1;
    while (Q < N) and IsIdentChar(Ord(S[Q + 1])) do Inc(Q);
    W := Copy(S, P + 1, Q - P);
    if Lookup(W, Kind) then
      Emit(Kind, P, Q - P)
    else
    begin
      I := 0;
      if FBareColonKeys then I := LinePropEnd(P);
      if I > 0 then
        Emit(ztkProp, P, I - P)
      else
      begin
        { TOML-style bare key: identifier, spaces, '='. Only for languages that
          actually write keys that way -- in C or Go "x = 1" is an assignment. }
        I := Q;
        if FBareEqualKeys then
          while (I < N) and (S[I + 1] = ' ') do Inc(I);
        if FBareEqualKeys and (I < N) and (S[I + 1] = '=') then
          Emit(ztkProp, P, Q - P)
        else
          Emit(ztkIdentifier, P, Q - P);
      end;
    end;
    Exit;
  end;

  { punctuation; two-character operators stay one token }
  Q := P + 1;
  if P + 1 < N then
  begin
    W := Copy(S, P + 1, 2);
    if (W = '=>') or (W = '->') or (W = '::') or (W = '==') or (W = '!=') or
       (W = '<=') or (W = '>=') or (W = '&&') or (W = '||') or (W = '??') or
       (W = '**') or (W = '<<') or (W = '+=') or (W = '-=') or (W = '*=') or
       (W = '/=') or (W = '?.') or (W = '..') then
      Q := P + 2;
  end;
  Emit(ztkSymbol, P, Q - P);
end;

function TZGeneralSyntax.GetTokenAttribute: TSynHighlighterAttributes;
begin
  if (FKind >= 0) and (FKind < ZSyntaxTokenKindCount) and (Attribute[FKind] <> nil) then
    Result := Attribute[FKind]
  else
    Result := Attribute[ztkIdentifier];
end;


{ ---------------------------------------------------------------------------
  TZMarkdownSyntax
  --------------------------------------------------------------------------- }

constructor TZMarkdownSyntax.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  AddKindAttr(ztkComment, 'Comment');
  AddKindAttr(ztkKeyword, 'Keyword');
  AddKindAttr(ztkString, 'String');
  AddKindAttr(ztkNumber, 'Number');
  AddKindAttr(ztkSymbol, 'Symbol');
  AddKindAttr(ztkProp, 'Property');
  AddKindAttr(ztkConstant, 'Constant');
  AddKindAttr(ztkBuiltin, 'Builtin');
  AddKindAttr(ztkIdentifier, 'Identifier');
  AddKindAttr(ztkDirective, 'Directive');
  AddKindAttr(ztkReference, 'Reference');
  AddKindAttr(ztkHeading, 'Heading');
  AddKindAttr(ztkEscape, 'Escape');
  AddKindAttr(ztkStrike, 'Strike');
  AddKindAttr(ztkEmphasis, 'Emphasis');
  AddKindAttr(ztkCode, 'Code');
end;

procedure TZMarkdownSyntax.ResetRange;
begin
  FInFence := False;
  FInFrontMatter := False;
  FCodeLine := False;
  FHeading := False;
  FHeadingStart := 0;
end;

{ State bits: 1 = a fence is open after this line, 2 = inside front matter.
  FCodeLine/FHeading are per-line and deliberately not part of the state. }
function TZMarkdownSyntax.GetRange: Pointer;
var
  V: PtrInt;
begin
  V := 0;
  if FInFence then V := V or 1;
  if FInFrontMatter then V := V or 2;
  if V = 0 then Result := nil else Result := Pointer(V);
end;

procedure TZMarkdownSyntax.SetRange(Value: Pointer);
var
  V: PtrInt;
begin
  V := PtrInt(Value);
  FInFence := (V and 1) <> 0;
  FInFrontMatter := (V and 2) <> 0;
end;

function TZMarkdownSyntax.GetTokenAttribute: TSynHighlighterAttributes;
begin
  if (FKind >= 0) and (FKind < ZSyntaxTokenKindCount) and (Attribute[FKind] <> nil) then
    Result := Attribute[FKind]
  else
    Result := Attribute[ztkIdentifier];
end;

procedure TZMarkdownSyntax.PrepareLine;
var
  S: string;
  N, P, Q: Integer;
begin
  S := CurrentLineText;
  N := Length(S);
  P := 1;
  while (P <= N) and (S[P] = ' ') do Inc(P);

  { A fence line (``` or ~~~, at any indent) opens or closes a code block, and
    is itself code; so is every line while the fence is open. FCodeLine is
    computed here because ScanToken cannot know whether the fence flag it sees
    belongs to this line or the previous one. }
  FCodeLine := FInFence;
  if (P <= N) and ((Copy(S, P, 3) = '```') or (Copy(S, P, 3) = '~~~')) then
  begin
    FInFence := not FInFence;
    FCodeLine := True;
    Exit;
  end;

  { YAML front matter: '---' on the very first line, closed by '---' or '...'. }
  if FOptions.YAMLFrontMatter and (LineIndex = 0) and (Copy(S, 1, 3) = '---') then
    FInFrontMatter := True
  else if FInFrontMatter and ((Copy(S, 1, 3) = '---') or (Copy(S, 1, 3) = '...')) then
    FInFrontMatter := False;

  { ATX heading: 1-6 '#' at the start of the line, then a space or the end. }
  FHeading := False;
  FHeadingStart := 0;
  if (not FInFence) and (not FInFrontMatter) and (P <= N) and (S[P] = '#') then
  begin
    Q := P;
    while (Q <= N) and (S[Q] = '#') do Inc(Q);
    if (Q - P <= 6) and ((Q > N) or (S[Q] = ' ') or (S[Q] = #9)) then
    begin
      FHeading := True;
      { Text starts at the first non-space after the hashes. }
      while (Q <= N) and ((S[Q] = ' ') or (S[Q] = #9)) do Inc(Q);
      FHeadingStart := Q - 1;
    end;
  end;
end;

procedure TZMarkdownSyntax.ScanInline(var AStart: Integer; const AEnd: Integer;
  AContext: TObject; AToken: TZTokenProc);
{ One inline token at AStart, never past AEnd. }
var
  S: string;
  P, Q, I, RunLen: Integer;
  C: Char;

  procedure Emit(AKind, AFrom, ALen: Integer);
  begin
    SetToken(AFrom, ALen, AKind);
    if AToken <> nil then AToken(AContext, AFrom, ALen, AKind);
  end;

  function IsEscape(const AChars: string): Boolean;
  begin
    Result := (P + 1 < AEnd) and (Pos(S[P + 2], AChars) > 0);
  end;

begin
  S := CurrentLineText;
  P := AStart;
  if P >= AEnd then Exit;
  C := S[P + 1];

  { backslash escape }
  if (C = '\') and IsEscape('\`*_{}[]()#+-.!|>~') then
  begin
    Emit(ztkEscape, P, 2);
    Exit;
  end;

  { inline code span: the closing run must be as long as the opening one }
  if C = '`' then
  begin
    Q := P;
    while (Q < AEnd) and (S[Q + 1] = '`') do Inc(Q);
    RunLen := Q - P;
    I := Q;
    while I < AEnd do
    begin
      if S[I + 1] = '`' then
      begin
        Q := I + 1;
        while (Q < AEnd) and (S[Q + 1] = '`') do Inc(Q);
        if Q - I = RunLen then
        begin
          Emit(ztkCode, P, Q - P);
          Exit;
        end;
        I := Q;
      end
      else
        Inc(I);
    end;
    Emit(ztkIdentifier, P, RunLen);
    Exit;
  end;

  { link or image: the whole [text](target) is one reference token }
  if (C = '[') or ((C = '!') and (P + 1 < AEnd) and (S[P + 2] = '[')) then
  begin
    Q := P;
    if C = '!' then Inc(Q);
    Inc(Q);
    while (Q < AEnd) and (S[Q + 1] <> ']') do Inc(Q);
    if (Q < AEnd) and (Q + 1 < AEnd) and ((S[Q + 2] = '(') or (S[Q + 2] = '[')) then
    begin
      C := S[Q + 2];
      Inc(Q, 2);
      while (Q < AEnd) and (S[Q + 1] <> C) and
            ((C = '[') or (S[Q + 1] <> ')')) do Inc(Q);
      if Q < AEnd then Inc(Q);
      Emit(ztkReference, P, Q - P);
      Exit;
    end;
  end;

  { emphasis markers; the text between them is found by the caller's loop }
  if C in ['*', '_'] then
  begin
    Q := P;
    while (Q < AEnd) and (S[Q + 1] = C) do Inc(Q);
    Emit(ztkEmphasis, P, Q - P);
    Exit;
  end;
  if (C = '~') and FOptions.Strikethrough and (P + 1 < AEnd) and (S[P + 2] = '~') then
  begin
    Emit(ztkStrike, P, 2);
    Exit;
  end;

  { plain run: stop before the next character with meaning }
  Q := P;
  while (Q < AEnd) and (Pos(S[Q + 1], '\`[*_~') = 0) do Inc(Q);
  if Q = P then Inc(Q);
  Emit(ztkIdentifier, P, Q - P);
end;

procedure TZMarkdownSyntax.ScanToken(AOffs: Integer; AContext: TObject;
  AToken: TZTokenProc);
var
  S: string;
  N, P, Q, E, Hash: Integer;
  C: Char;

  procedure Emit(AKind, AFrom, ALen: Integer);
  begin
    SetToken(AFrom, ALen, AKind);
    if AToken <> nil then AToken(AContext, AFrom, ALen, AKind);
  end;

begin
  S := CurrentLineText;
  N := Length(S);
  P := AOffs;
  if P >= N then Exit;
  C := S[P + 1];

  { Code blocks: fence lines and everything inside them. }
  if FCodeLine then
  begin
    Emit(ztkCode, P, N - P);
    Exit;
  end;

  { Front matter is YAML, painted as a string block by the preview. }
  if FInFrontMatter then
  begin
    Emit(ztkString, P, N - P);
    Exit;
  end;

  { whitespace }
  if (C = ' ') or (C = #9) then
  begin
    Q := P;
    while (Q < N) and ((S[Q + 1] = ' ') or (S[Q + 1] = #9)) do Inc(Q);
    Emit(ztkIdentifier, P, Q - P);
    Exit;
  end;

  { heading: the hashes are markers, the text is a heading }
  if FHeading then
  begin
    { AOffs (P) is 0-based and so is FHeadingStart: PrepareLine stores "Q - 1",
      turning the 1-based scan position into an index. Comparing them directly is
      correct -- but the MARKER token used to end at the hashes instead of after
      the space, so the scanner resumed one character into the text. For "### 亮"
      that character was the first byte of a three-byte glyph, and SynEdit painted
      the fragment as "?".
      The hashes and the space therefore go out as ONE token. }
    if P = 0 then
    begin
      { The hashes AND the space that follows them: one marker token, so the
        heading text starts on a character boundary and the marker is painted as
        a unit. }
      Q := 0;
      while (Q < N) and (S[Q + 1] = '#') do Inc(Q);
      E := Q;
      while (E < N) and ((S[E + 1] = ' ') or (S[E + 1] = #9)) do Inc(E);
      Emit(ztkHeading, P, E - P);
      Exit;
    end;
    if P < FHeadingStart then
    begin
      Emit(ztkHeading, P, FHeadingStart - P);
      Exit;
    end;
    if P = FHeadingStart then
    begin
      { Text up to the closing hashes (if any). }
      E := N;
      while (E > P) and (S[E] = ' ') do Dec(E);
      Q := E;
      while (Q > P) and (S[Q] = '#') do Dec(Q);
      if (Q < E) and ((Q = P) or (S[Q] = ' ')) then E := Q;
      while (E > P) and (S[E] = ' ') do Dec(E);
      if E > P then
      begin
        Emit(ztkHeading, P, E - P);
        Exit;
      end;
    end;
  end;

  { thematic break: --- *** ___ alone on a line }
  if (P = 1) and (C in ['-', '*', '_']) then
  begin
    Q := P;
    while (Q < N) and (S[Q + 1] = C) do Inc(Q);
    if Q - P >= 3 then
    begin
      E := Q;
      while (E < N) and (S[E + 1] = ' ') do Inc(E);
      if E >= N then
      begin
        Emit(ztkHeading, P, N);
        Exit;
      end;
    end;
  end;

  { block quote marker }
  if C = '>' then
  begin
    Emit(ztkHeading, P, 1);
    Exit;
  end;

  { list item: -, * or + followed by a space; 1. / 1) too }
  if (C in ['-', '*', '+']) and ((P = N) or (S[P + 2] = ' ')) then
  begin
    if (P = 1) and (S = '-') then
    begin
      Emit(ztkIdentifier, P, 1);
      Exit;
    end;
    Emit(ztkHeading, P, 1);
    Exit;
  end;
  if C in ['0'..'9'] then
  begin
    Q := P;
    while (Q < N) and (S[Q + 1] in ['0'..'9']) do Inc(Q);
    if (Q < N) and (S[Q + 1] in ['.', ')']) and ((Q + 1 = N) or (S[Q + 2] = ' ')) then
    begin
      Emit(ztkHeading, P, Q + 1 - P);
      Exit;
    end;
  end;

  { task list checkbox }
  if (C = '[') and (P + 3 <= N) and (S[P + 2] in [' ', 'x', 'X']) and
     (S[P + 3] = ']') then
  begin
    Emit(ztkConstant, P, 3);
    Exit;
  end;

  { table row: pipes are markers, the cells use inline rules }
  if FOptions.Tables and (C = '|') and (Pos('|', Copy(S, 2, MaxInt)) > 0) then
  begin
    Emit(ztkSymbol, P, 1);
    Exit;
  end;

  E := N;
  ScanInline(P, E, AContext, AToken);
end;

constructor TZYamlSyntax.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBlockIndent := -1;
  AddKindAttr(ztkComment, 'Comment');
  AddKindAttr(ztkKeyword, 'Keyword');
  AddKindAttr(ztkString, 'String');
  AddKindAttr(ztkNumber, 'Number');
  AddKindAttr(ztkSymbol, 'Symbol');
  AddKindAttr(ztkProp, 'Property');
  AddKindAttr(ztkConstant, 'Constant');
  AddKindAttr(ztkBuiltin, 'Builtin');
  AddKindAttr(ztkIdentifier, 'Identifier');
  AddKindAttr(ztkDirective, 'Directive');
  AddKindAttr(ztkReference, 'Reference');
  AddKindAttr(ztkHeading, 'Heading');
  AddKindAttr(ztkEscape, 'Escape');
  AddKindAttr(ztkStrike, 'Strike');
  AddKindAttr(ztkEmphasis, 'Emphasis');
  AddKindAttr(ztkCode, 'Code');
end;

procedure TZYamlSyntax.ResetRange;
begin
  FBlockIndent := -1;
  FFlow := 0;
end;

{ Bits 0..11: block-scalar indent + 1; bits 12+: flow depth. }
function TZYamlSyntax.GetRange: Pointer;
var
  V: PtrInt;
begin
  V := (FBlockIndent + 1) or (FFlow shl 12);
  if V = 0 then Result := nil else Result := Pointer(V);
end;

procedure TZYamlSyntax.SetRange(Value: Pointer);
var
  V: PtrInt;
begin
  V := PtrInt(Value);
  FBlockIndent := (V and $FFF) - 1;
  FFlow := V shr 12;
end;

procedure TZYamlSyntax.PrepareLine;
var
  S: string;
  N, P: Integer;
begin
  S := CurrentLineText;
  N := Length(S);
  P := 1;
  while (P <= N) and (S[P] = ' ') do Inc(P);
  { A block scalar continues while its lines are indented deeper than the key
    that owns it; a blank line keeps it open, a shallower line ends it. }
  if FBlockIndent >= 0 then
  begin
    if Trim(S) = '' then Exit;
    if P - 1 <= FBlockIndent then FBlockIndent := -1;
  end;
end;

procedure TZYamlSyntax.ScanToken(AOffs: Integer; AContext: TObject;
  AToken: TZTokenProc);
var
  S: string;
  N, P, Q: Integer;
  C: Char;
  Word_: string;

  procedure Emit(AKind, AFrom, ALen: Integer);
  begin
    SetToken(AFrom, ALen, AKind);
    if AToken <> nil then AToken(AContext, AFrom, ALen, AKind);
  end;

  { Index just past the quote closing the scalar that opens at APos, or AEnd. }
  function QuotedEnd(APos, AEnd: Integer; AQuote: Char): Integer;
  var
    R: Integer;
  begin
    R := APos + 1;
    while R < AEnd do
    begin
      if (AQuote = Q1D) and (S[R + 1] = '\') then
      begin
        Inc(R, 2);
        Continue;
      end;
      if S[R + 1] = AQuote then Exit(R + 1);
      Inc(R);
    end;
    Result := AEnd;
  end;

  { End of a plain run of text (key or value) starting at APos. Stops at a
    comment (" #"), a flow marker, a mapping separator or the line end. }
  function PlainEnd(APos: Integer; AStopAtColon: Boolean): Integer;
  var
    R: Integer;
  begin
    R := APos;
    while R < N do
    begin
      if (S[R + 1] = '#') and ((R = APos) or (S[R] = ' ') or (S[R] = #9)) then
        Exit(R);
      if S[R + 1] in ['[', ']', #123, #125, ','] then Exit(R);
      if AStopAtColon and (S[R + 1] = ':') and
         ((R + 1 = N) or (S[R + 2] = ' ')) and (R > APos) then
        Exit(R);
      Inc(R);
    end;
    { Trailing spaces belong to no token -- but never step back onto a '#' or
      the comment would be swallowed into this scalar. }
    while (R > APos) and ((S[R] = ' ') or (S[R] = #9)) do
    begin
      if (R < N) and (S[R + 1] = '#') then Break;
      Dec(R);
    end;
    Result := R;
  end;

begin
  S := CurrentLineText;
  N := Length(S);
  P := AOffs;
  if P >= N then Exit;
  C := S[P + 1];

  { A block scalar's indented body is a string, all of it. }
  if FBlockIndent >= 0 then
  begin
    Emit(ztkString, P, N - P);
    Exit;
  end;

  { indentation / run of spaces, but stop before a comment }
  if C = ' ' then
  begin
    Q := P;
    while (Q < N) and (S[Q + 1] = ' ') do Inc(Q);
    while (Q > P) and (Q < N) and (S[Q + 1] = '#') do Dec(Q);
    Emit(ztkIdentifier, P, Q - P);
    Exit;
  end;

  { comment: at the start of the line, or after a space, it runs to the end }
  if (C = '#') and ((P = 0) or (S[P] = ' ') or (S[P] = #9)) then
  begin
    Emit(ztkComment, P, N - P);
    Exit;
  end;

  { document start/end markers and list dashes }
  if (P = 1) and ((S = '---') or (Copy(S, 1, 3) = '---') or
     (Copy(S, 1, 3) = '...')) then
  begin
    Emit(ztkHeading, 0, N);
    Exit;
  end;
  if (C = '-') and ((P = N) or (S[P + 2] = ' ')) then
  begin
    Emit(ztkHeading, P, 1);
    Exit;
  end;

  { quoted scalar }
  if (C = Q1D) or (C = Q1S) then
  begin
    Q := QuotedEnd(P, N, C);
    Emit(ztkString, P, Q - P);
    Exit;
  end;

  { anchors (&), aliases (*), tags (!), directives (%) }
  if C in ['&', '*', '!', '%'] then
  begin
    Q := P + 1;
    while (Q < N) and (not (S[Q + 1] in [' ', #9, ',', ']', #125])) do Inc(Q);
    Emit(ztkReference, P, Q - P);
    Exit;
  end;

  { flow markers }
  if C in ['[', ']', #123, #125, ','] then
  begin
    if (C = '[') or (C = #123) then
      Inc(FFlow)
    else if ((C = ']') or (C = #125)) and (FFlow > 0) then
      Dec(FFlow);
    Emit(ztkSymbol, P, 1);
    Exit;
  end;

  { block scalar header: | or > with optional +/- and an indent digit. The
    body is every following line indented deeper than the KEY of this line, so
    record the leading indentation of this line, not the column of the '|'. }
  if (C = '|') or (C = '>') then
  begin
    Q := P + 1;
    while (Q < N) and (S[Q + 1] in ['+', '-', '0'..'9']) do Inc(Q);
    FBlockIndent := 0;
    while (FBlockIndent < N) and (S[FBlockIndent + 1] = ' ') do Inc(FBlockIndent);
    Emit(ztkBuiltin, P, Q - P);
    Exit;
  end;

  { mapping separator }
  if C = ':' then
  begin
    Emit(ztkSymbol, P, 1);
    Exit;
  end;

  { key:  -- a plain or quoted run followed by ':' and a space }
  Q := PlainEnd(P, True);
  if (Q < N) and (S[Q + 1] = ':') and ((Q + 1 = N) or (S[Q + 2] = ' ')) then
  begin
    Emit(ztkProp, P, Q - P);
    Exit;
  end;

  { plain scalar: booleans/null, numbers or text }
  if Q = P then
  begin
    Emit(ztkIdentifier, P, 1);
    Exit;
  end;
  Word_ := LowerCase(Copy(S, P + 1, Q - P));
  if (Word_ = 'true') or (Word_ = 'false') or (Word_ = 'yes') or (Word_ = 'no') or
     (Word_ = 'on') or (Word_ = 'off') or (Word_ = 'null') or (Word_ = '~') then
    Emit(ztkConstant, P, Q - P)
  else if Char(Word_[1]) in ['0'..'9', '-', '+'] then
    Emit(ztkNumber, P, Q - P)
  else
    Emit(ztkIdentifier, P, Q - P);
end;

function TZYamlSyntax.GetTokenAttribute: TSynHighlighterAttributes;
begin
  if (FKind >= 0) and (FKind < ZSyntaxTokenKindCount) and (Attribute[FKind] <> nil) then
    Result := Attribute[FKind]
  else
    Result := Attribute[ztkIdentifier];
end;

end.
