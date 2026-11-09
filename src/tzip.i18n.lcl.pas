unit tzip.i18n.lcl;

{ LCL side of the language support: installing a translation into the running
  program. It lives in its own unit so headless units (and the tests) can use
  the resource strings and the config helpers from tzip.i18n without pulling
  the LCL into the link.

  LCLTranslator installs the catalogue before the main form is created, so extra
  language packs can be dropped in without a rebuild. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, LCLTranslator, GetText, tzip.i18n;

{ Install the language pack. Empty/system -> OS locale; an explicit id such as
  'zh_CN' is used as-is. Returns the id LCL selected ('' when nothing matched). }
function TzApplyLanguage(const ALang: string): string;

implementation

function TzApplyLanguage(const ALang: string): string;
var
  Lang, Dir, LclMo: string;
begin
  Lang := Trim(ALang);
  if (Lang = '') or SameText(Lang, LanguageSystem) then Lang := '';
  Dir := TzLanguagesDir;

  { The strings of the widgetset itself -- the application menu's Hide/Quit/
    Services lines, the file dialog buttons -- live in LCLStrConsts, a unit we
    do not own, so they were never part of tzip.zh_CN.mo and stayed English
    while the rest of the window switched language. SetDefaultLang only reads
    the one unit it is given, so the LCL catalogue is applied separately.

    GetText.TranslateResourceStrings is global: it registers the entries for
    every resource string in the program, and LCLStrConsts is registered the
    same way. Loading it before SetDefaultLang means tzip's own catalogue is
    applied last and wins where the two ever overlap. }
  if Lang <> '' then
  begin
    LclMo := Dir + 'lclstrconsts.' + Lang + '.mo';
    if FileExists(LclMo) then
      try
        GetText.TranslateResourceStrings(LclMo);
      except
        { A missing or unreadable catalogue only costs the LCL strings. }
      end;
  end;

  Result := SetDefaultLang(Lang, Dir, 'tzip');
end;

end.
