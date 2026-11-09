program editor_integration;

{ Loads a real TSynEdit (headless -- no window is shown) with each new
  highlighter and asks SynEdit to scan the text, which is the path the preview
  pane takes: StartAtLineIndex/SetLine/Next/GetTokenAttribute over several
  lines with the per-line range cache. Catches crashes and nil attributes that
  the token unit test cannot. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Interfaces, Graphics,
  SynEdit, SynEditHighlighter,
  tzip.preview, tzip.preview.syntax;

var
  Fails: Integer;
  Edit: TSynEdit;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then WriteLn('ok   ', AMsg)
  else
  begin
    WriteLn('FAIL ', AMsg);
    Inc(Fails);
  end;
end;

procedure TryLang(const AFile: string; const ALines: array of string);
var
  H: TSynCustomHighlighter;
  I, K: Integer;
  Pal: TZPreviewPalette;
  AttrOk: Boolean;
begin
  H := TzPreviewHighlighter(Edit, TzPreviewLanguageForFile(AFile));
  try
    Edit.Highlighter := H;
    Edit.Lines.Clear;
    for I := Low(ALines) to High(ALines) do
      Edit.Lines.Add(ALines[I]);
    Pal := TzMakePreviewPalette(clWhite, clBlack);
    TzPreviewTintHighlighter(H, Pal);
    { Walk the text the way the editor paints it. }
    AttrOk := True;
    for I := 0 to Edit.Lines.Count - 1 do
    begin
      H.StartAtLineIndex(I);
      while not H.GetEol do
      begin
        if H.GetTokenAttribute = nil then AttrOk := False;
        K := H.GetTokenKind;
        if (K < 0) or (K >= ZSyntaxTokenKindCount) then AttrOk := False;
        H.Next;
      end;
    end;
    Check(AttrOk, AFile + ': every token has an attribute in range');
    Check(Edit.Lines.Count = Length(ALines), AFile + ': all lines kept');
  finally
    Edit.Highlighter := nil;
    H.Free;
  end;
end;

var
  Pal: TZPreviewPalette;
begin
  Fails := 0;
  Edit := TSynEdit.Create(nil);
  try
    TzPreviewStyleEditor(Edit, TzMakePreviewPalette(clWhite, clBlack));
    TryLang('README.md', ['---', 'title: x', '---', '', '# Heading', '',
      'Some **bold** and *italic* with [a link](a.md) and `code`.', '',
      '- list', '- [x] done', '', '```pascal', 'procedure Foo; begin end;', '```',
      '', '| a | b |', '|---|---|', '| 1 | 2 |', '', '> quote', '', '---']);
    TryLang('main.c', ['#include <stdio.h>', '', '/* block', '   comment */',
      'int main(void) {', '  char *s = "hi \" there";', '  // line comment',
      '  return 0;', '}']);
    TryLang('lib.rs', ['fn main() {', '    let s = r#"raw "x" "#;', '    let c = ''a'';',
      '    // comment', '    /* multi', '       line */', '}']);
    TryLang('app.go', ['package main', '', 'func main() {', '    s := `raw`',
      '    var n int', '    // c', '}']);
    TryLang('config.yaml', ['# top', 'name: demo', 'script: |', '  echo one',
      '  echo two', 'list:', '  - a', '  - b', 'flags: [a, b]',
      'ref: &anchor', 'use: *anchor', 'enabled: true', 'port: 8080']);
    TryLang('Cargo.toml', ['[package]', 'name = "demo"', 'edition = "2021"',
      'keywords = ["a", "b"]', '# comment']);
    TryLang('data.json', ['{', '  "name": "demo",', '  "on": true,',
      '  "list": [1, 2, 3]', '}']);
    TryLang('x.rb', ['class Foo', '  def bar', '    puts %w[a b]', '  end', 'end']);
    TryLang('x.swift', ['func f() -> Int {', '    let x = 1', '    return x', '}']);
    TryLang('x.kt', ['fun main() {', '    val x = 1', '    println("$x")', '}']);
    TryLang('x.cs', ['public class A {', '    private int x;', '    void F() {}', '}']);
    TryLang('x.lua', ['local x = 1', '-- c', 'if x then print(x) end']);
    TryLang('Makefile', ['all: build', '\tcc -o x x.c', 'build:', '\techo hi']);

    { Switching languages on the same editor must not leak or crash. }
    Pal := TzMakePreviewPalette(clBlack, clWhite);
    TzPreviewStyleEditor(Edit, Pal);
    Check(True, 'dark palette restyles the editor');
  finally
    Edit.Free;
  end;
  WriteLn('FAILS=', Fails);
  if Fails <> 0 then Halt(1);
end.
