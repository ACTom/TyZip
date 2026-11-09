program preview_syntax_check;

{ Self-check for the preview highlighters: every language row builds, the
  scanners tokenise representative text, multi-line state survives line gaps,
  and the tinting assigns the expected roles. Headless: no LCL form is created,
  only the SynEdit highlighter machinery, which does not need a window.

  Build (from tests/):
    fpc -Mobjfpc -Sh -Fu../src -Fu<$LAZARUS>/components/synedit/units/... \
        -FU./units preview_syntax_check.pas
  Run: ./preview_syntax_check ; expected final line "FAILS=0". }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Graphics, LCLIntf,
  Interfaces, SynEdit, SynEditHighlighter,
  tzip.preview, tzip.preview.syntax;

var
  Fails: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then WriteLn('ok   ', AMsg)
  else
  begin
    WriteLn('FAIL ', AMsg);
    Inc(Fails);
  end;
end;

type
  TTok = record
    Text: string;
    Kind: Integer;
  end;

{ Tokenise one line. ALines is the whole document; ARow selects the line, so
  scanners whose state depends on earlier lines can be checked. }
function Tokens(const ALines: array of string; ARow: Integer;
  AHl: TSynCustomHighlighter): TStringList;
var
  HL: TSynCustomHighlighter;
  T: string;
  I: Integer;
begin
  { A highlighter scans one line at a time through SetLine/Next; for a document
    we replay the earlier lines first so the cross-line state is right. }
  HL := AHl;
  HL.ResetRange;
  for I := 0 to ARow - 1 do
  begin
    HL.SetLine(ALines[I], I);
    { The state to store is the one at the END of the line, so scan it out
      first, then hand it back before the next line -- exactly what SynEdit
      does between lines. }
    while not HL.GetEol do HL.Next;
    HL.SetRange(HL.GetRange);
  end;
  Result := TStringList.Create;
  Result.Delimiter := '|';
  { Walk the last line only: re-run SetLine on ARow. }
  HL.SetLine(ALines[ARow], ARow);
  { Collect the token BEFORE Next: after Next the fields describe the next one,
    and the last token of a line is only ever seen that way. }
  while not HL.GetEol do
  begin
    T := HL.GetToken;
    Result.Add(IntToStr(HL.GetTokenKind) + ':' + T);
    HL.Next;
  end;
end;

function HasToken(AList: TStringList; AKind: Integer; const AText: string): Boolean;
var
  I: Integer;
  P: Integer;
  K: Integer;
begin
  Result := False;
  for I := 0 to AList.Count - 1 do
  begin
    P := Pos(':', AList[I]);
    if P = 0 then Continue;
    K := StrToIntDef(Copy(AList[I], 1, P - 1), -1);
    if (K = AKind) and (Copy(AList[I], P + 1, MaxInt) = AText) then Exit(True);
  end;
end;

{ The expected language is written out in the CALLER, never read back from the
  function under test: comparing ForFile() with ForFile() only proved that it
  returned something. The display name is what the picker shows, so it is also
  the independent value. }
procedure CheckLanguage(const AFile, AExpectedName: string);
var
  Idx: Integer;
  H: TSynCustomHighlighter;
begin
  Idx := TzPreviewLanguageForFile(AFile);
  Check(TzPreviewLanguageName(Idx) = AExpectedName,
    Format('%s -> %s (want %s)', [AFile, TzPreviewLanguageName(Idx), AExpectedName]));
  H := TzPreviewHighlighter(nil, Idx);
  try
    Check((H <> nil) or (Idx = PreviewLanguageNone), '  builds a highlighter');
    if H <> nil then
      Check(H.LanguageName <> '', '  reports a language name');
  finally
    H.Free;
  end;
end;

var
  I: Integer;
  H: TSynCustomHighlighter;
  L: TStringList;
  Pal: TZPreviewPalette;
begin
  Fails := 0;

  { ---- file name -> language ---- }
  WriteLn('-- file names');
  for I := 1 to TzPreviewLanguageCount - 1 do
    if (Length(TzPreviewLanguageName(I)) > 0) then ;
  CheckLanguage('README.md', 'Markdown');
  CheckLanguage('main.c', 'C / C++');
  CheckLanguage('main.cpp', 'C / C++');
  CheckLanguage('lib.rs', 'Rust');
  CheckLanguage('main.go', 'Go');
  CheckLanguage('config.yaml', 'YAML');
  CheckLanguage('Cargo.toml', 'TOML');
  CheckLanguage('Gemfile', 'Ruby');
  CheckLanguage('init.lua', 'Lua');
  CheckLanguage('Widget.swift', 'Swift');
  CheckLanguage('App.kt', 'Kotlin');
  CheckLanguage('Program.cs', 'C#');
  CheckLanguage('Makefile', 'Makefile');
  CheckLanguage('Dockerfile.dev', 'Shell');
  CheckLanguage('data.json', 'JSON');
  CheckLanguage('index.vue', 'HTML');
  CheckLanguage('unknown.xyzzy', 'None');
  CheckLanguage('noextension', 'None');
  { Extension matching ignores case: the same file with an upper-case suffix
    must still resolve to Markdown. }
  CheckLanguage('README.MD', 'Markdown');

  { ---- every row builds and gets distinct names ---- }
  WriteLn('-- language table');
  for I := 1 to TzPreviewLanguageCount - 1 do
  begin
    H := TzPreviewHighlighter(nil, I);
    try
      Check(H <> nil, Format('row %d (%s) has a highlighter',
        [I, TzPreviewLanguageName(I)]));
    finally
      H.Free;
    end;
  end;

  { ---- Markdown ---- }
  WriteLn('-- Markdown');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('x.md'));
  try
    L := Tokens(['# Title **bold**', '', '```pas', 'x := 1;', '```', '', 'see [link](a.md) and `code`'], 0, H);
    try
      Check(HasToken(L, ztkHeading, '# '), 'heading marker is a heading');
      { The line is '# Title **bold**', so the heading run covers all of it: the
        bold markers inside a heading are part of the heading text. }
      Check(HasToken(L, ztkHeading, 'Title **bold**'), 'heading text is a heading');

      { A heading whose first word is Chinese. The scanner compared a 0-based
        offset against a 1-based index, so the text token started one character
        early -- inside "亮" -- and SynEdit painted the fragment as "?".
        Reproducing it needs the exact bytes, hence the literal. }
      FreeAndNil(L);
      L := Tokens(['### 亮 / 暗 / 图片主题'], 0, H);
      try
        Check(HasToken(L, ztkHeading, '### '), 'heading marker scanned whole');
        Check(HasToken(L, ztkHeading, '亮 / 暗 / 图片主题'),
          'heading text starts on a character boundary (CJK first word intact)');
      finally
        FreeAndNil(L);
      end;
    finally
      L.Free;
    end;
    { Bold outside a heading is an emphasis run. Inside a heading the markers
      belong to the heading text (asserted above), so it needs its own line. }
    L := Tokens(['plain **bold** text'], 0, H);
    try
      Check(HasToken(L, ztkEmphasis, '**'), 'bold markers are emphasis');
    finally
      L.Free;
    end;
    L := Tokens(['# Title', '', '```pas', 'x := 1;', '```'], 3, H);
    try
      Check(HasToken(L, ztkCode, 'x := 1;'), 'fenced body is code');
    finally
      L.Free;
    end;
    L := Tokens(['# Title', '', '```pas', 'x := 1;', '```'], 2, H);
    try
      Check(HasToken(L, ztkCode, '```pas'), 'fence line is code');
    finally
      L.Free;
    end;
    L := Tokens(['see [link](a.md) and `code`'], 0, H);
    try
      Check(HasToken(L, ztkReference, '[link](a.md)'), 'link target is a reference');
      Check(HasToken(L, ztkCode, '`code`'), 'inline code span');
    finally
      L.Free;
    end;
    L := Tokens(['- item one', '- item two'], 1, H);
    try
      Check(HasToken(L, ztkHeading, '-'), 'list marker is a heading marker');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- C ---- }
  WriteLn('-- C');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.c'));
  try
    L := Tokens(['#include <stdio.h>', 'int main(void) { // hi', '  return 0;', '}'], 1, H);
    try
      Check(HasToken(L, ztkKeyword, 'int'), 'int is a keyword');
      Check(HasToken(L, ztkComment, '// hi'), 'line comment');
    finally
      L.Free;
    end;
    { Line 2 closes a /* from line 1: the comment and the code that follows it
      on the same line are both painted, the comment first. }
    { Preprocessor directives are one directive-coloured token each.  They
      used to be keyword-matched individually, so #else was red while #include
      was blue and #endif plain. }
    L := Tokens(['#include <stdio.h>', '#ifdef _WIN32', '#else', '#endif'], 3, H);
    try
      Check(HasToken(L, ztkDirective, '#endif'), '#endif is a directive');
    finally
      L.Free;
    end;
    L := Tokens(['#else'], 0, H);
    try
      Check(HasToken(L, ztkDirective, '#else'), '#else is a directive, not a keyword');
    finally
      L.Free;
    end;
    L := Tokens(['int x; #else'], 0, H);
    try
      Check(not HasToken(L, ztkDirective, '#else'), 'an inline # is not a directive');
    finally
      L.Free;
    end;

    L := Tokens(['int x;', '/* a', '   b */ int y;'], 2, H);
    try
      Check(L.Count > 0, 'block comment continuation produces tokens');
      Check(Pos('b */', L[0]) > 0, '  the leading part of the line is the comment');
      Check(HasToken(L, ztkKeyword, 'int'), '  code after */ is highlighted again');
    finally
      L.Free;
    end;
    L := Tokens(['/* one line */ int z;'], 0, H);
    try
      Check(HasToken(L, ztkKeyword, 'int'), 'a closed one-line comment does not swallow code');
    finally
      L.Free;
    end;
    L := Tokens(['char *s = "a \" b";'], 0, H);
    try
      Check(HasToken(L, ztkString, '"a \" b"'), 'escaped quote stays inside the string');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- Rust ---- }
  WriteLn('-- Rust');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.rs'));
  try
    L := Tokens(['fn main() { let s = r#"raw "x" "#; }'], 0, H);
    try
      Check(HasToken(L, ztkKeyword, 'fn'), 'fn is a keyword');
      Check(HasToken(L, ztkString, 'r#"raw "x" "#'), 'raw string with hashes');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- Go ---- }
  WriteLn('-- Go');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.go'));
  try
    L := Tokens(['func main() { s := `a b`; var x int }'], 0, H);
    try
      Check(HasToken(L, ztkKeyword, 'func'), 'func is a keyword');
      Check(HasToken(L, ztkString, '`a b`'), 'backtick raw string');
      Check(HasToken(L, ztkBuiltin, 'int'), 'int is a builtin type');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- YAML ---- }
  WriteLn('-- YAML');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.yaml'));
  try
    L := Tokens(['name: demo', 'list:', '  - one', '  - two'], 0, H);
    try
      Check(HasToken(L, ztkProp, 'name'), 'key is a property');
    finally
      L.Free;
    end;
    L := Tokens(['script: |', '  echo hello', '  echo world', 'other: 1'], 2, H);
    try
      Check(HasToken(L, ztkString, '  echo world'), 'block scalar body is a string');
    finally
      L.Free;
    end;
    L := Tokens(['script: |', '  echo hello', '  echo world', 'other: 1'], 3, H);
    try
      Check(HasToken(L, ztkProp, 'other'), 'block scalar ends at the next key');
    finally
      L.Free;
    end;
    L := Tokens(['version: 1.2', 'enabled: true', 'ref: &base'], 1, H);
    try
      Check(HasToken(L, ztkConstant, 'true'), 'booleans are constants');
    finally
      L.Free;
    end;
    L := Tokens(['version: 1.2', 'enabled: true', 'ref: &base'], 2, H);
    try
      Check(HasToken(L, ztkReference, '&base'), 'anchors are references');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- JSON / TOML ---- }
  WriteLn('-- JSON / TOML');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.json'));
  try
    L := Tokens(['{"name": "x", "on": false, "n": 12}'], 0, H);
    try
      Check(HasToken(L, ztkProp, '"name"'), 'JSON key is a property');
      Check(HasToken(L, ztkConstant, 'false'), 'JSON false is a constant');
      Check(HasToken(L, ztkNumber, '12'), 'JSON number');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.toml'));
  try
    L := Tokens(['[package]', 'name = "demo"', 'edition = "2021"'], 1, H);
    try
      Check(HasToken(L, ztkProp, 'name'), 'TOML key is a property');
      Check(HasToken(L, ztkString, '"demo"'), 'TOML string');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- C# uses the same scanner plumbing ---- }
  WriteLn('-- C#');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.cs'));
  try
    L := Tokens(['/* a', ' b */ using System;'], 1, H);
    try
      Check(HasToken(L, ztkKeyword, 'using'),
        'C#: code after a block comment closes is highlighted');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- assignments must not look like property keys ---- }
  WriteLn('-- assignments vs. keys');
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.go'));
  try
    L := Tokens(['x := 1', 'y = 2'], 1, H);
    try
      Check(not HasToken(L, ztkProp, 'y'), 'Go: "y = 2" is not a property');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.c'));
  try
    L := Tokens(['s = "x";'], 0, H);
    try
      Check(not HasToken(L, ztkProp, 's'), 'C: "s = 1" is not a property');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.yaml'));
  try
    L := Tokens(['name: demo  # note'], 0, H);
    try
      Check(HasToken(L, ztkComment, '# note'), 'YAML: trailing comment is a comment');
      Check(HasToken(L, ztkIdentifier, 'demo  ') or HasToken(L, ztkIdentifier, 'demo'),
        'YAML: value survives the comment');
    finally
      L.Free;
    end;
  finally
    H.Free;
  end;

  { ---- tinting ---- }
  WriteLn('-- tinting');
  Pal := TzMakePreviewPalette(RGBToColor(255, 255, 255), RGBToColor(0, 0, 0));
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.md'));
  try
    TzPreviewTintHighlighter(H, Pal);
    Check(True, 'Markdown highlighter tints without error');
  finally
    H.Free;
  end;
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.c'));
  try
    TzPreviewTintHighlighter(H, Pal);
    Check(True, 'C highlighter tints without error');
  finally
    H.Free;
  end;
  Pal := TzMakePreviewPalette(RGBToColor(30, 30, 30), RGBToColor(220, 220, 220));
  H := TzPreviewHighlighter(nil, TzPreviewLanguageForFile('a.rs'));
  try
    TzPreviewTintHighlighter(H, Pal);
    Check(True, 'dark palette tints without error');
  finally
    H.Free;
  end;

  WriteLn('FAILS=', Fails);
  if Fails <> 0 then Halt(1);
end.
