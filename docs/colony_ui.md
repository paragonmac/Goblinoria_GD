# Colony Management UI

The docked interface presents the existing prototype, not completed versions of
every system in the game design document. Management panels do not pause the world.

## Layout and controls

The layout follows the approved icon-first concept (dark translucent panels,
warm brass accents) and keeps the top of the screen clear for the world.

- Bottom command bar, left: status chips for Busy, Moving, Idle and Reserve
  workers and Pending, Blocked and Stored. Worker chips open Workers filtered to
  that activity, Pending/Blocked open Tasks filtered the same way, Stored opens
  Resources.
- Bottom command bar, centre: tool palette Inspect [1], Dig [2], Build [3],
  Stairs [4/5], Erase [6], Stockpile [7]. Stairs is one tool; a contextual row
  above the palette offers Up/Down (keys 4/5 still select directly) and the
  rotate hint. Other tools show a one-line hint in the same row.
- Bottom command bar, right: Colony, Workers, Jobs, Tasks, Stockpiles, Resources,
  More and Menu. More lists the remaining categories (Dig & Build, Zones & Rooms,
  Production, Needs & Health, Defense, World & Environment, Game & Diagnostics).
- Right edge: depth gauge with up/down buttons, the level relative to the
  starting level and the absolute Y ([ / ] and Shift + mouse wheel also step
  the level; Shift + wheel takes priority over stair rotation and zoom).
- A warning toast above the bar reports jobs no worker can reach; it opens Tasks
  filtered to Blocked.
- Left: one scrollable management panel above the bar. Workers and Tasks have
  search, filters and 50-row pages. Stockpiles and Resources are also paginated.
  Planned and tentative features collapse into a "Coming later (N)" section.
- Jobs opens a movable, non-modal worker-list pop-out instead of a docked page.
  Close, Escape or clicking Jobs again closes it.
- Windows: the management panel, details panel, Jobs pop-out and the F7
  Rendering panel are windows. Drag a window by its header; drag its edges or
  corners to resize (docked windows resize from their inner edge only). Drop a
  window within 64 px of the left or right screen-side edge (a brass highlight
  shows the slot) to dock it; windows docked on the same side stack and share
  the height. Drag a docked window's header to float it again. Defaults:
  management docked left, details docked right, Jobs and F7 floating. The layout
  is saved to user://ui_layout.cfg and restored on start (pulled back on screen
  for a smaller window); Game menu > Reset window layout restores the defaults.
  The Work Priorities editor still widens the details window while it is shown.
  It starts with just search, filters, pagination and worker rows, without feature cards.
- Click an already-open category or the same selected information row again to
  close its panel; no timed double-click is needed. Programmatic open/refresh
  operations (including Open Workers in the context menu) remain idempotent.
- Right (left of the depth gauge): selected worker, task, stockpile, material or
  live cell details with a block header and tags. Cell
  terrain and occupants refresh every 0.2 seconds with clickable related entries.
  Selection does not move the camera or change a role. Use Locate to
  center the target and request its level through the normal render controller.
- W opens Workers. Live diagnostic and recording status sit at the top centre.
- Escape closes a popup first, then the most recently opened details/management
  panel, then opens the game menu. Right-click context actions and right-drag
  panning remain available in the world. Panel gestures remain GUI-owned.
- Submenus use the same icon language: list rows show an activity/task-type
  icon with a status tag, Colony shows a tile grid of counts, detail actions are
  icon rows, and the Jobs pop-out, priority editor, right-click context menu and
  game menu carry icons. Popup and button icons come from `UiIconAtlas`, which
  bakes the code-drawn `UiIcon` vectors into one SubViewport (no image assets).
- F1-F12 retain their existing diagnostic meanings. In debug builds the backtick
  key toggles 1x/10x simulation speed (also under More > Game & Diagnostics).
  In debug builds F7 opens the Rendering debug panel (non-modal, runtime only;
  its Draw mode includes "Wireframe (visible only)" - opaque fill with depth-tested
  edges, no see-through wires - and "Polygons"),
  which holds the ramp-count dump (`Dump ramp counts`) and live renderer switches.

Text fields and popups own their keys; typing a tool or diagnostic shortcut does
not activate it after focus changes. Long lists scroll inside their panels.

Up/Down Stairs show a translucent 2 x 1 flight, rising one level along its length.
Wheel up/down rotates it by opposite 90-degree steps instead of zooming. Click to
designate one complete flight; dragging does not fill an area with stairs. Up
anchors the lower end above the clicked floor; Down anchors the upper end in the
clicked surface. Red means the footprint is unavailable. UI scrolling retains
priority. Existing saved one-cell stairs are not resized.
The queued stair marker keeps the ghost's shape and position. Its color changes
with job state (including amber when assigned); assignment does not enlarge it.

The logical baseline is 1920 x 1080, with 20-pixel body text and controls at least
36 pixels tall. The window starts at that size where the desktop work area permits;
otherwise its minimum and initial size fit the work area minus native decorations
and a small safety margin. Monitor/work-area changes are checked every 0.5 seconds.
Canvas Items scaling with expanding aspect preserves proportions and leaves 3D at
the actual window resolution; see the [Godot resolution guidance](https://docs.godotengine.org/en/stable/tutorials/rendering/multiple_resolutions.html).
The game does not force fullscreen. Smaller displays proportionally reduce text.

## Reading colony activity

Workers is an information panel: current activity, task, carried material and waiting
reason. It distinguishes working, travelling, waiting and reserve. A default
unassigned Fighter is **Fighter - Reserve; combat not implemented yet**, not a failed
worker. Open Jobs to change work; suggestions link there and never change
settings automatically.

Jobs has a searchable worker list. Selecting a worker opens a
screenshot-inspired layout with grouped work-enable checkboxes on the left and
the selected worker's priority controls on the right. This editor widens the right
dock from 340 to 680 logical pixels; other details retain their compact width.
Work types include Hauling,
Mining, Crafting, Building and future work. Set available work to Off or 1-9:
1 is highest, then 2, then 3, and so on. Move Up decreases the selected work type's
numeric priority by one; Move Down increases it by one, within 1-9. These controls
change only the selected value; ties are allowed and other values are not renumbered.
Equal-priority work uses the cheapest reachable path, not straight-line proximity.
Off or an unchecked enable checkbox disables future claims. Changes may be made
while a worker is busy, but current work finishes first.
Checking disabled work back on starts it at priority 2. Move controls do not turn
Off work back on. The sorted list puts Off last; order within a numbered tie is
visual only and does not change the scheduler's route-cost rule.
Crafting, gathering, farming and combat stay disabled until those systems exist.
Mining covers digging; Building covers existing placement and stairs. Role templates
provide initial defaults (priority 2 for their existing work) rather than permanent
eligibility restrictions. Enabling work on a Fighter makes that worker available
for it; disabling every work type leaves a reserve.

Player-editable work-priority templates are explicitly deferred future design.
The existing role defaults above do not provide a template editor. Active work is
tracked in GitHub Issues and the Goblinoria Roadmap, not a local TODO board.
The requested follow-up ticket could not be created on 2026-09-06: the GitHub
integration returned 403 (Resource not accessible by integration). This deferred
design note is not a claim that a tracker item exists.

Tasks and Jobs are display names. Internal category IDs `jobs` and
`assignments`, feature IDs, and routes `open:jobs` and `open:assignments` remain stable.

Tasks show their target, type, assignment and current accessibility observation.
Unknown accessibility is "Not evaluated". A recorded failure includes its age;
retry time becoming due is not proof of a new evaluation. Pending and blocked are
overlapping counts, not separate queues. Only pending tasks can be cancelled.
Cancelling one hauling task releases its reservations through the normal API.

Resources separate stored (currently spendable), loose and carried quantities.
Reserved is an overlapping subset, not another amount to add. Stockpile details
edit only the selected zone's category filters and named material overrides.
"Use category" removes the override. Removing a zone leaves physical items loose
and removes them from spendable storage. Related item IDs and carrier/stockpile
links are bounded and report truncation.

Rename a selected stockpile in its details panel using Enter or Rename. Names are
trimmed, 1-64 characters, without line breaks/control characters. Duplicate names
are allowed; identity and logistics still use stable IDs. Names are searchable and
persist in saves. Renaming does not rebuild hauling or change filters/items.

Place currently costs one stored iron ore; there is no construction-site delivery.
Erase cancels pending designations/removes stockpile designation, not terrain
demolition. Finished gestures report accepted/rejected counts and reasons, including
"Already designated as stockpile" and unavailable placement material.

## Availability and persistence

Every category remains navigable. Future actions display "Not implemented yet"
with an explanation and cannot dispatch gameplay commands. Partial systems describe
the prototype subset; tentative features are explicitly marked tentative. Lighting
and fog of war are placeholders, not new rendering/gameplay behavior. Fire/smoke
and temperature/pressure remain tentative.

V8 save/load restores terrain, two-cell stair geometry, physical storage, stockpile names, role templates and
work priorities, but workers
respawn and unfinished tasks reset. Full colony-session continuation is unavailable.
V4-V7 saves remain readable; absent names and priorities receive existing default
names and role-based work settings. Unsupported save versions are rejected.
Loading and world replacement clear selection, including replacement in the same
World node. Removed or stale targets report "No longer available".

The presentation model works with diagnostics disabled. Collection/filtering is
cooperatively bounded to 128 records or 1 ms per pump; worker observations refresh
on a 200 ms cadence. "Updating" means the last completed observation is retained
while collection catches up. Sustained mutations can delay an economy rebuild;
the interface does not label a mixed rebuild as a current complete observation.

## Acceptance

Headless validators cover catalog availability, presentation invariants, real Main
input, scaling and lifecycle. They do not establish visual legibility or rendering
correctness. After separate graphical approval, check navigation/focus, long labels,
disabled explanations, the four-worker staffing scenario, named stockpile filters,
dig/haul/build/reload, and monitor movement. Terrain-visibility sign-off remains
deferred to lighting/fog-of-war work. Active work stays in GitHub, not this document.
