"""Exercise process identity filtering without stopping or launching real apps.

The launch script must select the development identity while leaving production
and unrelated apps alone. Fixtures use real bundle plists and replace only process enumeration.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallationLocationTests(unittest.TestCase):
    """Resolve migration preferences without building, signing, or changing real app installs."""

    def resolve(self, local_id=None, environment_id=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            if local_id is not None:
                subprocess.run(["git", "-C", str(root), "config", "--local",
                                "extensions.worktreeConfig", "true"], check=True)
                subprocess.run(["git", "-C", str(root), "config", "--worktree",
                                "lingrove.devInstallation.checkout123456789abc", local_id], check=True)
            return self.probe(root, environment_id)

    def probe(self, root, environment_id=None, checkout_id="123456789abc"):
        script = (ROOT / "scripts/build_and_run.sh").read_text()
        function = script.split("dev_installation_id() {", 1)[1].split("\n}", 1)[0]
        probe = ('set -euo pipefail\nCHECKOUT_ID=' + checkout_id + '\n'
                 'dev_installation_id() {' + function + '\n}\ndev_installation_id\n')
        environment = {**os.environ, "ROOT_DIR": str(root)}
        environment.pop("LINGROVE_DEV_INSTALLATION_ID", None)
        if environment_id is not None:
            environment["LINGROVE_DEV_INSTALLATION_ID"] = environment_id
        return subprocess.run(["bash", "-c", probe], capture_output=True, text=True, env=environment)

    def test_unconfigured_worktree_keeps_its_own_installation(self):
        result = self.resolve()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "123456789abc")

    def test_moved_checkout_reuses_the_explicit_local_installation(self):
        result = self.resolve(local_id="abcdef123456")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "abcdef123456")

    def test_explicit_environment_takes_precedence_over_local_preference(self):
        result = self.resolve(local_id="abcdef123456", environment_id="fedcba654321")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "fedcba654321")

    def test_invalid_ids_cannot_change_the_install_directory(self):
        for value in ["../production", "ABCDEF123456", "abcdef123456/other", "abcdef123456\nother"]:
            with self.subTest(value=value):
                result = self.resolve(local_id=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_linked_worktree_does_not_inherit_the_main_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "main"
            linked = Path(temporary) / "linked"
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c",
                            "user.email=fixture@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "Fixture"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "--local", "extensions.worktreeConfig", "true"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "--worktree",
                            "lingrove.devInstallation.checkout123456789abc", "abcdef123456"], check=True)
            subprocess.run(["git", "-C", str(root), "worktree", "add", "--quiet", "--detach", str(linked)], check=True)
            self.assertEqual(self.probe(root).stdout.strip(), "abcdef123456")
            self.assertEqual(self.probe(linked, checkout_id="fedcba654321").stdout.strip(), "fedcba654321")

    def test_shared_local_preference_is_not_treated_as_a_worktree_preference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "--local",
                            "lingrove.devInstallation.checkout123456789abc", "abcdef123456"], check=True)
            self.assertEqual(self.probe(root).stdout.strip(), "123456789abc")


@unittest.skipUnless(sys.platform == "darwin", "uses macOS PlistBuddy")
class LaunchIdentityTests(unittest.TestCase):
    def test_only_development_processes_are_selected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for folder, bundle_id in (("dev", "io.ichthyoplanktonzyh.lingrove.dev"),
                                      ("production", "io.ichthyoplanktonzyh.lingrove"),
                                      ("other", "org.example.other")):
                name = "Lingrove Dev"
                contents = root / folder / f"{name}.app" / "Contents"
                contents.mkdir(parents=True)
                (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
            commands = root / "bin"
            commands.mkdir()
            (commands / "pgrep").write_text(
                '#!/bin/bash\ncase "$2" in\n'
                '"Lingrove Dev") printf "101\\n102\\n103\\n104\\n";;\n'
                'esac\n')
            (commands / "ps").write_text(
                '#!/bin/bash\ncase "$3" in\n'
                '101) echo "$FIXTURE_ROOT/dev/Lingrove Dev.app/Contents/MacOS/Lingrove Dev";;\n'
                '102) echo "$FIXTURE_ROOT/production/Lingrove Dev.app/Contents/MacOS/Lingrove Dev";;\n'
                '103) echo "$FIXTURE_ROOT/other/Lingrove Dev.app/Contents/MacOS/Lingrove Dev";;\n'
                '104) exit 1;;\nesac\n')
            for command in commands.iterdir():
                command.chmod(0o755)
            script = (ROOT / "scripts/build_and_run.sh").read_text()
            function = script.split("dev_pids() {", 1)[1].split("\n}", 1)[0]
            probe = 'set -euo pipefail\nAPP_NAME="Lingrove Dev"\nBUNDLE_ID=io.ichthyoplanktonzyh.lingrove.dev\n'
            probe += "dev_pids() {" + function + "\n}\ndev_pids\n"
            result = subprocess.run(["bash", "-c", probe], check=True, capture_output=True, text=True,
                                    env={**os.environ, "FIXTURE_ROOT": str(root),
                                         "PATH": str(commands) + os.pathsep + os.environ["PATH"]})
            self.assertEqual(result.stdout.splitlines(), ["101"])
