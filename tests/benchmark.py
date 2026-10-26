"""Measure whole-process local prediction latency. Model/network time is excluded."""
import json
import math
import os
import re
from pathlib import Path
import statistics
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
binary = root / "zig-out/bin" / ("shell-buddy.exe" if os.name == "nt" else "shell-buddy")
with tempfile.TemporaryDirectory(prefix="shell-buddy-benchmark-") as directory:
    env = os.environ.copy()
    env["SHELL_BUDDY_CONFIG"] = str(Path(directory) / "config.json")
    env["SHELL_BUDDY_CACHE"] = str(Path(directory) / "cache.json")
    env["SHELL_BUDDY_BIN"] = str(binary)
    command = [str(binary), "suggest", "--shell", "zsh", "--intent", "创建 hello.txt 文件"]
    samples = []
    for i in range(105):
        start = time.perf_counter_ns()
        result = subprocess.run(command, env=env, cwd=directory, capture_output=True, check=True)
        elapsed = (time.perf_counter_ns() - start) / 1_000_000
        assert result.stdout.strip() == b"touch './hello.txt'"
        if i >= 5:
            samples.append(elapsed)
    report = {"binary_bytes": binary.stat().st_size, "samples": len(samples),
              "median_ms": round(statistics.median(samples), 3),
              "p95_ms": round(sorted(samples)[94], 3)}
    if os.name != "nt":
        from integration import Session
        latencies = []
        for i in range(25):
            start = time.perf_counter_ns()
            session = Session([str(binary), "edit", "--shell", "zsh", "--initial", "// 创建 hello.txt 文件"], env, directory)
            try:
                session.wait_for("touch")
                elapsed = (time.perf_counter_ns() - start) / 1_000_000
                session.send(b"\x03")
                assert session.result() == (20, "")
                if i >= 5:
                    latencies.append(elapsed)
            finally:
                session.close()
        report["tty_ready_p95_ms"] = round(sorted(latencies)[math.ceil(len(latencies) * .95) - 1], 3)
        if shutil.which("zsh"):
            native = Session([shutil.which("zsh"), "-f", "-i"], env, directory)
            try:
                native.send('PROMPT="BENCH> "\neval "$("$SHELL_BUDDY_BIN" init zsh)"\nprintf \'%s%s\\n\' BENCH _READY >&2\n')
                native.wait_for("BENCH_READY")
                native.wait_screen(lambda screen: screen.display[screen.y] == "BENCH>")
                inline_latencies = []
                for i in range(25):
                    start = time.perf_counter_ns()
                    native.send("//当前路径")
                    native.wait_for("\x1b[0mpwd")
                    elapsed = (time.perf_counter_ns() - start) / 1_000_000
                    native.send(b"\x03")
                    native.wait_screen(lambda screen: screen.display[screen.y] == "BENCH>")
                    if i >= 5:
                        inline_latencies.append(elapsed)
                report["shell_inline_p95_ms"] = round(sorted(inline_latencies)[math.ceil(len(inline_latencies) * .95) - 1], 3)
                native.send("exit\n")
                assert native.result()[0] == 0
            finally:
                native.close()
        session = Session([str(binary), "edit", "--shell", "zsh", "--initial", "// 创建 hello.txt 文件"], env, directory)
        try:
            session.wait_for("touch")
            session.send(b"\r")
            assert session.result()[0] == 0
        finally:
            session.close()
        cache_path = Path(env["SHELL_BUDDY_CACHE"])
        record = json.loads(cache_path.read_text())[0]
        record["command"] = "printf '%s' 'cached'"
        fixture = [{"key": f"{i:064x}", "command": "printf '%s' '" + "x" * 4000 + "'"}
                   for i in range(255)] + [record]
        cache_path.write_text(json.dumps(fixture))
        cached = []
        for i in range(55):
            start = time.perf_counter_ns()
            result = subprocess.run(command, env=env, cwd=directory, capture_output=True, check=True)
            elapsed = (time.perf_counter_ns() - start) / 1_000_000
            assert result.stdout.strip() == b"printf '%s' 'cached'"
            if i >= 5:
                cached.append(elapsed)
        report["cache_entries"] = 256
        report["cache_p95_ms"] = round(sorted(cached)[math.ceil(len(cached) * .95) - 1], 3)
        if Path("/usr/bin/time").exists():
            options = ["-l"] if sys.platform == "darwin" else ["-f", "SHELL_BUDDY_RSS_KB=%M"]
            session = Session(["/usr/bin/time", *options, str(binary), "edit", "--shell", "zsh", "--initial", "// 当前路径"], env, directory)
            try:
                session.wait_for("pwd")
                session.send(b"\x03")
                assert session.result()[0] == 20
                pattern = rb"(\d+)\s+maximum resident set size" if sys.platform == "darwin" else rb"SHELL_BUDDY_RSS_KB=(\d+)"
                if match := re.search(pattern, session.log):
                    report["tty_peak_rss_bytes"] = int(match[1]) * (1 if sys.platform == "darwin" else 1024)
            finally:
                session.close()
    print(json.dumps(report, indent=2))
    if report["binary_bytes"] > 5 * 1024 * 1024:
        raise SystemExit("Binary size exceeds the 5 MiB budget")
