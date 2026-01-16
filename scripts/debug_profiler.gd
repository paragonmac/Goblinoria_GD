class_name DebugProfiler
extends RefCounted
## Frame timing profiler with rolling window statistics.

#region State
var enabled: bool = false
var window_sec: float = 2.0
var hold_sec: float = 0.5
var frame_data: Dictionary = {}
var active: Dictionary = {}
var history: Dictionary = {}
var stats: Dictionary = {}
var order: Array = []
var hold_values: Dictionary = {}
var hold_until: Dictionary = {}
#endregion


#region Control
func reset() -> void:
	frame_data.clear()
	active.clear()
	history.clear()
	stats.clear()
	order.clear()
	hold_values.clear()
	hold_until.clear()
#endregion


#region Timing
func begin(label: String) -> void:
	if not enabled:
		return
	if active.has(label):
		return
	if not order.has(label):
		order.append(label)
	active[label] = Time.get_ticks_usec()


func end(label: String) -> void:
	if not enabled:
		return
	if not active.has(label):
		return
	var start: int = int(active[label])
	active.erase(label)
	var elapsed: int = Time.get_ticks_usec() - start
	frame_data[label] = int(frame_data.get(label, 0)) + elapsed


func finish_frame() -> void:
	if not enabled:
		frame_data.clear()
		active.clear()
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var cutoff: float = now - window_sec
	_prune_history(cutoff)
	for label in frame_data.keys():
		var ms: float = float(frame_data[label]) / 1000.0
		var samples: Array = history.get(label, [])
		samples.append({"t": now, "ms": ms})
		while samples.size() > 0 and float(samples[0]["t"]) < cutoff:
			samples.remove_at(0)
		var sum := 0.0
		var peak := 0.0
		for entry in samples:
			var v: float = float(entry["ms"])
			sum += v
			if v > peak:
				peak = v
		var avg := sum / float(samples.size()) if samples.size() > 0 else 0.0
		var prev_hold := float(hold_values.get(label, 0.0))
		var prev_until := float(hold_until.get(label, 0.0))
		var hold := prev_hold
		if now >= prev_until or ms >= prev_hold:
			hold = ms
			hold_until[label] = now + hold_sec
		hold_values[label] = hold
		stats[label] = {"last": ms, "avg": avg, "peak": peak, "hold": hold}
		history[label] = samples

	frame_data.clear()
	active.clear()
#endregion


func _prune_history(cutoff: float) -> void:
	for label in history.keys():
		var samples: Array = history[label]
		while samples.size() > 0 and float(samples[0]["t"]) < cutoff:
			samples.remove_at(0)
		if samples.is_empty():
			history.erase(label)
			stats.erase(label)
			hold_values.erase(label)
			hold_until.erase(label)
		else:
			history[label] = samples


#region External Samples
func add_sample(label: String, ms: float) -> void:
	if not enabled:
		return
	if not order.has(label):
		order.append(label)
	frame_data[label] = int(frame_data.get(label, 0)) + int(ms * 1000.0)
#endregion


#region Reporting
func get_report_lines(limit: int = 8) -> Array:
	var lines: Array = []
	var labels: Array = []
	for label in order:
		if stats.has(label):
			labels.append(label)
	var count: int = min(limit, labels.size())
	var min_val := INF
	var max_val := 0.0
	for label in labels:
		var entry: Dictionary = stats[label]
		var v: float = float(entry.get("hold", entry.get("last", 0.0)))
		if v < min_val:
			min_val = v
		if v > max_val:
			max_val = v
	for i in range(count):
		var label: String = labels[i]
		var entry: Dictionary = stats[label]
		var display_ms: float = float(entry.get("hold", entry.get("last", 0.0)))
		var color_hex := _color_hex_for_value(display_ms, min_val, max_val)
		lines.append("%s: %.2f ms (avg %.2f, peak %.2f)" % [
			"[color=#%s]%s[/color]" % [color_hex, label],
			display_ms,
			float(entry["avg"]),
			float(entry["peak"])
		])
	return lines


func _color_hex_for_value(value: float, min_val: float, max_val: float) -> String:
	var t := 0.0
	if max_val > min_val:
		t = clamp((value - min_val) / (max_val - min_val), 0.0, 1.0)
	var color := Color(0.0, 1.0, 0.0).lerp(Color(1.0, 0.0, 0.0), t)
	return "%02x%02x%02x" % [int(color.r * 255.0), int(color.g * 255.0), int(color.b * 255.0)]
#endregion
