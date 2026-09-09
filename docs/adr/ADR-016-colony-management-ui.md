# ADR-016: Colony UI Ownership And Availability

Status: Accepted
Date: 2026-09-05

## Context

The prototype HUD hid essential staffing and economy information. An idle Fighter
looked like broken assignment even though combat is unavailable. Player explanations
must work without enabling developer diagnostics or rerunning gameplay decisions.

## Decision

Main owns one ColonyUIController. A code-created theme/navigation shell, management
panel presenter and UI-independent ColonyPresentationModel separate presentation
from authoritative actions. The shared capability catalog supplies stable feature
IDs, category membership, implementation status, explanations and named action
bindings. The existing tool catalog remains authoritative for tools and shortcuts.
Unavailable entries are visible and disabled; dispatch independently rejects them.

Domain mutation signals invalidate cached economy observations. Bounded native
dictionary cursors avoid bulk key extraction; each collection/filter pump limits
work to 128 records or 1 ms. Visible pages contain at most 50 rows. Worker activity
has an independent 200 ms refresh cadence. Immutable completed observations remain
available during rebuilding, with an Updating state. Continuous economy changes
may delay publication; cancelled rebuilds never publish mixed generations.

The model reads existing state only. It does not generate terrain, expire
reservations, run assignment/pathfinding or depend on diagnostic history. Stored,
loose and carried material quantities partition physical items; reserved overlaps
that partition. Unknown and old accessibility evidence retain those qualifications.

Selected IDs carry model/world identity and exact current domain identities where
applicable. World has a runtime-only epoch independent of optional diagnostics;
init and successful load commit advance it. Loading/replacement reconnects models
and clears selection; action-time checks reject stale IDs before the next UI tick.
Pending task cancellation uses an identity-checked TaskManager wrapper sharing the
existing hauling reservation cleanup. Filters and roles use authoritative APIs.

The shell overlays the existing viewport. Management continues simulation. Main's
input coordination gives GUI-origin gestures ownership through release and absorbs
text/popup keys without replay. Escape closes popup, latest dock, then game menu.
Right-click inspection feeds a labeled snapshot in the shared details dock. Both
context and Information inspection raycasts use existing loaded terrain only.

ADR-017 separates Workers information from Jobs settings. Jobs uses a code-created
movable worker-list pop-out owned by ColonyUIController; its selected priority editor
remains in the details dock. Tasks is the
player-facing name for the task list. Category IDs `assignments` and `jobs`, feature
IDs and routes `open:assignments` and `open:jobs` remain unchanged.
The selected worker's screenshot-inspired priority layout has grouped enable
checkboxes on the left and priority controls on the right. Move Up/Down changes
only the selected numeric priority by one within 1-9 (1 highest; ties allowed).
Off disables future claims and current work finishes. Player-editable priority
templates are explicitly deferred future design; existing role defaults remain.
Active work belongs in GitHub Issues and the Goblinoria Roadmap, not a local TODO board.

Repeated clicks on
the same category or information-row button close that panel; programmatic opens
stay idempotent. Stockpile details include a validated name editor. Priority and
name mutations revalidate selected identity and use authoritative domain APIs.

Window policy is runtime code: 1920 x 1080 logical Canvas Items/expand, native 3D,
and a desktop-fitting native minimum checked on monitor/work-area changes. No
scene/resource edits or new art dependencies are required.

## Consequences and limits

- The old HUD and worker-window production surfaces are retired, while compatibility
  helpers remain for existing API fixtures. There is one player-facing stockpile editor.
- Player explanations describe actual prototype limits, including inactive combat,
  global iron placement cost and workers/tasks restarting on load.
- Controls and labels do not implement future needs, production, combat, lighting
  or fog of war. Capability availability is not GDD milestone completion.
- Main.colony_ui_ms reports collection/presentation cost independently of recorder
  bookkeeping. Cooperative budgets are not hard guarantees against engine stalls.
- Toggling live diagnostics never clears renderer-owned read-only view evidence.
- Headless coverage is not graphical acceptance or a performance benchmark.

## Guardrails

- scripts/ui/colony_ui_controller.gd, colony_capability_catalog.gd,
  colony_presentation_model.gd and colony_window_policy.gd.
- tools/validate_colony_capabilities.gd, validate_colony_presentation.gd and
  validate_colony_ui.gd; existing selection/context/economy validators remain active.
- [Player controls and acceptance notes](../colony_ui.md).
