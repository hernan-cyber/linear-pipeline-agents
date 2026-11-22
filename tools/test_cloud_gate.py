#!/usr/bin/env python3
"""Exercise real gates while aborting any attempt to enter a live script body."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINTS = ("setup.sh", "start.sh", "scripts/pipeline-driver.sh", "scripts/pipeline-watch.sh")
BASH = "/bin/bash"
WRAPPER = r'''
qa_entrypoint=$1
qa_guard_end=$2
qa_log=$3
set -T
trap 'if [[ ${BASH_SOURCE[0]:-} == "$qa_entrypoint" && $LINENO -gt "$qa_guard_end" ]]; then printf "%s\n" "downstream attempted" > "$qa_log"; exit 97; fi' DEBUG
source "$qa_entrypoint"
'''


class LiveGateTests(unittest.TestCase):
    def test_real_entrypoints_stay_inert(self):
        for name in ENTRYPOINTS:
            path = ROOT / name
            lines = path.read_text().splitlines()
            gate_end = lines.index("# End live-operation gate.") + 1
            for value in (None, "", "0", "false", "yes", "01"):
                with self.subTest(entrypoint=name, opt_in=value), tempfile.TemporaryDirectory() as tmp:
                    log = Path(tmp) / "downstream.log"
                    env = {"PATH": tmp, "LC_ALL": "C"}
                    if value is not None:
                        env["LINEAR_PIPELINE_ENABLE_LIVE"] = value
                    result = subprocess.run([BASH, "--noprofile", "--norc", "-c", WRAPPER,
                                             "gate-test", str(path), str(gate_end), str(log)],
                                            cwd=tmp, env=env, capture_output=True, text=True, timeout=3)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("Live pipeline disabled.", result.stdout)
                    self.assertEqual(result.stderr, "")
                    self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_explicit_opt_in_only_reaches_fixture_body(self):
        for name in ENTRYPOINTS:
            lines = (ROOT / name).read_text().splitlines()
            gate_end = lines.index("# End live-operation gate.") + 1
            prefix = "\n".join(lines[:gate_end]) + "\n"
            with self.subTest(entrypoint=name), tempfile.TemporaryDirectory() as tmp:
                fixture = Path(tmp) / "entrypoint.sh"
                fixture.write_text(prefix + "printf '%s\\n' 'fixture body reached'\n")
                result = subprocess.run([BASH, "--noprofile", "--norc", str(fixture)],
                                        cwd=tmp, env={"PATH": tmp, "LC_ALL": "C",
                                                      "LINEAR_PIPELINE_ENABLE_LIVE": "1"},
                                        capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "fixture body reached\n")
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
