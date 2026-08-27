"""Focused desktop-avatar mechanics after removal of cross-app runtimes."""
import importlib
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def load_avatar_modules():
    """Load algorithm modules without requiring the packaged detector wheel."""
    injected = {}
    try:
        missing_mediapipe = importlib.util.find_spec("mediapipe") is None
    except ValueError:
        # A discovery harness may already have installed a spec-less stub.
        missing_mediapipe = "mediapipe" not in sys.modules
    if missing_mediapipe:
        mediapipe = types.ModuleType("mediapipe")
        tasks = types.ModuleType("mediapipe.tasks")
        python = types.ModuleType("mediapipe.tasks.python")
        vision = types.ModuleType("mediapipe.tasks.python.vision")
        tasks.python = python
        python.vision = vision
        mediapipe.tasks = tasks
        injected = {
            "mediapipe": mediapipe,
            "mediapipe.tasks": tasks,
            "mediapipe.tasks.python": python,
            "mediapipe.tasks.python.vision": vision,
        }
    with mock.patch.dict(sys.modules, injected):
        cutout = importlib.import_module("studio.cutout")
        body = importlib.import_module("studio.body")
        motion = importlib.import_module("studio.motion")
    return cutout, body, motion


class DesktopAvatarSurfaceTests(unittest.TestCase):
    def setUp(self):
        self.page = (ROOT / "web" / "index.html").read_text(encoding="utf-8")
        self.shell = (ROOT / "electron" / "main.cjs").read_text(encoding="utf-8")
        self.server = (ROOT / "server" / "app.py").read_text(encoding="utf-8")

    def test_avatar_window_remains_transparent_click_through_and_always_on_top(self):
        self.assertIn("transparent: true", self.shell)
        self.assertIn("frame: false", self.shell)
        self.assertIn("setIgnoreMouseEvents", self.shell)
        self.assertIn("screen.getCursorScreenPoint()", self.shell)
        self.assertIn("setAlwaysOnTop", self.shell)

    def test_regular_ptt_and_livekit_live_talk_have_separate_routes(self):
        self.assertIn("fetch('/stt'", self.page)
        self.assertIn("/api/livekit/session", self.page)
        self.assertIn('src="/livekit-client.js"', self.page)
        self.assertIn("/live-talk-connection.wav", self.page)
        self.assertIn('@app.post("/reply")', self.server)
        self.assertIn('@app.post("/say")', self.server)
        self.assertIn('@app.post("/stt")', self.server)
        self.assertIn('@app.post("/api/livekit/session")', self.server)

    def test_runtime_assets_resolve_through_the_active_avatar(self):
        self.assertIn('@app.get("/assets/{path:path}")', self.server)
        marker = self.server.index('@app.get("/assets/{path:path}")')
        window = self.server[marker:marker + 500]
        self.assertIn("active_slug()", window)
        self.assertIn("_safe_file(runtime_dir(s), path)", window)


class MatteMechanicsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cutout, cls.body, cls.motion = load_avatar_modules()

    def test_edge_decontamination_replaces_plate_tint_with_subject_color(self):
        image = np.zeros((40, 40, 4), np.uint8)
        image[6:34, 6:34, :3] = (0, 255, 0)
        image[6:34, 6:34, 3] = 80
        image[8:32, 8:32, :3] = (40, 60, 180)
        image[8:32, 8:32, 3] = 255
        cleaned = self.cutout._decontaminate_edges(image.copy())
        edge = cleaned[7, 20, :3]
        self.assertGreater(int(edge[2]), int(edge[1]))
        self.assertEqual(80, int(cleaned[7, 20, 3]))

    def test_white_plate_refinement_cuts_pockets_and_keeps_cream_wardrobe(self):
        """Legacy test id: off-white is now deliberately a plate colour.

        Body authoring forbids white/off-white garments, shoes, and soles. A
        matte cannot safely distinguish that wardrobe from a compressed white
        floor shadow, so the hard exterior-plate gate must reject it while a
        clearly non-white wardrobe colour remains intact.
        """
        source = np.full((200, 200, 3), 255, np.uint8)
        source[40:160, 60:140] = (30, 30, 190)
        source[150:196, 90:108] = (225, 236, 245)
        source[150:196, 116:134] = (45, 55, 210)
        source[70:100, 120:138] = 255
        source[70:80, 138:200] = 255
        alpha = np.zeros((200, 200), np.uint8)
        alpha[38:198, 55:145] = 255
        refined = self.motion._refine_white_matte(source, np.dstack([source, alpha]))
        output = refined[:, :, 3]
        self.assertLess(int(output[85, 130]), 40)
        self.assertEqual(255, int(output[100, 100]))
        self.assertLess(int(output[170, 100]), 40)
        self.assertGreater(int(output[170, 124]), 200)

    def test_normalised_frames_preserve_transparency_and_never_upscale(self):
        frame = np.zeros((240, 180, 4), np.uint8)
        frame[20:220, 30:150, :3] = (50, 100, 180)
        frame[20:220, 30:150, 3] = 255
        frames, bounds, scale = self.motion._normalise_frames(
            [frame], include_scale=True
        )
        self.assertLessEqual(scale, 1.0)
        self.assertEqual((self.motion.TARGET_HEIGHT, self.motion.TARGET_WIDTH, 4),
                         frames[0].shape)
        self.assertTrue(np.all(frames[0][:, :, :3][frames[0][:, :, 3] == 0] == 0))
        self.assertGreater(bounds[2], 0)
        self.assertGreater(bounds[3], 0)


class MotionAuthoringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _cutout, cls.body, cls.motion = load_avatar_modules()

    def test_walk_presets_keep_complete_in_place_cycles(self):
        self.assertEqual("office", self.motion.DEFAULT_WALK_STYLE)
        self.assertEqual(
            {"office", "runway", "stroll", "power", "promenade", "cartwheel"},
            set(self.motion.WALK_STYLE_PRESETS),
        )
        for style_id in ("office", "runway", "stroll", "power", "promenade"):
            prompt = self.motion._walk_video_prompt(style_id)
            self.assertIn("IN PLACE", prompt)
            self.assertIn("EXACT first frame and the EXACT final frame", prompt)
        self.assertEqual("traversal", self.motion.resolve_walk_style("cartwheel")["validation"])

    def test_custom_walk_and_move_prompts_are_validated(self):
        custom = self.motion.resolve_walk_style(
            "custom", "a gentle in-place two-step with compact arm movement"
        )
        self.assertEqual("custom", custom["id"])
        self.assertIn("gentle", custom["prompt"])
        with self.assertRaisesRegex(ValueError, "at least"):
            self.motion.resolve_walk_style("custom", "spin")
        move = self.motion.resolve_move_style(
            "custom", "vogue with sharp arm frames and a final pose"
        )
        self.assertEqual("free", move["validation"])

    def test_body_prompt_keeps_user_notes_and_public_decency_floor(self):
        direction = self.body._direction({
            "prompt": "Tailored navy evening suit",
            "notes": "keep the red glasses",
        })
        self.assertIn("Tailored navy evening suit", direction)
        self.assertIn("MUST KEEP: keep the red glasses", direction)
        default = self.body.DEFAULT_BODY_PROMPT.lower()
        for phrase in ("opaque", "no nudity", "both hands stay empty"):
            self.assertIn(phrase, default)

    def test_gait_metrics_turn_stride_into_ground_speed(self):
        frames = []
        for separation in (26, 38, 52, 38):
            frame = np.zeros(
                (self.motion.TARGET_HEIGHT, self.motion.TARGET_WIDTH, 4), np.uint8
            )
            center = self.motion.TARGET_WIDTH // 2
            cv2.circle(frame, (center - separation // 2, 900), 24,
                       (120, 120, 120, 255), -1)
            cv2.circle(frame, (center + separation // 2, 900), 24,
                       (120, 120, 120, 255), -1)
            frames.append(frame)
        metrics = self.motion._gait_metrics(
            frames, 24, [200, 200, 320, 800]
        )
        self.assertGreater(metrics["stride_pixels"], 0)
        self.assertGreater(metrics["ground_speed"], 0)
        self.assertAlmostEqual(
            metrics["ground_speed"],
            metrics["stride_pixels"] / metrics["cycle_seconds"],
            delta=0.5,
        )


if __name__ == "__main__":
    unittest.main()
