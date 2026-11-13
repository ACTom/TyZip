program unit_nameenc;
{$mode objfpc}{$H+}
{ The ZIP name-encoding table.

  These ids are persisted in the settings file and the code pages cross the
  C ABI into 7-Zip, so a silent change here would make every archive opened
  with that setting decode wrongly. "auto" resolves from the interface
  language, which is why the resolver takes the language as a plain string
  (this unit stays headless). }
uses
  SysUtils, tzip.nameenc;

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

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant]));
  end;
end;

procedure EqInt(AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure EqCode(AGot, AWant: LongWord; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else
  begin
    Inc(Fails);
    WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant]));
  end;
end;

procedure TestTable;
begin
  { The table order is the UI order; the ids and code pages are the stored
    values. Adjust both together with the settings dialog. }
  Check(Length(NameEncodings) = 18, 'table: eighteen encodings');
  EqStr(NameEncodings[0].Id, 'auto', 'table: 0 is auto');
  EqCode(NameEncodings[0].Codepage, 0, 'table: auto has no code page');
  EqStr(NameEncodings[1].Id, 'utf8', 'table: 1 is utf8');
  EqCode(NameEncodings[1].Codepage, 65001, 'table: utf8 is 65001');
  EqStr(NameEncodings[2].Id, 'gb18030', 'table: 2 is gb18030');
  EqCode(NameEncodings[2].Codepage, 54936, 'table: gb18030 is 54936');
  EqStr(NameEncodings[3].Id, 'gbk', 'table: 3 is gbk');
  EqCode(NameEncodings[3].Codepage, 936, 'table: gbk is 936');
  EqStr(NameEncodings[4].Id, 'big5', 'table: 4 is big5');
  EqCode(NameEncodings[4].Codepage, 950, 'table: big5 is 950');
  EqStr(NameEncodings[5].Id, 'sjis', 'table: 5 is sjis');
  EqCode(NameEncodings[5].Codepage, 932, 'table: sjis is 932');
  EqStr(NameEncodings[6].Id, 'euckr', 'table: 6 is euckr');
  EqCode(NameEncodings[6].Codepage, 949, 'table: euckr is 949');
  EqStr(NameEncodings[7].Id, 'cp1252', 'table: 7 is cp1252');
  EqCode(NameEncodings[7].Codepage, 1252, 'table: cp1252 is 1252');
  EqStr(NameEncodings[8].Id, 'latin1', 'table: 8 is latin1');
  EqCode(NameEncodings[8].Codepage, 28591, 'table: latin1 is 28591');
  EqStr(NameEncodings[9].Id, 'cp1250', 'table: 9 is cp1250');
  EqCode(NameEncodings[9].Codepage, 1250, 'table: cp1250 is 1250');
  EqStr(NameEncodings[10].Id, 'cp1251', 'table: 10 is cp1251');
  EqCode(NameEncodings[10].Codepage, 1251, 'table: cp1251 is 1251');
  EqStr(NameEncodings[11].Id, 'cp1253', 'table: 11 is cp1253');
  EqCode(NameEncodings[11].Codepage, 1253, 'table: cp1253 is 1253');
  EqStr(NameEncodings[12].Id, 'cp1254', 'table: 12 is cp1254');
  EqCode(NameEncodings[12].Codepage, 1254, 'table: cp1254 is 1254');
  EqStr(NameEncodings[13].Id, 'cp1255', 'table: 13 is cp1255');
  EqCode(NameEncodings[13].Codepage, 1255, 'table: cp1255 is 1255');
  EqStr(NameEncodings[14].Id, 'cp1256', 'table: 14 is cp1256');
  EqCode(NameEncodings[14].Codepage, 1256, 'table: cp1256 is 1256');
  EqStr(NameEncodings[15].Id, 'cp1257', 'table: 15 is cp1257');
  EqCode(NameEncodings[15].Codepage, 1257, 'table: cp1257 is 1257');
  EqStr(NameEncodings[16].Id, 'cp1258', 'table: 16 is cp1258');
  EqCode(NameEncodings[16].Codepage, 1258, 'table: cp1258 is 1258');
  EqStr(NameEncodings[17].Id, 'cp874', 'table: 17 is cp874');
  EqCode(NameEncodings[17].Codepage, 874, 'table: cp874 is 874');
  EqStr(NameEncodingDefault, 'auto', 'table: the default is auto');
end;

procedure TestById;
begin
  EqStr(TzNameEncodingById('gbk').Id, 'gbk', 'by id: gbk');
  EqCode(TzNameEncodingById('gbk').Codepage, 936, 'by id: gbk code page');
  EqCode(TzNameEncodingById('GB18030').Codepage, 54936,
    'by id: matching ignores case');
  EqStr(TzNameEncodingById('').Id, 'auto', 'by id: empty falls back to auto');
  EqStr(TzNameEncodingById('klingon').Id, 'auto',
    'by id: unknown falls back to auto');
  { Settings loading relies on this: the returned id is canonical. }
  EqStr(TzNameEncodingById('GBK').Id, 'gbk', 'by id: the id is canonical');
end;

procedure TestIndexByCodepage;
begin
  EqInt(TzNameEncodingIndexByCodepage(0), 0, 'index: 0 is auto');
  EqInt(TzNameEncodingIndexByCodepage(936), 3, 'index: gbk');
  EqInt(TzNameEncodingIndexByCodepage(28591), 8, 'index: latin1');
  EqInt(TzNameEncodingIndexByCodepage(874), 17, 'index: cp874');
  EqInt(TzNameEncodingIndexByCodepage(437), -1, 'index: DOS-437 is unknown');
end;

procedure TestResolve;
begin
  { auto follows the interface language. zh_TW must be tested before zh_CN's
    prefix rule, or Traditional users would get GB18030. }
  EqCode(TzResolveNameCodepage('auto', 'zh_CN'), 54936, 'auto: simplified');
  EqCode(TzResolveNameCodepage('auto', 'zh'), 54936, 'auto: bare zh');
  EqCode(TzResolveNameCodepage('auto', 'zh_TW'), 950, 'auto: traditional');
  EqCode(TzResolveNameCodepage('auto', 'zh_HK'), 950, 'auto: hong kong');
  EqCode(TzResolveNameCodepage('auto', 'ja'), 932, 'auto: japanese');
  EqCode(TzResolveNameCodepage('auto', 'ja_JP'), 932, 'auto: japanese form');
  EqCode(TzResolveNameCodepage('auto', 'ko'), 949, 'auto: korean');
  EqCode(TzResolveNameCodepage('auto', 'ko_KR'), 949, 'auto: korean form');
  EqCode(TzResolveNameCodepage('auto', 'en'), 1252, 'auto: other languages');
  EqCode(TzResolveNameCodepage('auto', ''), 1252, 'auto: no language');

  { An explicit id wins over the language. }
  EqCode(TzResolveNameCodepage('gbk', 'zh_CN'), 936, 'explicit: gbk');
  EqCode(TzResolveNameCodepage('utf8', 'zh_CN'), 65001, 'explicit: utf8');
  EqCode(TzResolveNameCodepage('GBK', 'ja'), 936,
    'explicit: matching ignores case');
  { An unknown id is auto, not "no conversion". }
  EqCode(TzResolveNameCodepage('klingon', 'en'), 1252,
    'unknown: resolves like auto');
end;

begin
  Fails := 0;
  Passes := 0;
  WriteLn('-- table');
  TestTable;
  WriteLn('-- lookup');
  TestById;
  TestIndexByCodepage;
  WriteLn('-- resolve');
  TestResolve;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
