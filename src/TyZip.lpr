program TyZip;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Forms,
  SysUtils, Classes,
  tzip.i18n, tzip.i18n.lcl, tzip.timing, tzip.main;

begin
  TzMark('units initialized');
  { Every string in this program is UTF-8: the .pas sources are UTF-8, the
    archive engine speaks UTF-8, and macOS filenames are UTF-8 bytes. FPC's
    default is the locale ANSI code page, under which UTF8Encode() converts
    UTF-8 to UTF-8 a second time and a Chinese file name reaches 7-Zip as
    mojibake -- archived, then unopenable. Declaring the system code page makes
    every implicit AnsiString conversion a no-op. }
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Initialize;
  TzMark('Application.Initialize');
  { English is the built-in default. A .mo pack in languages/ selected by the
    Language setting overrides it. TYZIP_LANG is a development/testing override
    (e.g. TYZIP_LANG=zh_CN). }
  if GetEnvironmentVariable('TYZIP_LANG') <> '' then
    TzApplyLanguage(GetEnvironmentVariable('TYZIP_LANG'))
  else
    TzApplyLanguage(TzConfiguredLanguage);
  Application.Title := rsAppName;
  TzMark('language applied');
  Application.CreateForm(TMainForm, MainForm);
  TzMark('MainForm created');
  Application.Run;
end.
