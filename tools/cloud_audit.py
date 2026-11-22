#!/usr/bin/env python3
"""Offline source inspection only; never execute the legacy pipeline."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINTS = ("setup.sh", "start.sh", "scripts/pipeline-driver.sh", "scripts/pipeline-watch.sh")
SIGNALS = {
    "direct_linear_api": "https://api.linear.app/graphql",
    "permission_bypass": "--dangerously-skip-permissions",
    "polling_loop": "while true",
    "repository_push": "git push",
}


def audit():
    files, findings = [], []
    for name in ENTRYPOINTS:
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("Expected regular source file: " + name)
        raw = path.read_bytes()
        lines = raw.decode("utf-8").splitlines()
        gate_end = lines.index("# End live-operation gate.")
        files.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest(),
                      "live_gate_end_line": gate_end + 1})
        for number, line in enumerate(lines, 1):
            for signal, needle in SIGNALS.items():
                if needle in line:
                    findings.append({"path": name, "line": number, "signal": signal,
                                     "scope": "legacy live body behind explicit opt-in"})
    return {"schema_version": 1, "mode": "static_source_inspection",
            "files": files, "findings": findings, "executed_pipeline": False,
            "product_readiness_proven": False}


if __name__ == "__main__":
    try:
        print(json.dumps(audit(), indent=2))
    except (OSError, UnicodeError, ValueError) as error:
        print(json.dumps({"mode": "static_source_inspection", "outcome": "blocked",
                          "reason": str(error), "product_readiness_proven": False}))
        raise SystemExit(1)
