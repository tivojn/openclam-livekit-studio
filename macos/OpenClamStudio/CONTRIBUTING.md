# Contributing

OpenClam Studio is a standalone macOS application. Contributions must not add
phone pairing, account synchronization, LAN relay, EnConvo dependencies, or a
second Live Talk implementation.

Use the existing local chat/PTT provider boundary, the reviewed LiveKit tuple
contract, and the AVTR v2 schemas. Keep provider credentials in Keychain and
never return them to renderer code.

Before opening a pull request:

```bash
npm run check
npm audit --omit=dev
```

Use synthetic avatar and audio fixtures. Do not commit user portraits, generated
authoring directories, provider responses, keys, tokens, local paths, logs,
models, packaging caches, or release credentials.
