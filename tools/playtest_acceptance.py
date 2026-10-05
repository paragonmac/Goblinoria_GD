"""Exercise a running isolated graphical stair fixture through its public controls.

Start/Reset/Stop remain owned by playtest.ps1. This runner never changes terrain
directly, and records gameplay findings separately from control/capture failures.
"""
import argparse
import ctypes
import json
import socket
import time
import uuid
from pathlib import Path


def foreground_process_id():
    """Read OS ownership only; never activate a window or inject desktop input."""
    if not hasattr(ctypes, "WinDLL"):
        return None
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.GetForegroundWindow.restype = ctypes.c_void_p
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    process_id = ctypes.c_ulong()
    user32.GetWindowThreadProcessId(user32.GetForegroundWindow(), ctypes.byref(process_id))
    return process_id.value


class Client:
    def __init__(self, root: Path):
        self.root = root.resolve()
        descriptors = list((self.root / "control").glob("*.json"))
        if len(descriptors) != 1:
            raise RuntimeError("Expected exactly one control descriptor")
        self.descriptor = json.loads(descriptors[0].read_text(encoding="utf-8"))
        if self.descriptor["host"] != "127.0.0.1":
            raise RuntimeError("Expected local control endpoint")
        self.last_request = 0.0
        state = self.call("status", {})
        manifest = json.loads((self.root / "session.json").read_text(encoding="utf-8"))
        if state["run_id"] != manifest["run_id"] or state["session_id"] != self.descriptor["session_id"]:
            raise RuntimeError("Session identity mismatch")
        if Path(state["run_root"]).resolve() != self.root:
            raise RuntimeError("Run directory mismatch")
        self.session = state["session_id"]

    def call(self, operation, args):
        time.sleep(max(0, 0.25 - (time.monotonic() - self.last_request)))
        self.last_request = time.monotonic()
        request_id = uuid.uuid4().hex
        wire = json.dumps({"id": request_id, "token": self.descriptor["token"],
                           "op": operation, "args": args}).encode() + b"\n"
        with socket.create_connection(("127.0.0.1", self.descriptor["port"]), timeout=8) as sock:
            sock.sendall(wire)
            data = b""
            while b"\n" not in data:
                packet = sock.recv(65536)
                if not packet:
                    raise RuntimeError("Control connection closed before its receipt")
                data += packet
                if len(data) > 262144:
                    raise RuntimeError("Control response exceeds its bound")
        reply = json.loads(data.split(b"\n", 1)[0])
        if reply.get("id") != request_id:
            raise RuntimeError("Control response identity mismatch")
        if "error" in reply:
            raise RuntimeError(str(reply["error"].get("code", "transport_error")))
        return reply["result"]

    def operation(self, name, args=None, timeout=45):
        state = self.call("status", {})
        supplied = dict(args or {})
        for key in ("session_id", "world_epoch", "view_id"):
            supplied.setdefault(key, state[key])
        supplied.setdefault("seq", state["last_sequence"] + 1)
        receipt = self.call(name, supplied)
        if "operation_id" not in receipt:
            raise RuntimeError(str(receipt.get("error", "missing_operation_receipt")))
        deadline = time.monotonic() + timeout
        while receipt["state"] not in ("complete", "failed", "cancelled"):
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Operation {receipt['operation_id']} timed out; inspect before retrying")
            receipt = self.call("operation_status", {"session_id": self.session,
                                                       "operation_id": receipt["operation_id"]})
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_root", type=Path)
    args = parser.parse_args()
    client = Client(args.run_root)
    root = client.root
    results = {"harness_result": "running", "checks": [], "gameplay_findings": [], "observations": []}
    background_samples = []
    last_observation = [None]

    def check(condition, description):
        results["checks"].append({"passed": bool(condition), "description": description})
        if not condition:
            raise RuntimeError(description)

    def act(events):
        receipt = client.operation("act", {"events": events})
        check(receipt["state"] == "complete", "Input action completed: " + str(receipt.get("error", "")))
        return receipt

    def capture(label, cells):
        before = client.call("status", {})
        receipt = client.operation("observe", {"label": label, "cells": cells, "workers": [1],
                                                 "tasks": before["created_task_ids"]})
        observation = receipt.get("observation", {})
        results["observations"].append({"label": label, "state": receipt["state"], "paths": observation.get("paths", {}),
                                         "error": receipt.get("error", "")})
        check(receipt["state"] == "complete", "Graphical observation completed: " + label + ": " + str(receipt.get("error", "")))
        snapshot_path = Path(observation["paths"]["snapshot"])
        check(snapshot_path.resolve().is_relative_to(root), "Observation remains in the run directory")
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
        check(snapshot["screenshot"]["available"], "Observation contains rendered pixels")
        check(snapshot["coherence"]["coherent"], "Observation has coherent frame identities")
        control = snapshot["playtest_observation"]["control"]
        check(control["simulation_steps"] == before["simulation_steps"], "Observation does not advance simulation")
        previous = last_observation[0]
        current = snapshot["playtest_observation"]
        if previous and previous["control"]["simulation_steps"] == control["simulation_steps"]:
            worker_states = lambda value: {row["id"]: row["result"].get("state") for row in value["queries"]["workers"]}
            check(worker_states(previous) == worker_states(current), "Worker positions and progress remain frozen between paused observations")
            old_tasks = {row["id"]: row["result"].get("state") for row in previous["queries"]["tasks"]}
            new_tasks = {row["id"]: row["result"].get("state") for row in current["queries"]["tasks"]}
            check(all(old_tasks[key] == new_tasks[key] for key in old_tasks.keys() & new_tasks.keys()),
                  "Observed task state remains frozen without simulation advancement")
        last_observation[0] = current
        background_samples.append({"label": label, "window_has_focus": control["window_has_focus"],
                                   "foreground_process_id": foreground_process_id(), "game_process_id": control["pid"],
                                   "desktop_pointer": control["desktop_pointer"], "pointer": control["pointer"]})
        return snapshot

    def record_preview(snapshot):
        observation = snapshot["playtest_observation"]
        rows = observation["rendering"]["previews"]
        results["gameplay_findings"].append({"kind": "preview", "label": observation["label"],
                                             "rotation": observation["control"]["stair_rotation"], "entries": rows})

    try:
        initial = client.call("status", {})
        (root / "acceptance-initial.json").write_text(json.dumps(initial, indent=2), encoding="utf-8")
        check(initial["ready"] and initial["paused"], "Fixture starts ready and paused")
        check(initial["simulation_steps"] == 0, "Initial fixture has not advanced simulation")
        scenario = initial["scenario"]
        names = scenario["named_positions"]
        cells = list(names.values())
        capture("initial", cells)
        # Select through real shortcuts, even when the fixture initially chose stairs.
        act([{"kind": "key", "key": "1", "state": "down"}, {"kind": "key", "key": "1", "state": "up"}])
        act([{"kind": "key", "key": "5", "state": "down"}, {"kind": "key", "key": "5", "state": "up"}])
        state = client.call("status", {})
        check(state["player_mode"] == 4, "Down Stairs selected through the interface")
        target = state["screen_targets"]["hover_cell"]
        check(target["inside_viewport"] and not target["behind_camera"], "Scenario target is visible to the camera")
        point = target["point"]
        act([{"kind": "pointer_move", "point": point}])
        preview = capture("down-stairs-preview-rotation-0", cells)
        record_preview(preview)
        if scenario["scenario"] == "stair_preview":
            for rotation in (1, 2, 3, 0):
                act([{"kind": "wheel", "delta": 1, "point": point}])
                state = client.call("status", {})
                check(state["stair_rotation"] == rotation, f"Stair rotation {rotation} follows wheel input")
                record_preview(capture(f"down-stairs-preview-rotation-{rotation}-cycled", cells))
            before = client.call("status", {})
            check(before["simulation_steps"] == 0, "Hover, rotation and observation leave simulation paused")
            receipt = act([{"kind": "click", "point": point, "button": "left"}])
            task_ids = receipt["created_task_ids"]
            results["gameplay_findings"].append({"kind": "designation", "created_task_ids": task_ids})
            if task_ids:
                check(len(task_ids) == 1, "One stair flight designation produces one task")
                capture("queued-stairs", cells)
                capture("queued-stairs-paused", cells)
                outcome = client.operation("run_until", {"condition": {"kind": "task_state", "id": task_ids[0], "status": "completed"},
                                                           "timeout_sec": 60}, timeout=75)
                results["gameplay_findings"].append({"kind": "excavation", "state": outcome["state"], "error": outcome.get("error", ""),
                                                     "simulation_steps": outcome.get("end_steps")})
            else:
                results["gameplay_findings"].append({"kind": "designation_rejected", "feedback": client.call("status", {})["feedback"]})
            # Move into empty viewport space so the invalid hover overlay does
            # not obscure the completed terrain we are trying to compare.
            act([{"kind": "pointer_move", "point": [1850, 150]}])
            terrain = capture("excavation-outcome", cells)
            actual = {tuple(row["pos"]): row["result"].get("block", {}).get("id")
                      for row in terrain["playtest_observation"]["queries"]["cells"]}
            expected = {tuple(row["position"]): row["metadata"].get("stair_material")
                        for row in preview["playtest_observation"]["rendering"]["previews"]}
            results["gameplay_findings"].append({"kind": "preview_excavation_cells", "matches": bool(expected) and
                                                 all(actual.get(cell) == block for cell, block in expected.items())})
        else:
            receipt = act([{"kind": "click", "point": point, "button": "left"}])
            state = client.call("status", {})
            results["gameplay_findings"].append({"kind": "continuation", "created_task_ids": receipt["created_task_ids"], "feedback": state["feedback"]})
            capture("continuation-outcome", cells)
        final = client.call("status", {})
        check(final["paused"], "Session returns to paused state")
        check(initial["camera"] == final["camera"], "Before/after comparisons use the same camera")
        results["background_control"] = {"samples": background_samples,
                                           "unfocused_throughout": all(row["foreground_process_id"] not in (None, 0, row["game_process_id"]) for row in background_samples),
                                           "pointer_independence_observed": any(left["pointer"] != right["pointer"] and
                                                                               left["desktop_pointer"] == right["desktop_pointer"]
                                                                               for left, right in zip(background_samples, background_samples[1:])),
                                           "desktop_pointer_unchanged": all(row["desktop_pointer"] == initial["desktop_pointer"] for row in background_samples)}
        results["harness_result"] = "passed"
        results["gameplay_findings"].append({"kind": "visual_review", "state": "pending", "detail": "Inspect contact-sheet pixels before judging preview alignment."})
    except Exception as error:
        results["harness_result"] = "failed"
        results["error"] = str(error)
    finally:
        (root / "acceptance.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print(json.dumps({"run_root": str(root), "harness_result": results["harness_result"], "checks": len(results["checks"]),
                          "error": results.get("error", ""), "gameplay_findings": results["gameplay_findings"]}, indent=2), flush=True)
    return 0 if results["harness_result"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
