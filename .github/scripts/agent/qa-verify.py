#!/usr/bin/env python3
"""Re-runs the reproduction tests of the QA agent's `bug` and `spec` deviation findings and records, per finding key, whether one of
its own test functions failed. Groups in the same Ballerina test package run in a single `bal test` invocation.

Env: PR. Reads agent-output/result.json; writes agent-output/repro.json and agent-output/repro-<pkg>.log.
"""
import collections
import json
import os
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

PR = os.environ["PR"]
OUT = Path("agent-output")
RUNNER = ".github/scripts/run-tests.sh"
JAVA_RESULTS = {"native": "native/build/test-results/test",
                "compiler-plugin": "compiler-plugin-tests/build/test-results/test"}


def trim(message):
    message = re.sub(r"\n\s*callableName:[\s\S]*$", "", message or "")
    return message[:500]


def run(args, log):
    with open(log, "w") as fh:
        subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT, check=False)
    return " ".join(args)


def bal_statuses(report):
    """Maps test function name -> (status, failureMessage) from a Ballerina test_results.json."""
    statuses = {}

    def walk(node):
        if isinstance(node, dict):
            if isinstance(node.get("name"), str) and node.get("status") in ("PASSED", "FAILURE", "SKIPPED"):
                statuses[node["name"]] = (node["status"], node.get("failureMessage", ""))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(json.loads(report.read_text()))
    return statuses


def java_statuses(results_dir):
    statuses = {}
    for xml_file in Path(results_dir).glob("*.xml"):
        for case in ET.parse(xml_file).getroot().iter("testcase"):
            failure = case.find("failure")
            if failure is None:
                failure = case.find("error")
            status = "FAILURE" if failure is not None else "PASSED"
            statuses[case.get("name")] = (status, failure.get("message", "") if failure is not None else "")
    return statuses


def outcome(functions, statuses, command):
    found = {}
    for fn in functions:
        for name, value in statuses.items():
            if name == fn or name.startswith(fn + "#"):
                found[name] = value
    if not found:
        return {"status": "not-run", "reason": "None of the reproduction's test functions ran", "command": command}
    failed = [(name, msg) for name, (status, msg) in found.items() if status == "FAILURE"]
    if failed:
        return {"status": "reproduced", "reason": f"{len(failed)} of {len(found)} test(s) failed",
                "command": command, "message": trim(failed[0][1])}
    return {"status": "not-reproduced", "reason": f"All {len(found)} test(s) passed", "command": command}


def main():
    result = json.loads((OUT / "result.json").read_text())
    results = {}
    by_package = collections.defaultdict(list)

    for finding in result.get("findings", []):
        if not (finding.get("kind") == "bug"
                or (finding.get("kind") == "spec" and finding.get("spec_case") == "deviation")):
            continue
        key, repro = finding["key"], finding.get("repro")
        if not repro:
            results[key] = {"status": "not-run", "reason": "No reproduction was provided"}
            continue
        package, group = repro["test_package"], repro["group"]
        functions = re.findall(r"function\s+([A-Za-z_]\w*)\s*\(", repro["test_code"])
        if not re.fullmatch(rf"qa_{PR}_\d+", group):
            results[key] = {"status": "not-run", "reason": f"Invalid group {group}"}
        elif not functions:
            results[key] = {"status": "not-run", "reason": "No test function in test_code"}
        elif package in JAVA_RESULTS:
            test_filter = repro.get("test_filter", "")
            if not re.fullmatch(r"[A-Za-z0-9_.*]+", test_filter):
                results[key] = {"status": "not-run", "reason": "A Java reproduction needs a test_filter"}
            else:
                by_package[package].append((key, group, functions, test_filter))
        elif re.fullmatch(r"[a-z0-9-]+", package) and Path("ballerina-tests", package, "tests").is_dir():
            by_package[package].append((key, group, functions, None))
        else:
            results[key] = {"status": "not-run", "reason": f"Unknown test package {package}"}

    for package, items in by_package.items():
        if package in JAVA_RESULTS:
            for key, _group, functions, test_filter in items:
                shutil.rmtree(JAVA_RESULTS[package], ignore_errors=True)
                command = run([RUNNER, package, test_filter], OUT / f"repro-{package}-{key}.log")
                results[key] = outcome(functions, java_statuses(JAVA_RESULTS[package]), command)
            continue
        report_dir = Path("ballerina-tests", package, "target", "report")
        shutil.rmtree(report_dir, ignore_errors=True)
        groups = ",".join(sorted({group for _key, group, _fns, _f in items}))
        command = run([RUNNER, "bal", package, groups], OUT / f"repro-{package}.log")
        report = report_dir / "test_results.json"
        statuses = bal_statuses(report) if report.exists() else {}
        for key, _group, functions, _f in items:
            if not statuses:
                results[key] = {"status": "not-run", "reason": "No test report was produced (compilation failure?)",
                                "command": command}
            else:
                results[key] = outcome(functions, statuses, command)

    (OUT / "repro.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
