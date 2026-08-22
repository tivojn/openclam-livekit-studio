# Security policy

Security fixes apply to the latest release and `main`.

Report vulnerabilities through GitHub's private security advisory flow. Do not
attach real credentials, portraits, recordings, conversations, AVTR authoring
projects, signing material, or unredacted logs.

## Secret handling

- Keep provider keys and user tokens in the platform Keychain.
- Keep broker and LiveKit deployment secrets in the deployment platform's
  secret store.
- Keep the OpenClaw bridge bootstrap token, pairing pepper, token-verifier
  pepper, and pending-frame encryption key in that bridge's independent
  deployment secret store.
- Never put credentials in source, `.xcconfig`, `.env`, Worker configuration,
  command arguments, logs, room metadata, dispatch metadata, fixtures, or
  release archives.
- Samples must use obvious placeholders that cannot be mistaken for a working
  provider credential.

The ignored local files include `agent/livekit.toml`,
`cloudflare-broker/.dev.vars`,
`ios/OpenClamLiveKit/Config/LiveTalk.local.xcconfig`, and
`ios/OpenClamLiveKit/Config/AgentConnector.local.xcconfig`,
`openclaw-bridge/.dev.vars`, and `macos/OpenClamStudio/config.json`. They are
not release inputs. OpenClaw adapter credentials and sequence state are private
runtime files beneath the OpenClaw state directory and must never enter source
or release archives.

The OpenClaw connector accepts text-only input and is fail-closed. It must not
expose a Gateway owner token, provider key, local iPhone file or tool, reasoning,
tool argument or output, or approval surface. A capability-gated extension may
deliver generated files through authenticated, bounded storage; iOS verifies
their declared type, length, and SHA-256 before persisting them. Sensitive media
is excluded. Pairing credentials are role-scoped and revocable; token verifiers
are persisted instead of raw bridge tokens. Pending relay frames are encrypted
at rest. Generated-file metadata is bounded, contains no source path or bearer
credential, and is deleted on acknowledgement, error, revocation, or expiry.
The pilot requires App Attest and verified-installation rate limiting before
public-user distribution.

## Public release requirements

1. Build from a fresh public snapshot, not the private development history.
2. Run `python3 scripts/public-release-audit.py .` before committing.
   For a release, verify both the tree and extracted Git archive against one
   external file/mode/SHA-256 manifest.
3. For the first public commit, rerun it with `--require-fresh-history` after
   the commit exists.
4. Run the iOS, LiveKit broker/agent, OpenClaw bridge/plugin, and macOS test
   suites appropriate to the changed paths.
5. Publish no human-likeness asset outside the exact, hash-pinned Captain Ayer
   and Ara paths without documented ownership, consent, and redistribution
   rights. Keep their restricted media license separate from the MIT software
   license.
6. Publish macOS binaries only after Developer ID signing, Hardened Runtime,
   notarization, stapling, Gatekeeper assessment, and mounted-image re-audit.
7. Attach generated binaries to a GitHub Release; do not commit DMGs, IPAs,
   archives, model caches, or AVTR store packages to source history.

The macOS threat model and release details are in
[`macos/OpenClamStudio/SECURITY.md`](macos/OpenClamStudio/SECURITY.md). The
broker's one-use lease and authentication boundaries are documented in
[`cloudflare-broker/README.md`](cloudflare-broker/README.md).
