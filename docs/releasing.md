# Release checklist

Version is stored in `src/version.txt`. The current release target is `v0.2.1`.

1. Update that version, matching `docs/releases/vX.Y.Z.md`, and review all intended source changes.
2. Run native tests and installer checks: `zig build test`, `zig build -Doptimize=small`, `python3 tests/integration.py`, `zig build build-update-tests -Doptimize=small`, `python3 tests/update.py`, `python3 tests/release.py`, `python3 tests/benchmark.py`. Verify the font with `python3 tests/fonts.py` in an environment containing `tools/font-requirements.txt`.
3. Use **Release → Run workflow** to build downloadable workflow artifacts and test on all four native runners before creating a tag. This manual run does not create a GitHub Release.
4. Review native bash/zsh/PowerShell results, Windows ConPTY tests, font installation and visual behavior in actual terminals. A cross build is not native acceptance.
5. Once the reviewed changes are committed and pushed, create and push the matching `vX.Y.Z` tag. Tagging runs the release workflow again; all native jobs must pass before a **draft** Release is created.
6. Review the draft archives, `SHA256SUMS`, notes, bundled font, and installation instructions. Publish the draft explicitly when ready. Installers using `latest` cannot see drafts.
7. After the first public release, update the README/install-guide preparation notice and test the public download commands on fresh native environments.

The workflow verifies that the tag matches the executable version. It packages only allowlisted files; configuration, credentials, caches, and local helper scripts are not included. No real model requests are required by the tests.

Create an archive locally, without publishing:

```sh
python3 tools/package_release.py --binary zig-out/bin/shell-buddy --platform macos --architecture aarch64
```

Use the actual binary target, not necessarily the host target. The packager validates ELF, Mach-O, or PE architecture and writes the archive, per-archive checksum, and consolidated `dist/SHA256SUMS`.

Initial targets: macOS aarch64, macOS x86_64, Linux x86_64 musl, and Windows x86_64. `dist/` is ignored. Binaries are unsigned and macOS builds are not notarized; the release notes must state this.
