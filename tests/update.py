"""Native self-update tests: loopback fixtures, isolated copies, no real installations."""
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SUFFIX = '.exe' if os.name == 'nt' else ''
BINARY = ROOT / ('zig-out/bin/shell-buddy' + SUFFIX)
DRIVER = ROOT / ('zig-out/bin/update-driver' + SUFFIX)
VERSION = (ROOT / 'src/version.txt').read_text().strip()
PLATFORM = {'Darwin': 'macos', 'Linux': 'linux', 'Windows': 'windows'}[platform.system()]
ARCH = 'aarch64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
NAME = f'shell-buddy-{PLATFORM}-{ARCH}' + ('.zip' if os.name == 'nt' else '.tar.gz')

spec = importlib.util.spec_from_file_location('packager', ROOT / 'tools/package_release.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        server = self.server
        server.requests.append(self.path)
        status, body, headers, delay = server.responses.get(self.path, (404, b'not found', {}, 0))
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if delay:
            time.sleep(delay)
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


class UpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not DRIVER.exists():
            raise RuntimeError('Run zig build build-update-tests -Doptimize=small first')
        cls.package_dir = tempfile.TemporaryDirectory(prefix='shell-buddy-update-package-')
        archive = packager.package(BINARY, PLATFORM, ARCH, Path(cls.package_dir.name))
        cls.original_archive = archive.read_bytes()
        cls.binary_bytes = BINARY.read_bytes()
        cls.driver_bytes = DRIVER.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.package_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shell-buddy-update-')
        self.root = Path(self.temp.name)
        self.executable = self.root / 'custom bin' / ('shell-buddy' + SUFFIX)
        self.executable.parent.mkdir()
        shutil.copy2(DRIVER, self.executable)
        self.font = self.root / 'fonts' / 'ShellBuddyIcons.ttf'
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.responses = {}
        self.server.requests = []
        self.url = f'http://127.0.0.1:{self.server.server_port}'
        self.tag = 'v' + VERSION
        self.release = {'tag_name': self.tag, 'draft': False, 'prerelease': False,
                        'assets': [{'name': NAME}, {'name': 'SHA256SUMS'}]}
        self.publish(self.original_archive)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.env = dict(os.environ)
        config = self.root / 'config'
        config.mkdir()
        self.saved = {}
        for name in ('config.json', 'credentials.json', 'cache.json', 'state.json'):
            path = config / name
            path.write_bytes(b'private user data\n')
            self.saved[path] = path.read_bytes()
        self.env.update(SHELL_BUDDY_CONFIG=str(config / 'config.json'), XDG_CONFIG_HOME=str(self.root))

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def response(self, path, body=b'', status=200, headers=None, delay=0):
        self.server.responses[path] = (status, body, headers or {}, delay)

    def publish(self, archive):
        self.response('/latest', json.dumps(self.release).encode())
        self.response(f'/download/{self.tag}/{NAME}', archive)
        self.response(f'/download/{self.tag}/SHA256SUMS',
                      (hashlib.sha256(archive).hexdigest() + '  ' + NAME + '\n').encode())

    def run_update(self, *flags, current='0.0.0'):
        return subprocess.run([str(self.executable), self.url + '/latest', self.url + '/download',
                               current, str(self.font), *flags], env=self.env,
                              capture_output=True, text=True, timeout=12)

    def assert_preserved(self):
        self.assertEqual(self.executable.read_bytes(), self.driver_bytes)
        self.assertFalse(self.font.exists())
        self.assertFalse(list(self.executable.parent.glob('*.update-*')))
        for path, contents in self.saved.items():
            self.assertEqual(path.read_bytes(), contents)

    def repack(self, change):
        data = self.original_archive
        if os.name == 'nt':
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                entries = [(entry.filename, archive.read(entry)) for entry in archive.infolist()]
        else:
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                entries = [(entry.name, archive.extractfile(entry).read()) for entry in archive if entry.isfile()]
        entries = change(entries)
        result = io.BytesIO()
        if os.name == 'nt':
            with zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as archive:
                for name, contents in entries:
                    archive.writestr(name, contents)
        else:
            with tarfile.open(fileobj=result, mode='w:gz', format=tarfile.USTAR_FORMAT) as archive:
                for name, contents in entries:
                    entry = tarfile.TarInfo(name)
                    entry.size = len(contents)
                    archive.addfile(entry, io.BytesIO(contents))
        return result.getvalue()

    def test_replaces_running_executable_in_custom_path_and_updates_font(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executable.read_bytes(), self.binary_bytes)
        self.assertEqual(subprocess.check_output([str(self.executable), '--version'], text=True).strip(), VERSION)
        self.assertEqual(self.font.read_bytes(), (ROOT / 'fonts/ShellBuddyIcons.ttf').read_bytes())
        for path, contents in self.saved.items():
            self.assertEqual(path.read_bytes(), contents)
        if os.name != 'nt':
            self.assertEqual(self.executable.stat().st_mode & 0o777, DRIVER.stat().st_mode & 0o777)
        self.assertFalse(list(self.executable.parent.glob('*.update-*')))

    def test_check_only_does_not_create_lock_or_download(self):
        result = self.run_update('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Update available', result.stdout)
        self.assertEqual(self.server.requests, ['/latest'])
        self.assertFalse(Path(str(self.executable) + '.update.lock').exists())
        self.assert_preserved()

    def test_current_or_newer_version_does_not_downgrade(self):
        for current in (VERSION, '999.0.0'):
            result = self.run_update(current=current)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('up to date', result.stdout)
        self.assertEqual(self.server.requests, ['/latest', '/latest'])
        self.assert_preserved()

    def test_skip_font(self):
        result = self.run_update('--no-font')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.executable.read_bytes(), self.binary_bytes)
        self.assertFalse(self.font.exists())

    def test_checksum_mismatch_preserves_installation(self):
        self.response(f'/download/{self.tag}/{NAME}', self.original_archive + b'corruption')
        result = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn('ChecksumMismatch', result.stderr)
        self.assert_preserved()

    def test_duplicate_or_missing_checksum_preserves_installation(self):
        line = (hashlib.sha256(self.original_archive).hexdigest() + '  ' + NAME + '\n').encode()
        for data in (b'', line + line):
            self.response(f'/download/{self.tag}/SHA256SUMS', data)
            result = self.run_update()
            self.assertIn('InvalidChecksum', result.stderr)
            self.assert_preserved()

    def test_bad_archive_with_valid_checksum_preserves_installation(self):
        self.publish(b'not an archive')
        result = self.run_update()
        self.assertIn('InvalidArchive', result.stderr)
        self.assert_preserved()

    def test_missing_required_file_preserves_installation(self):
        self.publish(self.repack(lambda entries: [(n, d) for n, d in entries if n != 'shell-buddy/release.json']))
        result = self.run_update()
        self.assertIn('InvalidArchive', result.stderr)
        self.assert_preserved()

    def test_duplicate_binary_preserves_installation(self):
        self.publish(self.repack(lambda entries: entries + [(n, d) for n, d in entries if n.startswith('shell-buddy/bin/')]))
        result = self.run_update()
        self.assertIn('InvalidArchive', result.stderr)
        self.assert_preserved()

    def test_bundle_platform_must_match(self):
        def mutate(entries):
            return [(n, json.dumps({'version': VERSION, 'platform': 'other', 'architecture': ARCH}).encode()
                     if n == 'shell-buddy/release.json' else d) for n, d in entries]
        self.publish(self.repack(mutate))
        result = self.run_update()
        self.assertIn('InvalidArchive', result.stderr)
        self.assert_preserved()

    def test_candidate_must_run_and_report_expected_version(self):
        self.publish(self.repack(lambda entries: [(n, b'bad executable' if n.startswith('shell-buddy/bin/') else d) for n, d in entries]))
        result = self.run_update()
        self.assertIn('VersionMismatch', result.stderr)
        self.assert_preserved()

    def test_candidate_version_must_match_release_version(self):
        self.tag = 'v999.0.0'
        self.release['tag_name'] = self.tag
        def mutate(entries):
            return [(n, json.dumps({'version': '999.0.0', 'platform': PLATFORM, 'architecture': ARCH}).encode()
                     if n == 'shell-buddy/release.json' else d) for n, d in entries]
        self.publish(self.repack(mutate))
        result = self.run_update()
        self.assertIn('VersionMismatch', result.stderr)
        self.assert_preserved()

    def test_response_size_is_bounded(self):
        self.response('/latest', b' ' * (1024 * 1024 + 1))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()

    def test_truncated_download_preserves_installation(self):
        self.response(f'/download/{self.tag}/{NAME}', self.original_archive[:100])
        result = self.run_update()
        self.assertIn('ChecksumMismatch', result.stderr)
        self.assert_preserved()

    @unittest.skipIf(os.name == 'nt', 'POSIX symlinks')
    def test_symlink_keeps_pointing_to_upgraded_program(self):
        link = self.root / 'shell-buddy-link'
        link.symlink_to(self.executable)
        result = subprocess.run([str(link), self.url + '/latest', self.url + '/download',
                                 '0.0.0', str(self.font), '--no-font'], env=self.env,
                                capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.executable.read_bytes(), self.binary_bytes)

    def test_invalid_release_metadata_is_rejected(self):
        for mutation in ({'tag_name': '../evil'}, {'prerelease': True}, {'draft': True}, {'assets': []}):
            release = dict(self.release, **mutation)
            self.response('/latest', json.dumps(release).encode())
            result = self.run_update()
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assert_preserved()

    def test_server_errors_are_classified(self):
        for status, error in ((401, 'UpdateHttpError'), (403, 'UpdateRateLimited'),
                              (429, 'UpdateRateLimited'), (404, 'UpdateNotFound'), (500, 'UpdateHttpError')):
            self.response('/latest', b'provider error', status=status)
            result = self.run_update()
            self.assertIn(error, result.stderr)
            self.assertNotIn('provider error', result.stderr)
            self.assert_preserved()

    def test_timeout_cancels_request_and_preserves_installation(self):
        self.response(f'/download/{self.tag}/{NAME}', self.original_archive, delay=2)
        result = self.run_update()
        self.assertIn('UpdateTimeout', result.stderr)
        self.assert_preserved()

    def test_plaintext_non_loopback_redirect_is_rejected(self):
        self.response('/latest', status=302, headers={'Location': 'http://example.com/release'})
        result = self.run_update()
        self.assertIn('InsecureUpdateUrl', result.stderr)
        self.assert_preserved()

    def test_loopback_redirect_is_followed(self):
        self.response('/redirected', json.dumps(self.release).encode())
        self.response('/latest', status=302, headers={'Location': self.url + '/redirected'})
        result = self.run_update('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests, ['/latest', '/redirected'])
        self.assert_preserved()

    @unittest.skipIf(os.name == 'nt', 'POSIX flock fixture')
    def test_concurrent_update_is_rejected(self):
        import fcntl
        with open(str(self.executable) + '.update.lock', 'wb') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_update()
        self.assertIn('WouldBlock', result.stderr)
        self.assert_preserved()

    def test_font_failure_does_not_report_program_upgrade_failure(self):
        self.font.parent.write_bytes(b'not a directory')
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('font update failed', result.stdout)
        self.assertEqual(self.executable.read_bytes(), self.binary_bytes)


if __name__ == '__main__':
    unittest.main()
