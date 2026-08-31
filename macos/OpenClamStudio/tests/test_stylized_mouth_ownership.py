"""Actual renderer-helper regressions for detached cartoon mouth corners.

The old difference matte preserved low-contrast neutral lip stubs; its oval
also feathered the canonical corners to 18–46% on the reported soft-3D face.
These tests execute the shipped JS helpers, including atlas-cell clipping.
"""
import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "web/index.html").read_text()


def helper(name):
    match = re.search(
        rf"(const {name} = [\s\S]*?\n    (?:\}};|\);))", SOURCE)
    if match is None:
        raise AssertionError(f"Missing renderer helper {name}")
    return match.group(1)


def run_js(body):
    setup = """
      const expressionSmoothStep = value => {
        const x = Math.max(0, Math.min(1, Number(value) || 0));
        return x * x * (3 - 2 * x);
      };
      const manifest = {stylized_mouth: {
        box: [391, 694, 242, 124],
        viseme_x_offsets: {aa: .6376, ou: 1.8764, negative: -20, outside: 240}
      }};
    """
    definitions = "\n".join(helper(name) for name in (
        "runtimeBox", "stylizedVisemeGeometry", "stylizedMouthRegistration",
        "stylizedEmotionMouthPlacement", "stylizedMouthMaskAlpha",
        "stylizedMouthDifferenceAlpha", "stylizedMouthOwnershipAlpha",
    ))
    result = subprocess.run(
        ["node", "-e", setup + definitions + "\n" + body],
        check=True, text=True, capture_output=True,
    )
    return json.loads(result.stdout)


class StylizedMouthOwnershipTests(unittest.TestCase):
    def test_original_smile_corners_and_all_expression_extents_are_owned(self):
        result = run_js("""
          // Measured canonical corners + extreme authored smile/horror lips,
          // in portrait coordinates. No Sarah identity is needed by the rule.
          const points = [[431.886,729.977], [592.757,725.853],
            [429.017,744], [593.921,744], [510,707.587], [510,796.051]];
          console.log(JSON.stringify(points.map(([x,y]) => {
            const coverage = stylizedMouthMaskAlpha(x-391,y-694,242,124);
            return [coverage, stylizedMouthOwnershipAlpha(2,coverage)];
          })));
        """)
        self.assertEqual([[1, 1]] * 6, result)

    def test_low_contrast_old_corner_is_replaced_not_crossfaded(self):
        result = run_js("""
          const coverage = stylizedMouthMaskAlpha(202,32,242,124);
          const oldCorner = [130,70,55], replacementSkin = [139,78,62];
          const alpha = stylizedMouthOwnershipAlpha(9,coverage);
          console.log(JSON.stringify(replacementSkin.map((value,i) =>
            value*alpha + oldCorner[i]*(1-alpha))));
        """)
        self.assertEqual([139, 78, 62], result)

    def test_nose_and_rectangular_corners_remain_untouched(self):
        result = run_js("""
          console.log(JSON.stringify([[121,0],[0,0],[241,0],[0,123],[241,123]]
            .map(([x,y]) => stylizedMouthOwnershipAlpha(255,
              stylizedMouthMaskAlpha(x,y,242,124)))));
        """)
        self.assertEqual([0] * 5, result)

    def test_unchanged_exterior_skin_does_not_become_an_opaque_sticker(self):
        result = run_js("""
          console.log(JSON.stringify([0,.2,.5,.72].map(coverage =>
            stylizedMouthOwnershipAlpha(3,coverage))));
        """)
        self.assertEqual([0] * 4, result)

    def test_ownership_and_skin_feather_are_bounded_and_continuous(self):
        result = run_js("""
          const values = [];
          for (let i=0;i<=1000;i++) values.push(stylizedMouthOwnershipAlpha(2,i/1000));
          console.log(JSON.stringify({min:Math.min(...values),max:Math.max(...values),
            monotone:values.every((v,i) => !i || v>=values[i-1]),
            largestStep:Math.max(...values.slice(1).map((v,i)=>v-values[i]))}));
        """)
        self.assertEqual(0, result["min"])
        self.assertEqual(1, result["max"])
        self.assertTrue(result["monotone"])
        self.assertLess(result["largestStep"], .01)

    def test_real_atlas_crop_never_reads_next_emotion_cell(self):
        result = run_js("""
          console.log(JSON.stringify(stylizedEmotionMouthPlacement(
            {box:[380,658,265,148],states:[0,.18,.34,.68,1]},
            {state:2,row:10},'aa')));
        """)
        self.assertAlmostEqual(10.3624, result["sourceX"])
        self.assertEqual(52 * 148 + 36, result["sourceY"])
        self.assertEqual(112, result["sourceHeight"])
        self.assertEqual(242, result["sourceWidth"])
        self.assertEqual([242, 124], [result["width"], result["height"]])
        self.assertEqual([391, 694],
                         [result["destinationX"], result["destinationY"]])

    def test_left_top_clipping_preserves_patch_location_not_scale(self):
        result = run_js("""
          console.log(JSON.stringify(stylizedEmotionMouthPlacement(
            {box:[410,710,200,80],states:[0,1]},
            {state:1,row:1},'ou')));
        """)
        self.assertEqual(0, result["sourceX"])
        self.assertEqual(3 * 80, result["sourceY"])
        self.assertAlmostEqual(20.8764, result["patchX"])
        self.assertEqual(16, result["patchY"])
        self.assertEqual([200, 80],
                         [result["sourceWidth"], result["sourceHeight"]])
        self.assertEqual([242, 124], [result["width"], result["height"]])

    def test_negative_registration_keeps_its_sign_before_cell_clip(self):
        result = run_js("""
          console.log(JSON.stringify(stylizedEmotionMouthPlacement(
            {box:[380,658,265,148],states:[0,1]},
            {state:0,row:0},'negative')));
        """)
        self.assertEqual(31, result["sourceX"])
        self.assertEqual(234, result["sourceWidth"])
        self.assertEqual(0, result["patchX"])

    def test_disjoint_atlas_cell_fails_closed(self):
        result = run_js("""
          console.log(JSON.stringify(stylizedEmotionMouthPlacement(
            {box:[0,0,100,100],states:[0,1]},
            {state:0,row:0},'aa')));
        """)
        self.assertIsNone(result)

    def test_one_resolved_mouth_and_original_photo_branch(self):
        head = helper("composeHead")
        neutral_setup = head[:head.index("const blink =")]
        self.assertNotIn("drawStylizedVisemePatch(", neutral_setup)
        self.assertIn("if (stylizedRuntime && !stylizedMouthDrawn)", head)
        self.assertIn("stylizedMouthDrawn = drawStylizedEmotionMouthSample(", head)
        self.assertIn("faceContext.globalAlpha = blend;", neutral_setup)
        self.assertIn("Photorealistic runtimes retain the reviewed full-frame crossfade",
                      neutral_setup)
        patch = helper("prepareStylizedMouthPatch")
        self.assertLess(patch.index("selectedImage, x - registration"),
                        patch.index("patchContext.drawImage(emotionImage"))
        self.assertIn("placement.sourceWidth, placement.sourceHeight", patch)


if __name__ == "__main__":
    unittest.main()
