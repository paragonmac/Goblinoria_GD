extends RefCounted
## Test-only convergence wait. Runtime never spins or waits for visibility.
static func settle(renderer, timeout_ms: int = 5000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		renderer.pump_visibility()
		var state: Dictionary = renderer.get_visibility_snapshot()
		if state.applied_epoch == state.epoch and state.applied_sequence == state.requested_sequence and not state.application_pending:
			return true
		OS.delay_usec(250)
	push_error("Visibility fixture did not converge: %s" % renderer.get_visibility_snapshot())
	return false
