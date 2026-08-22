# Public release checklist

## Source snapshot

- [ ] Copy only the reviewed iOS, macOS, shared contract, broker, agent, and
      repository documentation paths into a new directory.
- [ ] Confirm the directory has no inherited `.git` directory or remotes.
- [ ] Exclude local configuration, Keychain exports, signing material, user
      data, caches, models, builds, logs, screenshots, recordings, and AVTR
      release packages.
- [ ] Run `python3 scripts/public-release-audit.py .` and review every finding.
- [ ] Review `contracts/release-feature-contract-v1.json` as a product diff.
      Any enabled-to-disabled feature or transcript-delivery change requires
      explicit product approval in its own commit.
- [ ] Write an external file/mode/SHA-256 manifest with `--write-manifest`,
      require it with `--manifest`, and verify an extracted Git archive against
      that same manifest.
- [ ] Initialize new history only after the audit passes.
- [ ] After the first commit, run
      `python3 scripts/public-release-audit.py --require-fresh-history .`.

## Tests

- [ ] Build and test the iOS app from the snapshot with generated data outside
      the source tree.
- [ ] When Store paths change, run only the pinned endpoint, catalog/package,
      collision/update, and Store-link visibility tests.
- [ ] When PTT/provider paths change, run only the provider route, audio-format,
      partial/final transcript, stop-tail, cancellation, and composer tests.
- [ ] Run one signed-device/provider smoke whenever a microphone capture or
      realtime transport path changes; mocked request data is not sufficient.
- [ ] Run the broker typecheck and tests.
- [ ] Run the agent lint and tests.
- [ ] When OpenClaw connector paths change, run the bridge typecheck,
      Workers-runtime tests, and Wrangler dry-run; run the channel plugin
      typecheck and mocked transport/config tests; build the iOS connector and
      run its pairing, routing, streaming, replay, cancellation, and revocation
      tests.
- [ ] Run one visible end-to-end OpenClaw check: redeem a fresh code, select the
      intended agent, stream and finalize one reply, cancel one turn, reconnect
      and reconcile replay, disconnect/revoke, and confirm On this iPhone still
      works without cross-route transcript reuse.
- [ ] Confirm the OpenClaw bridge is a separate deployment from LiveKit, has no
      provider/Gateway credentials, persists only verifiers plus encrypted
      bounded pending text, and has request-content logging disabled.
- [ ] Do not distribute the connector publicly until App Attest and
      verified-installation rate limiting protect pairing redemption and client
      WebSocket upgrades.
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
- [ ] Confirm the iOS Avatar Store is visible and uses the immutable catalog tag
      declared by the release feature contract; local AVTR import and deletion
      must remain available.

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
