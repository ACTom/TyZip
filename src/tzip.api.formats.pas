unit tzip.api.formats;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, fpjson, jsonparser, tzip.api.bind;

type
  TFormatInfo = record
    Name: string;
    Ext: string;
    AddExt: string;
    CanUpdate: Boolean;
  end;
  TFormatInfoArray = array of TFormatInfo;

function TzLoadFormats: TFormatInfoArray;
function TzParseFormatsJSON(const AJSON: string): TFormatInfoArray;
function TzFormatByName(const AName: string): TFormatInfo;

implementation

function TzParseFormatsJSON(const AJSON: string): TFormatInfoArray;
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  I: Integer;
begin
  Result := nil;
  Data := nil;
  try
    try
      Data := GetJSON(AJSON);
      if not (Data is TJSONArray) then Exit;
      Arr := TJSONArray(Data);
      SetLength(Result, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        { A row that is not an object is skipped, not fatal. }
        if not (Arr.Items[I] is TJSONObject) then Continue;
        Obj := TJSONObject(Arr.Items[I]);
        Result[I].Name := Obj.Get('name', '');
        Result[I].Ext := Obj.Get('ext', '');
        Result[I].AddExt := Obj.Get('addext', '');
        Result[I].CanUpdate := Obj.Get('update', False);
      end;
    except
      { The format table is a convenience for the UI. A truncated or corrupt one
        (older library, interrupted write) must not take the startup down. }
      SetLength(Result, 0);
    end;
  finally
    Data.Free;
  end;
end;

function TzLoadFormats: TFormatInfoArray;
var
  Need, Got: Integer;
  Buf: RawByteString;
begin
  Result := nil;
  if not TzLibraryLoaded then Exit;
  Need := _format_json(nil, 0);
  if Need <= 1 then Exit;
  SetLength(Buf, Need);
  Got := _format_json(PAnsiChar(Buf), Need);
  if Got <= 1 then Exit;
  { The ABI returns the required buffer size INCLUDING the trailing NUL, so "Got
    minus one" is the byte count. StrLen used to scan for a terminator in a
    buffer the bridge may have filled to the brim: a too-small buffer makes the
    bridge write nothing and return a larger requirement, and StrLen then read
    past the allocation. }
  if Got > Need then SetLength(Buf, Need) else SetLength(Buf, Got - 1);
  if Length(Buf) = 0 then Exit;
  Result := TzParseFormatsJSON(string(Buf));
end;

function TzFormatByName(const AName: string): TFormatInfo;
var
  F: TFormatInfo;
begin
  Result.Name := '';
  Result.Ext := '';
  Result.AddExt := '';
  Result.CanUpdate := False;
  for F in TzLoadFormats do
    if SameText(F.Name, AName) then Exit(F);
end;


end.
