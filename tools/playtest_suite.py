"""Run the graphical stair acceptance loop across fresh, isolated processes."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

from playtest_acceptance import Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot-path", required=True)
    parser.add_argument("--runs", type=int, default=3, choices=range(3, 11))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    suite = repo / ".playtest" / ("suite-" + uuid.uuid4().hex[:12])
    suite.mkdir(parents=True)
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not shell:
        raise RuntimeError("PowerShell is required for the owned-process launcher")
    record = {"harness_result": "running", "runs": [], "checks": []}
    active_root = None
    launch_count = 0
    original_environment = {key: os.environ.get(key) for key in ("APPDATA", "LOCALAPPDATA")}

    def check(condition, description):
        record["checks"].append({"passed": bool(condition), "description": description})
        if not condition:
            raise RuntimeError(description)

    def launch(command, *extra):
        nonlocal launch_count
        launch_count += 1
        output = suite / f"launcher-{launch_count}-{command}.json"
        errors = suite / f"launcher-{launch_count}-{command}.log"
        with output.open("w", encoding="utf-8") as stdout, errors.open("w", encoding="utf-8") as stderr:
            result = subprocess.run([shell, "-NoProfile", "-File", str(repo / "tools/playtest.ps1"), command,
                                     "-GodotPath", args.godot_path, "-TimeoutSec", "60", *map(str, extra)],
                                    cwd=repo, stdout=stdout, stderr=stderr, timeout=75)
        if result.returncode:
            raise RuntimeError(f"Launcher {command} failed; inspect {errors}")
        return json.loads(output.read_text(encoding="utf-8-sig"))

    def exercise(root):
        print(f"Exercising {root.name}", flush=True)
        with (root / "acceptance-console.log").open("w", encoding="utf-8") as output:
            result = subprocess.run([sys.executable, "-u", str(repo / "tools/playtest_acceptance.py"), str(root)],
                                    cwd=repo, stdout=output, stderr=subprocess.STDOUT, timeout=150)
        evidence = json.loads((root / "acceptance.json").read_text(encoding="utf-8"))
        record["runs"].append({"run_root": str(root), "harness_result": evidence["harness_result"],
                               "pointer_independence_observed": evidence.get("background_control", {}).get("pointer_independence_observed", False)})
        check(result.returncode == 0 and evidence["harness_result"] == "passed", "Graphical loop passed: " + root.name)
        check(evidence["background_control"]["unfocused_throughout"], "Synthetic controls operate in an unfocused game: " + root.name)
        subprocess.run([sys.executable, str(repo / "tools/playtest_report.py"), str(root)], cwd=repo, check=True,
                       stdout=subprocess.DEVNULL, timeout=15)
        return json.loads((root / "acceptance-initial.json").read_text(encoding="utf-8"))

    try:
        reply = launch("Start", "-RunId", suite.name + "-baseline", "-Scenario", "stair_preview")
        active_root = Path(reply["run_root"])
        baseline = None
        identities = set()
        for index in range(args.runs):
            state = Client(active_root).call("status", {})
            check(state["session_id"] not in identities, "Fresh session identity")
            identities.add(state["session_id"])
            check(Path(state["user_data_dir"]).resolve().is_relative_to(active_root.resolve()), "Resolved user data is isolated")
            initial = exercise(active_root)
            fingerprint = initial["scenario"]["initial_fingerprint"]
            if baseline is None:
                baseline = fingerprint
            else:
                check(fingerprint == baseline, "Reset restores identical terrain, workers, seeds and camera")
            previous_session = state["session_id"]
            previous_root = active_root
            next_scenario = "stair_continuation" if index == args.runs - 1 else "stair_preview"
            reply = launch("Reset", "-RunRoot", active_root, "-Scenario", next_scenario)
            active_root = Path(reply["run_root"])
            check(active_root != previous_root and (previous_root / "acceptance.json").is_file(), "Reset preserves earlier evidence")
            fresh = Client(active_root)
            rejected = fresh.call("pause", {"session_id": previous_session, "seq": 1})
            check(rejected.get("error") == "stale_session", "Fresh process rejects previous session requests")
        exercise(active_root)
        check(any(run["pointer_independence_observed"] for run in record["runs"]),
              "Synthetic pointer movement was observed without desktop pointer movement")
        check(original_environment == {key: os.environ.get(key) for key in original_environment}, "Parent application-data environment is unchanged")
        record["harness_result"] = "passed"
    except Exception as error:
        record["harness_result"] = "failed"
        record["error"] = str(error)
    finally:
        if active_root is not None:
            try:
                launch("Stop", "-RunRoot", active_root)
            except Exception as error:
                record["shutdown_error"] = str(error)
                record["harness_result"] = "failed"
        record["finished_at"] = time.time()
        (suite / "suite.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
        print(json.dumps({"suite": str(suite), **record}, indent=2), flush=True)
    return 0 if record["harness_result"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
