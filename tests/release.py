"""Offline release bundles and installers; all writes stay in temporary directories."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_release', ROOT / 'tools/package_release.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
BINARY = Path(os.environ.get('SHELL_BUDDY_TEST_BIN', ROOT/'zig-out/bin'/('shell-buddy.exe' if os.name=='nt' else 'shell-buddy'))).resolve()
PLATFORM = 'windows' if os.name=='nt' else ('macos' if sys.platform=='darwin' else 'linux')
ARCH = 'aarch64' if platform.machine().lower() in ('arm64','aarch64') else 'x86_64'


class Release(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shell-buddy-release-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = packager.package(BINARY, PLATFORM, ARCH, self.directory/'downloads')
        self.extracted = self.directory/'extracted'
        self.extracted.mkdir()
        if self.archive.suffix == '.zip':
            with zipfile.ZipFile(self.archive) as archive: archive.extractall(self.extracted)
        else:
            with tarfile.open(self.archive) as archive: archive.extractall(self.extracted)
        self.bundle = self.extracted/'shell-buddy'
        self.bin_dir, self.font_dir = self.directory/'binary with spaces', self.directory/'font with spaces'
        self.env = os.environ.copy()
        # Font cache refresh is irrelevant to file installation tests.
        if os.name != 'nt':
            fake = self.directory/'fake tools'
            fake.mkdir()
            cache = fake/'fc-cache'
            cache.write_text('#!/bin/sh\nexit 0\n');cache.chmod(0o755)
            self.env['PATH'] = str(fake) + os.pathsep + self.env.get('PATH','')
            self.fake = fake

    def local_install(self, no_font=False):
        if os.name == 'nt':
            command = ['pwsh','-NoLogo','-NoProfile','-File',str(self.bundle/'install.ps1'),'-BinDir',str(self.bin_dir),'-FontDir',str(self.font_dir),'-SkipFontRegistration']
            if no_font: command.append('-NoFont')
        else:
            command = ['sh',str(self.bundle/'install.sh'),'--bin-dir',str(self.bin_dir),'--font-dir',str(self.font_dir)]
            if no_font: command.append('--no-font')
        return subprocess.run(command,env=self.env,capture_output=True,text=True,timeout=20)

    def test_bundle_checksum_and_reproducible_archive(self):
        expected = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        manifest = self.archive.parent.joinpath('SHA256SUMS').read_text()
        self.assertEqual(manifest, expected+'  '+self.archive.name+'\n')
        again = packager.package(BINARY,PLATFORM,ARCH,self.directory/'again')
        self.assertEqual(again.read_bytes(),self.archive.read_bytes())
        meta = json.loads(self.bundle.joinpath('release.json').read_text())
        self.assertEqual(meta['default_icon'],'star')
        self.assertTrue(self.bundle.joinpath('fonts/ShellBuddyIcons.ttf').is_file())
        self.assertFalse(any(self.bundle.rglob('credentials.json')))
        self.assertFalse(any(self.bundle.rglob('config.json')))

    def test_bundle_installs_program_and_font_by_default(self):
        result = self.local_install()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        installed = self.bin_dir/('shell-buddy.exe' if os.name=='nt' else 'shell-buddy')
        self.assertEqual(installed.read_bytes(),BINARY.read_bytes())
        self.assertEqual(self.font_dir.joinpath('ShellBuddyIcons.ttf').read_bytes(),ROOT.joinpath('fonts/ShellBuddyIcons.ttf').read_bytes())
        self.assertEqual(subprocess.check_output([str(installed),'--version'],text=True).strip(),ROOT.joinpath('src/version.txt').read_text().strip())
        self.assertIn('terminal',result.stdout.lower())

    def test_font_can_be_skipped(self):
        result = self.local_install(no_font=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(self.font_dir.exists())

    @unittest.skipIf(os.name=='nt','POSIX bootstrap; native Windows bundle installer is tested above')
    def test_download_installer_verifies_hash_and_installs_bundled_font(self):
        curl = self.fake/'curl'
        curl.write_text('#!'+sys.executable+'\nimport os,sys,shutil\nfrom pathlib import Path\nurl=next(a for a in sys.argv if a.startswith("https://"))\nout=sys.argv[sys.argv.index("--output")+1]\nshutil.copyfile(Path(os.environ["SB_RELEASE_FIXTURE"])/url.rsplit("/",1)[-1],out)\n')
        curl.chmod(0o755)
        self.env['SB_RELEASE_FIXTURE'] = str(self.archive.parent)
        command = ['sh',str(ROOT/'install.sh'),'--version','v0.1.0','--','--bin-dir',str(self.bin_dir),'--font-dir',str(self.font_dir)]
        result = subprocess.run(command,env=self.env,capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(self.font_dir.joinpath('ShellBuddyIcons.ttf').exists())
        # A second download with a changed archive must fail before installing.
        self.archive.write_bytes(self.archive.read_bytes()+b'corrupt')
        fresh_bin, fresh_font = self.directory/'must not install',self.directory/'must not install font'
        result = subprocess.run(command[:-4]+['--bin-dir',str(fresh_bin),'--font-dir',str(fresh_font)],env=self.env,capture_output=True,text=True,timeout=20)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('checksum mismatch',result.stderr)
        self.assertFalse(fresh_bin.exists())
        self.assertFalse(fresh_font.exists())

    def test_rejects_invalid_target_and_version(self):
        with self.assertRaises(ValueError): packager.package(BINARY,'linux','aarch64',self.directory/'bad')
        with self.assertRaises(ValueError): packager.package(BINARY,PLATFORM,ARCH,self.directory/'bad',version='../bad')
        mismatched = 'windows' if PLATFORM != 'windows' else 'linux'
        with self.assertRaises(ValueError): packager.package(BINARY,mismatched,'x86_64',self.directory/'bad')
        if PLATFORM == 'macos':
            with self.assertRaises(ValueError): packager.package(BINARY,'macos','x86_64' if ARCH=='aarch64' else 'aarch64',self.directory/'bad')
        self.assertFalse(self.directory.joinpath('bad').exists())

    @unittest.skipUnless(os.name=='nt','Windows bootstrap runs on the native Windows CI runner')
    def test_windows_download_installer_verifies_hash_before_install(self):
        # Shadow only the download function; extraction, hash verification and
        # the bundled installer run for real. No host font registration occurs.
        harness = self.directory/'bootstrap-test.ps1'
        harness.write_text('''param([string]$Installer,[string]$Fixture,[string]$BinDir)
$ErrorActionPreference = 'Stop'
function Invoke-WebRequest {
    param([string]$Uri,[string]$OutFile)
    $name = ([uri]$Uri).Segments[-1]
    Copy-Item -LiteralPath (Join-Path $Fixture $name) -Destination $OutFile
}
& $Installer -Version v0.1.0 -BinDir $BinDir -NoFont
''',encoding='utf-8')
        command = ['pwsh','-NoLogo','-NoProfile','-File',str(harness),'-Installer',str(ROOT/'install.ps1'),'-Fixture',str(self.archive.parent),'-BinDir',str(self.bin_dir)]
        result = subprocess.run(command,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.bin_dir.joinpath('shell-buddy.exe').read_bytes(),BINARY.read_bytes())
        self.archive.write_bytes(self.archive.read_bytes()+b'corrupt')
        fresh = self.directory/'must not install'
        result = subprocess.run(command[:-1]+[str(fresh)],capture_output=True,text=True,timeout=30)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('checksum mismatch',result.stderr)
        self.assertFalse(fresh.exists())


if __name__=='__main__': unittest.main(verbosity=2)
