'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createHash} = require('node:crypto');
const {
  AVATAR_STORE_AVAILABLE,
  AvatarStore,
  AvatarStoreError,
  RELEASE_ENDPOINT_POLICY,
  assertInitialUrl,
  assertRedirectUrl,
  createGithubEndpointPolicy,
  secureFetch,
  validateCatalog,
} = require('../electron/avatar-store.cjs');

const ENDPOINT_POLICY = createGithubEndpointPolicy({
  owner: 'openclam-fixtures',
  repository: 'avatar-store-fixtures',
});
const CATALOG_URL = ENDPOINT_POLICY.catalogUrl;
const FIXTURE_ID = 'fixture-avatar';

const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const packageBytes = Buffer.from('small deterministic Mac AVTR fixture');
const thumbnailBytes = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64');

function catalog(overrides = {}) {
  const value = {
    schemaVersion: 1,
    entries: [{
      id: FIXTURE_ID,
      name: 'Fixture Avatar',
      author: 'Example Publisher',
      version: 1,
      thumbnail: {
        url: 'https://raw.githubusercontent.com/openclam-fixtures/avatar-store-fixtures/main/catalog/v1/fixture-avatar-thumbnail.png',
        sha256: sha(thumbnailBytes),
        bytes: thumbnailBytes.length,
        mime: 'image/png',
        width: 1,
        height: 1,
      },
      variants: {
        'ios-light': {
          url: 'https://github.com/openclam-fixtures/avatar-store-fixtures/releases/download/fixtures-v1/fixture-avatar-ios-light.avtr',
          sha256: '1'.repeat(64),
          bytes: 20,
          format: 'openclam-avatar',
          profile: 'ios-light',
        },
        'macos-full': {
          url: 'https://github.com/openclam-fixtures/avatar-store-fixtures/releases/download/fixtures-v1/fixture-avatar-macos-full.avtr',
          sha256: sha(packageBytes),
          bytes: packageBytes.length,
          format: 'openclam-avatar',
          profile: 'macos-full',
        },
      },
    }],
  };
  return Object.assign(value, overrides);
}

function response(bytes, options = {}) {
  return new Response(bytes, {
    status: options.status || 200,
    headers: {
      'content-length': String(bytes ? bytes.length : 0),
      ...(options.headers || {}),
    },
  });
}

async function expectStoreError(code, operation) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof AvatarStoreError);
    assert.equal(error.code, code);
    return true;
  });
}

async function main() {
  assert.equal(AVATAR_STORE_AVAILABLE, false);
  assert.equal(RELEASE_ENDPOINT_POLICY, null);
  let disabledFetchCount = 0;
  const disabledRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'openclam-avatar-store-disabled-'));
  try {
    const disabledStore = new AvatarStore({
      cacheRoot: disabledRoot,
      fetchImpl: async () => { disabledFetchCount += 1; throw new Error('must not fetch'); },
    });
    fs.writeFileSync(disabledStore.catalogPath(), JSON.stringify(catalog()));
    await expectStoreError('store_unavailable', () => disabledStore.catalog());
    await expectStoreError('store_unavailable', () => disabledStore.cachedCatalog());
    assert.equal(disabledFetchCount, 0,
      'release-disabled store must fail before network and before stale cache exposure');
  } finally {
    fs.rmSync(disabledRoot, {recursive: true, force: true});
  }

  const valid = validateCatalog(catalog(), ENDPOINT_POLICY);
  assert.equal(valid.schemaVersion, 1);
  assert.equal(valid.entries[0].id, FIXTURE_ID);
  assert.equal(valid.entries[0].variants['macos-full'].profile, 'macos-full');
  assert.ok(Object.isFrozen(valid));
  assert.ok(Object.isFrozen(valid.entries[0]));

  for (const mutate of [
    (value) => { value.extra = true; },
    (value) => { value.entries[0].extra = true; },
    (value) => { value.entries[0].version = '1'; },
    (value) => { value.entries[0].author = ' Invalid Publisher'; },
    (value) => { delete value.entries[0].variants['ios-light']; },
    (value) => { value.entries[0].thumbnail.mime = 'image/jpeg'; },
    (value) => { value.entries[0].variants['macos-full'].profile = 'ios-light'; },
    (value) => { value.entries[0].variants['macos-full'].url = 'https://example.com/avatar.avtr'; },
  ]) {
    const invalid = structuredClone(catalog());
    mutate(invalid);
    assert.throws(() => validateCatalog(invalid, ENDPOINT_POLICY), AvatarStoreError);
  }

  assert.equal(assertInitialUrl(CATALOG_URL, 'catalog', ENDPOINT_POLICY).href, CATALOG_URL);
  assert.throws(() => assertInitialUrl(
    `${CATALOG_URL}?changed=1`, 'catalog', ENDPOINT_POLICY), AvatarStoreError);
  assert.throws(() => assertInitialUrl(
    'http://github.com/openclam-fixtures/avatar-store-fixtures/releases/download/x/a.avtr',
    'package', ENDPOINT_POLICY), AvatarStoreError);
  assert.throws(() => assertInitialUrl(
    'https://github.com/other/repo/releases/download/x/a.avtr',
    'package', ENDPOINT_POLICY), AvatarStoreError);
  const opaque = 'https://release-assets.githubusercontent.com/github-production-release-asset/123/file?sig=opaque';
  assert.equal(assertRedirectUrl(opaque, 'package', true, ENDPOINT_POLICY).hostname,
    'release-assets.githubusercontent.com');
  assert.throws(() => assertRedirectUrl(
    'https://assets.example/avatar.avtr', 'package', true, ENDPOINT_POLICY), AvatarStoreError);
  assert.throws(() => assertRedirectUrl(
    'https://raw.githubusercontent.com/openclam-fixtures/avatar-store-fixtures/main/catalog/v1/not-an-avtr',
    'package', true, ENDPOINT_POLICY), AvatarStoreError);

  const redirectCalls = [];
  const redirected = await secureFetch(async (url) => {
    redirectCalls.push(url);
    if (redirectCalls.length === 1) return response(null, {
      status: 302,
      headers: {location: opaque},
    });
    return response(packageBytes);
  }, catalog().entries[0].variants['macos-full'].url, 'package', {
    endpointPolicy: ENDPOINT_POLICY,
  });
  assert.equal(await redirected.text(), packageBytes.toString());
  assert.equal(redirectCalls.length, 2);

  await expectStoreError('network_refused', () => secureFetch(async () => response(null, {
    status: 302,
    headers: {location: 'https://evil.example/stolen.avtr'},
  }), catalog().entries[0].variants['macos-full'].url, 'package', {
    endpointPolicy: ENDPOINT_POLICY,
  }));

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openclam-avatar-store-qa-'));
  try {
    const catalogBytes = Buffer.from(JSON.stringify(catalog()));
    const requests = [];
    const fetchImpl = async (url) => {
      requests.push(url);
      if (url === CATALOG_URL) return response(catalogBytes);
      if (url.includes('fixture-avatar-thumbnail.png')) return response(thumbnailBytes);
      if (url.includes('fixture-avatar-macos-full.avtr')) return response(packageBytes);
      throw new Error(`unexpected request ${url}`);
    };
    const store = new AvatarStore({cacheRoot: root, fetchImpl, endpointPolicy: ENDPOINT_POLICY});
    const loaded = await store.catalog();
    assert.equal(loaded.source, 'network');
    assert.equal(loaded.catalog.entries.length, 1);

    const thumbnail = await store.thumbnail(FIXTURE_ID);
    assert.match(thumbnail.dataUrl, /^data:image\/png;base64,/);
    assert.ok(Buffer.from(thumbnail.dataUrl.split(',')[1], 'base64').equals(thumbnailBytes));

    const progress = [];
    const downloaded = await store.download(FIXTURE_ID, {onProgress: (value) => progress.push(value)});
    assert.equal(downloaded.fromCache, false);
    assert.equal(fs.readFileSync(downloaded.file).toString(), packageBytes.toString());
    assert.equal(progress.at(-1).percent, 100);
    assert.equal(progress.at(-1).phase, 'validating');
    assert.ok(progress.filter(value => value.phase === 'downloading')
      .every(value => value.percent <= 99),
    'download progress must reserve 100% for post-EOF verification');

    const requestCount = requests.length;
    const cached = await store.download(FIXTURE_ID);
    assert.equal(cached.fromCache, true);
    assert.equal(requests.length, requestCount, 'verified cached AVTR must work offline');

    await store.recordInstallation(valid.entries[0], 'fixture-avatar-installed');
    assert.deepEqual(store.readInstallations()[FIXTURE_ID],
      {slug: 'fixture-avatar-installed', version: 1});
    await Promise.all([
      store.recordInstallation({id: 'second-avatar', version: 2}, 'second-avatar'),
      store.recordInstallation({id: 'third-avatar', version: 3}, 'third-avatar'),
    ]);
    assert.deepEqual(Object.keys(store.readInstallations()).sort(),
      [FIXTURE_ID, 'second-avatar', 'third-avatar'].sort(),
      'concurrent installs must serialize their installation ledger updates');

    const offline = new AvatarStore({
      cacheRoot: root,
      fetchImpl: async () => { throw new Error('offline'); },
      endpointPolicy: ENDPOINT_POLICY,
    });
    const saved = await offline.catalog();
    assert.equal(saved.source, 'cache');
    assert.match(saved.warning, /offline/i);
    const savedThumbnail = await offline.thumbnail(FIXTURE_ID);
    assert.equal(savedThumbnail.dataUrl, thumbnail.dataUrl);

    fs.writeFileSync(downloaded.file, Buffer.alloc(packageBytes.length, 0));
    assert.equal(await store.packageCached(loaded.catalog.entries[0]), false,
      'same-size corrupt cache must never be advertised as available offline');
    const repairing = new AvatarStore({
      cacheRoot: root,
      fetchImpl: async (url) => url === CATALOG_URL
        ? response(catalogBytes) : response(Buffer.from('wrong bytes with same-ish transport')),
      endpointPolicy: ENDPOINT_POLICY,
    });
    await repairing.catalog();
    await expectStoreError('integrity_failed', () => repairing.download(FIXTURE_ID));
    assert.equal(fs.existsSync(downloaded.file), false,
      'corrupt cache and failed replacement must not survive');

    const cancelRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'openclam-avatar-store-cancel-'));
    try {
      const controller = new AbortController();
      const cancelStore = new AvatarStore({
        cacheRoot: cancelRoot,
        fetchImpl: async (url) => url === CATALOG_URL
          ? response(catalogBytes) : response(packageBytes),
        endpointPolicy: ENDPOINT_POLICY,
      });
      await cancelStore.catalog();
      await expectStoreError('cancelled', () => cancelStore.download(FIXTURE_ID, {
        signal: controller.signal,
        onProgress: (value) => { if (value.loaded > 0) controller.abort(); },
      }));
      const packageDirectory = path.join(cancelRoot, 'packages');
      const leftovers = fs.existsSync(packageDirectory) ? fs.readdirSync(packageDirectory) : [];
      assert.deepEqual(leftovers, [], 'cancel must remove every partial download');
    } finally {
      fs.rmSync(cancelRoot, {recursive: true, force: true});
    }
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }

  console.log('avatar store QA passed');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
