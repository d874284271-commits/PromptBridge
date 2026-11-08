#!/usr/bin/env python3
"""Send an explicit native acceptance command and print its fresh result (stdlib only)."""

import argparse
import json
from pathlib import Path
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("action", choices=["capture", "capture-full", "generate", "copy", "fill", "restore",
                                       "show-launcher", "show-current", "focus-mode", "persistent-mode", "state", "quit", "translate", "auto-on", "auto-off", "edit-output"])
parser.add_argument("--until", choices=["ready", "blocked", "returned", "filled", "restored"])
parser.add_argument("--save", type=Path)
args = parser.parse_args()
deadline = time.monotonic() + 10


def request(action):
    command = {"id": str(uuid.uuid4()), "action": action}
    ledger = args.directory / "commands"
    ledger.mkdir(exist_ok=True)
    with (ledger / (command["id"] + ".json")).open("x") as evidence:
        evidence.write(json.dumps(command) + "\n")
    temporary = args.directory / "command.pending"
    temporary.write_text(json.dumps(command))
    temporary.replace(args.directory / "command.json")
    while time.monotonic() < deadline:
        try:
            result = json.loads((args.directory / "result.json").read_text())
            if result.get("id", "").lower() == command["id"]:
                return result
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    raise TimeoutError("No matching native acceptance result within 10 seconds; requestID=" + command["id"])


result = request(args.action)
while args.until and result["succeeded"]:
    completed = (args.until in ("ready", "blocked") and result["phase"] == args.until) or (
        args.until == "returned" and result.get("copyReturnSucceeded") is not None) or (
        args.until == "filled" and not result.get("busy") and (result.get("replacementReceiptVerified")
                                   or result["phase"] in ("blocked", "failed"))) or (
        args.until == "restored" and result.get("restoreSucceeded") is not None)
    if completed:
        break
    if time.monotonic() >= deadline:
        raise TimeoutError("Native acceptance did not reach " + args.until)
    time.sleep(0.1)
    result = request("state")
output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
if args.save:
    args.save.parent.mkdir(parents=True, exist_ok=True)
    args.save.write_text(output)
print(output, end="")
if not result["succeeded"] or (args.until == "returned" and not result.get("copyReturnSucceeded")) or (
        args.until == "filled" and not result.get("replacementReceiptVerified")) or (
        args.until == "restored" and not result.get("restoreSucceeded")):
    raise SystemExit(1)
