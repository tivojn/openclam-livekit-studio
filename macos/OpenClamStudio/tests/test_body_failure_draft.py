"""Focused QA for preserving a rejected Full Body Studio submission."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "web" / "settings.html"


def section(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


class BodyFailureDraftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page = SETTINGS.read_text(encoding="utf-8")
        cls.draft_code = section(
            cls.page,
            "/* qa:body-generation-draft:start */",
            "/* qa:body-generation-draft:end */",
        )

    def test_draft_helpers_keep_an_exact_job_scoped_copy(self):
        probe = self.draft_code + r"""
const assert = require('node:assert/strict');
const submitted = {
  style: 'editorial',
  pose: 'confident',
  prompt: '  vivid fuchsia sheath · no cobalt  ',
  presentation: 'feminine',
  medium: 'photograph',
};
rememberBodyGenerationDraft('cleo', 'job-38', submitted);
submitted.style = 'mutated outside';
submitted.prompt = 'mutated outside';
assert.deepEqual(bodyGenerationDraftFor('cleo', 'job-38'), {
  style: 'editorial',
  pose: 'confident',
  prompt: '  vivid fuchsia sheath · no cobalt  ',
  presentation: 'feminine',
  medium: 'photograph',
});
assert.equal(bodyGenerationDraftFor('other'), null);
assert.equal(bodyGenerationDraftFor('cleo', 'other-job'), null);
reviseBodyGenerationDraft('cleo', {prompt: 'retry words', pose: 'relaxed'});
assert.equal(bodyGenerationDraftFor('cleo').prompt, 'retry words');
assert.equal(bodyGenerationDraftFor('cleo').pose, 'relaxed');
assert.equal(bodyGenerationDraftFor('cleo').presentation, 'feminine');
assert.equal(clearBodyGenerationDraft('cleo', 'other-job'), false);
assert.notEqual(bodyGenerationDraftFor('cleo'), null);
assert.equal(clearBodyGenerationDraft('cleo', 'job-38'), true);
assert.equal(bodyGenerationDraftFor('cleo'), null);
"""
        result = subprocess.run(
            ["node", "-e", probe],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)

    def test_generate_records_only_the_profile_the_backend_accepted(self):
        generate = section(
            self.page, "async function generateBody() {", "async function editBody() {"
        )
        self.assertIn("const slug = BODY_SLUG;", generate)
        self.assertIn("const profile = bodyProfile();", generate)
        self.assertIn("body: JSON.stringify({ slug, profile })", generate)
        self.assertIn(
            "rememberBodyGenerationDraft(slug, response.job_id, profile);", generate
        )
        # A rejected start/already-running response is not the submitted build.
        self.assertGreater(
            generate.index("rememberBodyGenerationDraft"),
            generate.index("response.detail || !response.started"),
        )
        # Closing/switching during the POST must not resurrect a cleared draft.
        self.assertIn("if (BODY_SLUG !== slug) return;", generate)

    def test_failure_repaint_uses_draft_without_mutating_canonical_state(self):
        render = section(
            self.page, "function renderBodyStudio() {", "function motionSetCard(set) {"
        )
        self.assertIn("const submittedDraft = bodyGenerationDraftFor(BODY_SLUG);", render)
        self.assertIn("? submittedDraft.style : options.style", render)
        self.assertIn("? submittedDraft.pose : options.pose", render)
        self.assertIn("? submittedDraft.prompt", render)
        self.assertIn("setBodyPromptNote('retry', null);", render)
        self.assertNotIn("BODY_STATE.body.options = submittedDraft", render)
        self.assertNotIn("localStorage", self.draft_code)
        self.assertNotIn("sessionStorage", self.draft_code)
        self.assertNotIn("fetch(", self.draft_code)
        self.assertNotIn("api(", self.draft_code)

    def test_draft_clears_on_success_close_and_avatar_switch(self):
        close = section(self.page, "function closeBody() {", "const BODY_JOB_COPY")
        opened = section(
            self.page, "async function openBody(slug) {", "function bodyProfile() {"
        )
        poll = section(
            self.page, "async function pollBody(expectedJobId) {", "async function removeBody() {"
        )
        self.assertIn("clearBodyGenerationDraft();", close)
        self.assertIn("BODY_GENERATION_DRAFT.slug !== String(slug || '')", opened)
        self.assertIn("clearBodyGenerationDraft();", opened)
        self.assertIn("if (!bodyGenerationDraftFor(slug)", opened)
        self.assertIn("!job.error", poll)
        self.assertIn("bodyGenerationDraftFor(slug, expectedJobId)", poll)
        clear_at = poll.index("clearBodyGenerationDraft(slug, expectedJobId);")
        refresh_at = poll.index("BODY_STATE = await api('/api/avatar/body?slug='")
        render_at = poll.index("renderBodyStudio();", refresh_at)
        self.assertLess(clear_at, refresh_at)
        self.assertLess(refresh_at, render_at)

    def test_retry_edits_update_only_the_ephemeral_draft(self):
        handlers = section(
            self.page,
            "function syncBodyGenerationDraftFromEditor() {",
            "document.querySelectorAll('[data-body-mode]')",
        )
        self.assertIn("reviseBodyGenerationDraft(BODY_SLUG", handlers)
        self.assertIn("$('#body-style').addEventListener('change'", handlers)
        self.assertIn("$('#body-pose').addEventListener('change'", handlers)
        self.assertIn("$('#body-prompt').addEventListener('input'", handlers)
        self.assertNotIn("BODY_STATE", handlers)


if __name__ == "__main__":
    unittest.main()
