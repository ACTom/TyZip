program unit_services_paths;
{$mode objfpc}{$H+}
{$modeswitch objectivec1}
{ The Finder service conversion. Finder can hand a service a file REFERENCE URL
  (file:///.file/id=...), whose path is not a usable file name; turning that
  into the create dialog's default showed "/id=6571367.7z" (ticket 36). Pin the
  contract: the legacy filenames property list wins, public.file-url is resolved
  to a POSIX path, and a bare reference URL is rejected rather than mistaken for
  a path. }

uses
  SysUtils, Classes, Forms, Interfaces, CocoaAll, tzip.services_macos;

var
  Fails, Passes: Integer;

function Q(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(AnsiString(S)));
end;

{ A pasteboard shaped like the one Finder gives a file service. }
function MakeBoard(const ANames: array of string; const AUrl: string): NSPasteboard;
var
  Arr: NSMutableArray;
  I: Integer;
begin
  Result := NSPasteboard.pasteboardWithUniqueName;
  Result.clearContents;
  if Length(ANames) > 0 then
  begin
    Arr := NSMutableArray.alloc.init;
    for I := 0 to High(ANames) do
      Arr.addObject(Q(ANames[I]));
    Result.setPropertyList_forType(Arr, Q('NSFilenamesPboardType'));
  end;
  if AUrl <> '' then
    Result.setString_forType(Q(AUrl), Q('public.file-url'));
end;

procedure RunCase(const ANames: array of string; const AUrl: string;
  const AExpected: array of string; const AMsg: string);
var
  Board: NSPasteboard;
  Paths: TStringList;
  I: Integer;
  Ok: Boolean;
begin
  Board := MakeBoard(ANames, AUrl);
  Paths := TzServicePathsFromPasteboard(Board);
  try
    Ok := Paths.Count = Length(AExpected);
    if Ok then
      for I := 0 to High(AExpected) do
        if Paths[I] <> AExpected[I] then Ok := False;
    if Ok then Inc(Passes)
    else
    begin
      Inc(Fails);
      WriteLn('FAIL ', AMsg, ': got ', Paths.Count, ' path(s) [',
        StringReplace(Paths.Text, LineEnding, ' | ', [rfReplaceAll]), ']');
    end;
  finally
    Paths.Free;
  end;
end;

begin
  Fails := 0;
  Passes := 0;
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;

  { The real Finder case: plain paths in the legacy property list beat the
    reference URL in public.file-url. }
  RunCase(['/tmp/a b.txt'], 'file:///.file/id=6571367.1234', ['/tmp/a b.txt'],
    'filenames property list wins over a reference URL');

  { Only file URLs: resolve them, including percent escapes. }
  RunCase([], 'file:///tmp/a%20b.txt', ['/tmp/a b.txt'],
    'a public.file-url is turned into a POSIX path');

  { A bare reference URL has no usable path; never invent one. }
  RunCase([], 'file:///.file/id=6571367', [],
    'a reference URL alone yields no paths');

  { Several selected files keep their order. }
  RunCase(['/tmp/one.zip', '/tmp/two.7z'], '', ['/tmp/one.zip', '/tmp/two.7z'],
    'multiple selected files are kept in order');

  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
