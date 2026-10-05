# Autonomous Game Playtesting

The playtest runner starts a dedicated development game with isolated data. It
provides real interface input, explicit simulation advancement and synchronized
image/state observations. See [ADR-019](adr/ADR-019-autonomous-playtesting.md).

## Start, inspect and reset

Use PowerShell from the repository root. `-GodotPath` selects the installed Godot
4.7 executable. Graphical playtests follow the repository's authorization rule;
an authorized playtest includes the actions and resets within that session scope.

```powershell
./tools/playtest.ps1 Start -Scenario stair_preview -GodotPath 'C:/path/to/Godot.exe'
./tools/playtest.ps1 Status
./tools/playtest.ps1 Observe -Wait
./tools/playtest.ps1 Reset -Scenario stair_continuation
./tools/playtest.ps1 Stop
```

Use the returned `RunRoot` or run ID explicitly when several sessions exist. Each
run has a new identity, isolated `appdata`/`localappdata`, session/runtime metadata,
Godot log, action journal and observations. Reset preserves previous artifacts.
The ordinary Godot user-data directory is not a test fixture.

The launcher writes `playtest_startup.cfg` only inside the isolated Godot user
directory. The project's optional `user://playtest_startup.cfg` override supplies
window settings before the native window is created. No override file is written
to the ordinary user-data directory.

The launcher must establish child-only environment isolation before executing
Godot. The bootstrap checks the resolved path before adding Main to the tree.
Failed identity, startup or isolation checks stop the operation; they do not
select another process or fall back to ordinary saves.

## Actions and simulation

The client sends authenticated operations to the control endpoint. The independent
[diagnostics endpoint](live_diagnostics.md) retains its observation-only allowlist.

```powershell
./tools/playtest.ps1 Send -Operation act -Wait -ArgsJson '{"events":[{"kind":"key","key":"5","state":"down"},{"kind":"key","key":"5","state":"up"}]}'
./tools/playtest.ps1 Send -Operation act -Wait -ArgsJson '{"events":[{"kind":"pointer_move","point":[960,540]}]}'
./tools/playtest.ps1 Send -Operation act -Wait -ArgsJson '{"events":[{"kind":"click","point":[960,540],"button":"left"}]}'
./tools/playtest.ps1 Send -Operation advance -Wait -ArgsJson '{"steps":60}'
./tools/playtest.ps1 Send -Operation pause
```

Coordinates are viewport pixels. Choose them from the latest observation and pin
its `world_epoch` and `view_id` in the action arguments. The client fills absent
stamps for fresh requests but preserves explicit stamps. Camera changes require
a fresh observation before selecting another pixel target. `set_view` accepts
`position:[x,y,z]`, `rotation:[pitch,yaw,0]` in radians, `size` and `render_level`.

`act` accepts pointer movement, button/key down and up, click, drag, wheel, text
and bounded waits. Gesture stages span process frames so held-state polling sees
press and release edges. Text goes to the focused control. Popups retain normal
input ownership; a consumed click does not become a world designation.

Simulation is paused between operations. UI, camera, previews, mesh work and
diagnostics remain responsive. `advance` executes 1-7200 steps at 1/60 second,
with at most one step per process frame. `run_until` uses one of these conditions:

```json
{"condition":{"kind":"cells_match","cells":[{"pos":[-11,225,16],"block_id":124}]},"timeout_sec":30}
{"condition":{"kind":"task_state","id":1,"status":"completed"},"timeout_sec":30}
{"condition":{"kind":"worker_at","id":1,"pos":[-11,226,14]},"timeout_sec":30}
```

The deadline is wall time (default 30 seconds, maximum 120). Missing tasks do not
imply completion. Completion, timeout and cancellation leave simulation paused.
The normal game retains its existing timing; async job ordering is not replayed.

Mutations require `session_id`, a monotonically increasing `seq` and `world_epoch`.
The client normally manages these. `operation_status` retrieves the receipt by
`operation_id`. A retry must reuse its sequence: the latest 128 receipts are
returned without repeating input, and older discarded sequences are rejected.
Never issue a new click merely because a previous network response was lost.

## Evidence and results

`observe` waits up to ten seconds for relevant generated chunks, applied mesh
revisions and visibility state to settle across two frames, then captures a draw.
It produces a PNG, JSON snapshot and completion manifest. Relevant cells, workers
and tasks can be requested without scanning the entire world. Frame captures
include synthetic cursor state, actual preview entries, feedback and created task
IDs. They do not recalculate selection eligibility or worker decisions.

Headless execution can validate contracts and retain metadata. It cannot pass
visual acceptance. Readiness timeout, unavailable image, view changes, write
failure and omitted data must remain visible in the report. Renderer readiness
alone does not establish that the pixels look correct.

Review the action journal alongside the observation contact sheet. Report harness
success separately from gameplay findings. The stair scenarios are intended to
expose current preview/continuation behavior; existing defects are not silently
fixed or marked correct by the runner.

```powershell
python tools/playtest_acceptance.py '.playtest/<run-id>'
python tools/playtest_report.py '.playtest/<run-id>'
python tools/playtest_suite.py --godot-path 'C:/path/to/Godot.exe'
```

The acceptance client operates an already-running fixture. The suite owns its
launches, resets and shutdown: it repeats the baseline three times, compares
initial fingerprints, checks session rejection, then runs the continuation
fixture. Each run retains `acceptance.json`, `acceptance-initial.json`, original
PNG/JSON observations and `playtest_report.html`. The suite records its process
and reset checks in a separate ignored run directory. Pixel review remains an
explicit step; the script does not equate matching block IDs with visual quality.

For an interrupted client, use `Status -RunId <id>` and poll the returned active
operation with `Send -Operation operation_status -ArgsJson '{"operation_id":"N"}'`.
Use `pause` to cancel input or simulation, then inspect its receipt before retrying.
An action reports executed stages even after cancellation. If startup failed,
inspect `session.json` and `logs/godot.log` in its run directory. `Stop` refuses
unverifiable process identities; it never searches for another Godot to terminate.

Protocol replies contain compact metadata and local artifact paths. Credentials
are in the local descriptor and must stay out of reports and action journals.
Up to 128 observation queries can name cells, chunks, worker IDs or task IDs.
Missing targets have explicit query errors. Invalid input and authentication
requests do not consume a client sequence.

## Scenario authoring and acceptance

Scenarios are allowlisted repository scripts, not remote code. Each supplies a
version, terrain/drop seeds, explicit terrain patch, workers/priorities, camera,
render level, named cells, required chunks and initial-state fingerprint. Setup
uses production world mutation and invalidation; subsequent actions use the UI.

The baseline graphical sequence hovers Down Stairs, records all four rotations,
commits one designation, advances to its outcome and compares the terrain using
the same camera. The continuation fixture records the current rejection. Repeat
the baseline from a fresh process three times and compare initial fingerprints.

Verify operation without desktop mouse movement while another application is
active. Physical input directed at the test window cancels automation instead of
being recorded as a scripted action. Cancellation must never finish a pending
world drag. The UI and ordinary native-input regressions remain part of acceptance.

The Windows acceptance client reads the foreground process ID without activating
any window. Godot's cached `Window.has_focus()` flag is retained as evidence but
is not sufficient to establish desktop ownership. A sandbox may run on a separate
window station and return foreground PID zero; use an authorized interactive
desktop launch for that acceptance check. Synthetic controls themselves require
neither desktop focus nor the computer-use plugin. User mouse movement in another
application is allowed: independence is demonstrated when the synthetic pointer
moves without moving the desktop pointer, not by requiring the user to hold still
for the entire suite.

## Validation snapshot: 2026-09-12

Godot 4.7.2, Windows Vulkan Forward+, 1920x1080, NVIDIA RTX 5070 Ti:

- The graphical suite completed three baseline processes and one continuation
  process, preserving earlier artifacts and rejecting previous session identities.
- All baseline initial fingerprints matched. Each designated flight completed
  through worker execution in 40 simulation steps. Paused observations preserved
  worker state and task progress.
- The baseline's two preview cells became stair block IDs 124/128. Captured
  rotations followed wheel input. Pixel review did not reproduce the historical
  preview offset in this fixture; broader terrain cases remain unproven.
- Continuation reproduced `down_stairs_not_placeable` and created no task. The
  rejection remains a gameplay finding, with no gameplay fix in this change.
- Chrome retained desktop foreground ownership. Synthetic pointer movement was
  observed without desktop pointer movement.
- Real menu Save and F1 capture succeeded inside an isolated run. An intentionally
  wrong user-data path aborted before world initialization.
- New contract suites passed: transport 24, scenarios 28, gestures 80, control 170,
  observer 15. Existing selection, stair input, context menu, colony UI, diagnostics,
  diagnostics transport, rendering and passive profiling regressions passed.

Local evidence is under `.playtest/suite-a815f3bdfb84/index.html`; original images,
snapshots and receipts are retained in its linked run directories. Artifacts are
ignored by Git and are machine-local. The suite closes its owned processes.

Video, full-session save restoration, a broad scenario suite, gameplay fixes and
desktop-plugin repair are separate work. GitHub remains the active work tracker.
