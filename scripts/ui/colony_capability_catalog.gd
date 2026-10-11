extends RefCounted
class_name ColonyCapabilityCatalog
## Player-facing routes and grouped GDD targets; availability is not milestone completion.
## Main owns dispatch and runtime guards (loading, save existence, selected targets).
## Empty actions are disabled, including partial systems with no management surface.

const MainTools = preload("res://scripts/main_tool_catalog.gd")
const TOOL_DETAILS := {
	World.PlayerMode.INFORMATION: ["build", "information", "available", "Inspect loaded terrain and cell snapshots; right-click a location for context actions."],
	World.PlayerMode.DIG: ["build", "dig", "available", "Designate reachable horizontal excavation; mined blocks drop physical items."],
	World.PlayerMode.PLACE: ["build", "place", "partial", "Place blocks using globally stored iron ore; material choice and delivery to sites are future work."],
	World.PlayerMode.UP_STAIRS: ["build", "up_stairs", "available", "Designate upward stairs by replacing eligible terrain; stairs currently cost no material."],
	World.PlayerMode.DOWN_STAIRS: ["build", "down_stairs", "available", "Designate downward stairs by replacing eligible terrain."],
	World.PlayerMode.ERASE: ["build", "erase", "available", "Cancel pending tasks, remove stockpile cells and remove torches; right-click also offers location-specific removal."],
	World.PlayerMode.STOCKPILE: ["build", "stockpile", "available", "Designate storage cells for physical items and hauling."],
	World.PlayerMode.TORCH: ["build", "build", "available", "Designate explored floor cells for free torches placed by miners."],
}


static func categories() -> Array[Dictionary]:
	return [
		{"id": "colony", "label": "Colony"},
		{"id": "workers", "label": "Workers"},
		{"id": "assignments", "label": "Jobs"},
		{"id": "jobs", "label": "Tasks"},
		{"id": "stockpiles", "label": "Stockpiles"},
		{"id": "resources", "label": "Resources"},
		{"id": "build", "label": "Dig & Build"},
		{"id": "zones", "label": "Zones & Rooms"},
		{"id": "production", "label": "Production"},
		{"id": "needs", "label": "Needs & Health"},
		{"id": "defense", "label": "Defense"},
		{"id": "world", "label": "World & Environment"},
		{"id": "game", "label": "Game & Diagnostics"},
	]


static func entries(category: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for tool: Dictionary in MainTools.TOOLS:
		var details: Array = TOOL_DETAILS.get(tool.mode, [])
		if not details.is_empty() and details[0] == category:
			result.append(_feature(details[1], tool.label, details[2], details[3], "tool:%d" % int(tool.mode)))
	result.append_array(_grouped_entries(category))
	return result


static func find_feature(id: String) -> Dictionary:
	for category: Dictionary in categories():
		for feature: Dictionary in entries(category.id):
			if feature.id == id:
				return feature
	return {}


static func _feature(id: String, label: String, status: String, description: String, action: String = "") -> Dictionary:
	return {"id": id, "label": label, "status": status, "description": description, "action": action}


static func _grouped_entries(category: String) -> Array[Dictionary]:
	match category:
		"colony":
			return [
				_feature("colony_overview", "Colony overview", "partial", "Review worker availability, pending and blocked tasks, stored materials, and staffing suggestions; needs and threats remain planned.", "open:colony"),
				_feature("alerts", "Alerts and blocked work", "planned", "Explain shortages, inaccessible tasks, unsafe paths, and colony emergencies."),
				_feature("policies", "Colony policies", "planned", "Allowed work, priorities, access policies, and future scheduling."),
				_feature("colony_history", "Colony history", "tentative", "A readable record of discoveries, losses, and settlement events."),
			]
		"workers":
			return [
				_feature("worker_roster", "Worker list and details", "available", "Open workers to inspect assignments, movement, and current work.", "open:workers"),
				_feature("worker_skills", "Skills and professions", "planned", "Learn through practice, training, and survival; specialize without permanent classes."),
				_feature("worker_equipment", "Equipment and inventory", "planned", "Manage tools, armor, weapons, and personal equipment; hauling currently carries item stacks."),
				_feature("worker_schedules", "Schedules", "planned", "Coordinate work, rest, training, and other assignments."),
				_feature("worker_personality", "Preferences and personality", "tentative", "Individual preferences and personality may add planning pressure later."),
			]
		"assignments":
			return [
				_feature("worker_roles", "Jobs", "partial", "Open the worker list to manage individual work priorities. 1 is highest; ties use the cheapest route. Crafting and combat are not implemented.", "open:assignments"),
				_feature("work_priorities", "Per-worker priorities", "available", "Use Off or 1-9 for each available work type. Off disables future claims; current work finishes before new priorities take effect.", "open:assignments"),
				_feature("work_templates", "Reusable priority templates", "planned", "Save named work-priority presets for multiple workers. Deferred; current settings remain per-worker."),
			]
		"jobs":
			return [
				_feature("job_list", "Task list and blocked reasons", "partial", "Inspect and filter current tasks, claims, and cached blocked reasons; cancel pending work. Rich priorities and alerts remain planned.", "open:jobs"),
				_feature("job_priorities", "Individual task priorities", "planned", "Per-worker work priorities are available through Jobs. Per-task overrides remain future work."),
				_feature("hauling", "Hauling", "partial", "Inspect hauling tasks that move loose items to eligible stockpiles; production and construction delivery remain planned.", "open:jobs"),
				_feature("operate_jobs", "Workshop operation", "planned", "Assign workers to operate workshops and production buildings."),
				_feature("maintenance_jobs", "Maintenance and recovery", "planned", "Repair, clean, restock, replace equipment, and recover materials."),
				_feature("defense_jobs", "Defense tasks", "planned", "Fight, flee, guard, and operate traps."),
			]
		"stockpiles":
			return [
				_feature("stockpile_filters", "Stockpile filters", "available", "Select a stockpile to edit accepted categories and material overrides or remove its designation.", "open:stockpiles"),
				_feature("stockpile_capacity", "Storage capacity and contents", "available", "Inspect storage zones, contents, and capacity; each stockpile cell holds 16 items.", "open:stockpiles"),
				_feature("stockpile_links", "Stockpile priorities and links", "planned", "Control supply destinations, workshop links, and hauling priorities."),
				_feature("stockpile_containers", "Containers and storage rules", "planned", "Define bins, containers, stack rules, and material-specific storage management."),
			]
		"resources":
			return [
				_feature("resource_inventory", "Stored resources", "available", "Inspect stored material totals; loose items are not spendable inventory.", "open:resources"),
				_feature("physical_items", "Physical items and logistics", "partial", "Inspect loose, reserved, carried, and stored quantities with related stockpiles; advanced supply and demand remain planned.", "open:resources"),
				_feature("raw_materials", "Raw materials", "partial", "Stone, soil, and ore support mining drops; logs, food, usable water, and special materials need further systems."),
				_feature("resource_accounting", "Supply and demand", "planned", "Track missing inputs, consumption, production outputs, and shortages."),
			]
		"build":
			return [
				_feature("construction_materials", "Materials and site delivery", "planned", "Choose construction materials and haul them to reachable building sites."),
				_feature("walls_floors", "Walls and floors", "planned", "Purpose-built construction designations beyond basic block placement."),
				_feature("ramps_bridges", "Ramps and bridges", "planned", "Construct slopes, crossings, and controlled access routes."),
				_feature("doors_access", "Doors and access control", "planned", "Manage doors, restricted routes, and safe paths."),
				_feature("furniture", "Furniture and fixtures", "planned", "Build beds, tables, storage fixtures, and other furnishings."),
				_feature("workshop_buildings", "Workshop construction", "planned", "Place production buildings with inputs, outputs, and worker access."),
				_feature("supports", "Supports and structural rules", "planned", "Build supports and contain fluids; support failure and cave-ins remain future work."),
				_feature("build_traps", "Trap construction", "planned", "Build and maintain colony traps."),
				_feature("lighting", "Lighting", "planned", "Place light sources and make underground illumination readable."),
			]
		"zones":
			return [
				_feature("rooms", "Rooms and quality", "planned", "Define or detect useful rooms from zones, furniture, materials, and access."),
				_feature("bedrooms", "Bedrooms and dormitories", "planned", "Assign sleeping spaces and shelter."),
				_feature("dining_meeting", "Dining and meeting halls", "planned", "Organize eating, gathering, and social spaces."),
				_feature("farm_zones", "Farms and gathering zones", "planned", "Designate cultivation and resource gathering areas."),
				_feature("workshop_storage_zones", "Workshop and storage rooms", "planned", "Organize functional production and storage spaces around stockpiles."),
				_feature("barracks", "Barracks and defensive areas", "planned", "Define training, guard, and defensive spaces."),
				_feature("medical_rooms", "Medical and recovery rooms", "planned", "Assign healing and recovery spaces."),
				_feature("restricted_zones", "Burrows and restricted zones", "planned", "Constrain access and establish safe areas during alerts."),
			]
		"production":
			return [
				_feature("extraction", "Chopping, gathering, farming, hunting", "planned", "Expand extraction beyond the existing mining tool."),
				_feature("refinement", "Smelting, milling, and cooking", "planned", "Turn ore into bars, logs into planks, and raw food into meals."),
				_feature("crafting", "Crafting", "planned", "Make tools, furniture, weapons, containers, and trade goods."),
				_feature("recipes_orders", "Recipes and production orders", "planned", "Queue workshop recipes, assign operators, and diagnose missing inputs."),
				_feature("production_logistics", "Production chains", "planned", "Connect extraction, refinement, crafting, construction, and maintenance through physical hauling."),
			]
		"needs":
			return [
				_feature("food_drink", "Food and drink", "planned", "Feed workers and supply drink or usable water."),
				_feature("sleep_shelter", "Sleep and shelter", "planned", "Provide rest and protective living spaces."),
				_feature("safety", "Safety", "planned", "Make danger and safe access affect worker needs."),
				_feature("morale_social", "Morale and social life", "planned", "Social spaces and job satisfaction affect colony health."),
				_feature("health", "Health, injuries, and death", "planned", "Track injuries, treatment, recovery, and loss; falling recovery currently causes no injury system."),
			]
		"defense":
			return [
				_feature("threats", "Creatures, factions, and wildlife", "planned", "Respond to hostiles, wildlife, and dangerous underground discoveries."),
				_feature("combat", "Combat and fleeing", "planned", "Readable fighting, escape, injuries, and defense outcomes."),
				_feature("squads", "Squads and guard assignments", "planned", "Organize protection, chokepoints, and prepared positions."),
				_feature("combat_roles", "Fighters, rangers, clerics, specialists", "planned", "Learn melee, ranged, healing, poison removal, protection, scouting, and support roles."),
				_feature("advanced_abilities", "Advanced learned abilities", "planned", "Train shield walls, ranged volleys, mass healing, cures, and area storm-blade cleaves."),
				_feature("defense_alerts", "Defense alerts and traps", "planned", "Coordinate traps, safe zones, doors, walls, and bridges during threats."),
			]
		"world":
			return [
				_feature("level_up", "View level up", "available", "Reveal the next vertical terrain slice.", "level:up"),
				_feature("level_down", "View level down", "available", "Reveal the previous vertical terrain slice.", "level:down"),
				_feature("rotate_left", "Rotate view left", "available", "Rotate the camera left around the current view (comma).", "camera:left"),
				_feature("rotate_right", "Rotate view right", "available", "Rotate the camera right around the current view (period).", "camera:right"),
				_feature("world_generation", "Biomes, geology, caves, and ores", "partial", "Full-map generation has climate, biomes, geology, caves, ores, slopes, and flowers; streamed generation is simpler.", "game:menu"),
				_feature("world_overlays", "Access, tasks, resources, danger, fluids", "partial", "Task, item, and stockpile markers exist; selectable access, danger, and fluid overlays remain planned."),
				_feature("fog", "Fog of war and exploration", "planned", "Track discovery and obscured terrain as the colony explores."),
				_feature("water_flooding", "Water and flooding", "planned", "Readable fluid simulation and containment; static underground water generation is currently disabled."),
				_feature("lava", "Lava and damaging fluids", "planned", "Simulate dangerous fluids and colony consequences."),
				_feature("cave_ins", "Cave-ins and support failure", "planned", "Make unsupported terrain and structural failure affect the colony."),
				_feature("poison_gas", "Poison gas and underground hazards", "planned", "Dangerous underground features and their recovery consequences."),
				_feature("fire_smoke", "Fire and smoke", "tentative", "Potential later hazards if they support understandable gameplay."),
				_feature("temperature_pressure", "Temperature and pressure", "tentative", "Consider only if these systems add clear gameplay."),
			]
		"game":
			return [
				_feature("game_menu", "Game menu", "available", "Open pause/menu controls and the full-map generation option.", "game:menu"),
				_feature("new_world", "Start world", "available", "Start a world from the initial menu; Main guards an existing session.", "game:new"),
				_feature("resume", "Resume", "available", "Open the game menu to resume the current world.", "game:menu"),
				_feature("save", "Save world", "partial", "V9 saves terrain, items, stockpiles, roles, priorities, worker positions, pending jobs, and the camera view; work progress is not restored.", "game:save"),
				_feature("load", "Load world", "partial", "Load the saved world; workers return to their saved spots, pending jobs reload, jobs in progress restart, and carried items become loose.", "game:load"),
				_feature("session_persistence", "Full session persistence", "planned", "Restore worker state, queued designations, work progress, inventory, and production; keep version checks explicit."),
				_feature("settings", "Settings and controls", "planned", "Player-facing graphics, audio, input, and accessibility settings."),
				_feature("live_diagnostics", "Live diagnostics", "available", "Toggle the live diagnostic service and bounded evidence collection.", "diagnostics:live"),
				_feature("capture_bug", "Capture bug report", "available", "Capture bounded live diagnostic state and optional viewport evidence (F1).", "diagnostics:capture"),
				_feature("performance", "Performance diagnostics", "available", "Open performance recording and diagnostic controls.", "diagnostics:performance"),
				_feature("profiler", "Profiler", "available", "Toggle development profiler (F2).", "debug:profiler"),
				_feature("draw_burden", "Draw burden", "available", "Toggle rendering burden diagnostics (F3).", "debug:burden"),
				_feature("debug_timings", "Debug timings", "available", "Toggle timing diagnostics (F4).", "debug:timings"),
				_feature("streaming_stats", "Streaming statistics", "available", "Toggle streaming statistics (F5).", "debug:streaming"),
				_feature("streaming_capture", "Streaming capture", "available", "Toggle streaming capture (F6).", "debug:streaming_capture"),
				_feature("render_panel", "Rendering panel", "available", "Live rendering switches, void meter and draw modes (F7).", "debug:render_panel"),
				_feature("ramp_counts", "Ramp counts", "available", "Dump ramp diagnostics (also in the Rendering panel).", "debug:ramps"),
				_feature("debug_normals", "Terrain normals", "available", "Toggle terrain normal visualization (F8).", "debug:normals"),
				_feature("map_snapshot", "Map snapshot", "available", "Export a diagnostic map snapshot (F9).", "debug:map"),
				_feature("timings_log", "Timing log", "available", "Toggle timing log capture (F10).", "debug:timings_log"),
				_feature("worker_trace", "Worker trace", "available", "Toggle worker trace capture (F11).", "debug:workers"),
				_feature("quit", "Quit game", "available", "Open the game menu to exit the application.", "game:menu"),
			]
	return []
