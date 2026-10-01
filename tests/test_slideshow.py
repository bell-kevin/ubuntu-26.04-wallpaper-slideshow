#!/usr/bin/env python3
"""Exercise the slideshow CLI without changing the user's desktop settings.

Run with: python3 -m unittest discover -s tests -v
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[1] / "cycle-desktop-pictures.sh"

# One executable supplies isolated desktop settings, deterministic time/order,
# and a small wallpaper collection. Other utilities use the real filesystem.
FAKE_COMMAND = r'''
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse

name = Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = Path(os.environ["WALLPAPER_TEST_STATE"])

if name == "gsettings":
    state = json.loads(state_path.read_text())
    action = args[0]
    if action == "get":
        print(repr(state.get(args[2], "default")))
    elif action == "set":
        state[args[2]] = args[3]
        state_path.write_text(json.dumps(state))
    elif action != "monitor":
        raise SystemExit("Unexpected gsettings arguments: " + repr(args))
elif name == "gio":
    value = args[-1]
    path = Path(unquote(urlparse(value).path) if value.startswith("file:") else value)
    if not path.exists():
        raise SystemExit(1)
    print("uri: " + path.absolute().as_uri())
    print("local path: " + str(path.absolute()))
elif name == "find":
    if "/usr/share/backgrounds" in args:
        folder = Path(os.environ["WALLPAPER_TEST_PICTURES"])
        for path in sorted(folder.iterdir()):
            if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".jxl"}:
                print(path.resolve())
    else:
        raise SystemExit(subprocess.call([os.environ["WALLPAPER_TEST_REAL_FIND"], *args]))
elif name == "date":
    if args == ["+%s"]:
        print(Path(os.environ["WALLPAPER_TEST_CLOCK"]).read_text().strip())
    else:
        raise SystemExit(subprocess.call([os.environ["WALLPAPER_TEST_REAL_DATE"], *args]))
elif name == "shuf":
    sys.stdout.write(sys.stdin.read())
elif name == "systemctl":
    pass
else:
    raise SystemExit("Unexpected fake command: " + name)
'''


class SlideshowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wallpaper-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.pictures = self.root / "pictures"
        self.pictures.mkdir()
        # Exercise spaces, XML escaping, and URI encoding on real paths.
        self.images = [self.pictures / name for name in ("A & dawn.jpg", "B sunset.png", "C night.webp")]
        for path in self.images:
            path.write_bytes(b"test wallpaper")
        self.state = self.root / "settings.json"
        self.state.write_text(json.dumps({
            "color-scheme": "default",
            "picture-uri": self.images[0].as_uri(),
            "picture-uri-dark": self.images[0].as_uri(),
        }))
        self.clock = self.root / "clock"
        self.epoch = 1800000000
        self.set_time(0)
        commands = self.root / "bin"
        commands.mkdir()
        for name in ("gsettings", "gio", "find", "date", "shuf", "systemctl"):
            command = commands / name
            command.write_text("#!" + sys.executable + "\n" + FAKE_COMMAND)
            command.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home),
            "PATH": str(commands) + os.pathsep + self.env.get("PATH", ""),
            "WALLPAPER_TEST_STATE": str(self.state),
            "WALLPAPER_TEST_PICTURES": str(self.pictures),
            "WALLPAPER_TEST_CLOCK": str(self.clock),
            "WALLPAPER_TEST_REAL_FIND": shutil.which("find"),
            "WALLPAPER_TEST_REAL_DATE": shutil.which("date"),
        })
        self.slideshow_dir = self.home / ".local/share/wallpaper-slideshow"
        self.helper = self.slideshow_dir / "cycle-desktop-pictures.sh"

    def run_script(self, *args, script=SCRIPT, success=True):
        result = subprocess.run(
            ["bash", str(script), *map(str, args)],
            env=self.env, text=True, capture_output=True, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def set_time(self, elapsed):
        self.clock.write_text(str(self.epoch + elapsed))

    def settings(self):
        return json.loads(self.state.read_text())

    def current_file(self):
        return Path(unquote(urlparse(self.settings()["picture-uri"]).path))

    def pick(self, path):
        state = self.settings()
        state["picture-uri"] = path.as_uri()
        state["picture-uri-dark"] = path.as_uri()
        self.state.write_text(json.dumps(state))

    def slides(self):
        root = ET.parse(self.current_file()).getroot()
        static = root.findall("static")
        transitions = root.findall("transition")
        self.assertEqual(len(static), len(transitions))
        result = []
        for item, transition in zip(static, transitions):
            self.assertEqual(transition.findtext("from"), item.findtext("file"))
            self.assertEqual(float(transition.findtext("duration")), 5)
            result.append((Path(item.findtext("file")), int(item.findtext("duration")) + 5))
        for index, transition in enumerate(transitions):
            self.assertEqual(Path(transition.findtext("to")), result[(index + 1) % len(result)][0])
        return result

    def test_override_survives_helper_pick_and_normal_interval_changes(self):
        self.run_script("7")
        self.run_script("--set-duration", "20", self.images[1])
        slides = self.slides()
        self.assertEqual(slides[0], (self.images[1], 1200))
        self.assertEqual(dict(slides), {self.images[0]: 420, self.images[1]: 1200, self.images[2]: 420})

        self.pick(self.images[2])
        self.run_script("--watch", "7", script=self.helper)
        self.assertEqual(self.slides()[0], (self.images[2], 420))
        self.assertEqual(dict(self.slides())[self.images[1]], 1200)

        self.run_script("10")
        self.assertEqual(dict(self.slides()), {self.images[0]: 600, self.images[1]: 1200, self.images[2]: 600})
        self.run_script("--reset-duration", self.images[1])
        self.assertEqual(self.slides()[0], (self.images[1], 600))
        self.assertEqual(set(dict(self.slides()).values()), {600})

    def test_current_picture_can_be_extended_and_reset(self):
        self.run_script("5")
        self.set_time(400)
        self.run_script("--set-duration", "20")
        self.assertEqual(self.slides()[0], (self.images[1], 1200))
        self.run_script("--reset-duration")
        self.assertEqual(self.slides()[0], (self.images[1], 300))
        self.assertEqual(set(dict(self.slides()).values()), {300})

    def test_existing_helper_interval_is_preserved_when_upgrading(self):
        unit = self.home / ".config/systemd/user/wallpaper-slideshow.service"
        unit.parent.mkdir(parents=True)
        unit.write_text(
            "[Service]\n"
            "ExecStart=%h/.local/share/wallpaper-slideshow/cycle-desktop-pictures.sh --watch 7\n"
        )
        self.run_script("--set-duration", "20", self.images[1])
        self.assertEqual(dict(self.slides()), {self.images[0]: 420, self.images[1]: 1200, self.images[2]: 420})

    def test_symlink_shares_preference_with_canonical_picture(self):
        alias = self.pictures / "Alias sunset.png"
        alias.symlink_to(self.images[1])
        self.run_script("--set-duration", "20", alias)
        self.assertEqual(self.slides()[0], (self.images[1], 1200))
        self.assertEqual(len(self.slides()), 3)
        self.run_script("--set-duration", "30", self.images[1])
        self.assertEqual(len(list((self.slideshow_dir / "durations").iterdir())), 1)
        self.pick(alias)
        self.run_script("--watch", "5", script=self.helper)
        self.assertEqual(self.slides()[0], (self.images[1], 1800))
        self.run_script("--reset-duration", alias)
        self.assertEqual(dict(self.slides())[self.images[1]], 300)

    def test_stop_finds_picture_using_variable_durations_and_cleans_up(self):
        self.run_script("--set-duration", "20", self.images[1])
        self.run_script("5")
        self.set_time(700)
        self.run_script("--stop")
        self.assertEqual(self.current_file(), self.images[1])
        self.assertEqual(self.settings()["picture-uri"], self.settings()["picture-uri-dark"])
        self.assertFalse(self.slideshow_dir.exists())
        self.assertFalse((self.home / ".config/systemd/user/wallpaper-slideshow.service").exists())

    def test_picture_showing_boundaries_and_cycle_wrap(self):
        self.run_script("--set-duration", "20", self.images[1])
        self.run_script("5")
        slideshow = self.current_file()
        definitions = SCRIPT.read_text().rsplit("\ncase $action in\n", 1)[0]
        probe = self.root / "picture-showing.sh"
        probe.write_text(definitions + '\npicture_showing "$WALLPAPER_TEST_SLIDESHOW"\n')
        self.env["WALLPAPER_TEST_SLIDESHOW"] = str(slideshow)
        for elapsed, expected in (
            (0, self.images[0]), (299, self.images[0]),
            (300, self.images[1]), (1499, self.images[1]),
            (1500, self.images[2]), (1799, self.images[2]),
            (1800, self.images[0]), (2100, self.images[1]),
        ):
            with self.subTest(elapsed=elapsed):
                self.set_time(elapsed)
                result = self.run_script(script=probe)
                self.assertEqual(result.stdout.strip(), str(expected))

        # Older installations used only the epoch in their XML filename.
        legacy = self.slideshow_dir / f"slideshow-{self.epoch}.xml"
        shutil.copyfile(slideshow, legacy)
        self.env["WALLPAPER_TEST_SLIDESHOW"] = str(legacy)
        self.set_time(700)
        self.assertEqual(self.run_script(script=probe).stdout.strip(), str(self.images[1]))

    def test_same_second_updates_use_distinct_slideshow_files(self):
        self.run_script("5")
        first = self.current_file()
        self.run_script("--set-duration", "20", self.images[1])
        second = self.current_file()
        self.assertNotEqual(first, second)
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertEqual(list(self.slideshow_dir.glob("slideshow-*.xml")), [second])

    def test_pause_freezes_extended_slide_and_resume_starts_a_fresh_interval(self):
        self.run_script("--set-duration", "20", self.images[1])
        self.run_script("7")
        # The second slide is still showing well after its normal interval.
        self.set_time(1300)
        preferences = {
            path.name: path.read_text()
            for path in (self.slideshow_dir / "durations").iterdir()
        }
        self.run_script("--pause")
        paused = self.slideshow_dir / "paused"
        self.assertTrue(paused.is_file())
        self.assertEqual(self.current_file(), self.images[1])
        self.assertEqual(self.settings()["picture-uri-dark"], self.images[1].as_uri())
        self.assertEqual((self.slideshow_dir / "interval").read_text().strip(), "7")
        self.assertTrue(self.helper.is_file())
        self.assertTrue((self.home / ".config/systemd/user/wallpaper-slideshow.service").is_file())

        # A helper started on a later login must leave the static picture alone.
        self.set_time(7 * 86400)
        self.run_script("--watch", "7", script=self.helper)
        self.run_script("--pause", script=self.helper)
        self.assertTrue(paused.is_file())
        self.assertEqual(self.current_file(), self.images[1])
        self.assertEqual(preferences, {
            path.name: path.read_text()
            for path in (self.slideshow_dir / "durations").iterdir()
        })

        self.run_script("--resume", script=self.helper)
        self.assertFalse(paused.exists())
        self.assertEqual(self.slides()[0], (self.images[1], 1200))
        self.assertEqual(dict(self.slides()), {
            self.images[0]: 420, self.images[1]: 1200, self.images[2]: 420,
        })
        # Pausing again just short of twenty minutes proves resume reset time.
        self.set_time(7 * 86400 + 1199)
        self.run_script("--pause")
        self.assertEqual(self.current_file(), self.images[1])

    def test_pause_uses_dark_picture_and_allows_manual_picks_until_unpaused(self):
        self.run_script("5")
        state = self.settings()
        state["color-scheme"] = "prefer-dark"
        state["picture-uri-dark"] = self.images[2].as_uri()
        self.state.write_text(json.dumps(state))
        self.run_script("--pause")
        self.assertEqual(self.current_file(), self.images[2])
        self.assertEqual(self.settings()["picture-uri-dark"], self.images[2].as_uri())

        # Settings may change only the dark key. The watcher must ignore the
        # pick and resume must use the image actually visible in dark style.
        state = self.settings()
        state["picture-uri-dark"] = self.images[1].as_uri()
        self.state.write_text(json.dumps(state))
        self.set_time(86400)
        self.run_script("--watch", "5", script=self.helper)
        self.assertEqual(self.settings(), state)
        self.run_script("--unpause", script=self.helper)
        self.assertFalse((self.slideshow_dir / "paused").exists())
        self.assertEqual(self.slides()[0], (self.images[1], 300))
        self.assertEqual(self.settings()["picture-uri"], self.settings()["picture-uri-dark"])

    def test_explicit_pause_keeps_selected_picture_and_can_change_it(self):
        self.run_script("7")
        self.run_script("--pause", self.images[2])
        self.assertEqual(self.current_file(), self.images[2])
        self.run_script("--pause", self.images[1], script=self.helper)
        self.assertEqual(self.current_file(), self.images[1])
        self.run_script("--watch", "7", script=self.helper)
        self.assertEqual(self.current_file(), self.images[1])
        self.run_script("--resume")
        self.assertEqual(self.slides()[0], (self.images[1], 420))

    def test_interval_and_duration_edits_preserve_pause(self):
        self.run_script("7")
        self.run_script("--set-duration", "20", self.images[1])
        self.run_script("--pause", self.images[2])
        frozen = self.settings()
        for args in (
            ("10",),
            ("--set-duration", "30", self.images[0]),
            ("--reset-duration", self.images[1]),
            ("--set-duration", "40"),
        ):
            with self.subTest(args=args):
                self.run_script(*args)
                self.assertEqual(self.settings(), frozen)
                self.assertTrue((self.slideshow_dir / "paused").is_file())
                self.run_script("--watch", "10", script=self.helper)
                self.assertEqual(self.settings(), frozen)
        self.assertEqual((self.slideshow_dir / "interval").read_text().strip(), "10")
        self.run_script("--resume")
        self.assertEqual(self.slides()[0], (self.images[2], 2400))
        self.assertEqual(dict(self.slides()), {
            self.images[0]: 1800, self.images[1]: 600, self.images[2]: 2400,
        })

    def test_repeated_resume_keeps_existing_slideshow_and_elapsed_time(self):
        self.run_script("7")
        self.run_script("--pause")
        self.run_script("--resume")
        slideshow = self.current_file()
        self.set_time(400)
        self.run_script("--resume")
        self.run_script("--unpause", script=self.helper)
        self.assertEqual(self.current_file(), slideshow)
        self.set_time(450)
        self.run_script("--pause")
        self.assertEqual(self.current_file(), self.images[1])

    def test_stop_while_paused_keeps_picture_and_removes_saved_configuration(self):
        self.run_script("--set-duration", "20", self.images[1])
        self.run_script("--pause", self.images[2])
        self.set_time(86400)
        self.run_script("--stop", script=self.helper)
        self.assertEqual(self.current_file(), self.images[2])
        self.assertEqual(self.settings()["picture-uri-dark"], self.images[2].as_uri())
        self.assertFalse(self.slideshow_dir.exists())
        self.assertFalse((self.home / ".config/systemd/user/wallpaper-slideshow.service").exists())

    def test_invalid_pause_does_not_change_existing_paused_configuration(self):
        self.run_script("--set-duration", "20", self.images[1])
        self.run_script("--pause", self.images[2])
        frozen = self.settings()
        saved = {
            str(path.relative_to(self.slideshow_dir)): path.read_bytes()
            for path in self.slideshow_dir.rglob("*") if path.is_file()
        }
        self.run_script("--pause", self.root / "missing.jpg", success=False)
        self.assertEqual(self.settings(), frozen)
        self.assertEqual(saved, {
            str(path.relative_to(self.slideshow_dir)): path.read_bytes()
            for path in self.slideshow_dir.rglob("*") if path.is_file()
        })

    def test_invalid_arguments_leave_settings_unchanged(self):
        original = self.settings()
        invalid = (
            ("--set-duration",), ("--set-duration", "0"),
            ("--set-duration", "-1"), ("--set-duration", "1.5"),
            ("--set-duration", "no"),
            ("--set-duration", "20", self.root / "missing.jpg"),
            ("--set-duration", "20", self.state),
            ("--set-duration", "20", self.images[0], "extra"),
            ("--reset-duration", self.images[0], "extra"),
            ("--pause", ""), ("--pause", self.root / "missing.jpg"),
            ("--pause", self.state), ("--pause", self.images[0], "extra"),
            ("--resume", "extra"), ("--unpause", "extra"),
            ("--stop", "extra"), ("5", "extra"), ("--unknown",),
        )
        for args in invalid:
            with self.subTest(args=args):
                self.run_script(*args, success=False)
                self.assertEqual(self.settings(), original)


if __name__ == "__main__":
    unittest.main()
