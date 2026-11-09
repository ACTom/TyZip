# 0001 — Split the main form by state and lifetime

- Status: accepted (2026-10-29)
- Owners: main area (ticket 13)

## Context

`src/tzip.main.pas` is one class, `TMainForm`, of about 8.4k lines and ~350
methods. It is the window, the navigation state machine, the icon cache
controller, the background-job scheduler, the preview pane, the archive command
set and the settings store at the same time. Every change to an archive command
or a preview rule has to be made inside the class that owns the window, which is
why almost none of it can be tested and why small fixes keep regressing
neighbouring behaviour.

The code health tickets already moved the pieces that were pure and obviously
separable: `tzip.extract` (extraction destinations and the conflict policy),
`tzip.queue` (batch item scheduling), `tzip.jobqueue` (the waiting-job FIFO),
`tzip.iconkeys`, `tzip.imageinfo`, `tzip.navpaths`, `tzip.arcpath`. What is
left needs a deliberate seam.

## Decision

Split by **state and lifetime**, not by feature menu:

1. A unit owns a piece of state and the rules that keep it valid, together with
   the lifetime that state has (one navigation stack, one icon index table, one
   job run).
2. A unit does **not** own a feature: "preview" is not a unit, "the preview session
   that lives while one item is selected" is.
3. Dependencies point one way: **UI → controller → engine → api**. A controller
   unit may use `tzip.engine`; it must not use LCL, `tzip.ui.*`, `tzip.main` or
   `tzip.dialogs`. The window wires the controller to widgets.
4. Each extraction replaces the old code in `tzip.main` in the same commit.
   Two implementations of the same rule are a defect, not a migration step.

### The five seams

| Unit | Owns | Layer | LCL |
|---|---|---|---|
| `TNavHistory`, breadcrumb builders (`tzip.navstate`) | back/forward stacks, crumb path derivation | controller (uses engine types) | no |
| `TZIconStore` (`tzip.iconstore`) | suffix/bundle key → image index tables, pending queues, cache-age policy | controller | no |
| `TJobController` (`tzip.jobcontrol`) | waiting-job FIFO, batch tally and summary, password-retry clone | controller (uses tzip.jobs) | no |
| `TPreviewPane` / `TPreviewSession` | preview session, encoding, highlighting, zoom, its worker threads | UI-adjacent (SynEdit/BGRABitmap) | yes |
| `TArchiveCommands` + completion handlers | command construction and per-purpose completion, separated from prompting | UI → engine | mostly no |

Phases:

- **Phase 1 (pure):** `TNavState`/breadcrumbs, `TZIconStore`, `TJobController`.
  Each gets a `tests/unit_*` program; each extraction is its own commit.
- **Phase 2 (LCL):** `TPreviewPane`/`TPreviewSession`, `TArchiveCommands`.
  Behaviour must be identical; no visual change is part of this work.
- **Phase 3:** `CompleteJob`'s switch becomes a table of per-purpose handlers;
  `TMainForm` keeps only widget assembly and event forwarding.

## What this ADR does NOT decide

- No rewrite of the window and no new UI. The widget tree built by `BuildUi`
  stays a linear block of control creation; splitting it into a builder framework
  is not part of this work (it has no behaviour and no tests to gain).
- No change to user-visible behaviour, wording, shortcuts or layout. If a move
  would change behaviour, the behaviour is fixed separately, before the move.
- No new dependencies from lower layers to upper ones, and no event bus: the
  window calls controllers, controllers call the engine, the engine calls the
  bridge.
- No test-only hooks in production units: controllers stay plain objects whose
  inputs are parameters.

## Consequences

- `tzip.main` shrinks phase by phase; each phase must keep
  `tests/run_all.sh` (app build + engine suite + preview suite) green.
- Every new controller unit is headless-testable; the window becomes harder to
  get wrong in the parts that no test can reach.
- The completion-handler table in phase 3 is the place where per-purpose
  behaviour is added from then on; adding a purpose stops meaning "edit a
  300-line switch".
