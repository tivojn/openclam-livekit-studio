# Public release checklist

## Source snapshot

- [ ] Copy only the reviewed iOS, macOS, shared contract, broker, agent, and
      repository documentation paths into a new directory.
- [ ] Confirm the directory has no inherited `.git` directory or remotes.
- [ ] Exclude local configuration, Keychain exports, signing material, user
      data, caches, models, builds, logs, screenshots, recordings, and AVTR
      release packages.
- [ ] Run `python3 scripts/public-release-audit.py .` and review every finding.
- [ ] Write an external file/mode/SHA-256 manifest with `--write-manifest`,
      require it with `--manifest`, and verify an extracted Git archive against
      that same manifest.
- [ ] Initialize new history only after the audit passes.
- [ ] After the first commit, run
      `python3 scripts/public-release-audit.py --require-fresh-history .`.

## Tests

- [ ] Build and test the iOS app from the snapshot with generated data outside
      the source tree.
- [ ] Run the broker typecheck and tests.
- [ ] Run the agent lint and tests.
- [ ] Run the complete macOS regression, dependency, license, privacy, native,
      and packaged-runtime checks.

## Avatar rights

- [ ] Confirm the only bundled avatar media are the reviewed Captain Ayer and
      Ara runtime files listed by the provenance record and binary allowlist.
- [ ] Confirm `AVATAR_ASSET_LICENSE.md` remains separate from the MIT software
      license and grants no standalone media reuse.
- [ ] Require documented ownership, model consent where applicable, allowed
      uses, redistribution permission, source provenance, and immutable hashes
      before adding or replacing any likeness media.
- [ ] Confirm neither the public source nor its history can reach source
      portraits, authoring projects, unapproved avatars, or release packages.
- [ ] Confirm Avatar Store networking remains fail-closed for v1.0.1 while
      local AVTR import and deletion still work.

## macOS binary release

- [ ] Build the final DMG from the reviewed source commit.
- [ ] Verify the app and every nested executable are signed by the intended
      Developer ID with Hardened Runtime and only reviewed entitlements.
- [ ] Notarize and staple both the app and outer DMG.
- [ ] Verify the DMG, mount it read-only, and repeat signature, Gatekeeper,
      privacy, license, architecture, deployment-target, and runtime audits on
      the mounted app.
- [ ] Publish the DMG, SHA-256 sidecar, and required corresponding-source
      archives as GitHub Release assets, not repository files.

Do not publish while any audit is incomplete or any human-likeness rights
record is missing.
