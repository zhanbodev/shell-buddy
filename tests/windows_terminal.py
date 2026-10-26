"""Windows-native PowerShell/ConPTY checks; pip install pywinpty (test-only)."""
import os
import queue
import re
import subprocess
import threading
import time
import unittest

from integration import Base, BINARY, Handler, ROOT

if os.name == "nt":
    from winpty import PtyProcess


@unittest.skipUnless(os.name == "nt", "Windows ConPTY only")
class PowerShellTests(Base):
    def test_init_cloud_hides_key_and_creates_current_user_only_acl(self):
        import json
        self.env["SHELL_BUDDY_CONFIG"] = str(self.directory / "shell-buddy/config.json")
        process = self.start_shell()
        binary = str(BINARY).replace("'", "''")
        process.write(f"& '{binary}' init\r")
        self.wait_for("Profile: ")
        process.write("\t\r")
        self.wait_for("Base URL: ")
        process.write(f"http://127.0.0.1:{self.server.server_port}/v1\r")
        self.wait_for("Model: ")
        process.write("normal\r")
        self.wait_for("API key (hidden, required): ")
        process.write("dummy-windows-secret\r")
        self.wait_for("Input style: ")
        process.write("\r")
        self.wait_for("READY>")
        self.assertIn("Configuration reloaded", self.log)
        self.assertNotIn("dummy-windows-secret", self.log)
        path = self.directory / "shell-buddy/config.json"
        store = path.with_name("credentials.json")
        self.assertNotIn("dummy-windows-secret", path.read_text())
        self.assertEqual(json.loads(store.read_text()), {"cloud": "dummy-windows-secret"})
        source = f"""
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$paths = @('{str(path.parent).replace("'", "''")}', '{str(path).replace("'", "''")}', '{str(store).replace("'", "''")}')
foreach ($path in $paths) {{
    $acl = Get-Acl -LiteralPath $path
    if (-not $acl.AreAccessRulesProtected) {{ throw 'Inherited ACL was not disabled' }}
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 1 -or $rules[0].IdentityReference.Value -ne $sid -or $rules[0].AccessControlType -ne 'Allow') {{ throw 'Unexpected credential access' }}
}}
Write-Output 'ACL verified'
"""
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-Command', source],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ACL verified', result.stdout)
        result = self.run_cli("suggest", "--shell", "powershell", "--intent", "测试", "--generate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.authorizations[-1], "Bearer dummy-windows-secret")

    def test_init_cancel_saves_nothing_and_restores_powershell(self):
        process = self.start_shell()
        binary = str(BINARY).replace("'", "''")
        process.write(f"& '{binary}' init\r")
        self.wait_for("Profile: ")
        process.write("\x03")
        self.wait_for("READY>")
        self.assertIn("Setup cancelled", self.log)
        self.assertFalse(self.directory.joinpath("config.json").exists())
        self.assertFalse(self.directory.joinpath("credentials.json").exists())
        process.write("Write-Output 'RESTORED'\r")
        self.wait_for("RESTORED")

    def test_native_completion_inserts_profile_names_and_keeps_descriptions_separate(self):
        script = str(ROOT / "src/shell/completion.ps1").replace("'", "''")
        source = f"""
. '{script}'
$cases = @('shell-buddy ', 'shell-buddy llm ', 'shell-buddy llm c', 'shell-buddy suggest --shell ', 'shell-buddy suggest --g')
$result = @{{}}
foreach ($line in $cases) {{
    $completion = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null)
    $result[$line] = @($completion.CompletionMatches | ForEach-Object {{ @{{ text = $_.CompletionText; description = $_.ToolTip }} }})
}}
$result | ConvertTo-Json -Depth 5 -Compress
"""
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-Command', source],
                                env=self.env, text=True, encoding='utf-8', capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        import json
        values = json.loads(result.stdout)
        self.assertIn('llm', [v['text'] for v in values['shell-buddy ']])
        self.assertIn('init', [v['text'] for v in values['shell-buddy ']])
        self.assertEqual({v['text'] for v in values['shell-buddy llm ']}, {'local', 'cloud'})
        self.assertTrue(all(v['description'].startswith('Use the ') for v in values['shell-buddy llm ']))
        self.assertEqual([v['text'] for v in values['shell-buddy llm c']], ['cloud'])
        self.assertEqual({v['text'] for v in values['shell-buddy suggest --shell ']}, {'bash', 'zsh', 'powershell'})
        self.assertEqual([v['text'] for v in values['shell-buddy suggest --g']], ['--generate'])

    def start_shell(self):
        process = PtyProcess.spawn("pwsh -NoLogo -NoProfile -NoExit", env=self.env,
                                   cwd=str(self.directory), dimensions=(30, 160))
        self.addCleanup(lambda: process.close(force=True))
        self.messages = queue.Queue()
        self.log = ""

        def pump():
            try:
                while process.isalive():
                    self.messages.put(process.read())
            except (EOFError, OSError):
                pass

        threading.Thread(target=pump, daemon=True).start()
        self.wait_for(">")
        script = str(ROOT / "src/shell/powershell.ps1").replace("'", "''")
        # Encode the prompt so terminal echo of this setup line cannot be
        # mistaken for the real prompt after the module finished loading.
        process.write(f". '{script}'; function global:prompt {{ ([char[]](82,69,65,68,89,62,32) -join '') }}\r")
        self.wait_for("READY>")
        return process

    def wait_for(self, text, timeout=8):
        start = len(self.log)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if text in self.log[start:]:
                return
            try:
                self.log += self.messages.get(timeout=0.05)
            except queue.Empty:
                pass
        self.fail(f"Did not receive {text!r}: {self.log[-3000:]!r}")

    def test_enter_fills_line_then_second_enter_executes(self):
        process = self.start_shell()
        # Wait for the child editor to own console input before typing the intent.
        process.write("//")
        self.wait_for("What do you need?")
        process.write(" 创建 hello.txt 文件")
        self.wait_for("New-Item")
        self.assertIn("❯", re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", self.log))
        process.write("\r")
        time.sleep(0.2)
        self.assertFalse(self.directory.joinpath("hello.txt").exists())
        process.write("\r")
        self.wait_for("READY>")
        self.assertTrue(self.directory.joinpath("hello.txt").exists())

    def test_modified_enter_changes_current_powershell_directory(self):
        self.configure("cd")
        target = self.directory / "target directory"
        target.mkdir()
        # PowerShell expands Windows' 8.3 TEMP path when reporting its location.
        target = target.resolve()
        Handler.target = str(target)
        process = self.start_shell()
        # Wait for the child editor to own console input before typing the intent.
        process.write("//")
        self.wait_for("What do you need?")
        process.write(" 切换测试目录")
        self.wait_for("Set-Location")
        process.write("\x1b[13;5u")
        self.wait_for("READY>")
        process.write("(Get-Location).Path\r")
        self.wait_for(str(target))

    def test_slow_model_cancel_and_unicode_rule(self):
        self.configure("slow")
        process = self.start_shell()
        # Wait for the child editor to own console input before typing the intent.
        process.write("//")
        self.wait_for("What do you need?")
        process.write(" 流式测试")
        self.wait_for("touch")
        process.write("\x15当前路径")
        self.wait_for("Get-Location")
        process.write("\x03")
        time.sleep(0.2)
        process.write("Write-Output 'ALIVE'\r")
        self.wait_for("ALIVE")
        self.assertFalse(self.directory.joinpath("完整结果.txt").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
