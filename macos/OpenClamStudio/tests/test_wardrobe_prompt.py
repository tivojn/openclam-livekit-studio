"""The full-body brief is written from the portrait, not from a fixed paragraph.

These tests pin the things that actually matter: the brief adapts to the
subject, the rig-breaking garment families and carried props never survive,
glasses worn in the upload survive into every generated plate, and every failure
path lands on the static preset instead of breaking Full Body Studio.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
import cv2

from studio import body, generate, wardrobe
from server import app as server_app


ROOT = Path(__file__).resolve().parents[1]

FASHION = {
    "presentation": "feminine", "age_band": "young adult", "medium": "photograph",
    "register": "fashion-forward contemporary womenswear",
    "profession": "creative director", "palette": ["ivory", "scarlet", "platinum"],
    "direction": (
        "Dress her in one precisely cut scarlet lightweight silk-crepe office sheath "
        "with a modest bateau neckline, clean defined waist, professional ease, and "
        "a crisp hem 6cm above the knee. Keep scarlet as the vivid single hero and use only black "
        "as the quiet grounding tone. Omit jewellery and keep the styling visually "
        "clean. Finish with sleek pointed black killer stilettos at 110 millimetres "
        "with a fine heel shaft. Everything stays opaque, fluid, and impeccably "
        "fitted so the supermodel silhouette reads cleanly at full length."
    ),
}

HERO = {
    "presentation": "masculine", "age_band": "adult", "medium": "game art",
    "register": "mythic Chinese action-game hero", "profession": "warrior monk",
    "palette": ["lacquer black", "burnished bronze", "ember orange"],
    "direction": (
        "Render him in high-detail lacquered bronze scale armour over a fitted "
        "dark underlayer, with articulated shoulder plating, engraved bracers, "
        "and close-fitted greaves that keep the leg line readable. Surface the "
        "metal with edge wear, soot and micro-scratches at eight-K fidelity. "
        "Lacquer black carries the costume, burnished bronze is the hero metal, "
        "ember orange lights the trim. Use one restrained engraved chest "
        "fastening, with no other ornament. Light with a warm practical key and a cool rim to "
        "separate the armour silhouette from the background."
    ),
}

MENSWEAR = {
    "presentation": "masculine", "age_band": "adult", "medium": "photograph",
    "register": "minimal luxury menswear", "profession": "architect",
    "palette": ["scarlet", "charcoal", "platinum"],
    "direction": (
        "Dress him in a precisely cut scarlet lightweight double-breasted suit "
        "with a sculpted shoulder, controlled waist, slim straight trousers, "
        "and a charcoal fine-gauge knit. Keep scarlet as the single hero "
        "colour, platinum as the restrained accent, and charcoal as the neutral. "
        "Use lightweight opaque stretch crepe with crisp lapels and clean seam tension. "
        "Choose one slim platinum watch and no other accessories. Finish "
        "with polished black leather Oxfords. Keep every line opaque, fitted, and "
        "editorially refined from shoulder to ankle."
    ),
}

ANDROGYNOUS = {
    "presentation": "androgynous", "age_band": "young adult",
    "medium": "photograph", "register": "architectural minimal tailoring",
    "profession": "designer", "palette": ["coral", "black", "silver"],
    "direction": (
        "Build a close-cut coral lightweight crepe jacket with architectural seaming over a "
        "black silk-knit column and slim tailored trousers. Coral is the single "
        "hero colour, brushed silver is the restrained accent, and black is the "
        "neutral foundation. Keep the line elongated and clean with believable "
        "lightweight structure and silk-knit drape. Use one slim silver cuff with no "
        "other accessories and polished black ankle boots. The result stays "
        "opaque, poised, minimal, and presentation-neutral."
    ),
}


def _portrait(directory, name="head.png"):
    image = np.full((256, 256, 3), 180, dtype=np.uint8)
    cv2.circle(image, (128, 120), 60, (120, 90, 70), -1)
    path = os.path.join(directory, name)
    cv2.imwrite(path, image)
    return path


class WardrobeBanTests(unittest.TestCase):
    def test_banned_terms_catch_both_rig_breaking_families(self):
        for phrase in (
            "a heavy layered wool overcoat", "an oversized puffer jacket",
            "a long trench coat", "a flowing cape", "a draped shawl",
            "baggy cargo pants", "slouchy wide-leg trousers",
            "palazzo pants", "loose-fitting jeans", "a bulky parka",
        ):
            self.assertTrue(
                wardrobe.banned_terms(phrase),
                f"{phrase!r} should be rejected")

    def test_banned_terms_do_not_fire_on_legitimate_wardrobe(self):
        for phrase in (
            "a tailored scarlet blazer over an ivory silk shell",
            "slim cropped cigarette trousers and pointed leather pumps",
            "articulated bronze shoulder plating with engraved bracers",
            "a coated cotton pencil skirt with a fitted knit top",
        ):
            self.assertEqual(
                wardrobe.banned_terms(phrase), [],
                f"{phrase!r} should be allowed")

    def test_heavy_fabric_and_closed_neck_assignments_are_rejected(self):
        for phrase in (
            "use substantial wool fabric", "choose a thick fabric",
            "add heavy layering", "wear a fitted turtleneck",
            "finish with a roll-neck sweater", "use a mock-neck knit",
            "choose a modern tweed jacket", "use a boucle skirt suit",
            "finish the dress in velvet", "use coat-weight cloth",
            "choose midweight silk-crepe", "use medium weight satin",
        ):
            with self.subTest(phrase=phrase):
                self.assertTrue(wardrobe._assigns_heavy_styling(phrase))
        for phrase in (
            "no thick fabric", "never use heavy layering",
            "avoid turtlenecks and roll-neck sweaters",
            "never use tweed, boucle, or velvet",
            "never use midweight or medium-weight fabric",
        ):
            with self.subTest(phrase=phrase):
                self.assertFalse(wardrobe._assigns_heavy_styling(phrase))

    def test_aesthetic_audit_rejects_the_known_fragmented_outfit(self):
        disaster = (
            "She wears a sculpted longline waistcoat in scarlet wool crepe over "
            "a taupe silk top, paired with narrow black cigarette trousers."
        )
        self.assertEqual(1, len(wardrobe.aesthetic_conflicts(disaster)))
        with self.assertRaisesRegex(RuntimeError, "(?:aesthetic coherence|hem at or below)"):
            wardrobe._finalise(disaster, "feminine", "photograph")
        with self.assertRaisesRegex(ValueError, "(?:aesthetic coherence|hem at or below)"):
            body._prompt({"prompt": disaster, "presentation": "feminine"})

    def test_aesthetic_audit_allows_a_coherent_one_piece_or_short_layer(self):
        for direction in (
            "A scarlet coat-dress forms one uninterrupted column with tonal pumps.",
            "A cropped scarlet waistcoat tops a fine ivory shell and slim trousers.",
            "Never combine a longline waistcoat with a top and cropped trousers.",
        ):
            with self.subTest(direction=direction):
                self.assertEqual([], wardrobe.aesthetic_conflicts(direction))

    def test_system_instruction_states_both_hard_bans(self):
        instruction = wardrobe.SYSTEM.lower()
        self.assertIn("hard ban", instruction)
        self.assertIn("heavy layering", instruction)
        self.assertIn("baggy", instruction)
        self.assertIn("wide-leg", instruction)

    def test_system_instruction_carries_the_new_house_taste_rules(self):
        instruction = f"{wardrobe.SYSTEM} {wardrobe.USER_TEXT}".lower()
        for phrase in (
            "fuchsia", "scarlet", "coral", "blue-family colour",
            "one coherent office design language", "105–120mm",
            "oxfords", "never assign a dress", "pumps, stilettos, or heels",
            "do not infer a gender identity", "one complete outfit",
            "no more than two large colour blocks", "uninterrupted vertical line",
            "longline sleeveless waistcoat", "three complete looks",
            "exclusively lightweight opaque fabrics", "no turtleneck",
            "never use tweed", "coat-weight cloth",
            "gold is forbidden", "omission is preferred",
            "at most one small, understated choice",
            "no statement jewellery", "no layered necklaces",
            "5–8cm above the knee", "modest symmetrical",
            "no one-shoulder", "no bodycon", "office-appropriate",
            "zero fast-fashion noise",
        ):
            self.assertIn(phrase, instruction)
        self.assertIn("not a claim about the person's gender identity", instruction)
        self.assertIn("no yellow, rose, or white gold", instruction)
        self.assertNotIn("real-looking gold", instruction)
        self.assertNotIn("sensual", instruction)

    def test_blue_and_green_are_replaced_with_bright_safe_colours(self):
        rule = wardrobe.COLOR_RULE.lower()
        self.assertIn("ban the entire blue family", rule)
        self.assertIn("green is also unavailable", rule)
        self.assertIn("substitute vivid fuchsia, scarlet, or coral", rule)
        self.assertNotIn("camel", wardrobe.HERO_COLORS)
        for assigned in ("ultramarine dress", "navy suit", "teal skirt"):
            self.assertTrue(wardrobe._assigns_blue(assigned))
        self.assertFalse(wardrobe._assigns_blue(
            "ban blue, cobalt, ultramarine, navy, teal, and cyan"))
        self.assertFalse(wardrobe._assigns_blue(
            "preserve her exact blue eyes and blonde hair"))
        self.assertTrue(wardrobe._assigns_blue(
            "No navy, but use cobalt for the dress"))
        for assigned in ("emerald dress", "jade suit", "olive skirt"):
            self.assertTrue(wardrobe._assigns_green(assigned))
        self.assertFalse(wardrobe._assigns_green(
            "no green, emerald, jade, olive, mint, or sage"))
        self.assertFalse(wardrobe._assigns_green(
            "preserve his natural green eyes"))
        self.assertTrue(wardrobe._assigns_green(
            "Avoid olive but use emerald for the skirt"))

    def test_preset_prompt_carries_the_silhouette_rule(self):
        preset = wardrobe.preset_prompt()
        self.assertIn("never use heavy layering", preset.lower())
        self.assertIn("baggy", preset.lower())
        self.assertIn("opaque", preset.lower())
        self.assertIn(wardrobe.PROPORTION_RULE, preset)
        self.assertIn("runway-supermodel", preset.lower())
        self.assertIn("ban every blue-family", preset.lower())
        self.assertIn("clear, bright, saturated", preset.lower())
        self.assertIn("never force a gendered shoe", preset.lower())
        self.assertIn(wardrobe.ACCESSORY_RULE, preset)
        self.assertIn("gold is forbidden", preset.lower())
        self.assertIn("omission is preferred", preset.lower())
        self.assertNotIn("real-looking gold", preset.lower())
        self.assertNotIn("christian louboutin", preset.lower())
        self.assertNotIn("105–120mm", preset)

    def test_curated_variations_never_reintroduce_weighty_fabrics(self):
        serialized = " ".join(
            str(value)
            for variation in wardrobe.LUXURY_VARIATIONS
            for value in variation.values()
        )
        self.assertFalse(wardrobe._assigns_heavy_styling(serialized))
        self.assertNotIn("fuchsia-tweed", {
            variation["id"] for variation in wardrobe.LUXURY_VARIATIONS
        })


class WardrobeCompositionTests(unittest.TestCase):
    def _tailor(self, payload, directory, refresh=False):
        with mock.patch.object(wardrobe, "_llm_route",
                               return_value=("llm/features/x/chat", "m")), \
             mock.patch.object(wardrobe, "_chat",
                               return_value=json.dumps(payload)):
            return wardrobe.tailored_prompt(directory, refresh=refresh)

    def test_fashion_subject_gets_fashion_direction(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(FASHION, directory)
        self.assertEqual(result["source"], "tailored")
        self.assertIn(wardrobe.AESTHETIC_COHERENCE_RULE, result["prompt"])
        self.assertNotIn("CURATED LOOK", result["prompt"])
        self.assertIn("The single vivid hero colour", result["prompt"])
        self.assertEqual(result["traits"]["presentation"], "feminine")
        self.assertEqual(result["traits"]["medium"], "photograph")
        self.assertIn("look", result["traits"])
        self.assertIn(result["traits"]["hero_color"], wardrobe.HERO_COLORS)
        self.assertIn("scarlet", result["traits"]["palette"])
        self.assertNotIn(body.DEFAULT_BODY_PROMPT, result["prompt"])
        self.assertIn(wardrobe.FEMININE_RULE, result["prompt"])
        self.assertIn("105–120mm", result["prompt"])

    def test_masculine_photo_gets_luxury_menswear_and_never_feminine_heels(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(MENSWEAR, directory)
        self.assertEqual("tailored", result["source"])
        self.assertEqual("masculine", result["traits"]["presentation"])
        self.assertIn(wardrobe.MASCULINE_RULE, result["prompt"])
        self.assertIn("polished loafers, Oxfords, or Derbies", result["prompt"])
        self.assertNotIn("Christian Louboutin", result["prompt"])
        self.assertNotIn("105–120mm", result["prompt"])

    def test_source_presentation_aliases_route_without_inferring_identity(self):
        expected = {
            "female": "feminine",
            "male": "masculine",
            "ambiguous": "androgynous",
            "neutral": "androgynous",
            "": "androgynous",
        }
        for source_presentation, branch in expected.items():
            with self.subTest(source_presentation=source_presentation):
                self.assertEqual(
                    branch,
                    wardrobe._normalise_presentation(source_presentation),
                )

    def test_androgynous_photo_preserves_presentation_without_defaulting_to_heels(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(ANDROGYNOUS, directory)
        self.assertEqual("tailored", result["source"])
        self.assertEqual("androgynous", result["traits"]["presentation"])
        self.assertIn(wardrobe.ANDROGYNOUS_RULE, result["prompt"])
        self.assertIn("do not infer a gender identity", result["prompt"])
        self.assertNotIn("105–120mm", result["prompt"])

    def test_game_hero_gets_costume_direction_not_office_separates(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(HERO, directory)
        self.assertEqual(result["source"], "tailored")
        self.assertIn("armour", result["prompt"])
        self.assertIn("rim", result["prompt"])
        self.assertEqual(result["traits"]["medium"], "game art")
        self.assertNotIn("blazer", result["prompt"])
        self.assertIn(wardrobe.STYLISED_RULE, result["prompt"])
        for fashion_only in (
            "Cartier", "smoky eye", "bold lip", "Christian Louboutin",
            "exactly one hero colour from fuchsia",
        ):
            self.assertNotIn(fashion_only, result["prompt"])

    def test_every_tailored_prompt_appends_the_silhouette_rule(self):
        for payload in (FASHION, MENSWEAR, ANDROGYNOUS, HERO):
            with tempfile.TemporaryDirectory() as directory:
                _portrait(directory)
                result = self._tailor(payload, directory)
            self.assertIn(wardrobe.SILHOUETTE_RULE, result["prompt"])
            self.assertIn(wardrobe.PROPORTION_RULE, result["prompt"])
            self.assertIn(wardrobe.ACCESSORY_RULE, result["prompt"])
            if payload["medium"] == "game art":
                self.assertIn(wardrobe.STYLISED_RULE, result["prompt"])
                self.assertNotIn(wardrobe.COLOR_RULE, result["prompt"])
            else:
                self.assertIn("The single vivid hero colour", result["prompt"])
                self.assertNotIn(wardrobe.COLOR_RULE, result["prompt"])

    def test_gold_in_model_direction_falls_back_to_safe_preset(self):
        rogue = dict(FASHION)
        rogue["direction"] = (
            FASHION["direction"] + " Add warm gold buttons and gold-tone trim."
        )
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(rogue, directory)
        self.assertEqual("preset", result["source"])
        self.assertIn("banned material or colour gold", result["error"])
        self.assertIn(wardrobe.ACCESSORY_RULE, result["prompt"])

    def test_excessive_accessories_in_model_direction_fall_back(self):
        rogue = dict(MENSWEAR)
        rogue["direction"] = MENSWEAR["direction"].replace(
            "one slim platinum watch and no other accessories",
            "layered necklaces, stacked bracelets, and an oversized pendant",
        )
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(rogue, directory)
        self.assertEqual("preset", result["source"])
        self.assertIn("excessive accessories", result["error"])

    def test_explicit_gold_and_accessory_prohibitions_are_allowed(self):
        direction = (
            "Tailor a fitted scarlet lightweight crepe suit with slim trousers, crisp "
            "seams, and polished black Oxfords. Use no gold and no layered "
            "necklaces or stacked bracelets; omit accessories entirely. Keep "
            "the complete line opaque, refined, and readable from shoulder to ankle."
        )
        result = wardrobe._finalise(direction, "masculine", "photograph")
        self.assertIn("use no gold", result.lower())
        self.assertIn(wardrobe.ACCESSORY_RULE, result)
        for allowed in (
            "one small non-gold platinum watch",
            "one small gold-free silver watch",
        ):
            self.assertFalse(wardrobe._assigns_gold(allowed))

    def test_all_gold_forms_and_excessive_accessory_assignments_are_detected(self):
        for phrase in (
            "a yellow gold chain", "a rose gold watch", "white gold earrings",
            "gold-tone buttons", "gold-plated hardware", "a gilded belt buckle",
            "gilt embroidery", "golden metal trim",
        ):
            with self.subTest(phrase=phrase):
                self.assertTrue(wardrobe._assigns_gold(phrase))
        for phrase in (
            "a statement necklace", "layered silver chains",
            "stacked platinum bracelets", "an oversized stone pendant",
            "ornate belts and accessory clutter",
        ):
            with self.subTest(phrase=phrase):
                self.assertTrue(
                    wardrobe._assigns_excessive_accessories(phrase))

    def test_cobalt_in_model_direction_falls_back_to_safe_preset(self):
        rogue = dict(MENSWEAR)
        rogue["direction"] = MENSWEAR["direction"].replace(
            "scarlet", "cobalt")
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(rogue, directory)
        self.assertEqual("preset", result["source"])
        self.assertIn("banned blue-family colour", result["error"])

    def test_masculine_subject_with_feminine_heels_falls_back(self):
        rogue = dict(MENSWEAR)
        rogue["direction"] = MENSWEAR["direction"].replace(
            "polished black leather Oxfords",
            "Christian Louboutin 100mm stiletto pumps")
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(rogue, directory)
        self.assertEqual("preset", result["source"])
        self.assertIn("feminine heels", result["error"])

    def test_masculine_subject_with_feminine_garment_falls_back(self):
        rogue = dict(MENSWEAR)
        rogue["direction"] = (
            "Give him a lightweight scarlet office sheath dress with a modest "
            "neckline and polished black Oxfords."
        )
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(rogue, directory)
        self.assertEqual("preset", result["source"])
        self.assertIn("feminine garment", result["error"])

    def test_non_feminine_garment_guard_catches_silhouettes_but_allows_dress_shirts(self):
        self.assertTrue(wardrobe._assigns_feminine_garment(
            "Give the masculine subject feminine silhouettes."))
        self.assertTrue(wardrobe._assigns_feminine_garment(
            "Use a coral skirt with polished loafers."))
        self.assertFalse(wardrobe._assigns_feminine_garment(
            "Use a scarlet lightweight dress shirt with slim trousers."))
        self.assertFalse(wardrobe._assigns_feminine_garment(
            "Never assign a dress, skirt, or feminine silhouette."))
        plate = body._prompt({
            "presentation": "male",
            "medium": "photograph",
            "prompt": (
                "Use a scarlet lightweight dress shirt with a precise office "
                "jacket, slim straight trousers, and polished black Oxfords."
            ),
        })
        self.assertIn("dress shirt", plate)
        self.assertIn(wardrobe.MASCULINE_RULE, plate)

    def test_masculine_heel_guard_covers_generic_heel_language(self):
        for footwear in ("kitten heels", "pointed pumps", "d'Orsay shoes"):
            direction = (
                "A precisely tailored scarlet lightweight crepe suit with slim trousers, "
                "one platinum watch, restrained charcoal knitwear, and " + footwear
                + ", finished with immaculate seams and an opaque fitted line."
            )
            with self.subTest(footwear=footwear), self.assertRaisesRegex(
                    RuntimeError, "feminine heels"):
                wardrobe._finalise(direction, "masculine", "photograph")

    def test_masculine_heel_guard_accepts_explicit_prohibitions(self):
        direction = (
            "A precisely tailored scarlet lightweight crepe suit with slim trousers, "
            "one platinum watch, restrained charcoal knitwear, and polished "
            "Oxfords; never use high heels or pumps. Keep the line opaque, "
            "structured, and impeccably finished."
        )
        result = wardrobe._finalise(direction, "masculine", "photograph")
        self.assertIn("never use high heels", result.lower())
        self.assertIn(wardrobe.MASCULINE_RULE, result)

    def test_banned_garment_in_the_model_reply_falls_back_to_preset(self):
        rogue = dict(FASHION)
        rogue["direction"] = (
            "Wrap her in a heavy layered wool overcoat over baggy wide-leg "
            "trousers, styled with a long draped shawl and chunky boots for a "
            "relaxed oversized winter silhouette that hides the body line."
        )
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            result = self._tailor(rogue, directory)
        self.assertEqual(result["source"], "preset")
        self.assertEqual(result["prompt"], wardrobe.preset_prompt())
        self.assertIn("banned garment", result["error"])

    def test_markdown_fenced_json_is_still_parsed(self):
        fenced = "```json\n" + json.dumps(FASHION) + "\n```"
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat", return_value=fenced):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "tailored")
        self.assertIn(wardrobe.AESTHETIC_COHERENCE_RULE, result["prompt"])
        self.assertNotIn("CURATED LOOK", result["prompt"])


class WardrobeFallbackTests(unittest.TestCase):
    def test_missing_portrait_falls_back_without_calling_a_model(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(wardrobe, "_chat") as chat:
                result = wardrobe.tailored_prompt(directory)
        chat.assert_not_called()
        self.assertEqual(result["source"], "preset")
        self.assertEqual(result["prompt"], wardrobe.preset_prompt())

    def test_provider_failure_falls_back_and_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   side_effect=RuntimeError("no vision model")):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "preset")
        self.assertIn("no vision model", result["error"])

    def test_unparseable_reply_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value="Sure! Here is a lovely outfit."):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "preset")

    def test_short_brief_is_rejected(self):
        stub = dict(FASHION, direction="A red suit.")
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(stub)):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "preset")


class WardrobeCacheTests(unittest.TestCase):
    def test_current_stylized_cache_does_not_reject_its_own_policy_rule(self):
        with tempfile.TemporaryDirectory() as directory:
            portrait = _portrait(directory)
            traits = {
                "presentation": "masculine",
                "medium": "3d render",
                "register": "stylized action hero",
            }
            prompt = wardrobe._finalise(
                HERO["direction"], traits["presentation"], traits["medium"])
            self.assertIn(wardrobe.STYLISED_RULE, prompt)
            with open(os.path.join(directory, wardrobe.CACHE_NAME), "w") as handle:
                json.dump({
                    "version": wardrobe.CACHE_VERSION,
                    "digest": wardrobe._digest(portrait),
                    "prompt": prompt,
                    "traits": traits,
                    "variation_id": "cached-stylized-v9",
                }, handle)

            with mock.patch.object(wardrobe, "_llm_route") as route, \
                    mock.patch.object(wardrobe, "_chat") as chat:
                result = wardrobe.cached_prompt(directory)

        route.assert_not_called()
        chat.assert_not_called()
        self.assertIsNotNone(result)
        self.assertTrue(result["cached"])
        self.assertEqual(prompt, result["prompt"])
        self.assertEqual(traits, result["traits"])

    def test_v3_gold_cache_is_projected_safely_without_mutating_user_data(self):
        with tempfile.TemporaryDirectory() as directory:
            portrait = _portrait(directory)
            original = {
                "version": 3,
                "digest": wardrobe._digest(portrait),
                "prompt": (
                    "Keep her golden blonde hair and precisely tailored scarlet "
                    "wool blazer with slim charcoal trousers. Only one statement "
                    "Cartier gold necklace. Preserve the crisp seams, opaque fabric, "
                    "polished black shoes, and poised editorial silhouette. Render "
                    "real-looking gold, platinum, and stones, with exactly one "
                    "statement piece in the discipline of Cartier, Bulgari, Van "
                    "Cleef & Arpels, Tiffany, or Hermes and no competing jewellery."
                ),
                "traits": {"presentation": "feminine"},
            }
            with open(os.path.join(directory, wardrobe.CACHE_NAME), "w") as handle:
                json.dump(original, handle)
            with mock.patch.object(wardrobe, "_chat") as chat:
                result = wardrobe.tailored_prompt(directory)
            with open(os.path.join(directory, wardrobe.CACHE_NAME)) as handle:
                unchanged = json.load(handle)
        chat.assert_not_called()
        self.assertEqual("tailored", result["source"])
        self.assertTrue(result["cached"])
        self.assertTrue(result["migrated"])
        self.assertEqual(original, unchanged)
        self.assertIn("golden blonde hair", result["prompt"])
        self.assertIn("precisely tailored scarlet", result["prompt"])
        self.assertIn("polished black shoes", result["prompt"])
        self.assertNotIn("Cartier gold necklace", result["prompt"])
        self.assertNotIn("real-looking gold", result["prompt"])
        self.assertIn(wardrobe.ACCESSORY_RULE, result["prompt"])

    def test_second_open_reuses_the_cache_without_a_second_model_call(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)) as chat:
                first = wardrobe.tailored_prompt(directory)
                second = wardrobe.tailored_prompt(directory)
                self.assertEqual(chat.call_count, 1)
            self.assertFalse(first.get("cached"))
            self.assertTrue(second.get("cached"))
            self.assertEqual(first["prompt"], second["prompt"])
            self.assertTrue(os.path.isfile(
                os.path.join(directory, wardrobe.CACHE_NAME)))

    def test_refresh_rewrites_even_when_cached(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                wardrobe.tailored_prompt(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(HERO)) as chat:
                refreshed = wardrobe.tailored_prompt(directory, refresh=True)
                self.assertEqual(chat.call_count, 1)
        self.assertIn("armour", refreshed["prompt"])

    def test_refresh_advances_the_seed_without_forcing_it_into_the_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                first = wardrobe.tailored_prompt(directory)
                second = wardrobe.tailored_prompt(directory, refresh=True)
        self.assertNotEqual(first["variation_id"], second["variation_id"])
        # The mocked model deliberately returns the same audited outfit. The
        # rotating seed must not override that portrait-aware decision.
        self.assertEqual(first["prompt"], second["prompt"])
        self.assertNotIn("CURATED LOOK", first["prompt"])
        self.assertIn(
            "not mandatory",
            wardrobe._variation_instruction(wardrobe.LUXURY_VARIATIONS[0]),
        )
        self.assertEqual(1, first["prompt"].count("The single vivid hero colour"))
        self.assertEqual(1, second["prompt"].count("The single vivid hero colour"))

    def test_tailored_prompt_reports_real_bounded_work_stages(self):
        stages = []
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                wardrobe.tailored_prompt(
                    directory, refresh=True, progress=stages.append)
                cached_stages = []
                wardrobe.tailored_prompt(
                    directory, progress=cached_stages.append)
        self.assertEqual(stages, [
            "portrait", "planning", "analysis", "validation",
            "composition", "saving", "complete",
        ])
        self.assertEqual(cached_stages, ["portrait", "cache", "complete"])

    def test_curated_looks_are_gender_aware_lightweight_and_bright(self):
        self.assertGreaterEqual(len(wardrobe.LUXURY_VARIATIONS), 10)
        counts = {
            color: sum(item["hero"] == color
                       for item in wardrobe.LUXURY_VARIATIONS)
            for color in wardrobe.HERO_COLORS
        }
        self.assertEqual(len(wardrobe.LUXURY_VARIATIONS), sum(counts.values()))
        self.assertGreaterEqual(min(counts.values()), 3)
        self.assertLessEqual(max(counts.values()) - min(counts.values()), 1)
        for item in wardrobe.LUXURY_VARIATIONS:
            masculine = wardrobe._variation_rule(item, "masculine")
            androgynous = wardrobe._variation_rule(item, "androgynous")
            feminine = wardrobe._variation_rule(item, "feminine")
            self.assertNotRegex(masculine.lower(), r"\b(?:pump|stiletto|heel)s?\b")
            self.assertIn("lightweight", masculine.lower())
            self.assertIn("office", masculine.lower())
            self.assertFalse(wardrobe._assigns_feminine_garment(masculine))
            self.assertIn("lightweight", androgynous.lower())
            self.assertIn("office", androgynous.lower())
            self.assertFalse(wardrobe._assigns_feminine_garment(androgynous))
            self.assertIn("above the knee", feminine.lower())
            self.assertRegex(feminine.lower(), r"\b(?:5–8|6)cm\b")
            self.assertIn("lightweight", feminine.lower())
            self.assertFalse(wardrobe._assigns_blue(feminine))
            self.assertFalse(wardrobe._assigns_green(feminine))
            self.assertFalse(wardrobe._assigns_heavy_styling(feminine))
            self.assertFalse(wardrobe._assigns_long_feminine_hem(feminine))
            self.assertFalse(wardrobe._assigns_too_short_feminine_hem(feminine))
            self.assertFalse(wardrobe._assigns_immodest_office_style(feminine))
            self.assertTrue(item["feminine"])
            self.assertTrue(item["masculine"])
            self.assertTrue(item["androgynous"])

    def test_a_new_portrait_invalidates_the_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                wardrobe.tailored_prompt(directory)
            self.assertIsNotNone(wardrobe.cached_prompt(directory))
            image = np.full((256, 256, 3), 40, dtype=np.uint8)
            cv2.imwrite(os.path.join(directory, "head.png"), image)
            self.assertIsNone(wardrobe.cached_prompt(directory))

    def test_cached_prompt_is_none_without_a_portrait(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(wardrobe.cached_prompt(directory))

    def test_keyframe_is_used_when_there_is_no_head_plate(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory, name="keyframe.png")
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "tailored")


class WardrobeRequestTests(unittest.TestCase):
    def test_reference_is_downscaled_before_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "head.png")
            cv2.imwrite(path, np.full((2048, 1536, 3), 200, dtype=np.uint8))
            encoded = wardrobe._encoded_reference(path)
        import base64
        decoded = cv2.imdecode(
            np.frombuffer(base64.b64decode(encoded), np.uint8),
            cv2.IMREAD_COLOR)
        self.assertEqual(max(decoded.shape[:2]), wardrobe.ANALYSIS_EDGE)

    def test_llm_route_rejects_an_injected_provider_name(self):
        helper = mock.Mock()
        helper.load.return_value = {
            "llm": {"provider": "../../etc", "api_key": "not-used"},
        }
        helper.spec.return_value = {
            "id": "../../etc", "label": "Injected", "key": True,
            "managed": False,
        }
        with mock.patch.object(
                wardrobe.media_gen, "_providers", return_value=helper):
            with self.assertRaises(RuntimeError):
                wardrobe._llm_route()

    def test_preference_reader_refuses_paths_outside_its_root(self):
        self.assertEqual(wardrobe._preference("../../etc/passwd"), {})
        self.assertEqual(wardrobe._preference("llm/../../secret"), {})


class WardrobeIntegrationTests(unittest.TestCase):
    def test_one_click_prefers_proven_source_medium_over_fallback_traits(self):
        manifest = {
            "metrics": {"source_medium": "illustration"},
            "source_metrics": {"source_medium": "unknown"},
        }
        self.assertEqual(
            server_app._pipeline_body_medium(
                {"medium": "3d render"}, manifest),
            "photograph",
            "a present but invalid authoritative intake report must not fall "
            "through to generated-head or planner stylization",
        )
        self.assertEqual(
            server_app._pipeline_body_medium(
                {"medium": "anime"},
                {"metrics": {"source_medium": "photograph"}},
            ),
            "photograph",
        )
        self.assertEqual(
            server_app._pipeline_body_medium(
                {"medium": "photograph"},
                {
                    "source_metrics": {"source_medium": "3d render"},
                    "metrics": {"source_medium": "photograph"},
                },
            ),
            "3d render",
        )
        self.assertEqual(
            server_app._pipeline_body_medium(
                {"medium": "illustration"},
                {
                    "source_metrics": {"source_medium": "photograph"},
                    "metrics": {"source_medium": "illustration"},
                },
            ),
            "photograph",
        )
        self.assertEqual(
            server_app._pipeline_body_medium(
                {"medium": "illustration"},
                {
                    "source_metrics": {"source_medium": "future-medium"},
                    "metrics": {"source_medium": "illustration"},
                },
            ),
            "photograph",
        )
        self.assertEqual(
            server_app._pipeline_body_medium(
                {"medium": "photograph"},
                {"metrics": {"source_medium": "illustration"}},
            ),
            "illustration",
            "legacy generated-head evidence remains usable only when original "
            "source evidence is absent",
        )

    def test_one_click_rebuilds_legacy_or_stale_headwear_heads(self):
        base = {
            "status": "ready",
            "source_metrics": {"source_medium": "illustration"},
            "metrics": {"source_medium": "photograph"},
        }
        current_version = generate.head_prompt_version("illustration")

        self.assertTrue(server_app._pipeline_face_needs_rebuild(
            dict(base, head={"prompt_version": current_version}), "", False))
        self.assertTrue(server_app._pipeline_face_needs_rebuild(
            dict(base, head={
                "prompt_version": current_version - 1,
                "remove_headwear": False,
                "headwear_policy": "preserve",
            }), "", False))

        current = dict(base, head={
            "prompt_version": current_version,
            "remove_headwear": False,
            "headwear_policy": "preserve",
        })
        self.assertFalse(server_app._pipeline_face_needs_rebuild(
            current, "", False))
        self.assertTrue(server_app._pipeline_face_needs_rebuild(
            current, "keep the exact straw hat", False))
        self.assertTrue(server_app._pipeline_face_needs_rebuild(
            current, "", True))

        photo = {
            "status": "ready",
            "source_metrics": {"source_medium": "photograph"},
            "head": {
                "prompt_version": generate.head_prompt_version("photograph"),
                "remove_headwear": True,
                "headwear_policy": "remove",
            },
        }
        self.assertFalse(server_app._pipeline_face_needs_rebuild(
            photo, "", True))

        # Unknown/future intake labels take the same fail-closed photo prompt
        # branch as build_avatar. Passing the raw label to head_prompt_version
        # selects the generic prompt instead and causes an endless rebuild on
        # every one-click run even though the current photo head is valid.
        corrupt_source = {
            "status": "ready",
            "source_metrics": {"source_medium": "future-medium"},
            "metrics": {"source_medium": "illustration"},
            "head": {
                "prompt_version": generate.head_prompt_version("photograph"),
                "remove_headwear": False,
                "headwear_policy": "preserve",
            },
        }
        self.assertFalse(server_app._pipeline_face_needs_rebuild(
            corrupt_source, "", False))

    def test_body_prompt_accepts_a_tailored_direction(self):
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(HERO)):
                tailored = wardrobe.tailored_prompt(directory)["prompt"]
        plate = body._prompt({
            "style": "illustrated", "pose": "confident", "prompt": tailored})
        self.assertIn("armour", plate)
        self.assertIn("DECENCY FLOOR", plate)
        self.assertIn("IDENTITY LOCK", plate)

    def test_server_serves_the_cached_brief_and_exposes_the_rewrite_route(self):
        server = (ROOT / "server" / "app.py").read_text()
        self.assertIn("wardrobe.cached_prompt(directory)", server)
        self.assertIn(
            'body_metadata = body.public_body_metadata(manifest.get("body") or {})',
            server,
        )
        self.assertIn('"body": body_metadata or None', server)
        self.assertIn('"/api/avatar/body/prompt"', server)
        self.assertIn('"/api/avatar/body/prompt/stream"', server)
        self.assertIn('media_type="application/x-ndjson"', server)
        self.assertIn("class BodyPromptRequest", server)
        self.assertIn("wardrobe.tailored_prompt", server)

    def test_one_click_pipeline_uses_the_portrait_tailored_prompt(self):
        server = (ROOT / "server" / "app.py").read_text()
        pipeline = server.split("def _pipeline_thread", 1)[1].split(
            "class RigControlInput", 1)[0]
        self.assertIn("from studio import motion, wardrobe", pipeline)
        self.assertIn(
            "tailored = wardrobe.tailored_prompt(reg().adir(slug), log=writer)",
            pipeline,
        )
        self.assertIn("body_traits = tailored.get(\"traits\") or {}", pipeline)
        self.assertIn("body_medium = _pipeline_body_medium", pipeline)
        self.assertIn("style=_PIPELINE_BODY_MEDIA[body_medium]", pipeline)
        self.assertIn("presentation=body_traits.get(\"presentation\")", pipeline)
        self.assertIn("medium=body_medium", pipeline)

    def test_settings_places_generate_directly_below_the_prompt(self):
        settings = (ROOT / "web" / "settings.html").read_text()
        prompt_at = settings.index('id="body-prompt"')
        progress_at = settings.index('id="body-progress"')
        generate_at = settings.index('id="body-generate"')
        identity_at = settings.index('class="body-identity"')
        motion_at = settings.index('id="body-walk-generate"')
        self.assertLess(prompt_at, progress_at)
        self.assertLess(progress_at, generate_at)
        self.assertLess(generate_at, identity_at)
        self.assertLess(generate_at, motion_at)
        self.assertIn("tailorBodyPrompt", settings)
        self.assertIn('id="body-prompt-progress"', settings)
        self.assertIn('id="body-prompt-elapsed"', settings)
        self.assertIn("streamBodyPrompt", settings)
        self.assertIn("setBodyPromptNote", settings)
        self.assertIn("presentation,\n    medium,", settings)

    def test_server_profile_validates_visible_presentation_and_medium(self):
        server = (ROOT / "server" / "app.py").read_text()
        profile = server.split("class BodyProfileInput", 1)[1].split(
            "class BodyRequest", 1)[0]
        self.assertIn('pattern=r"^(feminine|masculine|androgynous)$"', profile)
        self.assertIn(
            'pattern=r"^(photograph|game art|anime|illustration|3d render)$"',
            profile,
        )


class CarriedPropTests(unittest.TestCase):
    """No bag, and nothing in the hands - the third structural rule."""

    def test_banned_terms_catch_carried_props(self):
        for phrase in (
            "a structured leather handbag", "carrying a small clutch",
            "a quilted shoulder bag", "a slim leather tote",
            "a canvas backpack", "a black briefcase", "a leather satchel",
            "a crossbody strap across the chest", "a folded umbrella",
            "holding a takeaway coffee cup", "a hand-held paper fan",
            "a bouquet in her hands", "shopping bags",
        ):
            self.assertTrue(
                wardrobe.banned_terms(phrase),
                f"{phrase!r} should be rejected")

    def test_carry_ban_does_not_fire_on_legitimate_wardrobe(self):
        for phrase in (
            "a tailored scarlet blazer over an ivory silk shell",
            "slim cropped cigarette trousers that hold a clean line",
            "lacquer black carries the costume, bronze is the hero metal",
            "articulated bronze shoulder plating with engraved bracers",
        ):
            self.assertEqual(
                wardrobe.banned_terms(phrase), [],
                f"{phrase!r} should be allowed")

    def test_system_instruction_states_the_carry_ban(self):
        instruction = wardrobe.SYSTEM.lower()
        self.assertIn("carries nothing", instruction)
        self.assertIn("handbag", instruction)
        self.assertIn("both hands stay empty", instruction)

    def test_preset_and_tailored_prompts_both_carry_the_hands_rule(self):
        self.assertIn(wardrobe.HANDS_RULE, wardrobe.preset_prompt())
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "tailored")
        self.assertIn(wardrobe.HANDS_RULE, result["prompt"])
        self.assertIn(wardrobe.SILHOUETTE_RULE, result["prompt"])

    def test_a_bag_in_the_model_reply_falls_back_to_preset(self):
        rogue = dict(FASHION)
        rogue["direction"] = (
            "Dress her in a precisely tailored scarlet blazer over an ivory silk "
            "shell with slim cigarette trousers, and finish the look with a "
            "structured black leather handbag carried in one hand, plus pointed "
            "leather pumps at ninety millimetres."
        )
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(rogue)):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "preset")
        self.assertEqual(result["prompt"], wardrobe.preset_prompt())
        self.assertIn("handbag", result["error"])

    def test_rejected_stylized_outfit_keeps_only_safe_source_traits(self):
        rogue = dict(HERO)
        rogue["medium"] = "anime"
        rogue["direction"] = (
            "Preserve the drawn pirate costume and add a leather shoulder bag "
            "while keeping the remaining cel-shaded outfit coherent and complete."
        )
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(rogue)):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "preset")
        self.assertEqual(
            result["traits"],
            {"presentation": "masculine", "medium": "anime"},
        )
        self.assertNotIn("direction", result["traits"])

    def test_the_appended_rules_are_never_read_as_a_violation(self):
        """The rules must name the props they forbid without self-rejecting."""
        self.assertTrue(wardrobe.banned_terms(wardrobe.STRUCTURAL_RULE))
        with tempfile.TemporaryDirectory() as directory:
            _portrait(directory)
            with mock.patch.object(wardrobe, "_llm_route",
                                   return_value=("llm/features/x/chat", "m")), \
                 mock.patch.object(wardrobe, "_chat",
                                   return_value=json.dumps(FASHION)):
                result = wardrobe.tailored_prompt(directory)
        self.assertEqual(result["source"], "tailored")

    def test_the_structural_rules_always_fit_inside_the_prompt_limit(self):
        longest = "x" * (wardrobe.PROMPT_LIMIT * 2)
        stub = dict(FASHION, direction=longest)
        direction, _traits = wardrobe._parse(json.dumps(stub))
        self.assertIn(wardrobe.STRUCTURAL_RULE, wardrobe._finalise(direction))

    def test_every_body_plate_bans_carried_objects(self):
        for view in body.BODY_VIEWS:
            plate = body._prompt({}, view=view)
            self.assertIn("CARRY NOTHING", plate)
            self.assertIn("handbag", plate)
            self.assertIn("both hands are completely empty", plate.lower())


class EyewearLockTests(unittest.TestCase):
    """Glasses worn in the upload survive into head.png and keyframe.png."""

    def test_head_prompt_preserves_existing_glasses(self):
        prompt = generate.HEAD_PROMPT
        self.assertIn("EYEWEAR", prompt)
        lowered = prompt.lower()
        self.assertIn("eyeglasses", lowered)
        self.assertIn("never remove them", lowered)
        self.assertIn("do not add any", lowered)

    def test_head_prompt_no_longer_strips_glasses_as_an_accessory(self):
        framing = generate.HEAD_PROMPT.split("FRAMING", 1)[1].split("\n\n", 1)[0]
        self.assertNotIn(
            "accessories, props, or text anywhere in the image.", framing)
        self.assertIn("eyeglasses already worn", framing)

    def test_head_prompt_version_moved_so_cached_heads_rebuild(self):
        self.assertGreaterEqual(generate.HEAD_PROMPT_VERSION, 3)

    def test_keyframe_is_cropped_from_the_generated_head(self):
        source = (ROOT / "studio" / "build.py").read_text()
        # the call moved inside the frontality-retry loop (2026-08-01), but
        # the keyframe must still be cropped from the generated head
        self.assertIn(
            "prep.build_keyframe(\n                head_path, staged_keyframe", source)

    def test_body_plates_keep_the_reference_glasses(self):
        for view in body.BODY_VIEWS:
            plate = body._prompt({}, view=view)
            self.assertIn("eyeglasses", plate)
            self.assertIn("never remove them", plate)

    def test_body_plates_ban_green_everywhere(self):
        # Owner rule 2026-08-01: downstream alpha keying misreads green as
        # background, so no plate may contain green - clothing, props,
        # backdrop, or lighting cast - in any of the three views. An art
        # direction asking for green gets a substitute color instead.
        for view in body.BODY_VIEWS:
            plate = body._prompt({}, view=view)
            self.assertIn("NO GREEN", plate)
            self.assertIn("no green clothing", plate)
            self.assertIn("never green or green-tinted", plate)
            self.assertIn("substitute a different color", plate)
            # Second owner rule, same day: white wardrobe dissolves into
            # the light studio backdrop and shreds the cutout silhouette.
            self.assertIn("NO WHITE WARDROBE", plate)
            self.assertIn("no white shoes", plate)
            self.assertIn("clearly non-white, non-green color", plate)

    def test_body_validation_rejects_the_new_aesthetic_failures_before_generation(self):
        failures = (
            ("a cobalt lightweight office sheath", "blue-family"),
            ("an emerald lightweight office sheath", "green-family"),
            ("a scarlet midweight silk-crepe office sheath", "heavy fabric"),
            ("a scarlet lightweight midi dress", "hem at or below"),
            ("a scarlet lightweight office sheath with ankle boots", "non-stiletto"),
            ("a scarlet lightweight upper-thigh micro-mini", "upper-thigh or mini"),
            ("a scarlet lightweight strapless office sheath", "non-office"),
            ("a scarlet lightweight bodycon partywear dress", "non-office"),
        )
        for prompt, error in failures:
            with self.subTest(prompt=prompt), self.assertRaisesRegex(
                    ValueError, error):
                body._prompt({
                    "prompt": prompt,
                    "presentation": "feminine",
                    "medium": "photograph",
                })

    def test_body_validation_allows_identity_colour_and_long_negative_lists(self):
        prompt = (
            "Preserve the exact woman's blue eyes and blonde hair. Dress her in "
            "a vivid fuchsia lightweight silk-crepe office sheath with a modest "
            "bateau neckline, professional ease, a hem 6cm above the knee, and "
            "pointed black killer stiletto pumps at 112mm. "
            "Never use midweight, stiff, bulky, layered, or coat-like fabric. "
            "No trousers, blazer, coat, longline layer, knitwear, turtleneck, "
            "midi, maxi, cobalt, blue, navy, ultramarine, teal, cyan, green, "
            "white wardrobe, boots, platforms, or fast-fashion details."
        )
        for view in body.BODY_VIEWS:
            plate = body._prompt({
                "prompt": prompt,
                "presentation": "feminine",
                "medium": "photograph",
            }, view=view)
            self.assertLessEqual(
                len(plate.encode("utf-8")), body.FULL_BODY_PROMPT_MAX_BYTES)
            self.assertIn("blue eyes", plate)

    def test_every_body_plate_enforces_taste_proportion_and_gender_proper_shoes(self):
        profiles = {
            "feminine": ("5–8cm above the knee", "fine 105–120mm heels"),
            "masculine": ("polished loafers, Oxfords, or Derbies", "Never assign a dress"),
            "androgynous": ("polished loafers, Oxfords, or Derbies", "Never default to a dress"),
        }
        for presentation, expected in profiles.items():
            for view in body.BODY_VIEWS:
                plate = body._prompt(
                    {"presentation": presentation, "medium": "photograph"},
                    view=view,
                )
                self.assertIn("PROPORTION TARGET", plate)
                self.assertIn("runway-supermodel silhouette", plate)
                self.assertIn("roughly 7.5 to 8 heads tall", plate)
                self.assertIn("long sculpted legs", plate)
                self.assertIn("Reject stretched limbs", plate)
                self.assertIn("PRESENTATION AND FOOTWEAR", plate)
                self.assertIn("NO GOLD AND MINIMAL ACCESSORIES", plate)
                self.assertIn(wardrobe.ACCESSORY_RULE, plate)
                self.assertIn(f"only the {presentation} branch", plate)
                for phrase in expected:
                    self.assertIn(phrase, plate)
                if presentation != "feminine":
                    self.assertNotIn("Christian Louboutin", plate)
                    self.assertNotIn("105–120mm", plate)
                self.assertIn("NO COBALT", plate)
                self.assertIn("Substitute vivid fuchsia, scarlet, or coral", plate)
                self.assertIn(
                    "White touches every outsole edge, both sides of each heel stem",
                    plate)
                self.assertIn("no bare midriff", plate)
                self.assertIn("extreme plunging neckline", plate)

    def test_stylised_plate_keeps_costume_register_without_fashion_suffix(self):
        plate = body._prompt({
            "style": "illustrated",
            "presentation": "masculine",
            "medium": "game art",
            "prompt": HERO["direction"],
        })
        self.assertIn(wardrobe.STYLISED_RULE, plate)
        self.assertNotIn("Christian Louboutin", plate)
        self.assertNotIn("Cartier", plate)
        self.assertNotIn("smoky eye", plate)

    def test_long_tailored_prompts_fit_the_xai_utf8_budget_without_losing_rules(self):
        verbose = (
            "Tailor an editorial fuchsia lightweight silk-crepe office sheath with a modest bateau neckline, a hem 6cm above the knee, precise sculpted seams, "
            "a restrained silver accent, luminous real skin, and polished finish. "
        ) * 80
        tailored = wardrobe._finalise(verbose, "feminine", "photograph")
        self.assertEqual(len(tailored), wardrobe.PROMPT_LIMIT)
        for view in body.BODY_VIEWS:
            plate = body._prompt({
                "prompt": tailored,
                "presentation": "feminine",
                "medium": "photograph",
            }, view=view)
            self.assertLessEqual(
                len(plate.encode("utf-8")), body.FULL_BODY_PROMPT_MAX_BYTES)
            self.assertIn("IDENTITY LOCK", plate)
            self.assertIn("PROPORTION TARGET", plate)
            self.assertIn("HOUSE STYLE", plate)
            self.assertIn(
                wardrobe.resolved_color_rule("fuchsia"), plate)
            self.assertNotIn(wardrobe.COLOR_RULE, plate)
            self.assertIn(wardrobe.LUXURY_FINISH_RULE, plate)
            self.assertIn(wardrobe.FEMININE_RULE, plate)
            self.assertIn(wardrobe.ACCESSORY_RULE, plate)
            self.assertIn("CARRY NOTHING", plate)
            self.assertIn("DECENCY FLOOR", plate)
            self.assertIn("NO COBALT", plate)
            self.assertIn("NO GREEN", plate)
            self.assertIn("NO WHITE WARDROBE", plate)

    def test_every_turnaround_branch_leaves_real_editable_prompt_budget(self):
        """Side/back contracts must not crowd the art direction out of 8 KiB."""
        marker = "EDITABLE ART DIRECTION — "
        prompts = {
            "feminine": (
                "scarlet lightweight silk-crepe office sheath with a modest "
                "bateau neckline and a hem 6cm above the knee"
            ),
            "masculine": (
                "scarlet lightweight tailored office suit with slim straight "
                "trousers and polished black Oxfords"
            ),
            "androgynous": (
                "coral lightweight architectural office jacket with slim "
                "trousers and polished black loafers"
            ),
        }
        for view in body.BODY_VIEWS:
            for presentation in ("feminine", "masculine", "androgynous"):
                plate = body._prompt({
                    "prompt": prompts[presentation],
                    "presentation": presentation,
                    "medium": "photograph",
                }, view=view)
                start = plate.index(marker) + len(marker)
                end = plate.index("\n\n", start)
                fixed = len((plate[:start] + plate[end:]).encode("utf-8"))
                self.assertGreaterEqual(
                    body.FULL_BODY_PROMPT_MAX_BYTES - fixed,
                    1_500,
                    f"{view}/{presentation} leaves too little editable budget",
                )

    def test_multibyte_direction_is_byte_bounded_and_keeps_owner_note(self):
        plate = body._prompt({
            "prompt": "高级定制廓形与精确剪裁。" * 500,
            "notes": "保留原来的眼镜和发型",
            "presentation": "androgynous",
            "medium": "photograph",
        })
        self.assertLessEqual(
            len(plate.encode("utf-8")), body.FULL_BODY_PROMPT_MAX_BYTES)
        self.assertIn("MUST KEEP: 保留原来的眼镜和发型", plate)

    def test_borderline_head_uses_output_resolution_and_fit_quality(self):
        cleo_like = body._head_alignment_failure(
                0.17229, (392, 72, 85, 107), (1152, 864, 3),
                np.array([1.14, 1.4, 5.35], dtype=np.float32))
        self.assertIsNone(cleo_like)
        # This exact 82x112 case used to fail only because its width was two
        # pixels below an arbitrary threshold, despite containing more face
        # detail than the nominal 84x100 target.
        narrow_but_crisp = body._head_alignment_failure(
            0.17229, (392, 72, 82, 112), (1152, 864, 3),
            np.array([1.14, 1.4, 5.35], dtype=np.float32))
        self.assertIsNone(narrow_but_crisp)
        self.assertIn(
            "transform is unsafe",
            body._head_alignment_failure(
                0.1699, (392, 72, 85, 107), (1152, 864, 3),
                np.array([1.0, 2.0], dtype=np.float32)))
        self.assertIn(
            "too small for a crisp identity lock",
            body._head_alignment_failure(
                0.172, (400, 75, 83, 99), (1152, 864, 3),
                np.array([1.0, 2.0], dtype=np.float32)))
        self.assertIn(
            "too small for a crisp identity lock",
            body._head_alignment_failure(
                0.172, (400, 75, 70, 120), (1152, 864, 3),
                np.array([1.0, 2.0], dtype=np.float32)))
        self.assertIn(
            "alignment is unstable",
            body._head_alignment_failure(
                0.17, (392, 72, 85, 107), (1152, 864, 3),
                np.array([8.0, 18.0], dtype=np.float32)))
        self.assertTrue(body._head_scale_is_safe(0.17229))
        self.assertFalse(body._head_scale_is_safe(0.1699))
        self.assertFalse(body._head_scale_is_safe(1.8001))
        self.assertFalse(body._head_scale_is_safe(np.nan))
        self.assertFalse(body._head_scale_is_safe(np.inf))

        # Exercise the real compound gate through _face_transform.  The
        # canonical oval is 500x620px; at Cleo's measured transform it lands
        # at roughly 86x108px in an 864x1152 full-body plate.
        indices = np.arange(478, dtype=np.float32)
        landmarks = np.column_stack((
            512.0 + ((indices % 17.0) - 8.0) * 12.0,
            512.0 + (((indices // 17.0) % 17.0) - 8.0) * 12.0,
        )).astype(np.float32)
        for point_index, landmark_index in enumerate(body.face.FACE_OVAL):
            angle = 2.0 * np.pi * point_index / len(body.face.FACE_OVAL)
            landmarks[landmark_index] = (
                512.0 + 250.0 * np.cos(angle),
                512.0 + 310.0 * np.sin(angle),
            )
        scale = 0.17229
        transform = np.array(
            [[scale, 0.0, 340.0], [0.0, scale, 20.0]], dtype=np.float64)
        target_landmarks = cv2.transform(
            landmarks[None, :, :], transform)[0]
        identity_image = np.zeros((1024, 1024, 3), dtype=np.uint8)
        body_image = np.zeros((1152, 864, 3), dtype=np.uint8)
        with mock.patch.object(
                body, "_detect",
                side_effect=[landmarks, target_landmarks]), \
             mock.patch.object(
                 body.cv2, "estimateAffinePartial2D",
                 return_value=(transform, None)):
            _matrix, receipt, _key = body._face_transform(
                identity_image, body_image)
        self.assertEqual(receipt["scale"], round(scale, 5))
        self.assertGreaterEqual(receipt["face_bounds"][2], 84)
        self.assertGreaterEqual(receipt["face_bounds"][3], 100)

    def test_stylized_face_alignment_locks_false_landmark_roll_upright(self):
        indices = np.arange(478, dtype=np.float32)
        landmarks = np.column_stack((
            512.0 + ((indices % 17.0) - 8.0) * 12.0,
            512.0 + (((indices // 17.0) % 17.0) - 8.0) * 12.0,
        )).astype(np.float32)
        for point_index, landmark_index in enumerate(body.face.FACE_OVAL):
            angle = 2.0 * np.pi * point_index / len(body.face.FACE_OVAL)
            landmarks[landmark_index] = (
                512.0 + 250.0 * np.cos(angle),
                512.0 + 310.0 * np.sin(angle),
            )
        angle = np.deg2rad(23.0)
        scale = 0.31
        detected = np.array([
            [scale * np.cos(angle), -scale * np.sin(angle), 360.0],
            [scale * np.sin(angle), scale * np.cos(angle), 40.0],
        ], dtype=np.float64)
        target = cv2.transform(landmarks[None, :, :], detected)[0]
        identity_image = np.zeros((1024, 1024, 3), dtype=np.uint8)
        body_image = np.zeros((1448, 1086, 3), dtype=np.uint8)

        with mock.patch.object(
                body, "_detect", side_effect=[landmarks, target]), \
             mock.patch.object(
                 body.cv2, "estimateAffinePartial2D",
                 return_value=(detected, None)):
            upright, receipt, _key = body._face_transform(
                identity_image, body_image, allow_stylized=True)

        self.assertAlmostEqual(upright[0, 0], scale, places=6)
        self.assertAlmostEqual(upright[1, 1], scale, places=6)
        self.assertAlmostEqual(upright[0, 1], 0.0, places=6)
        self.assertAlmostEqual(upright[1, 0], 0.0, places=6)
        source_anchor = np.array([512.0, 512.0])
        old_anchor = detected @ np.array([*source_anchor, 1.0])
        new_anchor = upright @ np.array([*source_anchor, 1.0])
        np.testing.assert_allclose(new_anchor, old_anchor, atol=1e-4)
        self.assertTrue(receipt["upright_lock"])
        self.assertAlmostEqual(
            receipt["detected_rotation_degrees"], 23.0, places=3)

        with mock.patch.object(
                body, "_detect", side_effect=[landmarks, target]), \
             mock.patch.object(
                 body.cv2, "estimateAffinePartial2D",
                 return_value=(detected, None)):
            photographic, photo_receipt, _key = body._face_transform(
                identity_image, body_image, allow_stylized=False)
        np.testing.assert_allclose(photographic, detected, atol=1e-7)
        self.assertFalse(photo_receipt["upright_lock"])

    def test_stylized_neck_center_uses_narrow_rows_before_shoulders(self):
        plate = np.zeros((720, 600, 4), dtype=np.uint8)
        # The measured face ends near y=280.  A broad jaw contracts into a
        # 60-pixel neck, then widens into the shoulders.  The narrow rows—not
        # the landmark-biased facial centre—are the body handoff authority.
        plate[230:260, 190:410, 3] = 255
        plate[260:286, 270:330, 3] = 255
        plate[286:350, 150:450, 3] = 255

        centre, receipt = body._stylized_neck_center(
            plate, (220, 100, 160, 180))

        self.assertAlmostEqual(centre, 299.5, places=3)
        self.assertTrue(receipt["applied"])
        self.assertEqual(receipt["method"], "narrow-body-silhouette")
        self.assertLessEqual(receipt["row_range"][0], 270)
        self.assertGreaterEqual(receipt["row_range"][1], 270)

    def test_stylized_upright_alignment_centres_neck_on_shoulders(self):
        indices = np.arange(478, dtype=np.float32)
        landmarks = np.column_stack((
            512.0 + ((indices % 17.0) - 8.0) * 12.0,
            512.0 + (((indices // 17.0) % 17.0) - 8.0) * 12.0,
        )).astype(np.float32)
        for point_index, landmark_index in enumerate(body.face.FACE_OVAL):
            angle = 2.0 * np.pi * point_index / len(body.face.FACE_OVAL)
            landmarks[landmark_index] = (
                512.0 + 250.0 * np.cos(angle),
                512.0 + 310.0 * np.sin(angle),
            )
        angle = np.deg2rad(23.0)
        scale = 0.31
        detected = np.array([
            [scale * np.cos(angle), -scale * np.sin(angle), 482.0],
            [scale * np.sin(angle), scale * np.cos(angle), -40.0],
        ], dtype=np.float64)
        target = cv2.transform(landmarks[None, :, :], detected)[0]
        oval = target[body.face.FACE_OVAL]
        face_bounds = cv2.boundingRect(np.round(oval).astype(np.int32))
        _face_x, face_y, face_width, face_height = face_bounds
        body_plate = np.zeros((1448, 1086, 4), dtype=np.uint8)
        target_neck_x = 540
        start = int(face_y + face_height * 0.72)
        stop = int(face_y + face_height * 1.20)
        body_plate[start:stop, target_neck_x - 38:target_neck_x + 38, 3] = 255
        identity_image = np.zeros((1024, 1024, 3), dtype=np.uint8)

        with mock.patch.object(
                body, "_detect", side_effect=[landmarks, target]), \
             mock.patch.object(
                 body.cv2, "estimateAffinePartial2D",
                 return_value=(detected, None)):
            upright, receipt, _key = body._face_transform(
                identity_image, body_plate, allow_stylized=True)

        mapped_neck_x = (
            upright[0, 0] * identity_image.shape[1] * 0.5 + upright[0, 2])
        self.assertAlmostEqual(mapped_neck_x, target_neck_x - 0.5, places=3)
        self.assertAlmostEqual(upright[0, 1], 0.0, places=6)
        self.assertAlmostEqual(upright[1, 0], 0.0, places=6)
        self.assertTrue(receipt["neck_alignment"]["applied"])
        self.assertLess(receipt["neck_alignment"]["shift_x"], 0)

    def test_runtime_head_mask_keeps_the_generated_hair_silhouette(self):
        """The live layer owns the face, not the portrait's square hairstyle."""
        landmarks = np.zeros((478, 2), dtype=np.float32)
        for point_index, landmark_index in enumerate(body.face.FACE_OVAL):
            angle = 2.0 * np.pi * point_index / len(body.face.FACE_OVAL)
            landmarks[landmark_index] = (
                512.0 + 250.0 * np.cos(angle),
                512.0 + 310.0 * np.sin(angle),
            )
        portrait = np.full((1024, 1024, 4), 255, dtype=np.uint8)
        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            body._head_mask(portrait, landmarks, mask_path)
            mask = cv2.imread(mask_path, cv2.IMREAD_UNCHANGED)
        alpha_points = cv2.findNonZero((mask[:, :, 3] > 8).astype(np.uint8))
        self.assertIsNotNone(alpha_points)
        _x, _y, width, height = cv2.boundingRect(alpha_points)
        self.assertLess(width, 700)
        self.assertLess(height, 800)

    def test_final_runtime_composite_rejects_an_oversized_live_head(self):
        body_plate = np.zeros((1152, 864, 4), dtype=np.uint8)
        body_plate[20:1128, 296:580, :3] = 180
        body_plate[20:1128, 296:580, 3] = 255
        transform = np.array(
            [[0.30, 0.0, 286.0], [0.0, 0.30, -6.0]],
            dtype=np.float64,
        )
        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            mask = np.full((1024, 1024, 4), 255, dtype=np.uint8)
            cv2.imwrite(mask_path, mask)
            failure = body._composite_head_proportion_failure(
                body_plate, mask_path, transform, [390, 61, 90, 127])
        self.assertIn("live head silhouette is too large", failure)

    def test_verified_stylized_composite_accepts_bounded_chibi_head(self):
        body_plate = np.zeros((1152, 864, 4), dtype=np.uint8)
        body_plate[20:1128, 296:580, :3] = 180
        body_plate[20:1128, 296:580, 3] = 255
        transform = np.array(
            [[0.30, 0.0, 286.0], [0.0, 0.30, -6.0]],
            dtype=np.float64,
        )
        # 0.384 wide x 0.158 tall deliberately reproduces the accepted 3D
        # Luffy body that the photographic 0.15 face-height ceiling rejects.
        face_bounds = [390, 61, 109, 175]
        with tempfile.TemporaryDirectory() as directory:
            mask_path = os.path.join(directory, "head-mask.png")
            mask = np.full((1024, 1024, 4), 255, dtype=np.uint8)
            cv2.imwrite(mask_path, mask)
            strict_failure = body._composite_head_proportion_failure(
                body_plate, mask_path, transform, face_bounds)
            stylized_failure = body._composite_head_proportion_failure(
                body_plate, mask_path, transform, face_bounds,
                verified_stylized=True)

        self.assertIn("generated head is too large", strict_failure)
        self.assertIsNone(stylized_failure)

    def test_masculine_plate_rejects_a_positive_heel_assignment(self):
        with self.assertRaisesRegex(ValueError, "non-feminine presentation"):
            body._prompt({
                "presentation": "masculine",
                "medium": "photograph",
                "prompt": (
                    "A precisely tailored scarlet suit with a slim opaque line, "
                    "one slim platinum cuff, and Christian Louboutin 100mm "
                    "stiletto heels."
                ),
            })

    def test_male_and_ambiguous_plates_reject_feminine_garments(self):
        for presentation in ("male", "ambiguous", "neutral"):
            with self.subTest(presentation=presentation), self.assertRaisesRegex(
                    ValueError, "non-feminine presentation"):
                body._prompt({
                    "presentation": presentation,
                    "medium": "photograph",
                    "prompt": (
                        "A scarlet lightweight tailored office sheath dress "
                        "with a modest neckline and polished black Oxfords."
                    ),
                })

    def test_female_male_and_ambiguous_plates_use_only_the_safe_branch(self):
        cases = {
            "female": (wardrobe.FEMININE_RULE, "105–120mm"),
            "male": (wardrobe.MASCULINE_RULE, "polished loafers"),
            "ambiguous": (wardrobe.ANDROGYNOUS_RULE, "do not infer a gender identity"),
        }
        all_rules = {
            wardrobe.FEMININE_RULE,
            wardrobe.MASCULINE_RULE,
            wardrobe.ANDROGYNOUS_RULE,
        }
        for source_presentation, (expected_rule, marker) in cases.items():
            with self.subTest(source_presentation=source_presentation):
                plate = body._prompt({
                    "presentation": source_presentation,
                    "medium": "photograph",
                })
                self.assertIn(expected_rule, plate)
                self.assertIn(marker, plate)
                for other_rule in all_rules - {expected_rule}:
                    self.assertNotIn(other_rule, plate)
                if source_presentation != "female":
                    self.assertNotIn("105–120mm", plate)

    def test_manual_prompt_and_keep_note_cannot_reintroduce_gold_or_clutter(self):
        with self.assertRaisesRegex(ValueError, "forbidden gold styling"):
            body._prompt({
                "presentation": "feminine",
                "medium": "photograph",
                "prompt": (
                    "A fitted scarlet wool suit with slim trousers, precise seams, "
                    "and a rose gold necklace; keep the line opaque and polished."
                ),
            })

    def test_stored_body_prompt_is_migrated_for_api_ui_without_disk_mutation(self):
        legacy = (
            "Keep her golden blonde hair and tailored fuchsia wool blazer. "
            "Only one statement Cartier gold necklace. Preserve slim charcoal "
            "trousers, crisp seams, and polished black heels. Render real-looking "
            "gold, platinum, and stones with exactly one statement piece in the "
            "discipline of Cartier, Bulgari, Van Cleef & Arpels, Tiffany, or Hermes."
        )
        metadata = {
            "created": "2026-08-01T12:00:00",
            "options": {"style": "editorial", "prompt": legacy},
        }
        projected = body.public_body_metadata(metadata)
        self.assertEqual(legacy, metadata["options"]["prompt"])
        self.assertIsNot(metadata, projected)
        self.assertIsNot(metadata["options"], projected["options"])
        prompt = projected["options"]["prompt"]
        self.assertIn("golden blonde hair", prompt)
        self.assertIn("tailored fuchsia wool blazer", prompt)
        self.assertIn("slim charcoal trousers", prompt)
        self.assertNotIn("Cartier gold necklace", prompt)
        self.assertNotIn("real-looking gold", prompt)
        self.assertIn(wardrobe.ACCESSORY_RULE, prompt)
        self.assertEqual(
            prompt,
            body.public_body_metadata(projected)["options"]["prompt"],
        )
        self.assertEqual(1, prompt.count(wardrobe.ACCESSORY_RULE))
        # The projected text is safe to send back through ordinary regeneration.
        body._prompt({"prompt": prompt, "presentation": "feminine"})

    def test_default_direction_has_the_current_accessory_rule(self):
        direction = body._direction({})
        self.assertIn(body.DEFAULT_BODY_PROMPT, direction)
        self.assertIn(wardrobe.ACCESSORY_RULE, direction)
        self.assertNotIn("sensual", direction.lower())

    def test_safe_long_manual_prompt_keeps_the_full_editor_budget(self):
        manual = "Tailored scarlet wool with precise seams and clean structure. " * 64
        self.assertLessEqual(len(manual), wardrobe.PROMPT_LIMIT)
        self.assertEqual(manual.strip(), body._direction({"prompt": manual}))

    def test_precise_edit_can_remove_gold_but_cannot_add_it_or_clutter(self):
        self.assertEqual(
            body._edit_instruction("Remove the gold necklace and preserve everything else"),
            "Remove the gold necklace and preserve everything else")
        with self.assertRaisesRegex(ValueError, "gold styling"):
            body._edit_instruction("Add a gold necklace")
        with self.assertRaisesRegex(ValueError, "excessive accessories"):
            body._edit_instruction("Add layered necklaces and stacked bracelets")
        for view in body.BODY_VIEWS:
            prompt = body._edit_prompt("Change the blazer to coral", view)
            self.assertIn("Precisely edit", prompt)
            self.assertIn("one coherent matched turnaround", prompt)
            self.assertIn(wardrobe.ACCESSORY_RULE, prompt)
            self.assertIn("No green or green cast", prompt)
        with self.assertRaisesRegex(ValueError, "excessive accessories"):
            body._prompt({
                "presentation": "androgynous",
                "medium": "photograph",
                "prompt": (
                    "A fitted camel wool suit with slim trousers, precise seams, "
                    "and polished black boots; keep the line opaque and refined."
                ),
                "notes": "keep the layered necklaces and stacked bracelets",
            })
        with self.assertRaisesRegex(ValueError, "forbidden gold styling"):
            body._prompt({
                "presentation": "masculine",
                "medium": "photograph",
                "outfit": (
                    "A fitted charcoal suit with slim trousers, gold buttons, "
                    "and polished black Oxfords."
                ),
            })


if __name__ == "__main__":
    unittest.main()


class KeepFromThePortrait(unittest.TestCase):
    """An add-on the owner types before a build: what must survive it."""

    def test_a_note_rides_with_the_prompt_never_instead_of_it(self):
        # It used to be DROPPED the moment an expanded prompt existed -
        # which is the normal path - so "keep his bandana" never reached
        # the model, and a character came back with the right face and
        # none of what made him recognisable (owner, 2026-08-04).
        sys.path.insert(0, str(ROOT))
        from studio import body
        house = body._direction({"prompt": "A tailored navy dress."})
        self.assertEqual(house, "A tailored navy dress.")
        both = body._direction({"prompt": "A tailored navy dress.",
                                "notes": "keep his bandana"})
        self.assertIn("A tailored navy dress.", both)
        self.assertIn("keep his bandana", both)
        # a note on its own still gets the house prompt behind it
        alone = body._direction({"notes": "keep her earrings"})
        self.assertIn(body.DEFAULT_BODY_PROMPT, alone)
        self.assertIn("keep her earrings", alone)

    def test_the_head_plate_is_told_what_to_keep(self):
        # The bandana is a HEAD accessory, and normalising the face is
        # exactly what removed it.
        source = (ROOT / "studio" / "generate.py").read_text(encoding="utf-8")
        self.assertIn("keep=\"\"", source)
        self.assertIn("MUST KEEP from the source portrait:", source)
        builder = (ROOT / "studio" / "build.py").read_text(encoding="utf-8")
        self.assertIn("keep=notes", builder)
        # and it reaches the worker from the UI
        self.assertIn('b.add_argument("--keep"', builder)

    def test_a_note_forces_the_face_to_be_rebuilt(self):
        # One-click SKIPS the face when it is already built. With a note,
        # skipping means the one thing the owner asked to keep never comes
        # back - his bandana lives on the head plate (owner, 2026-08-04).
        ready = {
            "status": "ready",
            "source_metrics": {"source_medium": "photograph"},
            "head": {
                "prompt_version": generate.head_prompt_version("photograph"),
                "remove_headwear": False,
                "headwear_policy": "preserve",
            },
        }
        self.assertTrue(server_app._pipeline_face_needs_rebuild(
            ready, "keep his bandana", False))

    def test_the_ui_asks_before_a_long_build(self):
        page = (ROOT / "web" / "settings.html").read_text(encoding="utf-8")
        self.assertIn("function askKeep(", page)
        self.assertIn("Add extra comments, e.g. keep the character", page)
        self.assertIn("Remove hats and headwear", page)
        self.assertIn("currentRemoveHeadwear=false", page)
        self.assertIn("remove_headwear: removeHeadwear.checked", page)
        # both long builds ask
        self.assertIn("if (what === 'build' || what === 'pipeline')", page)
