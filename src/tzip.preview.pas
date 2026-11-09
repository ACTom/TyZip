unit tzip.preview;

{ Text preview support: encoding detection/decoding and a theme-aware syntax
  highlighter for the SynEdit viewer in the preview pane.

  Everything here is deliberately free of TyZip UI knowledge: the main form owns
  the editor and its toolbar, this unit answers two questions -- "what bytes do
  I show, in which encoding?" and "which highlighter and colours for this file?"

  Encoding notes: FPC's TEncoding silently degrades multi-byte CJK code pages to
  Latin-1 (GetEncoding(936).GetString returns one char per byte), so the actual
  conversion goes through LCL's LConvEncoding tables, which do carry CP936/950/
  932/949. A UTF-8 file is passed through untouched. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Graphics, LConvEncoding, LCLIntf,
  SynEdit, SynEditHighlighter,
  tzip.preview.syntax;

type
  TZPreviewEncoding = record
    { Shown in the encoding combo. }
    LabelText: string;
    { LConvEncoding identifier; '' means "the bytes are already UTF-8". }
    EncodingId: string;
  end;

const
  PreviewEncodingCount = 8;
  { The detector always answers with one of these; there is no separate "auto"
    entry, so after a load the combo simply shows what was detected and picking
    another entry re-decodes the same bytes. }
  PreviewEncodingAuto = -1;

var
  PreviewEncodings: array[0..PreviewEncodingCount - 1] of TZPreviewEncoding;

type
  TZPreviewPalette = record
    Background: TColor;
    Text: TColor;
    GutterBackground: TColor;
    SelectionBackground: TColor;
    SelectionText: TColor;
    Dark: Boolean;
  end;

{ Palette derived from the live theme: ABackground/AText come from the resolved
  style of the preview pane, so the editor follows light/dark switches. }
function TzMakePreviewPalette(ABackground, AText: TColor;
  AGutterBackground: TColor = clNone): TZPreviewPalette;

{ Colour an editor (background, gutter, selection, font) for the palette. }
procedure TzPreviewStyleEditor(AEdit: TSynEdit; const APalette: TZPreviewPalette);

{ Index into PreviewEncodings for these bytes (BOM, strict UTF-8, else GBK). }
function TzDetectPreviewEncoding(ABuf: PByte; ALen: Integer): Integer;

{ Decode ABuf (already capped by the caller) to a UTF-8 string. An index of
  PreviewEncodingAuto detects first. A trailing partial UTF-8 sequence or an odd
  UTF-16 tail is dropped rather than shown as a replacement char. }
function TzDecodePreviewText(ABuf: PByte; ALen, AEncodingIndex: Integer): string;

{ True when the bytes are a binary payload a text viewer cannot render: a NUL
  byte before any UTF-16 BOM.  macOS AppleDouble sidecars ("._name") start with
  NULs; feeding one to the wrap editor made its validation loop forever. }
function TzPreviewLooksBinary(ABuf: PByte; ALen: Integer): Boolean;

{ The languages the preview can highlight, in the order the picker shows them.
  Index 0 is always "None" (plain text, no highlighter), so a caller that wants
  "just show me the file without colours" has a stable answer. }
const
  PreviewLanguageNone = 0;

{ Number of entries in PreviewLanguages. }
function TzPreviewLanguageCount: Integer;
{ Display name of entry AIndex ("None", "Pascal", "XML", ...). }
function TzPreviewLanguageName(AIndex: Integer): string;
{ Which language a file name maps to, by extension, or PreviewLanguageNone. This
  is the guess the picker starts from; the user can override it per file. }
function TzPreviewLanguageForFile(const AFileName: string): Integer;
{ A highlighter for language AIndex, or nil for PreviewLanguageNone. The caller
  owns the result. }
function TzPreviewHighlighter(AOwner: TComponent; AIndex: Integer): TSynCustomHighlighter;
{ A highlighter for AFileName's extension, or nil when the type has no
  highlighter (or highlighting is off). The caller owns the result. }
function TzPreviewHighlighterFor(AOwner: TComponent;
  const AFileName: string): TSynCustomHighlighter;

{ Re-map a highlighter's attributes onto the palette: keyword/string/comment/
  number/symbol keep their roles, every literal colour in the stock definitions
  is replaced, and backgrounds go transparent so the editor's one background
  shows through. }
procedure TzPreviewTintHighlighter(AHl: TSynCustomHighlighter;
  const APalette: TZPreviewPalette);

implementation

uses
  tzip.i18n,
  SynHighlighterPas, SynHighlighterPython, SynHighlighterJScript,
  SynHighlighterHTML, SynHighlighterXML, SynHighlighterCss, SynHighlighterDiff,
  SynHighlighterIni, SynHighlighterSQL, SynHighlighterBat,
  synhighlighterunixshellscript, SynHighlighterJava, SynHighlighterPerl,
  SynHighlighterPHP, SynHighlighterTeX, SynHighlighterVB;

function TzMix(AFrom, ATo: TColor; AAmount: Double): TColor;
  function MixByte(A, B: Byte): Byte;
  begin
    Result := Round(A + (B - A) * AAmount);
  end;
begin
  Result := RGBToColor(
    MixByte(GetRValue(ColorToRGB(AFrom)), GetRValue(ColorToRGB(ATo))),
    MixByte(GetGValue(ColorToRGB(AFrom)), GetGValue(ColorToRGB(ATo))),
    MixByte(GetBValue(ColorToRGB(AFrom)), GetBValue(ColorToRGB(ATo))));
end;

function TzMakePreviewPalette(ABackground, AText: TColor;
  AGutterBackground: TColor = clNone): TZPreviewPalette;
begin
  Result.Background := ABackground;
  Result.Text := AText;
  { The theme does not expose a "code editor" surface, so derive one: the
    gutter is a barely-there shade of the pane, and the selection is the text
    colour blended into the background so it reads in both light and dark. }
  Result.Dark := (GetRValue(ColorToRGB(ABackground)) +
    GetGValue(ColorToRGB(ABackground)) +
    GetBValue(ColorToRGB(ABackground))) < 3 * 128;
  { The line-number strip uses the same grey as the window's chrome, so the band
    and the pane beside it are one continuous surface instead of a lighter strip
    framed by two darker edges. AGutterBackground comes from the caller, which
    resolves --surface-chrome; the mix here is only the fallback. }
  if AGutterBackground <> clNone then
    Result.GutterBackground := AGutterBackground
  else
    Result.GutterBackground := TzMix(ABackground, AText, 0.12);
  if Result.Dark then
    Result.SelectionBackground := TzMix(ABackground, RGBToColor(90, 150, 230), 0.45)
  else
    Result.SelectionBackground := TzMix(ABackground, RGBToColor(60, 130, 220), 0.30);
  Result.SelectionText := AText;
  if Result.Dark then
    Result.SelectionText := RGBToColor(245, 248, 252);
end;

procedure TzPreviewStyleEditor(AEdit: TSynEdit; const APalette: TZPreviewPalette);
var
  I: Integer;
begin
  if AEdit = nil then Exit;
  AEdit.Color := APalette.Background;
  AEdit.Font.Color := APalette.Text;
  { A viewer, not a form field: Menlo is macOS's terminal//editor face and is
    present on every install (unlike Fira/Consolas). }
  AEdit.Font.Name := 'Menlo';
  if AEdit.Font.Size < 11 then AEdit.Font.Size := 12;
  { Gutter.Color only fills the bare strip. Each gutter PART paints its own
    background from its MarkupInfo, and the line-number part fills the whole
    visible strip -- so setting Color alone left the numbers on the part's
    default white. Both are set: Color for the strip, MarkupInfo for the numbers. }
  AEdit.Gutter.Color := APalette.GutterBackground;
  if AEdit.Gutter.Parts <> nil then
    for I := 0 to AEdit.Gutter.Parts.Count - 1 do
      if Pos('linenumber', LowerCase(AEdit.Gutter.Parts[I].Name)) > 0 then
      begin
        AEdit.Gutter.Parts[I].MarkupInfo.Background := APalette.GutterBackground;
        { Keep the numbers readable on the new background: the default is a mid
          grey chosen for white. }
        AEdit.Gutter.Parts[I].MarkupInfo.Foreground :=
          TzMix(APalette.Text, APalette.Background, 0.35);
      end;
  AEdit.SelectedColor.Background := APalette.SelectionBackground;
  AEdit.SelectedColor.Foreground := APalette.SelectionText;
  { Keep only the line-number part: change marks, a fold column and a separator
    all assume a working editor, and this one is read-only. }
  if AEdit.Gutter.Parts <> nil then
    for I := 0 to AEdit.Gutter.Parts.Count - 1 do
      AEdit.Gutter.Parts[I].Visible :=
        Pos('linenumber', LowerCase(AEdit.Gutter.Parts[I].Name)) > 0;
  AEdit.Invalidate;
end;

{ ---------------------------------------------------------------------------
  Encoding
  --------------------------------------------------------------------------- }

procedure InitEncodings;
begin
  PreviewEncodings[0].LabelText := 'UTF-8';
  PreviewEncodings[0].EncodingId := EncodingUTF8;
  PreviewEncodings[1].LabelText := 'UTF-16 LE';
  PreviewEncodings[1].EncodingId := EncodingUCS2LE;
  PreviewEncodings[2].LabelText := 'UTF-16 BE';
  PreviewEncodings[2].EncodingId := EncodingUCS2BE;
  PreviewEncodings[3].LabelText := 'GBK / GB18030';
  PreviewEncodings[3].EncodingId := EncodingCP936;
  PreviewEncodings[4].LabelText := 'Big5';
  PreviewEncodings[4].EncodingId := EncodingCP950;
  PreviewEncodings[5].LabelText := 'Shift-JIS';
  PreviewEncodings[5].EncodingId := EncodingCP932;
  PreviewEncodings[6].LabelText := 'EUC-KR';
  PreviewEncodings[6].EncodingId := EncodingCP949;
  PreviewEncodings[7].LabelText := 'Windows-1252';
  PreviewEncodings[7].EncodingId := EncodingCP1252;
end;

function Utf8StrictLength(ABuf: PByte; ALen: Integer): Integer;
{ Number of leading bytes that form complete, valid UTF-8 sequences; -1 when the
  buffer is not UTF-8 at all. }
var
  I, N, K, CP: Integer;
  B: Byte;
begin
  I := 0;
  while I < ALen do
  begin
    B := ABuf[I];
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end;
    if (B and $E0) = $C0 then
    begin
      N := 2; CP := B and $1F;
      if CP < 2 then Exit(-1);            { overlong }
    end
    else if (B and $F0) = $E0 then
    begin
      N := 3; CP := B and $0F;
    end
    else if (B and $F8) = $F0 then
    begin
      N := 4; CP := B and $07;
    end
    else
      Exit(-1);
    if I + N > ALen then
      { A truncated sequence at the 64 KB read boundary: the prefix is valid. }
      Exit(I);
    for K := 1 to N - 1 do
    begin
      if (ABuf[I + K] and $C0) <> $80 then Exit(-1);
      CP := (CP shl 6) or (ABuf[I + K] and $3F);
    end;
    if ((N = 3) and (CP < $800)) or ((N = 4) and (CP < $10000)) or
       (CP > $10FFFF) or ((CP >= $D800) and (CP <= $DFFF)) then
      Exit(-1);
    Inc(I, N);
  end;
  Result := ALen;
end;

function TzDetectPreviewEncoding(ABuf: PByte; ALen: Integer): Integer;
var
  AllAscii: Boolean;
  I, K: Integer;
begin
  Result := 0;                                   { UTF-8 }
  if (ABuf = nil) or (ALen <= 0) then Exit;
  if (ALen >= 3) and (ABuf[0] = $EF) and (ABuf[1] = $BB) and (ABuf[2] = $BF) then Exit;
  if (ALen >= 2) and (ABuf[0] = $FF) and (ABuf[1] = $FE) then Exit(1);
  if (ALen >= 2) and (ABuf[0] = $FE) and (ABuf[1] = $FF) then Exit(2);
  { A valid PREFIX is enough. The buffer is capped at 64 KB when read, so a
    Chinese document is very likely to end mid-sequence -- and demanding a
    complete sequence rejected every such file, falling through to the GBK guess
    and turning a perfectly good UTF-8 README into mojibake. Only a cut of four
    bytes or fewer can be a partial sequence; anything more is a real fault. }
  K := Utf8StrictLength(ABuf, ALen);
  if (K = ALen) or ((K > 0) and (ALen - K <= 4)) then Exit;
  { Not UTF-8. Pure ASCII would already have passed; high bytes that are not a
    valid UTF-8 sequence are far more likely GBK than Latin-1 for this program's
    audience, and the combo lets the reader pick something else in one click. }
  AllAscii := True;
  for I := 0 to ALen - 1 do
    if ABuf[I] >= $80 then
    begin
      AllAscii := False;
      Break;
    end;
  if AllAscii then Exit(0);
  Result := 3;
end;

function StripBom(const S: string): string;
begin
  Result := S;
  if (Length(Result) >= 3) and (Copy(Result, 1, 3) = #$EF#$BB#$BF) then
    Delete(Result, 1, 3)
  else if (Length(Result) >= 2) and
    ((Copy(Result, 1, 2) = #$FF#$FE) or (Copy(Result, 1, 2) = #$FE#$FF)) then
    Delete(Result, 1, 2);
end;

function TzPreviewLooksBinary(ABuf: PByte; ALen: Integer): Boolean;
var
  I, N, Bad: Integer;
  B: Byte;
begin
  Result := False;
  if (ABuf = nil) or (ALen <= 0) then Exit;
  { UTF-16 BOM: NULs are expected and the decode path handles it. }
  if (ALen >= 2) and
     (((ABuf[0] = $FF) and (ABuf[1] = $FE)) or
      ((ABuf[0] = $FE) and (ABuf[1] = $FF))) then Exit;
  N := ALen;
  if N > 8192 then N := 8192;
  Bad := 0;
  for I := 0 to N - 1 do
  begin
    B := ABuf[I];
    { A NUL is the hard tell; below it, count the C0 controls a text file does
      not use.  High bytes (UTF-8 emoji, CJK, GBK) are never counted here. }
    if B = 0 then Exit(True);
    if B in [1..8, 11, 12, 14..31] then Inc(Bad);
  end;
  { Text may carry a few control characters (pad bytes, ANSI colour); an eighth
    of the sniff window means the payload is binary. }
  Result := Bad > (N div 8);
end;

function TzDecodePreviewText(ABuf: PByte; ALen, AEncodingIndex: Integer): string;
var
  Raw: RawByteString;
  Enc: string;
  Encoded: Boolean;
begin
  Result := '';
  if (ABuf = nil) or (ALen <= 0) then Exit;
  if AEncodingIndex = PreviewEncodingAuto then
    AEncodingIndex := TzDetectPreviewEncoding(ABuf, ALen);
  if (AEncodingIndex < 0) or (AEncodingIndex >= PreviewEncodingCount) then
    AEncodingIndex := 0;
  SetLength(Raw, ALen);
  Move(ABuf^, Raw[1], ALen);
  Enc := PreviewEncodings[AEncodingIndex].EncodingId;
  if (Enc = '') or (Enc = EncodingUTF8) then
  begin
    Result := StripBom(Raw);
    Exit;
  end;
  if Enc = EncodingUCS2LE then
  begin
    { Drop an odd trailing byte so the last character is not a replacement. }
    if Odd(Length(Raw)) then SetLength(Raw, Length(Raw) - 1);
  end;
  Result := ConvertEncodingToUTF8(Raw, Enc, Encoded);
  if not Encoded then Result := Raw;
  Result := StripBom(Result);
end;
{ ---------------------------------------------------------------------------
  Highlighters
  --------------------------------------------------------------------------- }

type
  { Which implementation paints a row of the picker. Rows are grouped by kind
    so a language can gain extensions without touching the factory. }
  TZPreviewSyntaxKind = (
    skNone,
    skPas, skPython, skJScript, skHTML, skXML, skCss, skIni, skSQL, skShell,
    skBat, skDiff, skJava, skPerl, skPHP, skTeX, skVB,
    skC, skCSharp, skGo, skRust, skRuby, skLua, skSwift, skKotlin,
    skJson, skToml, skMarkdown, skYaml, skMake
  );

  { One row of the picker: its caption, the extensions that select it, file
    names that select it regardless of extension, and the scanner behind it. }
  TZPreviewLanguage = record
    Name: string;
    Exts: array of string;
    Names: array of string;
    Kind: TZPreviewSyntaxKind;
  end;

var
  GLanguages: array of TZPreviewLanguage;

procedure SetStringArray(var ADest: TStringArray; const AList: array of string);
var
  I: Integer;
begin
  SetLength(ADest, Length(AList));
  for I := Low(AList) to High(AList) do
    ADest[I - Low(AList)] := LowerCase(AList[I]);
end;

procedure AddLanguage(const AName: string; AKind: TZPreviewSyntaxKind;
  const AExts, ANames: array of string);
var
  N: Integer;
begin
  N := Length(GLanguages);
  SetLength(GLanguages, N + 1);
  GLanguages[N].Name := AName;
  GLanguages[N].Kind := AKind;
  SetStringArray(GLanguages[N].Exts, AExts);
  SetStringArray(GLanguages[N].Names, ANames);
end;

procedure SortLanguages;
var
  I, J: Integer;
  Item: TZPreviewLanguage;
begin
  { The picker is a list of names, so everything after the pinned "None" entry
    sorts alphabetically.  Insertion sort: the table is tiny and the records own
    dynamic arrays, so plain copies beat a comparison callback. }
  for I := 2 to High(GLanguages) do
  begin
    Item := GLanguages[I];
    J := I - 1;
    while (J >= 1) and (CompareText(GLanguages[J].Name, Item.Name) > 0) do
    begin
      GLanguages[J + 1] := GLanguages[J];
      Dec(J);
    end;
    GLanguages[J + 1] := Item;
  end;
end;

procedure InitLanguages;
begin
  if Length(GLanguages) > 0 then Exit;
  { Index 0 is "None": no highlighter at all, which is what a file whose type is
    unknown -- or one the user picked "None" for -- gets. }
  AddLanguage(rsPreviewLanguageNone, skNone, [], []);
  AddLanguage('Pascal', skPas,
    ['pas', 'pp', 'dpr', 'lpr', 'dpk', 'inc', 'p', 'dfm', 'lfm'], []);
  AddLanguage('C / C++', skC,
    ['c', 'h', 'cc', 'cpp', 'cxx', 'c++', 'hh', 'hpp', 'hxx', 'h++', 'ipp',
     'inl', 'tcc', 'm', 'mm'], []);
  AddLanguage('C#', skCSharp, ['cs', 'csx'], []);
  AddLanguage('Java', skJava, ['java'], []);
  AddLanguage('Kotlin', skKotlin, ['kt', 'kts'], []);
  AddLanguage('Swift', skSwift, ['swift'], []);
  AddLanguage('Rust', skRust, ['rs'], []);
  AddLanguage('Go', skGo, ['go'], []);
  AddLanguage('Python', skPython, ['py', 'pyw', 'pyi'], []);
  AddLanguage('JavaScript', skJScript, ['js', 'mjs', 'cjs', 'jsx'], []);
  AddLanguage('TypeScript', skJScript, ['ts', 'tsx', 'mts', 'cts'], []);
  AddLanguage('Ruby', skRuby, ['rb', 'rake', 'gemspec', 'ru'],
    ['Gemfile', 'Rakefile', 'Guardfile']);
  AddLanguage('PHP', skPHP, ['php', 'php3', 'php4', 'php5', 'php7', 'php8',
    'phtml', 'phps'], []);
  AddLanguage('Perl', skPerl, ['pl', 'pm'], []);
  AddLanguage('Lua', skLua, ['lua'], []);
  AddLanguage('Shell', skShell,
    ['sh', 'bash', 'zsh', 'ksh', 'csh', 'tcsh', 'fish', 'command', 'profile',
     'bashrc', 'zshrc', 'bash_profile', 'zprofile'],
    ['.bashrc', '.zshrc', '.profile', '.bash_profile', '.zprofile',
     '.zshenv', 'PKGBUILD', 'Dockerfile', 'Containerfile']);
  AddLanguage('Batch / PowerShell', skBat, ['bat', 'cmd', 'ps1', 'psm1', 'psd1'], []);
  AddLanguage('Visual Basic', skVB, ['vb', 'vbs', 'bas'], []);
  AddLanguage('HTML', skHTML,
    ['html', 'htm', 'xhtml', 'shtml', 'vue', 'hbs', 'handlebars', 'ejs'], []);
  AddLanguage('XML', skXML,
    ['xml', 'plist', 'svg', 'xib', 'storyboard', 'wsdl', 'xsd', 'dtd', 'xsl',
     'xslt', 'manifest', 'csproj', 'vcxproj', 'props', 'targets', 'resx',
     'gradle', 'xaml', 'rss', 'atom'], []);
  AddLanguage('CSS', skCss, ['css', 'scss', 'less', 'sass'], []);
  AddLanguage('JSON', skJson,
    ['json', 'jsonc', 'json5', 'geojson', 'webmanifest', 'har'], []);
  AddLanguage('YAML', skYaml, ['yaml', 'yml'], []);
  AddLanguage('TOML', skToml, ['toml'], ['Cargo.lock', 'Pipfile', 'poetry.lock']);
  AddLanguage('INI', skIni,
    ['ini', 'cfg', 'conf', 'config', 'properties', 'desktop', 'gitconfig',
     'editorconfig', 'npmrc', 'yarnrc', 'env', 'netrc'],
    ['.gitconfig', '.editorconfig', '.npmrc', '.yarnrc', '.env']);
  AddLanguage('SQL', skSQL, ['sql', 'ddl', 'dml', 'psql', 'mysql', 'pgsql'], []);
  AddLanguage('TeX', skTeX, ['tex', 'sty', 'cls', 'bib', 'ltx'], []);
  AddLanguage('Diff', skDiff, ['diff', 'patch'], []);
  { Prose types that are useful to preview but are not code. }
  AddLanguage('Markdown', skMarkdown,
    ['md', 'markdown', 'mdown', 'mkd', 'mdx', 'mdwn'], []);
  AddLanguage('Makefile', skMake, ['mk', 'mak', 'make'],
    ['Makefile', 'makefile', 'GNUmakefile']);
  SortLanguages;
end;

function TzPreviewLanguageCount: Integer;
begin
  InitLanguages;
  Result := Length(GLanguages);
end;

function TzPreviewLanguageName(AIndex: Integer): string;
begin
  InitLanguages;
  if (AIndex < 0) or (AIndex > High(GLanguages)) then Exit('');
  Result := GLanguages[AIndex].Name;
end;

function TzPreviewLanguageForFile(const AFileName: string): Integer;
var
  Base, E: string;
  I, K: Integer;
begin
  InitLanguages;
  Result := PreviewLanguageNone;
  Base := LowerCase(ExtractFileName(AFileName));
  { Names first: 'Makefile' has no extension, while 'Dockerfile.dev' should
    still find the Dockerfile row. }
  for I := 1 to High(GLanguages) do
    for K := 0 to High(GLanguages[I].Names) do
    begin
      if GLanguages[I].Names[K] = '' then Continue;
      if (Base = GLanguages[I].Names[K]) or
         (Copy(Base, 1, Length(GLanguages[I].Names[K]) + 1) =
          GLanguages[I].Names[K] + '.') then
        Exit(I);
    end;
  E := LowerCase(ExtractFileExt(AFileName));
  while (E <> '') and (E[1] = '.') do Delete(E, 1, 1);
  if E = '' then Exit;
  for I := 1 to High(GLanguages) do
    for K := 0 to High(GLanguages[I].Exts) do
      if E = GLanguages[I].Exts[K] then Exit(I);
end;

{ Keywords, given as a single space-separated string; "word=kind" entries set a
  non-keyword kind (see TZGeneralSyntax.Configure). }
const
  { A shared pool: C-like words that most of the scanner languages use. Words a
    language treats differently are overridden after the pool is added, and
    words a language does not have only cost a missed match, never a wrong one. }
  CommonWords =
    'if else for while do switch case default break continue return goto ' +
    'try catch finally throw throws new delete this super class interface ' +
    'struct enum extends implements import package namespace export public ' +
    'private protected internal static final abstract virtual override ' +
    'const volatile inline typeof instanceof sizeof switch async await yield ' +
    'function var let';
  CFamilyWords =
    'auto char short int long float double signed unsigned void restrict ' +
    'register extern typedef union sizeof static const volatile inline ' +
    'struct union enum do while switch case default break continue return ' +
    'goto if else for';
  CppExtraWords =
    'class public private protected virtual override final template typename ' +
    'namespace using noexcept constexpr consteval constinit decltype ' +
    'static_cast dynamic_cast const_cast reinterpret_cast new delete throw try ' +
    'catch friend mutable explicit operator alignas alignof static_assert ' +
    'nullptr true=6 false=6 this co_await co_return co_yield concept requires ' +
    'thread_local char8_t';
  CSharpWords =
    'abstract as base bool break byte case catch char checked class const ' +
    'continue decimal default delegate do double else enum event explicit ' +
    'extern false=6 finally fixed float for foreach goto if implicit in int ' +
    'interface internal is lock long namespace new null=6 object operator out ' +
    'override params private protected public readonly ref return sbyte sealed ' +
    'short sizeof stackalloc static string struct switch this throw true=6 ' +
    'try typeof uint ulong unchecked unsafe ushort using virtual void volatile ' +
    'while async await var dynamic record init get set namespace where ' +
    'partial yield';
  GoWords =
    'break case chan const continue default defer else fallthrough for func ' +
    'go goto if import interface map package range return select struct ' +
    'switch type var true=6 false=6 nil=6 iota=6 bool=7 byte=7 rune=7 ' +
    'string=7 error=7 int=7 int8=7 int16=7 int32=7 int64=7 uint=7 uint8=7 ' +
    'uint16=7 uint32=7 uint64=7 uintptr=7 float32=7 float64=7 complex64=7 ' +
    'complex128=7 append=7 cap=7 close=7 copy=7 delete=7 len=7 make=7 ' +
    'new=7 panic=7 print=7 println=7 recover=7';
  RustWords =
    'as async await break const continue crate dyn else enum extern false=6 ' +
    'fn for if impl in let loop match mod move mut pub ref return self=6 ' +
    'Self=6 static struct super trait true=6 type unsafe use where while ' +
    'bool=7 char=7 str=7 i8=7 i16=7 i32=7 i64=7 i128=7 isize=7 u8=7 u16=7 ' +
    'u32=7 u64=7 u128=7 usize=7 f32=7 f64=7 String=7 Vec=7 Option=7 Result=7 ' +
    'Some=7 None=6 Ok=7 Err=7 Box=7 self_fn=0';
  RubyWords =
    'alias and begin break case class def defined? do else elsif end ensure ' +
    'false=6 for if in module next nil=6 not or redo rescue retry return ' +
    'self=6 super then true=6 undef unless until when while yield require ' +
    'require_relative attr_accessor attr_reader attr_writer include extend ' +
    'lambda proc raise puts loop';
  LuaWords =
    'and break do else elseif end false=6 for function goto if in local nil=6 ' +
    'not or repeat return then true=6 until while';
  SwiftWords =
    'associatedtype class deinit enum extension fileprivate func import init ' +
    'inout internal let open operator private protocol public rethrows static ' +
    'struct subscript typealias var break case continue default defer do else ' +
    'fallthrough for guard if in repeat return switch where while as=1 ' +
    'Any=7 catch false=6 is=1 nil=6 self=6 super=6 throw throws true=6 ' +
    'try async await some any';
  KotlinWords =
    'as break class continue do else false=6 for fun if in interface is null=6 ' +
    'object package return super this throw true=6 try typealias val var when ' +
    'while by catch constructor finally import init where data enum companion ' +
    'override open abstract private public internal protected sealed lateinit ' +
    'suspend inline operator infix vararg out';
  PhpWords =
    'abstract and array as break callable case catch class clone const ' +
    'continue declare default do echo else elseif empty enddeclare endfor ' +
    'endforeach endif endswitch endwhile eval exit extends final finally fn ' +
    'for foreach function global goto if implements include include_once ' +
    'instanceof insteadof interface isset list match namespace new or print ' +
    'private protected public readonly require require_once return static ' +
    'switch throw trait try unset use var while xor yield true=6 false=6 ' +
    'null=6 int=7 float=7 string=7 bool=7 array=7 object=7 void=7 mixed=7';
  JsonWords = 'true=6 false=6 null=6';
  TomlWords = 'true=6 false=6 inf=6 nan=6';

procedure AddWords(AScanner: TZGeneralSyntax; const AWordPools: array of string);
var
  Parts: TStringList;
  I, J: Integer;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    for I := Low(AWordPools) to High(AWordPools) do
    begin
      Parts.DelimitedText := AWordPools[I];
      for J := 0 to Parts.Count - 1 do
        if Parts[J] <> '' then
          AScanner.AddWord(Parts[J]);
    end;
  finally
    Parts.Free;
  end;
end;

function MakeOptions(ALineComment: string; ABlockComment: Boolean;
  ASingle, ADouble, AThird, ABacktick: Boolean; AEscape: Char;
  ARawPrefix: Boolean = False; APercentLiteral: Boolean = False;
  AHeredoc: Boolean = False; ASecondComment: string = '';
  ASecondCommentColFloor: Integer = 0;
  APreprocessor: Boolean = False): TZScanOptions;
var
  N: Integer;
begin
  Result := Default(TZScanOptions);
  N := Ord(ALineComment <> '') + Ord(ASecondComment <> '');
  SetLength(Result.LineComments, N);
  SetLength(Result.LineCommentColFloor, N);
  N := 0;
  if ALineComment <> '' then
  begin
    Result.LineComments[N] := ALineComment;
    Result.LineCommentColFloor[N] := 0;
    Inc(N);
  end;
  if ASecondComment <> '' then
  begin
    Result.LineComments[N] := ASecondComment;
    Result.LineCommentColFloor[N] := ASecondCommentColFloor;
  end;
  Result.BlockComment := ABlockComment;
  Result.Preprocessor := APreprocessor;
  Result.SingleQuote := ASingle;
  Result.DoubleQuote := ADouble;
  Result.ThirdQuote := AThird;
  Result.Backtick := ABacktick;
  Result.Escape := AEscape;
  Result.RawPrefix := ARawPrefix;
  Result.PercentLiteral := APercentLiteral;
  Result.Heredoc := AHeredoc;
end;

{ Build a TZGeneralSyntax for one language: lexical options, case sensitivity
  and the keyword pools, in that order (Configure only takes the keyword list
  as it is, AddWord feeds it). }
procedure MakeGeneral(var AResult: TSynCustomHighlighter; AOwner: TComponent;
  const AName: string; const AOptions: TZScanOptions; ACaseSensitive: Boolean;
  const AWordPools: array of string; ABareEqualKeys: Boolean = False);
begin
  AResult := TZGeneralSyntax.Create(AOwner, AName);
  TZGeneralSyntax(AResult).Configure(AOptions, ACaseSensitive);
  TZGeneralSyntax(AResult).BareEqualKeys := ABareEqualKeys;
  AddWords(TZGeneralSyntax(AResult), AWordPools);
end;

function TzPreviewHighlighter(AOwner: TComponent; AIndex: Integer): TSynCustomHighlighter;
var
  Lang: TZPreviewLanguage;
  MD: TZMarkdownSyntax;
begin
  Result := nil;
  InitLanguages;
  if (AIndex <= 0) or (AIndex > High(GLanguages)) then Exit;
  Lang := GLanguages[AIndex];
  case Lang.Kind of
    skPas: Result := TSynPasSyn.Create(AOwner);
    skPython: Result := TSynPythonSyn.Create(AOwner);
    skJScript: Result := TSynJScriptSyn.Create(AOwner);
    skHTML: Result := TSynHTMLSyn.Create(AOwner);
    skXML: Result := TSynXMLSyn.Create(AOwner);
    skCss: Result := TSynCssSyn.Create(AOwner);
    skIni: Result := TSynIniSyn.Create(AOwner);
    skSQL: Result := TSynSQLSyn.Create(AOwner);
    skShell: Result := TSynUNIXShellScriptSyn.Create(AOwner);
    skBat: Result := TSynBatSyn.Create(AOwner);
    skDiff: Result := TSynDiffSyn.Create(AOwner);
    skJava: Result := TSynJavaSyn.Create(AOwner);
    skPerl: Result := TSynPerlSyn.Create(AOwner);
    skTeX: Result := TSynTeXSyn.Create(AOwner);
    skVB: Result := TSynVBSyn.Create(AOwner);
    skC:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, True, True, False, False, '\',
          False, False, False, '', 0, True), True,
        [CommonWords, CFamilyWords, CppExtraWords]);
    skCSharp:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, True, True, False, False, '\',
          False, False, False, '', 0, True), True,
        [CommonWords, CSharpWords]);
    skGo:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, False, True, False, True, '\'), True,
        [GoWords]);
    skRust:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, False, True, False, False, '\', True), True,
        [RustWords]);
    skRuby:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('#', False, False, True, False, False, '\', False, True, True), True,
        [RubyWords]);
    skLua:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('--', False, False, True, False, False, '\'), True,
        [LuaWords]);
    skSwift:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, False, True, False, False, '\'), True,
        [CommonWords, SwiftWords]);
    skKotlin:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, False, True, False, False, '\'), True,
        [CommonWords, KotlinWords]);
    skPHP:
      { PHP also accepts '#' comments, but only at the start of a line. }
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('//', True, True, True, False, False, '\', False, False,
          False, '#', 2), False, [PhpWords]);
    skJson:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('', False, False, True, False, False, '\'), True,
        [JsonWords]);
    skToml:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('#', False, False, True, False, False, '\'), True,
        [TomlWords], True);
    skMake:
      MakeGeneral(Result, AOwner, Lang.Name,
        MakeOptions('#', False, False, True, False, False, '\'), True,
        ['ifeq', 'ifneq', 'ifdef', 'ifndef', 'else', 'endif', 'include',
         'define', 'endef', 'export', 'unexport', 'override', 'vpath',
         'sinclude', 'make']);
    skMarkdown:
      begin
        MD := TZMarkdownSyntax.Create(AOwner);
        MD.YAMLFrontMatter := True;
        MD.Tables := True;
        MD.Strikethrough := True;
        Result := MD;
      end;
    skYaml: Result := TZYamlSyntax.Create(AOwner);
  end;
end;

function TzPreviewHighlighterFor(AOwner: TComponent;
  const AFileName: string): TSynCustomHighlighter;
begin
  Result := TzPreviewHighlighter(AOwner, TzPreviewLanguageForFile(AFileName));
end;

type
  TZTokenRole = (trText, trKeyword, trString, trComment, trNumber, trSymbol,
    trConstant, trType, trProp, trLink, trHeading);

{ Map an attribute to its role. Stock highlighters use their own names from
  SynEditStrConst (comment, string, keyword...); the scanners in
  tzip.preview.syntax use these captions, which are chosen to read as the same
  vocabulary. }
function RoleOf(const AName: string): TZTokenRole;
var
  N: string;
begin
  N := LowerCase(AName);
  if (Pos('strike', N) > 0) or (Pos('emphasis', N) > 0) then Exit(trKeyword);
  if (Pos('code', N) > 0) then Exit(trString);
  if (Pos('escape', N) > 0) then Exit(trSymbol);
  if (Pos('comment', N) > 0) or (Pos('doc', N) > 0) then Exit(trComment);
  if (Pos('string', N) > 0) or (Pos('char', N) > 0) or (Pos('text', N) > 0) or
     (Pos('heredoc', N) > 0) then Exit(trString);
  if (Pos('number', N) > 0) or (Pos('float', N) > 0) or (Pos('integer', N) > 0) or
     (Pos('hex', N) > 0) or (Pos('octal', N) > 0) or (Pos('binary', N) > 0) then
    Exit(trNumber);
  if (Pos('constant', N) > 0) then Exit(trConstant);
  if (Pos('heading', N) > 0) then Exit(trHeading);
  if (Pos('reference', N) > 0) or (Pos('link', N) > 0) then Exit(trLink);
  if (Pos('property', N) > 0) or (N = 'prop') or (Pos('variable', N) > 0) or
     (Pos('entity', N) > 0) then Exit(trProp);
  if (Pos('builtin', N) > 0) or (N = 'type') or (Pos('object', N) > 0) or
     (Pos('class', N) > 0) then Exit(trType);
  if (Pos('keyword', N) > 0) or (Pos('reserved', N) > 0) or (Pos('directive', N) > 0) or
     (Pos('preprocessor', N) > 0) or (Pos('compiler', N) > 0) or
     (Pos('assembler', N) > 0) or (Pos('command', N) > 0) or
     (Pos('system', N) > 0) or (Pos('modifier', N) > 0) then
    Exit(trKeyword);
  if (Pos('symbol', N) > 0) or (Pos('operator', N) > 0) or
     (Pos('delimiter', N) > 0) or (Pos('bracket', N) > 0) or
     (Pos('attribute', N) > 0) or (Pos('tag', N) > 0) then
    Exit(trSymbol);
  Result := trText;
end;

procedure TzPreviewTintHighlighter(AHl: TSynCustomHighlighter;
  const APalette: TZPreviewPalette);
var
  I: Integer;
  A: TSynHighlighterAttributes;
  Keyword, Str, Comment, Number, Symbol, Constant, Typ, Prop, Link, Heading: TColor;
begin
  if AHl = nil then Exit;
  AHl.BeginUpdate;
  try
  if APalette.Dark then
  begin
    Keyword := RGBToColor(198, 120, 221);
    Str := RGBToColor(152, 195, 121);
    Comment := RGBToColor(127, 132, 142);
    Number := RGBToColor(209, 154, 102);
    Symbol := RGBToColor(86, 182, 194);
    Constant := RGBToColor(86, 182, 194);
    Typ := RGBToColor(229, 192, 123);
    Prop := RGBToColor(224, 108, 117);
    Link := RGBToColor(97, 175, 239);
    Heading := RGBToColor(229, 192, 123);
  end
  else
  begin
    Keyword := RGBToColor(155, 35, 147);
    Str := RGBToColor(196, 26, 22);
    Comment := RGBToColor(93, 108, 121);
    Number := RGBToColor(28, 0, 207);
    Symbol := RGBToColor(63, 110, 116);
    Constant := RGBToColor(28, 0, 207);
    Typ := RGBToColor(150, 80, 0);
    Prop := RGBToColor(38, 86, 160);
    Link := RGBToColor(0, 92, 197);
    Heading := RGBToColor(38, 86, 160);
  end;
  for I := 0 to AHl.AttrCount - 1 do
  begin
    A := AHl.Attribute[I];
    if A = nil then Continue;
    { Transparent so the editor's own background (the themed pane colour) shows
      through everywhere; the stock definitions hard-code white. }
    A.Background := clNone;
    case RoleOf(A.Name) of
      trKeyword:
        begin
          A.Foreground := Keyword;
          A.Style := A.Style + [fsBold];
        end;
      trString: A.Foreground := Str;
      trComment:
        begin
          A.Foreground := Comment;
          A.Style := A.Style + [fsItalic];
        end;
      trNumber: A.Foreground := Number;
      trSymbol: A.Foreground := Symbol;
      trConstant: A.Foreground := Constant;
      trType: A.Foreground := Typ;
      trProp: A.Foreground := Prop;
      trLink:
        begin
          A.Foreground := Link;
          A.Style := A.Style + [fsUnderline];
        end;
      trHeading:
        begin
          A.Foreground := Heading;
          A.Style := A.Style + [fsBold];
        end;
    else
      A.Foreground := APalette.Text;
    end;
  end;
  finally
    AHl.EndUpdate;
  end;
end;

initialization
  InitEncodings;

end.
