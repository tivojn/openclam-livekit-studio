# Security policy

Security fixes apply to the latest release and `main`.

Report vulnerabilities through GitHub's private security advisory flow. Do not
attach real credentials, portraits, recordings, conversations, AVTR authoring
projects, signing material, or unredacted logs.

## Secret handling

- Keep provider keys and user tokens in the platform Keychain.
- Keep broker and LiveKit deployment secrets in the deployment platform's
  secret store.
- Never put credentials in source, `.xcconfig`, `.env`, Worker configuration,
  command arguments, logs, room metadata, dispatch metadata, fixtures, or
  release archives.
- Samples must use obvious placeholders that cannot be mistaken for a working
  provider credential.

The ignored local files include `agent/livekit.toml`,
`cloudflare-broker/.dev.vars`,
`ios/OpenClamLiveKit/Config/LiveTalk.local.xcconfig`, and
`macos/OpenClamStudio/config.json`. They are not release inputs.

## Public release requirements

1. Build from a fresh public snapshot, not the private development history.
2. Run `python3 scripts/public-release-audit.py .` before committing.
   For a release, verify both the tree and extracted Git archive against one
   external file/mode/SHA-256 manifest.
3. For the first public commit, rerun it with `--require-fresh-history` after
   the commit exists.
4. Run the iOS, broker, agent, and macOS test suites.
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
