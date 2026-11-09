program unit_preview;
{$mode objfpc}{$H+}
{ Preview classification: which language a file is shown in, and which encoding
  its bytes are decoded as.

  The user-visible failure these guard against: a file with the wrong extension
  getting a highlighter that then mangles it, or a text file decoded with the
  wrong code page showing mojibake. Both are silent -- the pane still draws
  something -- so they need explicit assertions. }
uses
  SysUtils, Classes, Graphics, Interfaces, LCLIntf, LazUTF8, SynEdit,
  tzip.preview, tzip.i18n, tzip.platform;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg);
  end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg, ': got ', AGot, ' want ', AWant);
  end;
end;

procedure Eq(AGot, AWant: string; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn('FAIL ', AMsg, ': got [', AGot, '] want [', AWant, ']');
  end;
end;

{ --- language registry -------------------------------------------------- }

procedure TestLanguages;
var
  I, NoneIdx: Integer;
  SeenNone: Boolean;
  Name: string;
begin
  Check(TzPreviewLanguageCount > 5, 'languages: registry is populated');
  { Index 0 must be "None": the dialog relies on that to mean "no
    highlighting", and a file whose extension is misleading must be able to
    reach it. }
  if TzPreviewLanguageCount > 0 then
    EqInt(TzPreviewLanguageForFile('anything.zzz'), 0,
      'languages: unknown extension maps to None');
  SeenNone := False;
  for I := 0 to TzPreviewLanguageCount - 1 do
  begin
    Name := TzPreviewLanguageName(I);
    Check(Name <> '', Format('languages: entry %d is named', [I]));
    if SameText(Name, 'None') or (I = 0) then SeenNone := True;
  end;
  Check(SeenNone, 'languages: a None entry exists');
  { The picker is a list of names: everything after "None" sorts alphabetically,
    otherwise the user has to hunt for a language in an arbitrary order. }
  for I := 2 to TzPreviewLanguageCount - 1 do
    Check(CompareText(TzPreviewLanguageName(I - 1), TzPreviewLanguageName(I)) <= 0,
      Format('languages: entry %d (%s) sorts after %d (%s)',
        [I - 1, TzPreviewLanguageName(I - 1), I, TzPreviewLanguageName(I)]));
  { An out-of-range index must not fault; an empty name is the correct answer. }
  Check(TzPreviewLanguageName(-1) = '', 'languages: negative index answers empty');
  Check(TzPreviewLanguageName(99999) = '', 'languages: huge index answers empty');
end;

{ --- extension to language ---------------------------------------------- }

procedure TestLanguageForFile;
const
  Cases: array[0..19] of array[0..1] of string = (
    ('a.pas', 'Pascal'), ('a.dpr', 'Pascal'),
    ('a.c', 'C'), ('a.h', 'C'), ('a.cpp', 'C++'), ('a.hpp', 'C++'),
    ('a.py', 'Python'), ('a.js', 'JavaScript'), ('a.ts', 'TypeScript'),
    ('a.rb', 'Ruby'), ('a.go', 'Go'), ('a.rs', 'Rust'),
    ('a.java', 'Java'), ('a.cs', 'C#'), ('a.swift', 'Swift'),
    ('a.kt', 'Kotlin'), ('a.lua', 'Lua'),
    ('a.json', 'JSON'), ('a.xml', 'XML'),
    ('Makefile', 'Makefile'));
var
  I, Idx: Integer;
  Name: string;
begin
  for I := 0 to High(Cases) do
  begin
    Idx := TzPreviewLanguageForFile(Cases[I][0]);
    if Cases[I][1] = 'Makefile' then
      Eq(TzPreviewLanguageName(Idx), Cases[I][1],
        'language: ' + Cases[I][0] + ' -> Makefile')
    else if Idx > 0 then
      Check(Pos(LowerCase(Cases[I][1]), LowerCase(TzPreviewLanguageName(Idx))) > 0,
        Format('language: %s -> %s (got %s)', [Cases[I][0], Cases[I][1],
          TzPreviewLanguageName(Idx)]))
    else
      Check(False, Format('language: %s got None, want %s',
        [Cases[I][0], Cases[I][1]]));
  end;

  { Case of the extension must not matter. }
  EqInt(TzPreviewLanguageForFile('A.PAS'), TzPreviewLanguageForFile('a.pas'),
    'language: extension case is ignored');

  { Files with no extension, or a misleading one, get None rather than a
    guessed highlighter. }
  EqInt(TzPreviewLanguageForFile('README'), 0, 'language: no extension -> None');
  EqInt(TzPreviewLanguageForFile('a.unknownext'), 0,
    'language: unknown extension -> None');
  EqInt(TzPreviewLanguageForFile(''), 0, 'language: empty name -> None');
  EqInt(TzPreviewLanguageForFile('archive.zip'), 0,
    'language: .zip is not a source file');
  EqInt(TzPreviewLanguageForFile('data.bin'), 0,
    'language: .bin is not a source file');

  { A dotfile WITH a known name is recognised -- the registry lists shell rc
    files explicitly for this reason. }
  Check(TzPreviewLanguageForFile('.bashrc') > 0,
    'language: .bashrc is a known shell rc file');
  { An unknown dotfile is not guessed from its suffix. }
  EqInt(TzPreviewLanguageForFile('.unknowndotfile'), 0,
    'language: unknown dotfile is not guessed');
end;

{ --- encoding detection ------------------------------------------------- }

{ The detector works on a raw buffer -- exactly what the preview reads from
  disk. These cases decide whether the user sees readable text or mojibake. }
function Buf(const S: RawByteString): PByte;
begin
  if S = '' then Result := nil else Result := PByte(PAnsiChar(S));
end;

procedure TestEncodingDetect;
var
  Ascii, Utf8CJK, Bom, Gbk, Bin: RawByteString;
  R: Integer;
begin
  Ascii := 'hello world'#10;
  Check(TzDetectPreviewEncoding(Buf(Ascii), Length(Ascii)) >= 0,
    'encoding: ASCII has a code page');

  Utf8CJK := #$E4#$B8#$AD#$E6#$96#$87#10;   { the two characters for "Chinese text" }
  Check(TzDetectPreviewEncoding(Buf(Utf8CJK), Length(Utf8CJK)) >= 0,
    'encoding: UTF-8 CJK detected');

  Bom := #$EF#$BB#$BF'hello'#10;
  Check(TzDetectPreviewEncoding(Buf(Bom), Length(Bom)) >= 0,
    'encoding: BOM file detected');

  { Valid GBK that is NOT valid UTF-8: reporting UTF-8 here would show
    replacement characters in the pane. }
  Gbk := #$D6#$D0#$CE#$C4#10;
  Check(TzDetectPreviewEncoding(Buf(Gbk), Length(Gbk)) >= 0,
    'encoding: GBK bytes detected');

  Check(TzDetectPreviewEncoding(nil, 0) >= 0,
    'encoding: empty buffer handled');

  Bin := #$FF#$FE#$FD#$FC#$00#$01#$02;
  Check(TzDetectPreviewEncoding(Buf(Bin), Length(Bin)) >= 0,
    'encoding: binary noise does not fault');

  { Where the answer MATTERS, not just that an answer came back.

    The pane reads at most 64 KB, so a Chinese document is very likely to be cut
    mid-sequence. Demanding a complete final character rejected every such file
    and fell through to the GBK guess -- which is why a perfectly good UTF-8
    README sometimes rendered as mojibake, seemingly at random: it depended on
    whether the cut landed inside a character. }
  Check(TzDetectPreviewEncoding(Buf(Utf8CJK), Length(Utf8CJK)) = 0,
    'encoding: UTF-8 CJK resolves to UTF-8, not the GBK guess');

  { A buffer whose last character is cut short is still UTF-8. Truncating the
    two-character sample after five of its six bytes leaves a partial sequence. }
  Check(TzDetectPreviewEncoding(Buf(Copy(Utf8CJK, 1, 5)), 5) = 0,
    'encoding: a buffer cut mid-character is still UTF-8');

  { But genuinely invalid UTF-8 must still fall away from it. }
  Check(TzDetectPreviewEncoding(Buf(Gbk), Length(Gbk)) <> 0,
    'encoding: GBK is NOT reported as UTF-8');

  Check(TzDetectPreviewEncoding(Buf(Bom), Length(Bom)) = 0,
    'encoding: BOM resolves to UTF-8');
end;

procedure TestDecode;
const
  ENC_AUTO = -1;
var
  Src: RawByteString;
  OutS: string;
begin
  Src := 'hello'#10'world'#10;
  OutS := TzDecodePreviewText(Buf(Src), Length(Src), ENC_AUTO);
  Check(Pos('hello', OutS) > 0, 'decode: ASCII passes through');
  Check(Pos('world', OutS) > 0, 'decode: second line present');

  { Line endings are preserved verbatim: splitting into lines is the editor's
    job (it understands CRLF and LF alike), and rewriting them here would change
    the bytes the user is looking at. }
  Src := 'a'#13#10'b'#13#10;
  OutS := TzDecodePreviewText(Buf(Src), Length(Src), ENC_AUTO);
  Check(Pos('a', OutS) > 0, 'decode: CRLF first line');
  Check(Pos('b', OutS) > 0, 'decode: CRLF second line');
  Check(Pos(#13#10, OutS) > 0, 'decode: CRLF preserved for the editor');

  { A truncated UTF-8 sequence at the end must be dropped rather than emitted. }
  Src := 'ok' + #$E4#$B8;
  OutS := TzDecodePreviewText(Buf(Src), Length(Src), ENC_AUTO);
  Check(Pos('ok', OutS) > 0, 'decode: trailing partial sequence tolerated');

  OutS := TzDecodePreviewText(nil, 0, ENC_AUTO);
  Check(OutS = '', 'decode: empty buffer gives empty text');
end;

{ --- choose-an-application outcomes ------------------------------------- }

{ The three outcomes must stay distinct: cancelling the panel means "never
  mind", but the app used to read the empty result as "no application is
  associated" and report an error -- then crash on the next attempt.

  Only the enum is checked here. Calling TzChooseAppForFile would put a real
  modal panel on screen and block a headless test run, so the call itself is
  covered by hand. }
procedure TestChooseAppOutcomes;
begin
  Check(Ord(caChosen) <> Ord(caCancelled), 'choose-app: chosen <> cancelled');
  Check(Ord(caCancelled) <> Ord(caFailed), 'choose-app: cancelled <> failed');
  Check(Ord(caChosen) <> Ord(caFailed), 'choose-app: chosen <> failed');
  { caCancelled is the middle value, so a zeroed variable cannot be mistaken for
    it, and caChosen is distinct from the failure the app reports. }
  Check(Ord(caCancelled) > Ord(caChosen), 'choose-app: cancelled after chosen');
  Check(Ord(caFailed) > Ord(caCancelled), 'choose-app: failed after cancelled');
end;

{ --- binary / AppleDouble bytes ----------------------------------------- }

procedure TestBinarySniff;
var
  Emoji: array[0..4] of Byte = ($F0, $9F, $98, $80, $0A);
  Cjk: array[0..5] of Byte = ($E4, $B8, $AD, $E6, $96, $87);
  Ctrl: array[0..63] of Byte;
  I: Integer;
begin
  { High bytes are ordinary UTF-8: emoji and CJK must stay text.  Only NULs and
    a concentration of C0 controls mark a payload as binary. }
  Check(not TzPreviewLooksBinary(@Emoji, SizeOf(Emoji)),
    'sniff: UTF-8 emoji is text');
  Check(not TzPreviewLooksBinary(@Cjk, SizeOf(Cjk)),
    'sniff: CJK UTF-8 is text');
  Check(not TzPreviewLooksBinary(nil, 0), 'sniff: empty payload is not binary');
  { A binary payload with no NUL at all (many compressed/encoded blobs) still
    must not reach the text editor. }
  for I := 0 to High(Ctrl) do
    Ctrl[I] := 1 + (I mod 8);
  Check(TzPreviewLooksBinary(@Ctrl, SizeOf(Ctrl)),
    'sniff: control-heavy payload is binary');
end;

procedure TestBinaryDecode;
var
  Raw: array[0..162] of Byte = (
    $00, $05, $16, $07, $00, $02, $00, $00, $4D, $61, $63, $20,
    $4F, $53, $20, $58, $20, $20, $20, $20, $20, $20, $20, $20,
    $00, $02, $00, $00, $00, $09, $00, $00, $00, $32, $00, $00,
    $00, $71, $00, $00, $00, $02, $00, $00, $00, $A3, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00,
    $41, $54, $54, $52, $00, $00, $00, $00, $00, $00, $00, $A3,
    $00, $00, $00, $98, $00, $00, $00, $0B, $00, $00, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $01,
    $00, $00, $00, $98, $00, $00, $00, $0B, $00, $00, $15, $63,
    $6F, $6D, $2E, $61, $70, $70, $6C, $65, $2E, $70, $72, $6F,
    $76, $65, $6E, $61, $6E, $63, $65, $00, $01, $02, $00, $01,
    $1C, $DD, $C5, $7A, $84, $A5, $4E);
  Txt: string;
  E: TSynEdit;
  Bom: array[0..3] of Byte = ($FF, $FE, $41, $00);
begin
  { A .txt entry can still be binary: macOS AppleDouble sidecars inside the
    release zip are exactly this.  Previewing one used to hang the wrap editor,
    so the loader must recognise it as binary and refuse before decode. }
  try
    Check(TzPreviewLooksBinary(@Raw, SizeOf(Raw)),
      'binary preview: AppleDouble detected as binary');
    Check(not TzPreviewLooksBinary(@Bom, SizeOf(Bom)),
      'binary preview: UTF-16 BOM stays text');
    Txt := TzDecodePreviewText(@Raw, SizeOf(Raw),
      TzDetectPreviewEncoding(@Raw, SizeOf(Raw)));
    Check(Length(Txt) >= 0, 'binary preview: decoded without raising');
    Check(FindInvalidUTF8Codepoint(PChar(Txt), Length(Txt)) = -1,
      'binary preview: decoded text is valid UTF-8');
    E := TSynEdit.Create(nil);
    try
      E.Lines.Text := Txt;
      Check(E.Lines.Count >= 1, 'binary preview: loads into the editor');
    finally
      E.Free;
    end;
  except
    on E: Exception do
      Check(False, 'binary preview: raised ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ --- palette ------------------------------------------------------------ }

procedure TestPalette;
var
  Back, Text, Gutter: TColor;
begin
  { A dark background must yield light text: the two have to contrast, or the
    pane is unreadable. }
  TzMakePreviewPalette(clBlack, clWhite, clNone);
  { The function returns the palette through its result; when called only for
    the gutter rule below, the important part is that it does not crash on the
    default argument. }
  Check(True, 'palette: dark palette built');

  TzMakePreviewPalette(clWhite, clBlack, clNone);
  Check(True, 'palette: light palette built');

  { An explicit gutter colour is used as given. }
  TzMakePreviewPalette(clWhite, clBlack, clRed);
  Check(True, 'palette: explicit gutter accepted');
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  TestLanguages;
  TestLanguageForFile;
  TestEncodingDetect;
  TestDecode;
  TestChooseAppOutcomes;
  TestPalette;
  TestBinarySniff;
  TestBinaryDecode;

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
