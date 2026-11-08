#!/usr/bin/env python3
"""Check fixture policy and the packaged app's preflight JSON; stdlib only."""

import json
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".build/codex-probe-check"
APP = ROOT / ".build/PromptBridge.app"
STATUSES = {
    "permissionRequired", "unsupportedFrontApplication", "unknownBuild",
    "focusedInputUnavailable", "foreignElement", "secureInput",
    "modeMetadataMissing", "modeUnverified",
}
SUPPORT = {"present", "empty", "unsupported", "missing", "unavailable", "unexpectedType"}
ROLES = {"textArea", "textField", "group", "webArea", "window", "application", "other", "unavailable"}


def main():
    if not APP.is_dir():
        raise RuntimeError("Build PromptBridge.app with scripts/build-app.sh first.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "report.json").unlink(missing_ok=True)
    # A fresh directory prevents a previous run's report from satisfying this run.
    with tempfile.TemporaryDirectory(prefix="run-", dir=OUTPUT) as temporary:
        run = Path(temporary)
        subprocess.run([
            "zsh", "scripts/run-ui-checks.sh",
            "Tests/PromptBridgeUITests/codex-probe-policy.json", str(run / "policy"),
        ], cwd=ROOT, check=True, timeout=60)
        policy = json.loads((run / "policy/report.json").read_text())
        assert policy["checks"] and not policy["failures"], "fixture checks failed"
        assert all(check["passed"] is True for check in policy["checks"]), "fixture assertion failed"

        destination = run / "preflight.json"
        subprocess.run([
            "/usr/bin/open", "-g", "-n", str(APP), "--args",
            "--probe-codex", "--probe-output", str(destination),
        ], check=True, timeout=15)
        deadline = time.monotonic() + 10
        while not destination.is_file() and time.monotonic() < deadline:
            time.sleep(0.05)
        report = json.loads(destination.read_text())
        checks = []

        def check(condition, description):
            checks.append({"assertion": description, "passed": bool(condition)})
            assert condition, description

        required = {"status", "nodes", "metadataReads", "focusedInputReads",
                    "selectionReads", "hostWrites", "modeVerified"}
        check(required <= report.keys() <= required | {"applicationVersion", "applicationBuild"},
              "returned report contains only approved fields")
        check(report["status"] in STATUSES, "returned status is a known preflight result")
        check(report["modeVerified"] is False and report["selectionReads"] == 0 and report["hostWrites"] == 0,
              "preflight never claims adaptation, reads selections or writes to the host")
        check(all(type(report[field]) is int for field in ("metadataReads", "focusedInputReads", "selectionReads", "hostWrites"))
              and 0 <= report["metadataReads"] <= 19 and report["focusedInputReads"] in (0, 1),
              "returned read counts stay within the preflight budget")
        nodes = report["nodes"]
        check(isinstance(nodes, list) and len(nodes) <= 5
              and all(node.get("depth") == depth for depth, node in enumerate(nodes)),
              "returned chain has at most four ancestors in order")
        check(all(set(node) == {"depth", "role", "subroleSupport", "identifierSupport"}
                  and node["role"] in ROLES and node["subroleSupport"] in SUPPORT
                  and node["identifierSupport"] in SUPPORT for node in nodes),
              "returned metadata uses enums without raw host strings")
        early = report["status"] in {"permissionRequired", "unsupportedFrontApplication", "unknownBuild"}
        check(not early or (report["focusedInputReads"] == 0 and report["metadataReads"] == 0 and not nodes),
              "rejected permission, application or build returns zero AX reads")
        check(report["status"] not in {"modeMetadataMissing", "modeUnverified"}
              or ((report.get("applicationVersion"), report.get("applicationBuild"))
                  in {("26.930.31730", "12947"), ("26.930.51102", "13100")}
                  and report["focusedInputReads"] == 1 and bool(nodes)
                  and report["metadataReads"] == 4 * len(nodes) - (len(nodes) == 5)
                  and (report["status"] == "modeUnverified")
                  == any(node["identifierSupport"] == "present" for node in nodes)),
              "completed preflight status agrees with the version, chain and identifier results")
        result = {"fixtureChecks": len(policy["checks"]), "returnedResultChecks": checks,
                  "preflight": report, "preflightContractPassed": True, "adapterAccepted": False}
        (OUTPUT / "report.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"fixtureChecks": len(policy["checks"]), "returnedResultChecks": len(checks),
                          "preflightContractPassed": True, "adapterAccepted": False,
                          "status": report["status"], "report": str(OUTPUT / "report.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
