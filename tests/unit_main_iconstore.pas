program unit_main_iconstore;
{$mode objfpc}{$H+}
{ The icon store's tables and queues.

  Pinned here: a failed lookup is not remembered, a type is queued once, aged
  entries are asked once per run and go before new ones, and a bundle path is
  queued once. These were five TStringLists with five different flag settings
  inside TMainForm, where the rules could not be seen in one place. }
uses
  SysUtils, tzip.iconstore;

var
  Fails, Passes: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then Inc(Passes)
  else begin Inc(Fails); WriteLn('FAIL ', AMsg); end;
end;

procedure EqStr(const AGot, AWant, AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got [%s] want [%s]', [AMsg, AGot, AWant])); end;
end;

procedure EqInt(const AGot, AWant: Integer; const AMsg: string);
begin
  if AGot = AWant then Inc(Passes)
  else begin Inc(Fails); WriteLn(Format('FAIL %s: got %d want %d', [AMsg, AGot, AWant])); end;
end;

{ --- table -------------------------------------------------------------- }

procedure TestExtTable;
var
  S: TZIconStore;
begin
  S := TZIconStore.Create;
  try
    EqInt(S.ExtIndex('png'), -1, 'ext: unknown type has no slot');
    Check(not S.ExtKnown('png'), 'ext: unknown type is not known');

    S.SetExtIndex('png', 7);
    EqInt(S.ExtIndex('png'), 7, 'ext: slot is remembered');
    Check(S.ExtKnown('.PNG'), 'ext: the key is normalised (dot and case)');
    EqInt(S.ExtIndex('PNG'), 7, 'ext: lookup is normalised too');

    { A rewrite replaces the value; the table stays sorted and single-valued. }
    S.SetExtIndex('.Png', 9);
    EqInt(S.ExtIndex('png'), 9, 'ext: a second value replaces the first');
    EqInt(S.ExtMap.Count, 1, 'ext: one row per type');

    { A failure must NOT be stored: -1 is not knowledge, and storing it is what
      pinned a suffix to the generic glyph for the whole session. }
    S.SetExtIndex('pdf', -1);
    Check(not S.ExtKnown('pdf'), 'ext: a failed lookup is not remembered');
    S.SetExtIndex('', 3);
    EqInt(S.ExtMap.Count, 1, 'ext: empty type is ignored');

    S.SetExtIndex('zip', 11);
    S.ClearExtIndex('zip');
    Check(not S.ExtKnown('zip'), 'ext: a cleared type can be asked again');
    { Clearing something absent is harmless. }
    S.ClearExtIndex('nope');
  finally S.Free; end;
end;

{ --- queues ------------------------------------------------------------- }

procedure TestExtQueue;
var
  S: TZIconStore;
begin
  S := TZIconStore.Create;
  try
    Check(not S.HasExtWork, 'queue: a new store has nothing queued');
    EqStr(S.TakeNextExt, '', 'queue: taking from an empty store is empty');

    Check(S.QueueExt('.PNG'), 'queue: a known type is queued');
    Check(not S.QueueExt('png'), 'queue: the same type is not queued twice');
    Check(S.QueueExt('jpg'), 'queue: a second type is queued');
    EqInt(S.ExtMap.Count, 0, 'queue: queuing does not resolve anything');

    EqStr(S.TakeNextExt, 'png', 'queue: FIFO, first in first out');
    EqStr(S.TakeNextExt, 'jpg', 'queue: then the second');
    EqStr(S.TakeNextExt, '', 'queue: drained');

    { A resolved type is never queued again. }
    S.SetExtIndex('gif', 4);
    Check(not S.QueueExt('gif'), 'queue: a known type is not queued');
  finally S.Free; end;
end;

procedure TestChecks;
var
  S: TZIconStore;
begin
  S := TZIconStore.Create;
  try
    S.AddCheck('png');
    S.AddCheck('.PNG');
    S.AddCheck('');
    Check(S.HasExtWork, 'checks: a waiting check counts as work');
    EqStr(S.TakeCheck, 'png', 'checks: normalised and queued once');
    EqStr(S.TakeCheck, '', 'checks: queue drained');
    Check(not S.HasExtWork, 'checks: drained means no work');

    { A new type goes after the aged ones: re-checking old entries first keeps
      the cache's own order of freshness. }
    S.AddCheck('old');
    S.QueueExt('new');
    EqStr(S.TakeNextExt, 'old', 'checks: aged entries come before new requests');
    EqStr(S.TakeNextExt, 'new', 'checks: then the new request');

    { One re-check per type per run. }
    Check(S.MarkChecked('png'), 'checks: first mark succeeds');
    Check(not S.MarkChecked('PNG'), 'checks: second mark is refused');
    S.AddCheck('png');
    EqStr(S.TakeCheck, '', 'checks: an already-checked type is not queued again');
  finally S.Free; end;
end;

{ --- application bundles ------------------------------------------------ }

procedure TestAppTable;
var
  S: TZIconStore;
begin
  S := TZIconStore.Create;
  try
    EqInt(S.AppIndex('app_abc'), -1, 'app: unknown key has no slot');
    Check(not S.AppKnown('app_abc'), 'app: unknown key is not known');
    S.SetAppIndex('app_abc', 12);
    EqInt(S.AppIndex('APP_ABC'), 12, 'app: key lookup is case-insensitive');
    S.SetAppIndex('app_abc', 13);
    EqInt(S.AppIndex('app_abc'), 13, 'app: a second value replaces the first');
    S.SetAppIndex('', 2);
    S.SetAppIndex('app_bad', -1);
    EqInt(S.AppIndex('app_bad'), -1, 'app: a failure is not remembered');

    Check(S.QueueAppPath('/tmp/Foo.app'), 'app: a bundle is queued');
    Check(not S.QueueAppPath('/tmp/Foo.app'), 'app: the same bundle is queued once');
    Check(S.QueueAppPath('/tmp/Bar.app'), 'app: a second bundle is queued');
    EqInt(S.AppPendingCount, 2, 'app: two waiting bundles');
    Check(S.HasAppWork, 'app: waiting bundles are work');
    EqStr(S.TakeAppPath, '/tmp/Foo.app', 'app: FIFO');
    EqStr(S.TakeAppPath, '/tmp/Bar.app', 'app: then the second');
    EqStr(S.TakeAppPath, '', 'app: drained');
    Check(not S.HasAppWork, 'app: no work left');
  finally S.Free; end;
end;

begin
  Fails := 0; Passes := 0;
  TestExtTable;
  TestExtQueue;
  TestChecks;
  TestAppTable;
  WriteLn;
  WriteLn(Format('PASSED %d, FAILED %d', [Passes, Fails]));
  if Fails <> 0 then Halt(1);
end.
