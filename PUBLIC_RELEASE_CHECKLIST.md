# Public release checklist

## Source snapshot

- [ ] Copy only the reviewed iOS, macOS, shared contract, broker, agent, and
      repository documentation paths into a new directory.
- [ ] Confirm the directory has no inherited `.git` directory or remotes.
- [ ] Exclude local configuration, Keychain exports, signing material, user
      data, caches, models, builds, logs, screenshots, recordings, and AVTR
      release packages.
- [ ] Run `python3 scripts/public-release-audit.py .` and review every finding.
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

- [ ] Keep the synthetic `OpenClam Guide` as the only likeness-free avatar in
      source.
- [ ] Keep all human thumbnails and AVTR packages in the separate Avatar Store
      release channel.
- [ ] Require documented owner, license, model consent, allowed uses,
      redistribution permission, source provenance, and immutable hashes.
- [ ] Confirm neither the public source nor its history can reach a quarantined
      portrait or package.

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
