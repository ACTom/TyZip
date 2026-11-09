program api_test;
{$mode objfpc}{$H+}
uses SysUtils, tzip.api, tzip.engine;
var
  F: TFormatInfo;
  A: TTzArchive;
  E: string;
  R: Integer;
  L: TListing;
  I: Integer;
  C: TArchiveContext;
  Ind: TLongWordArray;
begin
  if not TzLoadLibrary(ParamStr(0)) then
  begin
    WriteLn('lib load failed');
    Halt(1);
  end;
  WriteLn('lib: ', TzLibraryPath);
  for F in TzLoadFormats do
    if F.CanUpdate then WriteLn('format ', F.Name, ' [', F.Ext, ']');
  if ParamCount >= 1 then
  begin
    R := TzOpenContext(ParamStr(1), ExtractFileName(ParamStr(1)), '',
      nil, False, '', C, E);
    WriteLn('open=', R, ' err=', E);
    if R = 0 then
    begin
      WriteLn('format=', C.FormatName, ' entries=', Length(C.Entries),
        ' size=', C.TotalSize);
      L := TzListArchive(C, '', '', ascName, False);
      for I := 0 to High(L) do
        WriteLn(L[I].Name, ' dir=', L[I].IsDir, ' size=', L[I].Size,
          ' method=', L[I].Method);
      Ind := TzAllIndices(C);
      R := TzTest(C.Archive, Ind, '', E);
      WriteLn('test=', R, ' err=', E);
    end;
  end;
end.
