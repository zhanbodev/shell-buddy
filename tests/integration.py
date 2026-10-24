"""Offline integration checks. No model installation or real API key is needed."""
import contextlib
import gzip
import http.server
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("SHELL_BUDDY_TEST_BIN", ROOT / "zig-out/bin/shell-buddy")).resolve()
if os.name == "nt" and not BINARY.exists():
    BINARY = BINARY.with_suffix(".exe")


class Handler(http.server.BaseHTTPRequestHandler):
    requests = []
    authorizations = []
    accept_encodings = []
    target = ""

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(body)
        type(self).authorizations.append(self.headers.get("Authorization"))
        type(self).accept_encodings.append(self.headers.get("Accept-Encoding"))
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        mode = body["model"]
        if body.get("reasoning_effort") != "none":
            self.send_error(400, "Non-thinking mode must be explicit")
            return
        if mode.startswith("http-"):
            self.send_error(int(mode[5:]))
            return
        if mode in ("auth", "rate"):
            self.send_error(401 if mode == "auth" else 429)
            return
        if mode in ("negotiate-compression", "force-compression"):
            wire = ("data: " + json.dumps({"choices": [{"delta": {"content": "printf '%s\\n' '你好'"},
                                                         "finish_reason": "stop"}]}, ensure_ascii=False) + "\n\n").encode()
            compressed = mode == "force-compression" or "gzip" in self.headers.get("Accept-Encoding", "")
            if compressed:
                wire = gzip.compress(wire)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            if compressed:
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                for start in range(0, len(wire), 7):
                    self.wfile.write(wire[start:start + 7])
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        if mode == "disconnect":
            self.send_header("Content-Length", "1048576")
        self.end_headers()
        self.close_connection = True

        def event(content=None, reason=None):
            data = {"choices": [{"delta": {"content": content}, "finish_reason": reason}]}
            # Deliberately fragment UTF-8 and SSE boundaries across TCP writes.
            wire = ("data: " + json.dumps(data, ensure_ascii=False) + "\r\n\r\n").encode()
            for start in range(0, len(wire), 7):
                self.wfile.write(wire[start:start + 7])
                self.wfile.flush()

        try:
            if mode == "timeout":
                time.sleep(1.5)
            elif mode == "bad":
                event("echo \u001b[2J", "stop")
            elif mode == "length":
                event("echo incomplete", "length")
            elif mode == "truncated":
                event("touch ")
            elif mode == "disconnect":
                event("touch ")
            elif mode == "done-without-stop":
                self.wfile.write(b"data: [DONE]\n\n")
            elif mode == "thinking":
                self.wfile.write(b'data: {"choices":[{"delta":{"reasoning_content":"private reasoning"}}]}\n\n')
            elif mode == "filtered":
                event(None, "content_filter")
            elif mode == "empty":
                event(None, "stop")
            elif mode == "refused":
                self.wfile.write(b'data: {"choices":[{"delta":{"refusal":"declined"}}]}\n\n')
            elif mode == "tool":
                event(None, "tool_calls")
            elif mode == "stream-error":
                self.wfile.write(b'data: {"error":{"message":"private provider error"}}\n\n')
            elif mode == "slow":
                event("touch ")
                time.sleep(0.5)
                event("'完整结果.txt'", "stop")
            elif mode == "cd":
                system = body["messages"][0]["content"]
                path = type(self).target
                event(("Set-Location -LiteralPath '" + path.replace("'", "''") + "'") if "powershell" in system else ("cd '" + path.replace("'", "'\\''") + "'"), "stop")
            else:
                event("printf ")
                event("'%s\\n' '你好'", "stop")
                self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shell-buddy-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env.update({
            "SHELL_BUDDY_CONFIG": str(self.directory / "config.json"),
            "SHELL_BUDDY_CACHE": str(self.directory / "cache.json"),
            "SHELL_BUDDY_BIN": str(BINARY),
            "HISTFILE": os.devnull,
            "TERM": "xterm-256color",
        })
        # Test runs must never inherit a developer's live API credential.
        self.env.pop("SHELL_BUDDY_API_KEY", None)

    def configure(self, mode="normal", timeout=2000):
        self.directory.joinpath("config.json").write_text(json.dumps({
            "default": "local",
            "profiles": {"local": {"base_url": f"http://127.0.0.1:{self.server.server_port}/v1", "model": mode}},
            "timeout_ms": timeout,
            "debounce_ms": 20,
        }))

    def run_cli(self, *args):
        return subprocess.run([str(BINARY), *args], env=self.env, cwd=self.directory,
                              text=True, capture_output=True, timeout=5, encoding="utf-8")


class CLI(Base):
    def test_init_help_and_invalid_api_key_env_never_expose_a_key(self):
        result = self.run_cli("init", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("credentials.json", result.stdout)
        self.assertIn("init", self.run_cli("--help").stdout)
        self.assertNotIn("onboard", self.run_cli("--help").stdout)
        self.assertNotEqual(self.run_cli("onboard").returncode, 0)
        self.configure()
        path = self.directory / "config.json"
        value = json.loads(path.read_text())
        value["profiles"]["local"]["api_key_env"] = "dummy-misplaced-secret"
        path.write_text(json.dumps(value))
        result = self.run_cli("doctor")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("environment variable name", result.stdout)
        self.assertNotIn("dummy-misplaced-secret", result.stdout + result.stderr)

    def test_saved_credentials_are_profile_scoped_and_environment_takes_priority(self):
        self.configure()
        path = self.directory / "config.json"
        value = json.loads(path.read_text())
        value["profiles"]["local"]["api_key_env"] = "SHELL_BUDDY_API_KEY"
        path.write_text(json.dumps(value))
        store = self.directory / "credentials.json"
        store.write_text(json.dumps({"cloud": "dummy-other-profile"}))
        args = ("suggest", "--shell", "bash", "--intent", "测试", "--generate")
        result = self.run_cli(*args)
        self.assertIn("MissingApiKey", result.stderr)
        store.write_text(json.dumps({"local": "dummy-saved-key", "cloud": "dummy-other-profile"}))
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.authorizations[-1], "Bearer dummy-saved-key")
        self.env["SHELL_BUDDY_API_KEY"] = "dummy-environment-key"
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.authorizations[-1], "Bearer dummy-environment-key")
        self.env["SHELL_BUDDY_API_KEY"] = "dummy-key\r\nInjected: header"
        result = self.run_cli(*args)
        self.assertIn("InvalidApiKey", result.stderr)
        for key in ("dummy-saved-key", "dummy-environment-key", "dummy-other-profile", "Injected"):
            self.assertNotIn(key, result.stdout + result.stderr + self.run_cli("doctor").stdout)

    def test_invalid_credentials_fail_closed_but_rules_still_work(self):
        self.configure()
        for content in ("{broken", '[]', '{"local": "bad\\nkey"}', '{"local": 123}'):
            with self.subTest(content=content):
                self.directory.joinpath("credentials.json").write_text(content)
                result = self.run_cli("suggest", "--shell", "bash", "--intent", "测试", "--generate")
                self.assertIn("InvalidCredentialsFile", result.stderr)
                self.assertEqual(result.stdout, "")
                result = self.run_cli("suggest", "--shell", "bash", "--intent", "当前路径")
                self.assertEqual(result.stdout, "pwd\n")

    def test_rules_without_configuration(self):
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "创建hello.txt 文件")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "touch './hello.txt'")
        self.assertFalse(self.directory.joinpath("hello.txt").exists())

    def test_powershell_syntax(self):
        result = self.run_cli("suggest", "--shell", "powershell", "--intent", "创建 hello.txt 文件")
        self.assertEqual(result.stdout.strip(), "New-Item -ItemType File -Path 'hello.txt'")

    def test_streaming_unicode_and_endpoint(self):
        self.configure()
        result = self.run_cli("suggest", "--shell", "bash", "--intent", "测试流式", "--generate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "printf '%s\\n' '你好'")
        request = Handler.requests[-1]
        self.assertTrue(request["stream"])
        self.assertEqual(request["reasoning_effort"], "none")
        self.assertEqual(request["max_tokens"], 2048)
        self.assertIn(str(self.directory), request["messages"][0]["content"])
        self.assertFalse(self.directory.joinpath("cache.json").exists(), "Unconfirmed output must not be persisted")

    def test_failures_never_return_partial_command(self):
        for mode, error in (("truncated", "IncompleteStream"), ("length", "OutputLimitReached"),
                            ("disconnect", "StreamDisconnected"),
                            ("done-without-stop", "IncompleteStream"), ("thinking", "ThinkingNotDisabled"),
                            ("filtered", "ContentFiltered"), ("empty", "EmptyResponse"),
                            ("refused", "ModelRefused"), ("tool", "UnsupportedToolCall"),
                            ("stream-error", "ModelStreamError"),
                            ("bad", "InvalidCommand"), ("auth", "AuthenticationFailed"), ("rate", "RateLimited")):
            with self.subTest(mode=mode):
                self.configure(mode)
                result = self.run_cli("suggest", "--shell", "bash", "--intent", "测试", "--generate")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn(error, result.stderr)
                self.assertNotIn("private reasoning", result.stderr)
                self.assertNotIn("private provider error", result.stderr)

    def test_http_errors_are_classified_and_do_not_expose_provider_bodies(self):
        for status, category in ((400, "InvalidRequest"), (402, "InsufficientBalance"),
                                 (403, "PermissionDenied"), (404, "EndpointOrModelNotFound"),
                                 (408, "Timeout"), (413, "RequestTooLarge"), (422, "InvalidParameters"),
                                 (503, "ServiceUnavailable"), (504, "Timeout"), (307, "RedirectRejected")):
            with self.subTest(status=status):
                self.configure(f"http-{status}")
                result = self.run_cli("suggest", "--shell", "zsh", "--intent", "测试错误分类", "--generate")
                self.assertEqual(result.stdout, "")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(category, result.stderr)
                self.assertNotIn("<!DOCTYPE", result.stderr)

    def test_configured_output_budget_is_sent_and_invalid_values_do_not_reload(self):
        self.configure()
        path = self.directory / "config.json"
        document = json.loads(path.read_text())
        document["max_tokens"] = 4096
        path.write_text(json.dumps(document))
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "测试预算", "--generate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.requests[-1]["max_tokens"], 4096)
        self.assertEqual(Handler.requests[-1]["reasoning_effort"], "none")
        self.assertIn("max_tokens: 4096", self.run_cli("doctor").stdout)
        self.assertIn("thinking: disabled", self.run_cli("doctor").stdout)
        self.assertEqual(self.run_cli("start").returncode, 0)
        state = self.directory.joinpath("state.json").read_bytes()
        for value in (0, -1, 32769, True, None, "2048", 1.5):
            with self.subTest(value=value):
                document["max_tokens"] = value
                path.write_text(json.dumps(document))
                result = self.run_cli("restart")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("max_tokens", result.stderr)
                self.assertEqual(self.directory.joinpath("state.json").read_bytes(), state)

    def test_sse_requests_negotiate_only_supported_content_encoding(self):
        # A real service may compress whenever the client advertises gzip.
        self.configure("negotiate-compression")
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "测试压缩协商", "--generate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "printf '%s\\n' '你好'\n")
        self.assertEqual(Handler.accept_encodings[-1], "identity")

    def test_unrequested_compressed_response_never_becomes_a_command(self):
        self.configure("force-compression")
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "测试压缩响应", "--generate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedEncoding", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_timeout_cancels_blocked_network_read(self):
        self.configure("timeout", timeout=150)
        start = time.monotonic()
        result = self.run_cli("suggest", "--shell", "bash", "--intent", "测试", "--generate")
        self.assertIn("Timeout", result.stderr)
        self.assertLess(time.monotonic() - start, 1.0)

    def test_model_latency_reporting_is_separate_from_command_stdout(self):
        self.configure("slow")
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "流式测试", "--generate", "--timings")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "touch '完整结果.txt'")
        metrics = json.loads(result.stderr)
        self.assertGreaterEqual(metrics["first_token_ms"], 0)
        self.assertGreaterEqual(metrics["complete_ms"] - metrics["first_token_ms"], 400)

    def test_malformed_config_does_not_disable_rules(self):
        self.directory.joinpath("config.json").write_text("{broken")
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "当前路径")
        self.assertEqual(result.stdout.strip(), "pwd")

    def test_init_scripts_and_missing_provider(self):
        for shell in ("bash", "zsh", "powershell"):
            self.assertEqual(self.run_cli("init", shell).returncode, 0)
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "无法由规则处理")
        self.assertIn("NoModel", result.stderr)

    def test_restart_explains_unloaded_shell_integration(self):
        self.env.pop("SHELL_BUDDY_SHELL", None)
        self.env["SHELL"] = "/bin/zsh"
        result = self.run_cli("restart")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Shell integration is not loaded in this session", result.stdout)
        self.assertIn(str(BINARY), result.stdout)
        self.assertIn("Invoke-Expression" if os.name == "nt" else "init zsh)", result.stdout)
        self.env["SHELL_BUDDY_SHELL"] = "zsh"
        self.assertNotIn("Shell integration is not loaded", self.run_cli("restart").stdout)
        self.assertIn("shell integration: zsh", self.run_cli("doctor").stdout)

    def test_start_creates_home_config_without_overwriting_edits(self):
        self.env.pop("SHELL_BUDDY_CONFIG", None)
        self.env.pop("XDG_CONFIG_HOME", None)
        self.env["HOME"] = self.env["USERPROFILE"] = str(self.directory)
        path = self.directory / ".config/shell-buddy/config.json"
        result = self.run_cli("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(path), result.stdout)
        self.assertEqual(json.loads(path.read_text())["default"], "local")
        if os.name != "nt":
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        content = json.dumps({"active_profile": None, "timeout_ms": 3000})
        path.write_text(content)
        self.assertEqual(self.run_cli("restart").returncode, 0)
        self.assertEqual(path.read_text(), content)

    def test_xdg_directory_and_init_preserve_stopped_state(self):
        self.env.pop("SHELL_BUDDY_CONFIG", None)
        self.env["XDG_CONFIG_HOME"] = str(self.directory / "custom-config")
        path = self.directory / "custom-config/shell-buddy/config.json"
        self.assertEqual(self.run_cli("init", "zsh").returncode, 0)
        self.assertTrue(path.exists())
        self.assertEqual(self.run_cli("stop").returncode, 0)
        state = path.with_name("state.json").read_bytes()
        self.assertEqual(self.run_cli("init", "bash").returncode, 0)
        self.assertEqual(path.with_name("state.json").read_bytes(), state)

    def test_lifecycle_and_invalid_restart_preserve_previous_state(self):
        self.assertIn("enabled", self.run_cli("status").stdout)
        self.assertEqual(self.run_cli("stop").returncode, 0)
        self.assertIn("stopped", self.run_cli("status").stdout)
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "当前路径")
        self.assertIn("Stopped", result.stderr)
        self.assertEqual(result.stdout, "")
        result = self.run_cli("edit", "--shell", "zsh", "--initial", "// 当前路径")
        self.assertEqual((result.returncode, result.stdout), (20, "// 当前路径"))
        state_path = self.directory / "state.json"
        state = state_path.read_bytes()
        self.directory.joinpath("config.json").write_text("{broken")
        result = self.run_cli("restart")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JSON", result.stderr)
        self.assertEqual(state_path.read_bytes(), state)
        self.configure()
        self.assertEqual(self.run_cli("restart").returncode, 0)
        self.assertIn("enabled", self.run_cli("status").stdout)
        result = self.run_cli("suggest", "--shell", "zsh", "--intent", "当前路径")
        self.assertEqual(result.stdout.strip(), "pwd")
        self.assertEqual(self.run_cli("stop").returncode, 0)
        self.assertEqual(self.run_cli("start").returncode, 0)

    def test_restart_validates_timing_and_selected_profile(self):
        for value in ({"timeout_ms": 0}, {"debounce_ms": "fast"},
                      {"active_profile": "absent", "profiles": {}}, {"active_profile": "missing-profiles"}):
            with self.subTest(value=value):
                self.directory.joinpath("config.json").write_text(json.dumps(value))
                self.assertNotEqual(self.run_cli("restart").returncode, 0)
                self.assertFalse(self.directory.joinpath("state.json").exists())

    def test_concurrent_first_start_and_state_updates_are_atomic(self):
        processes = [subprocess.Popen([str(BINARY), "start"], env=self.env, cwd=self.directory,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(6)]
        for process in processes:
            _, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(json.loads(self.directory.joinpath("config.json").read_text())["default"], "local")
        state = json.loads(self.directory.joinpath("state.json").read_text())
        self.assertEqual(state, {"enabled": True, "revision": 6})

    def test_help_uses_english_descriptions_and_separate_profile_entries(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("usage: shell-buddy <command>"))
        self.assertTrue(result.stdout.isascii())
        for args in (("llm",), ("llm", "--help")):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("  - local  Use the local model service\n", result.stdout)
            self.assertIn("  - cloud  Use the cloud model service\n", result.stdout)
            self.assertNotIn("local|cloud", result.stdout)
            self.assertNotIn("local | cloud", result.stdout)
            self.assertTrue(result.stdout.isascii())

    def test_llm_selection_persists_preserves_fields_and_stopped_state(self):
        self.configure()
        path = self.directory / "config.json"
        document = json.loads(path.read_text())
        document["profiles"]["cloud"] = {"base_url": f"http://127.0.0.1:{self.server.server_port}/v1", "model": "slow"}
        document["custom"] = {"keep": "unchanged"}
        document["active_profile"] = "unused-legacy-value"
        path.write_text(json.dumps(document))
        self.assertEqual(self.run_cli("stop").returncode, 0)
        result = self.run_cli("llm", "cloud")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "LLM profile: cloud\n")
        updated = json.loads(path.read_text())
        self.assertEqual(updated["default"], "cloud")
        self.assertEqual(updated["profiles"], document["profiles"])
        self.assertEqual(updated["custom"], document["custom"])
        self.assertNotIn("active_profile", updated)
        self.assertIn("stopped", self.run_cli("status").stdout)
        self.assertIn("LLM profile: cloud", self.run_cli("llm").stdout)
        self.assertEqual(self.run_cli("llm", "local").stdout, "LLM profile: local\n")
        self.assertEqual(json.loads(path.read_text())["default"], "local")
        if os.name != "nt":
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_invalid_llm_selection_does_not_modify_config_or_state(self):
        self.configure()
        self.assertEqual(self.run_cli("start").returncode, 0)
        path = self.directory / "config.json"
        state_path = self.directory / "state.json"
        original, state = path.read_bytes(), state_path.read_bytes()
        for profile in ("unknown", "cloud"):
            result = self.run_cli("llm", profile)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(result.stderr.isascii())
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(state_path.read_bytes(), state)
        path.write_text("{broken")
        self.assertNotEqual(self.run_cli("llm", "local").returncode, 0)
        self.assertEqual(path.read_text(), "{broken")
        self.assertEqual(state_path.read_bytes(), state)

    def test_default_selection_validation_and_legacy_configuration(self):
        for value in (None, "unknown", 1, False):
            self.directory.joinpath("config.json").write_text(json.dumps({"default": value}))
            result = self.run_cli("restart")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("default must be 'local' or 'cloud'", result.stderr)
        self.configure()
        path = self.directory / "config.json"
        document = json.loads(path.read_text())
        document["active_profile"] = document.pop("default")
        path.write_text(json.dumps(document))
        self.assertEqual(self.run_cli("llm").stdout.splitlines()[0], "LLM profile: local")
        self.assertEqual(self.run_cli("llm", "local").returncode, 0)
        self.assertEqual(json.loads(path.read_text())["default"], "local")

    def test_concurrent_llm_switches_keep_valid_configuration(self):
        self.assertEqual(self.run_cli("stop").returncode, 0)
        processes = [subprocess.Popen([str(BINARY), "llm", profile], env=self.env, cwd=self.directory,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for profile in ("cloud", "local") * 3]
        for process in processes:
            _, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
        document = json.loads(self.directory.joinpath("config.json").read_text())
        self.assertIn(document["default"], ("local", "cloud"))
        self.assertEqual(set(document["profiles"]), {"local", "cloud"})
        state = json.loads(self.directory.joinpath("state.json").read_text())
        self.assertEqual(state, {"enabled": False, "revision": 7})

    def test_stop_and_restart_cancel_inflight_cli_requests(self):
        for command, error in (("stop", "Stopped"), ("restart", "ConfigurationReloaded")):
            with self.subTest(command=command):
                self.configure("timeout")
                self.assertEqual(self.run_cli("start").returncode, 0)
                count = len(Handler.requests)
                process = subprocess.Popen([str(BINARY), "suggest", "--shell", "zsh", "--intent", "测试", "--generate"],
                                           env=self.env, cwd=self.directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 2
                    while len(Handler.requests) == count and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertGreater(len(Handler.requests), count)
                    self.assertEqual(self.run_cli(command).returncode, 0)
                    stdout, stderr = process.communicate(timeout=1)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertEqual(stdout, b"")
                    self.assertIn(error.encode(), stderr)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()


if os.name != "nt":
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios
    from terminal_screen import Screen

    class Session:
        def __init__(self, argv, env, cwd):
            self.master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            self.original = termios.tcgetattr(self.master)
            self.read_fd, write_fd = os.pipe()
            self.pid = os.fork()
            if self.pid == 0:
                try:
                    os.setsid()
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                    os.dup2(slave, 0)
                    os.dup2(write_fd, 1)
                    os.dup2(slave, 2)
                    for fd in (self.master, slave, self.read_fd, write_fd):
                        if fd > 2:
                            os.close(fd)
                    os.chdir(cwd)
                    os.execvpe(argv[0], argv, env)
                except BaseException as error:
                    os.write(2, str(error).encode())
                    os._exit(125)
            os.close(slave)
            os.close(write_fd)
            self.log = b""
            self.status = None
            self.screen = Screen()

        def record(self, data):
            self.log += data
            rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(self.master, termios.TIOCGWINSZ, b"\0" * 8))
            if columns >= 10 and rows and (columns, rows) != (self.screen.columns, self.screen.rows):
                self.screen.resize(columns, rows)
            response = self.screen.feed(data)
            if response:
                os.write(self.master, response)

        def send(self, value):
            os.write(self.master, value.encode() if isinstance(value, str) else value)

        def wait_for(self, value, timeout=3):
            value = value.encode() if isinstance(value, str) else value
            start = len(self.log)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if value in self.log[start:]:
                    return
                ready, _, _ = select.select([self.master], [], [], 0.05)
                if ready:
                    try:
                        data = os.read(self.master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    self.record(data)
            raise AssertionError(f"Did not receive {value!r}; terminal tail: {self.log[-2000:]!r}")

        def wait_screen(self, predicate, timeout=3):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate(self.screen):
                    return
                if select.select([self.master], [], [], 0.01)[0]:
                    self.record(os.read(self.master, 65536))
            raise AssertionError(f"Screen condition not met: {self.screen.display!r}")

        def result(self, timeout=4):
            deadline = time.monotonic() + timeout
            while self.status is None and time.monotonic() < deadline:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
                if pid:
                    self.status = status
                    break
                ready, _, _ = select.select([self.master], [], [], 0.01)
                if ready:
                    with contextlib.suppress(OSError):
                        self.record(os.read(self.master, 65536))
            if self.status is None:
                raise AssertionError(f"Terminal child did not exit; terminal tail: {self.log[-2000:]!r}")
            while select.select([self.master], [], [], 0)[0]:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                self.record(data)
            chunks = []
            while chunk := os.read(self.read_fd, 65536):
                chunks.append(chunk)
            return os.waitstatus_to_exitcode(self.status), b"".join(chunks).decode()

        def close(self):
            if self.status is None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(self.pid, signal.SIGKILL)
            os.close(self.master)
            os.close(self.read_fd)
            if self.status is None:
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline:
                    try:
                        if os.waitpid(self.pid, os.WNOHANG)[0]:
                            break
                    except ChildProcessError:
                        break
                    time.sleep(0.01)

    class SetupTests(Base):
        def start_setup(self):
            session = Session([str(BINARY), "init"], self.env, self.directory)
            self.addCleanup(session.close)
            session.wait_for("Profile: ")
            return session

        def cloud_key_step(self, session):
            session.send("\t\r")
            session.wait_for("Base URL: ")
            session.send(f"http://127.0.0.1:{self.server.server_port}/v1\r")
            session.wait_for("Model: ")
            session.send("normal\r")
            session.wait_for("API key (hidden, required): ")

        def test_local_setup_creates_private_config_and_preserves_terminal(self):
            path = self.directory / ".config/shell-buddy/config.json"
            self.env["SHELL_BUDDY_CONFIG"] = str(path)
            session = self.start_setup()
            session.send("\r")
            session.wait_for("Base URL: ")
            session.send("\r")
            session.wait_for("Model: ")
            session.send("test-model:latest\r")
            session.wait_for("API key (hidden, optional): ")
            session.send("\r")
            self.assertEqual(session.result(), (0, ""))
            self.assertEqual(termios.tcgetattr(session.master), session.original)
            value = json.loads(path.read_text())
            self.assertEqual(value["default"], "local")
            self.assertEqual(value["max_tokens"], 2048)
            self.assertEqual(value["profiles"]["local"]["model"], "test-model:latest")
            self.assertEqual(value["profiles"]["local"]["base_url"], "http://localhost:11434/v1")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertFalse(path.with_name("credentials.json").exists())
            self.assertIn(b"Configuration reloaded", session.log)

        def test_cloud_setup_hides_key_and_immediately_authenticates_with_saved_key(self):
            session = self.start_setup()
            self.cloud_key_step(session)
            session.send("dummy-onboard-secret\r")
            self.assertEqual(session.result(), (0, ""))
            self.assertEqual(termios.tcgetattr(session.master), session.original)
            self.assertNotIn(b"dummy-onboard-secret", session.log)
            path = self.directory / "config.json"
            self.assertNotIn("dummy-onboard-secret", path.read_text())
            self.assertEqual(json.loads(path.read_text())["default"], "cloud")
            store = path.with_name("credentials.json")
            self.assertEqual(json.loads(store.read_text()), {"cloud": "dummy-onboard-secret"})
            self.assertEqual(store.stat().st_mode & 0o777, 0o600)
            result = self.run_cli("suggest", "--shell", "zsh", "--intent", "测试", "--generate")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Handler.authorizations[-1], "Bearer dummy-onboard-secret")

        def test_cancel_while_entering_key_saves_nothing_and_restores_terminal(self):
            for cancel in (b"\x03", b"\x1b", b"\x04"):
                with self.subTest(cancel=cancel):
                    session = self.start_setup()
                    self.cloud_key_step(session)
                    session.send(b"dummy-cancelled-secret" + cancel)
                    self.assertEqual(session.result(), (130, ""))
                    self.assertIn(b"No changes saved", session.log)
                    self.assertNotIn(b"dummy-cancelled-secret", session.log)
                    self.assertEqual(termios.tcgetattr(session.master), session.original)
                    self.assertEqual(list(self.directory.iterdir()), [])

        def test_reconfigure_keeps_credentials_fields_and_stopped_state_and_repairs_env(self):
            self.configure()
            path = self.directory / "config.json"
            value = json.loads(path.read_text())
            local = value["profiles"]["local"].copy()
            value["profiles"]["cloud"] = dict(local, api_key_env="dummy-misplaced-secret")
            value["default"] = "cloud"
            value["extra"] = "preserve-me"
            value["max_tokens"] = 4096
            path.write_text(json.dumps(value))
            store = self.directory / "credentials.json"
            store.write_text(json.dumps({"local": "dummy-local-key", "cloud": "dummy-kept-key"}))
            self.assertEqual(self.run_cli("stop").returncode, 0)
            session = self.start_setup()
            session.send("\r")
            session.wait_for("Base URL: ")
            session.send("\r")
            session.wait_for("Model: ")
            session.send("\r")
            session.wait_for("API key (hidden, Enter to keep): ")
            session.send("\r")
            self.assertEqual(session.result(), (0, ""))
            updated = json.loads(path.read_text())
            self.assertEqual(updated["profiles"]["local"], local)
            self.assertEqual(updated["extra"], "preserve-me")
            self.assertEqual(updated["max_tokens"], 4096)
            self.assertEqual(updated["profiles"]["cloud"]["api_key_env"], "SHELL_BUDDY_API_KEY")
            self.assertNotIn(b"dummy-misplaced-secret", session.log)
            self.assertEqual(json.loads(store.read_text()), {"local": "dummy-local-key", "cloud": "dummy-kept-key"})
            self.assertEqual(json.loads(self.directory.joinpath("state.json").read_text()), {"enabled": False, "revision": 2})
            # Rotating the selected key preserves the other profile's key.
            session = self.start_setup()
            session.send("\r\r\r")
            session.wait_for("API key (hidden, Enter to keep): ")
            session.send("dummy-rotated-key\r")
            self.assertEqual(session.result(), (0, ""))
            self.assertEqual(json.loads(store.read_text()), {"local": "dummy-local-key", "cloud": "dummy-rotated-key"})

        def test_invalid_input_and_multiline_key_paste_require_retry(self):
            session = self.start_setup()
            self.cloud_key_step(session)
            session.send("\r")
            session.wait_for("cloud requires an existing or new key")
            session.send("\x1b[200~dummy-pasted\nwrong-line\x1b[201~")
            session.wait_for("Use a single line")
            # Drain terminal redraws while sending a paste larger than the
            # PTY input buffer, so this test also works on macOS.
            def oversized_input():
                remaining = memoryview(b"x" * 4097 + b"\r")
                while remaining:
                    remaining = remaining[os.write(session.master, remaining):]
            writer = threading.Thread(target=oversized_input, daemon=True)
            writer.start()
            session.wait_for("Value too long")
            writer.join(timeout=1)
            self.assertFalse(writer.is_alive())
            self.assertFalse(self.directory.joinpath("credentials.json").exists())
            session.send("dummy-valid-key\r")
            self.assertEqual(session.result(), (0, ""))
            self.assertNotIn(b"dummy-pasted", session.log)
            self.assertNotIn(b"wrong-line", session.log)
            self.assertEqual(json.loads(self.directory.joinpath("credentials.json").read_text()), {"cloud": "dummy-valid-key"})

        def test_invalid_store_is_not_overwritten_by_setup(self):
            self.configure()
            original = self.directory.joinpath("config.json").read_bytes()
            store = self.directory / "credentials.json"
            store.write_text("{broken")
            session = self.start_setup()
            session.send("\r\r\r")
            self.assertEqual(session.result()[0], 1)
            self.assertEqual(self.directory.joinpath("config.json").read_bytes(), original)
            self.assertEqual(store.read_text(), "{broken")
            self.assertFalse(self.directory.joinpath("state.json").exists())
            self.assertEqual(termios.tcgetattr(session.master), session.original)

    class TerminalTests(Base):
        def supported_shells(self):
            shells = []
            if shutil.which("zsh"):
                shells.append((shutil.which("zsh"), ["-f", "-i"], "zsh", "PROMPT='READY> '"))
            bash = os.environ.get("SHELL_BUDDY_TEST_BASH") or shutil.which("bash")
            if bash and int(subprocess.check_output([bash, "-c", "printf '%s' \"${BASH_VERSINFO[0]}\""])) >= 5:
                shells.append((bash, ["--noprofile", "--norc", "-i"], "bash", "PS1='READY> '"))
            return shells

        def start_shell(self, binary, flags, shell, prompt):
            session = Session([binary, *flags], self.env, self.directory)
            self.addCleanup(session.close)
            session.send(f'{prompt}\neval "$("$SHELL_BUDDY_BIN" init {shell})"\nprintf \'%s%s\\n\' SHELL_BUDDY_ READY >&2\n')
            session.wait_for("SHELL_BUDDY_READY")
            session.wait_screen(lambda screen: screen.display[screen.y] == "READY>")
            return session

        def session(self, initial="", shell="zsh"):
            session = Session([str(BINARY), "edit", "--shell", shell, "--initial", initial], self.env, self.directory)
            self.addCleanup(session.close)
            return session

        def test_compression_failure_and_rate_limit_have_distinct_hints(self):
            for mode, hint in (("force-compression", "Unsupported response compression"),
                               ("rate", "Rate limited")):
                with self.subTest(mode=mode):
                    self.configure(mode)
                    session = self.session("// 测试服务")
                    session.wait_for(hint)
                    self.assertTrue(session.screen.display[session.screen.y].startswith("✦ 测试服务"))
                    self.assertNotIn(b"Model request failed", session.log)
                    session.send(b"\x03")
                    self.assertEqual(session.result(), (20, ""))
                    self.assertEqual(termios.tcgetattr(session.master), session.original)

        def test_ai_mode_shows_ready_state_and_keeps_chinese_cursor_and_result_clean(self):
            session = self.session()
            session.wait_for("✦")
            row = session.screen.y
            self.assertEqual(session.screen.display[row], "✦")
            session.send("当前路径")
            session.wait_for("pwd")
            self.assertEqual(session.screen.y, row)
            self.assertIn("✦ 当前路径  pwd", session.screen.display[row])
            self.assertNotIn("Tab next", session.screen.display[row])
            self.assertEqual(session.screen.x, 10)
            self.assertIn(b"\x1b[36m", session.log)
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "pwd"))
            self.assertEqual(termios.tcgetattr(session.master), session.original)

        def test_ai_icon_pulses_only_while_a_request_is_active(self):
            self.configure("timeout")
            count = len(Handler.requests)
            session = self.session("// 测试服务")
            pulse = rb"\x1b\[(?:2|1|22)m" + re.escape("✦".encode())
            session.wait_screen(lambda screen: bool(re.findall(pulse, session.log)))
            row = session.screen.y
            first = re.findall(pulse, session.log)[-1]
            session.wait_screen(lambda screen: re.findall(pulse, session.log)[-1] != first)
            self.assertEqual(session.screen.y, row)
            self.assertNotIn("Enter accept", session.screen.display[row])
            self.assertEqual(len(Handler.requests), count + 1)
            session.send(b"\x03")
            self.assertEqual(session.result(), (20, ""))
            self.assertEqual(termios.tcgetattr(session.master), session.original)

        def test_enter_accepts_and_persists_only_after_confirmation(self):
            session = self.session("// 创建 hello.txt 文件")
            session.wait_for("touch")
            self.assertFalse(self.directory.joinpath("cache.json").exists())
            session.send(b"\r")
            code, result = session.result()
            self.assertEqual((code, result), (0, "touch './hello.txt'"), session.log.decode(errors="replace"))
            self.assertFalse(self.directory.joinpath("hello.txt").exists())
            self.assertEqual(termios.tcgetattr(session.master), session.original)
            self.assertEqual(len(json.loads(self.directory.joinpath("cache.json").read_text())), 1)

        def test_modified_enter_reports_execute_and_ctrl_c_cancels(self):
            session = self.session("// 当前路径")
            session.wait_for("pwd")
            session.send(b"\x1b[13;9u")
            self.assertEqual(session.result(), (10, "pwd"))
            other = self.session("// 当前路径")
            other.wait_for("pwd")
            other.send(b"\x03")
            self.assertEqual(other.result(), (20, ""))
            self.assertEqual(termios.tcgetattr(other.master), other.original)

        def test_external_termination_restores_terminal(self):
            session = self.session("// 当前路径")
            session.wait_for("pwd")
            os.kill(session.pid, signal.SIGTERM)
            self.assertEqual(session.result(), (20, ""))
            self.assertEqual(termios.tcgetattr(session.master), session.original)

        def test_stop_cancels_all_editors_and_restores_terminals(self):
            self.configure("slow")
            first = self.session("// 流式测试")
            second = self.session("// 当前路径")
            first.wait_for("touch")
            second.wait_for("pwd")
            start = time.monotonic()
            self.assertEqual(self.run_cli("stop").returncode, 0)
            self.assertEqual(first.result(timeout=1), (20, "// 流式测试"))
            self.assertEqual(second.result(timeout=1), (20, "// 当前路径"))
            self.assertLess(time.monotonic() - start, 0.5)
            for session in (first, second):
                self.assertEqual(termios.tcgetattr(session.master), session.original)
            self.assertFalse(self.directory.joinpath("cache.json").exists())

        def test_restart_reloads_active_editor_and_discards_old_stream(self):
            self.configure("slow")
            session = self.session("// 流式测试")
            session.wait_for("touch")
            self.configure()
            result = self.run_cli("restart")
            self.assertEqual(result.returncode, 0, result.stderr)
            session.wait_for("printf")
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "printf '%s\\n' '你好'"))
            self.assertEqual(termios.tcgetattr(session.master), session.original)
            records = json.loads(self.directory.joinpath("cache.json").read_text())
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["command"], "printf '%s\\n' '你好'")

        def test_llm_switch_reloads_editor_and_isolates_cache(self):
            self.configure("slow")
            path = self.directory / "config.json"
            document = json.loads(path.read_text())
            document["profiles"]["cloud"] = {"base_url": f"http://127.0.0.1:{self.server.server_port}/v1", "model": "normal"}
            path.write_text(json.dumps(document))
            session = self.session("// 当前路径")
            session.wait_for("pwd")
            session.send(b"\t")
            session.wait_for("m✦")
            self.assertEqual(self.run_cli("llm", "cloud").returncode, 0)
            session.send(b"\t")
            # Allow reload to discard the old request before requesting an
            # alternative to the freshly computed local rule.
            time.sleep(0.15)
            session.send(b"\t")
            session.wait_for("printf")
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "printf '%s\\n' '你好'"))
            self.assertEqual(self.run_cli("suggest", "--shell", "zsh", "--intent", "当前路径").stdout.strip(), "printf '%s\\n' '你好'")
            self.assertEqual(self.run_cli("llm", "local").returncode, 0)
            self.assertEqual(self.run_cli("suggest", "--shell", "zsh", "--intent", "当前路径").stdout.strip(), "pwd")

        def test_native_tab_completion_has_descriptions_and_inserts_only_names(self):
            self.assertEqual(self.run_cli("start").returncode, 0)
            for binary, flags, shell, prompt in self.supported_shells():
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.1)
                    session.send('export PATH="${SHELL_BUDDY_BIN%/*}:$PATH"\n')
                    session.wait_for("READY> ")
                    session.send("shell-buddy ll\t")
                    session.send(" \t")
                    session.wait_for("Use the local model service")
                    session.send("c\t\n")
                    session.wait_for("READY> ")
                    session.send("exit\n")
                    code, stdout = session.result()
                    self.assertEqual(code, 0, session.log.decode(errors="replace"))
                    self.assertIn("LLM profile: cloud", stdout)
                    self.assertEqual(json.loads(self.directory.joinpath("config.json").read_text())["default"], "cloud")

        def test_zsh_autosuggestions_and_highlighting_preserve_enter_after_reinitialization(self):
            zsh = shutil.which("zsh")
            plugins = []
            for name in ("zsh-autosuggestions", "zsh-syntax-highlighting"):
                paths = [Path(prefix) / name / (name + ".zsh") for prefix in
                         ("/opt/homebrew/share", "/usr/local/share", "/usr/share")]
                path = next((value for value in paths if value.exists()), None)
                if path is None or not zsh:
                    self.skipTest("Zsh plugins not installed")
                plugins.append(path)
            session = Session([zsh, "-f", "-i"], self.env, self.directory)
            self.addCleanup(session.close)
            session.send("PROMPT='READY> '\n" + "\n".join("source " + shlex.quote(str(path)) for path in plugins) +
                         "\nprintf '%s%s\\n' PLUGINS _READY >&2\n")
            session.wait_for("PLUGINS_READY")
            session.wait_screen(lambda screen: screen.display[screen.y] == "READY>")
            for _ in range(3):
                session.send('eval "$("$SHELL_BUDDY_BIN" init zsh)"\n')
                session.wait_for("READY> ")
                session.send("printf '%s%s\\n' ENTER _WORKS >&2\n")
                session.wait_for("ENTER_WORKS")
                session.wait_screen(lambda screen: screen.display[screen.y] == "READY>")
            session.send("//当前路径")
            session.wait_for("pwd")
            session.send(b"\r")
            session.wait_screen(lambda screen: screen.display[screen.y] == "READY> pwd")
            session.send(b"\r")
            session.wait_for("READY> ")
            session.send("exit\n")
            self.assertEqual(session.result()[0], 0, session.log.decode(errors="replace"))

        def test_inline_editor_keeps_multiline_colored_prompt_and_input_on_same_row(self):
            for binary, flags, shell, prompt in self.supported_shells():
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.1)
                    if shell == "zsh":
                        session.send("PROMPT=$'%F{cyan}PROJECT%f\\n%F{green}❯%f '\n")
                    else:
                        session.send("PS1=$'\\[\\e[36m\\]PROJECT\\[\\e[0m\\]\\n\\[\\e[32m\\]❯\\[\\e[0m\\] '\n")
                    session.wait_for("\x1b[32m❯")
                    row = session.screen.y
                    self.assertEqual(session.screen.display[row - 1], "PROJECT")
                    session.send("//")
                    session.wait_for("✦")
                    self.assertEqual(session.screen.y, row, session.screen.display)
                    self.assertTrue(session.screen.display[row].startswith("❯ ✦"))
                    self.assertEqual(session.screen.display[row - 1], "PROJECT")
                    session.send("创建 hello.txt 文件")
                    session.wait_for("touch")
                    self.assertEqual(session.screen.y, row, session.screen.display)
                    self.assertTrue(session.screen.display[row].startswith("❯ ✦ 创建 hello.txt 文件"), session.screen.display)
                    self.assertIn("touch './hello.txt'", session.screen.display[row])
                    session.send(b"\r")
                    session.wait_for("touch './hello.txt'")
                    self.assertEqual(session.screen.y, row, session.screen.display)
                    self.assertEqual(session.screen.display[row], "❯ touch './hello.txt'")
                    self.assertFalse(self.directory.joinpath("hello.txt").exists())
                    session.send(b"\r")
                    session.wait_for("\x1b[36mPROJECT")
                    session.wait_screen(lambda screen: screen.display[screen.y] == "❯")
                    self.assertTrue(self.directory.joinpath("hello.txt").exists())
                    self.directory.joinpath("hello.txt").unlink()
                    row = session.screen.y
                    session.send("//")
                    session.wait_for("✦")
                    session.send("你好")
                    session.wait_for("Model not configured")
                    self.assertEqual(session.screen.y, row)
                    session.send(b"\x1b")
                    session.wait_for("\x1b[?2004l")
                    session.send("\x15exit\n")
                    self.assertEqual(session.result()[0], 0, session.log.decode(errors="replace"))

        def test_wrapped_paste_is_edited_on_original_prompt_row(self):
            for binary, flags, shell, prompt in self.supported_shells():
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.1)
                    row = session.screen.y
                    description = "很长的描述" * 25
                    session.send("\x1b[200~// " + description + "\x1b[201~")
                    session.wait_for("描述")
                    session.send(b"\r")
                    session.wait_for("✦")
                    self.assertEqual(session.screen.y, row, session.screen.display)
                    self.assertTrue(session.screen.display[row].startswith("READY> ✦ "), session.screen.display)
                    self.assertTrue(all(not line for line in session.screen.display[row + 1:]), session.screen.display)
                    session.send(b"\x03")
                    session.wait_for("READY> ")
                    self.assertEqual(session.screen.display[row], "READY>", session.screen.display)
                    session.send("exit\n")
                    self.assertEqual(session.result()[0], 0)

        def test_relative_init_without_path_survives_cd_and_handles_unconfigured_input(self):
            tool = self.directory / "tool's directory" / "shell-buddy"
            tool.parent.mkdir()
            shutil.copy2(BINARY, tool)
            relative = "./" + str(tool.relative_to(self.directory))
            env = self.env.copy()
            env.pop("SHELL_BUDDY_BIN", None)
            env.pop("SHELL_BUDDY_SHELL", None)
            env["PATH"] = "/usr/bin:/bin"
            for binary, flags, shell, prompt in self.supported_shells():
                with self.subTest(shell=shell):
                    target = self.directory / (shell + " working directory")
                    target.mkdir()
                    session = Session([binary, *flags], env, self.directory)
                    self.addCleanup(session.close)
                    session.send(f'{prompt}\neval "$({shlex.quote(relative)} init {shell})"\nprintf \'%s%s\\n\' BOOTSTRAP _DONE >&2\n')
                    session.wait_for("BOOTSTRAP_DONE")
                    session.send("// 你好")
                    session.wait_for("Model not configured")
                    session.send(b"\x03")
                    session.wait_for("READY> ")
                    session.send(f"cd {shlex.quote(str(target))}\n")
                    session.wait_for("READY> ")
                    session.send("// 创建 hello.txt 文件")
                    session.wait_for("touch")
                    session.send(b"\r")
                    session.wait_for("READY> ")
                    self.assertFalse((target / "hello.txt").exists())
                    session.send(b"\r")
                    session.wait_for("READY> ")
                    session.send('"$SHELL_BUDDY_BIN" doctor\nexit\n')
                    code, stdout = session.result()
                    self.assertEqual(code, 0, session.log.decode(errors="replace"))
                    self.assertTrue((target / "hello.txt").exists())
                    self.assertIn(f"shell integration: {shell}", stdout)
                    self.assertNotIn(b"permission denied: //", session.log)
                    self.assertNotIn(b"command not found: shell-buddy", session.log)

        def test_invalid_restart_keeps_current_editor_and_candidate(self):
            session = self.session("// 当前路径")
            session.wait_for("pwd")
            self.directory.joinpath("config.json").write_text("{broken")
            self.assertNotEqual(self.run_cli("restart").returncode, 0)
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "pwd"))

        def test_partial_stream_cannot_be_accepted(self):
            self.configure("slow")
            session = self.session("// 流式测试")
            session.wait_for("touch")
            self.assertNotIn("Enter accept", session.screen.display[session.screen.y])
            session.send(b"\r")
            time.sleep(0.08)
            self.assertEqual(os.waitpid(session.pid, os.WNOHANG), (0, 0))
            session.wait_for("完整结果.txt")
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "touch '完整结果.txt'"))

        def test_edit_cancels_old_request_and_never_restores_stale_suggestion(self):
            self.configure("slow")
            session = self.session("// 流式测试")
            session.wait_for("touch")
            start = time.monotonic()
            session.send("\x15当前路径")
            session.wait_for("pwd")
            self.assertLess(time.monotonic() - start, 0.4)
            time.sleep(0.6)
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "pwd"))

        def test_paste_newline_is_text_and_esc_keeps_description(self):
            session = self.session()
            session.wait_for("✦")
            session.send("\x1b[200~创建 hello\rworld.txt 文件\x1b[201~")
            session.wait_for("touch")
            session.send(b"\x1b")
            self.assertEqual(session.result(), (20, "// 创建 hello world.txt 文件"))

        def test_resize_and_chinese_backspace(self):
            session = self.session("// 当前路径你")
            session.wait_for("当前路径你")
            fcntl.ioctl(session.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 16, 0, 0))
            session.send(b"\x7f")
            session.wait_screen(lambda screen: screen.columns == 16 and screen.display[screen.y].startswith("✦ 当前路径"))
            self.assertEqual(session.screen.x, 10)
            fcntl.ioctl(session.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            # The compact line already fits at 16 columns, so resizing alone
            # need not emit an identical frame. Exercise cursor movement too.
            session.send(b"\x01\x05")
            session.wait_screen(lambda screen: screen.columns == 80 and "pwd" in screen.display[screen.y] and screen.x == 10)
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "pwd"))

        def test_tab_requests_alternative_without_replacing_local_result_early(self):
            self.configure("slow")
            session = self.session("// 当前路径")
            session.wait_for("pwd")
            session.send(b"\t")
            time.sleep(0.1)
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "pwd"))

        def test_tab_accepts_new_complete_candidate_and_cache_wins_over_rules(self):
            self.configure()
            session = self.session("// 当前路径")
            session.wait_for("pwd")
            requests = len(Handler.requests)
            time.sleep(0.08)
            self.assertEqual(len(Handler.requests), requests)
            session.send(b"\t")
            session.wait_for("printf")
            session.send(b"\r")
            self.assertEqual(session.result(), (0, "printf '%s\\n' '你好'"))
            result = self.run_cli("suggest", "--shell", "zsh", "--intent", "当前路径")
            self.assertEqual(result.stdout.strip(), "printf '%s\\n' '你好'")

        def test_concurrent_confirmations_preserve_cache_and_enforce_bound(self):
            self.directory.joinpath("cache.json").write_text(json.dumps([
                {"key": str(i), "command": "pwd"} for i in range(256)
            ]))
            sessions = [self.session(f"// 创建 file-{i}.txt 文件") for i in range(6)]
            for session in sessions:
                session.wait_for("touch")
            for session in sessions:
                session.send(b"\r")
            for session in sessions:
                self.assertEqual(session.result()[0], 0)
            records = json.loads(self.directory.joinpath("cache.json").read_text())
            self.assertEqual(len(records), 256)
            self.assertEqual(sum("file-" in item["command"] for item in records), 6)

        def test_shell_adapter_executes_cd_in_current_shell(self):
            self.configure("cd")
            target = self.directory / "target directory"
            target.mkdir()
            Handler.target = str(target)
            shells = self.supported_shells()
            if not shells:
                self.skipTest("No supported bash/zsh installed")
            for binary, flags, shell, prompt in shells:
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.1)
                    session.send("// 切换测试目录")
                    session.wait_for("cd '")
                    session.send(b"\x1b[13;5u")
                    session.wait_for("READY> ")
                    session.send("pwd\nexit\n")
                    code, stdout = session.result()
                    self.assertEqual(code, 0)
                    self.assertIn(str(target), stdout)

        def test_shell_lifecycle_commands_work_without_reinitializing_adapter(self):
            for binary, flags, shell, prompt in self.supported_shells():
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.08)
                    session.send('"$SHELL_BUDDY_BIN" stop\n')
                    session.wait_for("READY> ")
                    cache_path = self.directory / "cache.json"
                    previous = cache_path.read_bytes() if cache_path.exists() else None
                    session.send("// 当前路径")
                    session.wait_for("当前路径")
                    self.assertEqual(cache_path.read_bytes() if cache_path.exists() else None, previous)
                    session.send('\x15"$SHELL_BUDDY_BIN" restart\n')
                    session.wait_for("READY> ")
                    session.send("// 当前路径")
                    session.wait_for("pwd")
                    session.send(b"\x1b[13;5u")
                    session.wait_for("READY> ")
                    session.send("exit\n")
                    code, stdout = session.result()
                    self.assertEqual(code, 0, session.log.decode(errors="replace"))
                    self.assertIn("stopped", stdout)
                    self.assertIn("restarted", stdout)
                    self.assertIn(str(self.directory), stdout)

        def test_shell_enter_fills_before_native_execution_and_ordinary_slashes_work(self):
            shells = self.supported_shells()
            if not shells:
                self.skipTest("No supported bash/zsh installed")
            for binary, flags, shell, prompt in shells:
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.1)
                    session.send(f"// 创建 {shell}.txt 文件")
                    session.wait_for("touch")
                    session.send(b"\r")
                    session.wait_for("READY> ")
                    time.sleep(0.05)
                    self.assertFalse(self.directory.joinpath(f"{shell}.txt").exists())
                    session.send(b"\r")
                    session.send("printf '%s\\n' '你好/a'\nfalse\nprintf 'PREVIOUS=%s\\n' \"$?\"\nexit\n")
                    code, stdout = session.result()
                    self.assertEqual(code, 0)
                    self.assertTrue(self.directory.joinpath(f"{shell}.txt").exists(), session.log.decode(errors="replace"))
                    self.assertIn("你好/a", stdout)
                    self.assertIn("PREVIOUS=1", stdout)
                    self.assertNotIn(b"invalid keymap", session.log)

        def test_vi_insert_keymaps_and_reinitialization(self):
            for binary, flags, shell, prompt in self.supported_shells():
                with self.subTest(shell=shell):
                    session = self.start_shell(binary, flags, shell, prompt)
                    time.sleep(0.08)
                    session.send(f'eval "$("$SHELL_BUDDY_BIN" init {shell})"\n')
                    session.wait_for("READY> ")
                    session.send("set -o vi\n" if shell == "bash" else "bindkey -v\n")
                    session.wait_for("READY> ")
                    session.send("// 当前路径")
                    session.wait_for("pwd")
                    session.send(b"\x1b[13;5u")
                    session.wait_for("READY> ")
                    session.send("exit\n")
                    code, stdout = session.result()
                    self.assertEqual(code, 0)
                    self.assertIn(str(self.directory), stdout)
                    self.assertNotIn(b"invalid keymap", session.log)
                    self.assertNotIn(b"can only `return'", session.log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
