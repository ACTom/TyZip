unit tzip.nameenc;
{$mode objfpc}{$H+}
{ The ZIP name-encoding table.

  Shared by the settings file, the open path and the update path; non-LCL on
  purpose because tzip.engine/jobs and the headless tests use it.

  "auto" means "resolve from the interface language". Every other id is a
  Windows code page that crosses the C ABI into 7-Zip. Keep this array in step
  with the settings dialog: the order here is the combo order. }
interface

uses
  SysUtils;

type
  TNameEncoding = record
    Id: string;
    Codepage: LongWord;
  end;

const
  NameEncodingDefault = 'auto';
  NameEncodings: array[0..17] of TNameEncoding = (
    (Id: 'auto'; Codepage: LongWord(0)),
    (Id: 'utf8'; Codepage: LongWord(65001)),
    (Id: 'gb18030'; Codepage: LongWord(54936)),
    (Id: 'gbk'; Codepage: LongWord(936)),
    (Id: 'big5'; Codepage: LongWord(950)),
    (Id: 'sjis'; Codepage: LongWord(932)),
    (Id: 'euckr'; Codepage: LongWord(949)),
    (Id: 'cp1252'; Codepage: LongWord(1252)),
    (Id: 'latin1'; Codepage: LongWord(28591)),
    (Id: 'cp1250'; Codepage: LongWord(1250)),
    (Id: 'cp1251'; Codepage: LongWord(1251)),
    (Id: 'cp1253'; Codepage: LongWord(1253)),
    (Id: 'cp1254'; Codepage: LongWord(1254)),
    (Id: 'cp1255'; Codepage: LongWord(1255)),
    (Id: 'cp1256'; Codepage: LongWord(1256)),
    (Id: 'cp1257'; Codepage: LongWord(1257)),
    (Id: 'cp1258'; Codepage: LongWord(1258)),
    (Id: 'cp874'; Codepage: LongWord(874))
  );

{ The entry for AId; unknown or empty ids fall back to auto. Matching ignores
  case because the settings file is hand editable. }
function TzNameEncodingById(const AId: string): TNameEncoding;

{ Combo index for a code page: 0 for "auto" (0), -1 when no entry has it. Used
  to seed the create/convert dialog from a stored code page. }
function TzNameEncodingIndexByCodepage(ACodepage: LongWord): Integer;

{ The code page an open should pass across the ABI. An explicit id returns its
  code page; auto (or an unknown id) resolves from AEffectiveLanguage. }
function TzResolveNameCodepage(const AId, AEffectiveLanguage: string): LongWord;

implementation

{ The fallback for archives whose names are not valid UTF-8 and carry no flag.
  zh_TW/zh_HK must be checked before the zh prefix, or Traditional users would
  be given GB18030 and still see mojibake. Other languages get Windows-1252,
  which matches the historical byte-per-character fallback for 0xA0..0xFF. }
function TzLanguageCodepage(const ALanguage: string): LongWord;
var
  L: string;
begin
  L := LowerCase(Trim(ALanguage));
  if (L = 'zh') or (L = 'zh_cn') or (L = 'zh_hans') then
    Result := 54936
  else if (L = 'zh_tw') or (L = 'zh_hk') or (L = 'zh_hant') then
    Result := 950
  else if (L = 'ja') or (Copy(L, 1, 3) = 'ja_') or (Copy(L, 1, 3) = 'ja-') then
    Result := 932
  else if (L = 'ko') or (Copy(L, 1, 3) = 'ko_') or (Copy(L, 1, 3) = 'ko-') then
    Result := 949
  else
    Result := 1252;
end;

function TzNameEncodingById(const AId: string): TNameEncoding;
var
  I: Integer;
  L: string;
begin
  L := LowerCase(Trim(AId));
  for I := 0 to High(NameEncodings) do
    if NameEncodings[I].Id = L then
      Exit(NameEncodings[I]);
  Result := NameEncodings[0];
end;

function TzNameEncodingIndexByCodepage(ACodepage: LongWord): Integer;
var
  I: Integer;
begin
  if ACodepage = 0 then Exit(0);
  for I := 0 to High(NameEncodings) do
    if NameEncodings[I].Codepage = ACodepage then Exit(I);
  Result := -1;
end;

function TzResolveNameCodepage(const AId, AEffectiveLanguage: string): LongWord;
var
  E: TNameEncoding;
begin
  E := TzNameEncodingById(AId);
  if E.Codepage > 0 then
    Result := E.Codepage
  else
    Result := TzLanguageCodepage(AEffectiveLanguage);
end;

end.
