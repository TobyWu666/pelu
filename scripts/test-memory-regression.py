#!/usr/bin/env python3
"""Measure Codex JSONL reads using synthetic data, never the user's sessions.

Run normally to check the fixed reader, or pass --baseline-ref d31f831 to
measure the original shipping reader against exactly the same workload.
Requires a macOS Swift toolchain; all generated files live in a temp directory.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    parser.add_argument("--megabytes", type=int, default=32)
    parser.add_argument("--iterations", type=int, default=6)
    parser.add_argument("--max-memory-mb", type=int, default=256)
    args = parser.parse_args()
    if min(args.megabytes, args.iterations, args.max_memory_mb) <= 0:
        parser.error("All numeric options must be positive")

    root = pathlib.Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="pelu-memory-regression-") as scratch:
        scratch = pathlib.Path(scratch)
        codex = scratch / "codex"
        today = datetime.datetime.now()
        directory = codex / "sessions" / today.strftime("%Y/%m/%d")
        directory.mkdir(parents=True)
        fixture = directory / "rollout-synthetic.jsonl"
        timestamp = "2026-10-12T00:00:00.000Z"
        unrelated = json.dumps({"type": "response_item", "payload": {"text": "x" * 32768}}).encode() + b"\n"
        event = json.dumps({"timestamp": timestamp, "type": "event_msg", "payload": {
            "type": "token_count", "info": {"total_token_usage": {
                "input_tokens": 123456, "cached_input_tokens": 12300, "output_tokens": 42
            }}
        }}).encode() + b"\n"
        with fixture.open("wb") as handle:
            while handle.tell() < args.megabytes * 1024 * 1024:
                handle.write(unrelated)
                handle.write(event)

        core_sources = sorted((root / "Sources" / "PeluCore").glob("*.swift"))
        subprocess.run([
            "swiftc", "-parse-as-library", "-emit-library", "-emit-module", "-O", "-swift-version", "6",
            "-module-name", "PeluCore", "-module-cache-path", str(scratch / "module-cache"),
            "-emit-module-path", str(scratch / "PeluCore.swiftmodule"),
            "-o", str(scratch / "libPeluCore.dylib"), *map(str, core_sources),
        ], check=True)

        additional_sources = []
        reader_name = "CodexJSONLReader"
        if args.baseline_ref:
            original = subprocess.run([
                "git", "show", args.baseline_ref + ":Apps/PeluMac/PeluMacApp.swift"
            ], cwd=root, text=True, capture_output=True, check=True).stdout
            original = original[original.index("struct CodexJSONLReader {"):original.index("// MARK: - UsageMonitor")]
            original = original.replace("CodexJSONLReader", "BaselineCodexJSONLReader")
            original = original.replace(
                'init() {\n        codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")\n    }',
                'init(codexDirectory: URL) { codexDir = codexDirectory }',
            )
            if "homeDirectoryForCurrentUser" in original:
                raise RuntimeError("Baseline reader must only use the synthetic fixture directory")
            legacy = scratch / "BaselineReader.swift"
            legacy.write_text("import Foundation\nimport PeluCore\n" + original)
            additional_sources.append(str(legacy))
            reader_name = "BaselineCodexJSONLReader"

        probe = scratch / "Probe.swift"
        probe.write_text("""import Foundation
import PeluCore
@main struct Probe {
    static func main() {
        let reader = READER(codexDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
        let iterations = Int(CommandLine.arguments[2])!
        autoreleasepool {
            for _ in 0..<iterations {
                guard let usage = reader.summedTokenUsage(),
                      usage.inputTokens == 123456,
                      usage.cachedInputTokens == 12300,
                      usage.outputTokens == 42 else {
                    fatalError("Synthetic token total changed")
                }
            }
        }
        print("Synthetic token totals verified")
    }
}
""".replace("READER", reader_name))
        binary = scratch / "Probe"
        subprocess.run([
            "swiftc", "-parse-as-library", "-O", "-swift-version", "6",
            "-module-cache-path", str(scratch / "module-cache"), "-I", str(scratch),
            "-L", str(scratch), "-lPeluCore", "-Xlinker", "-rpath", "-Xlinker", str(scratch),
            *additional_sources, str(probe), "-o", str(binary),
        ], check=True)
        measured = subprocess.run([
            "/usr/bin/time", "-l", str(binary), str(codex), str(args.iterations)
        ], text=True, capture_output=True, timeout=120)
        if measured.returncode:
            raise RuntimeError(measured.stdout + measured.stderr)
        resident = re.search(r"(\d+)\s+maximum resident set size", measured.stderr)
        footprint = re.search(r"(\d+)\s+peak memory footprint", measured.stderr)
        if not resident:
            raise RuntimeError("No macOS peak memory measurement: " + measured.stderr)
        peak = max(int(resident.group(1)), int(footprint.group(1)) if footprint else 0)
        result = {
            "reader": "baseline:" + args.baseline_ref if args.baseline_ref else "fixed",
            "fixture_bytes": fixture.stat().st_size,
            "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
            "iterations": args.iterations,
            "peak_bytes": peak,
            "memory_limit_bytes": args.max_memory_mb * 1024 * 1024,
            "token_totals_verified": True,
            "memory_limit_passed": peak <= args.max_memory_mb * 1024 * 1024,
        }
        print(json.dumps(result, indent=2))
        return 0 if result["memory_limit_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
