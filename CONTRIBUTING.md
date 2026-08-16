# Contributing

Keep changes scoped to the public source tree and preserve the privacy and
credential boundaries documented in `PRIVACY.md` and `SECURITY.md`.

Before opening a pull request:

1. Run `python3 scripts/public-release-audit.py .`.
2. Run the tests for each changed component.
3. Do not add generated builds, caches, logs, screenshots, recordings, private
   configuration, signing material, source portraits, or human-likeness avatar
   assets.
4. Update locks and third-party notices when dependencies change.
5. Use synthetic fixtures in tests. Construct secret-shaped validation strings
   at runtime instead of committing credential-like literals.

Avatar Store packages are release artifacts maintained outside this source
tree. A proposal for a human-likeness avatar must include a rights record,
consent scope, redistribution license, source provenance, and hashes for the
thumbnail and every package variant before publication review begins.
