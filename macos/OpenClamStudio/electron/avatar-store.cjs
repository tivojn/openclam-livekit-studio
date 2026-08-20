'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createHash, randomBytes } = require('node:crypto');

// v1.0.1 has no reviewed remote catalog. A null release policy means the
// shipped app has no catalog URL to request, even if stale cache files exist.
const AVATAR_STORE_AVAILABLE = false;
const RELEASE_ENDPOINT_POLICY = null;
const CATALOG_SCHEMA_VERSION = 1;
const CATALOG_MAX_BYTES = 256 * 1024;
const THUMBNAIL_MAX_BYTES = 8 * 1024 * 1024;
const AVTR_MAX_BYTES = 4 * 1024 * 1024 * 1024;
const NETWORK_TIMEOUT_MS = 15_000;
const AVTR_DOWNLOAD_TIMEOUT_MS = 30 * 60 * 1000;
const CATALOG_MEMORY_TTL_MS = 5 * 60 * 1000;
const RAW_HOST = 'raw.githubusercontent.com';
const RELEASE_HOST = 'github.com';
const RELEASE_REDIRECT_HOSTS = new Set([
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
]);
const HASH_RE = /^[0-9a-f]{64}$/;
const ID_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const PROFILE_NAMES = new Set(['ios-light', 'macos-full']);
const THUMBNAIL_MIME = 'image/png';

class AvatarStoreError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AvatarStoreError';
    this.code = code;
  }
}

function createGithubEndpointPolicy({owner, repository}) {
  const component = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
  if (!component.test(String(owner || '')) || !component.test(String(repository || ''))) {
    throw new TypeError('Avatar Store endpoint identity is invalid');
  }
  const repo = `${owner}/${repository}`;
  return Object.freeze({
    repo,
    catalogUrl: `https://${RAW_HOST}/${repo}/main/catalog/v1/catalog.json`,
  });
}

function requireEndpointPolicy(endpointPolicy) {
  if (!endpointPolicy || typeof endpointPolicy.catalogUrl !== 'string'
      || typeof endpointPolicy.repo !== 'string') {
    throw new AvatarStoreError(
      'store_unavailable',
      'Avatar Store is not available in this release. Import local .avtr files in Avatar Studio.',
    );
  }
  return endpointPolicy;
}

function plainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
    && Object.getPrototypeOf(value) === Object.prototype;
}

function exactKeys(value, expected, label) {
  if (!plainObject(value)) throw new AvatarStoreError('catalog_invalid', `invalid ${label}`);
  const keys = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (keys.length !== wanted.length || keys.some((key, index) => key !== wanted[index])) {
    throw new AvatarStoreError('catalog_invalid', `invalid ${label} fields`);
  }
}

function safeText(value, label, maximum = 64) {
  if (typeof value !== 'string' || value !== value.trim() || !value
      || value.length > maximum || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new AvatarStoreError('catalog_invalid', `invalid ${label}`);
  }
  return value;
}

function safeHttpsUrl(value, label) {
  let parsed;
  try { parsed = new URL(value); } catch {
    throw new AvatarStoreError('catalog_invalid', `invalid ${label} URL`);
  }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.hash) {
    throw new AvatarStoreError('catalog_invalid', `unsafe ${label} URL`);
  }
  return parsed;
}

function isRawRepoUrl(parsed, endpointPolicy) {
  return parsed.hostname === RAW_HOST
    && parsed.pathname.startsWith(`/${endpointPolicy.repo}/`)
    && !parsed.search;
}

function isReleaseRepoUrl(parsed, endpointPolicy) {
  return parsed.hostname === RELEASE_HOST
    && parsed.pathname.startsWith(`/${endpointPolicy.repo}/releases/download/`)
    && !parsed.search;
}

function assertInitialUrl(value, kind, endpointPolicy) {
  const endpoints = requireEndpointPolicy(endpointPolicy);
  const parsed = safeHttpsUrl(value, kind);
  if (kind === 'catalog') {
    if (parsed.href !== endpoints.catalogUrl) {
      throw new AvatarStoreError('catalog_invalid', 'catalog URL is not pinned');
    }
  } else if (kind === 'thumbnail') {
    if (!isRawRepoUrl(parsed, endpoints) && !isReleaseRepoUrl(parsed, endpoints)) {
      throw new AvatarStoreError('catalog_invalid', 'thumbnail is outside the avatar store repository');
    }
  } else if (kind === 'package') {
    if (!isReleaseRepoUrl(parsed, endpoints)) {
      throw new AvatarStoreError('catalog_invalid', 'avatar package is outside the release repository');
    }
  } else {
    throw new AvatarStoreError('catalog_invalid', 'unknown avatar store resource');
  }
  return parsed;
}

function assertRedirectUrl(value, kind, releaseChain, endpointPolicy) {
  const endpoints = requireEndpointPolicy(endpointPolicy);
  const parsed = safeHttpsUrl(value, kind);
  if (kind === 'catalog') {
    if (parsed.href !== endpoints.catalogUrl) {
      throw new AvatarStoreError('network_refused', 'catalog redirected outside its pinned location');
    }
    return parsed;
  }
  if (kind === 'thumbnail' && isRawRepoUrl(parsed, endpoints)) return parsed;
  if (isReleaseRepoUrl(parsed, endpoints)) return parsed;
  if (releaseChain && RELEASE_REDIRECT_HOSTS.has(parsed.hostname)) return parsed;
  throw new AvatarStoreError('network_refused', `${kind} redirected outside GitHub release storage`);
}

function positiveInteger(value, maximum, label) {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw new AvatarStoreError('catalog_invalid', `invalid ${label}`);
  }
  return value;
}

function validateVariant(value, profile, endpointPolicy) {
  exactKeys(value, ['url', 'sha256', 'bytes', 'format', 'profile'], `${profile} variant`);
  if (value.format !== 'openclam-avatar' || value.profile !== profile) {
    throw new AvatarStoreError('catalog_invalid', `invalid ${profile} package identity`);
  }
  if (typeof value.sha256 !== 'string' || !HASH_RE.test(value.sha256)) {
    throw new AvatarStoreError('catalog_invalid', `invalid ${profile} package hash`);
  }
  positiveInteger(value.bytes, AVTR_MAX_BYTES, `${profile} package size`);
  assertInitialUrl(value.url, 'package', endpointPolicy);
  return Object.freeze({
    url: value.url,
    sha256: value.sha256,
    bytes: value.bytes,
    format: value.format,
    profile: value.profile,
  });
}

function validateThumbnail(value, endpointPolicy) {
  exactKeys(value, ['url', 'sha256', 'bytes', 'mime', 'width', 'height'], 'thumbnail');
  if (typeof value.sha256 !== 'string' || !HASH_RE.test(value.sha256)) {
    throw new AvatarStoreError('catalog_invalid', 'invalid thumbnail hash');
  }
  positiveInteger(value.bytes, THUMBNAIL_MAX_BYTES, 'thumbnail size');
  positiveInteger(value.width, 8192, 'thumbnail width');
  positiveInteger(value.height, 8192, 'thumbnail height');
  if (value.mime !== THUMBNAIL_MIME) {
    throw new AvatarStoreError('catalog_invalid', 'unsupported thumbnail type');
  }
  assertInitialUrl(value.url, 'thumbnail', endpointPolicy);
  return Object.freeze({
    url: value.url,
    sha256: value.sha256,
    bytes: value.bytes,
    mime: value.mime,
    width: value.width,
    height: value.height,
  });
}

function validateEntry(value, endpointPolicy) {
  exactKeys(value, ['id', 'name', 'author', 'version', 'thumbnail', 'variants'], 'catalog entry');
  if (typeof value.id !== 'string' || !ID_RE.test(value.id)) {
    throw new AvatarStoreError('catalog_invalid', 'invalid avatar identifier');
  }
  const name = safeText(value.name, 'avatar name');
  const author = safeText(value.author, 'avatar publisher');
  positiveInteger(value.version, Number.MAX_SAFE_INTEGER, 'avatar version');
  if (!plainObject(value.variants)) {
    throw new AvatarStoreError('catalog_invalid', 'invalid avatar variants');
  }
  const variantNames = Object.keys(value.variants).sort();
  if (variantNames.length !== PROFILE_NAMES.size
      || variantNames.some((profile) => !PROFILE_NAMES.has(profile))) {
    throw new AvatarStoreError('catalog_invalid', 'invalid avatar variant names');
  }
  const variants = {};
  for (const profile of variantNames) {
    variants[profile] = validateVariant(value.variants[profile], profile, endpointPolicy);
  }
  return Object.freeze({
    id: value.id,
    name,
    author,
    version: value.version,
    thumbnail: validateThumbnail(value.thumbnail, endpointPolicy),
    variants: Object.freeze(variants),
  });
}

function validateCatalog(value, endpointPolicy) {
  const endpoints = requireEndpointPolicy(endpointPolicy);
  exactKeys(value, ['schemaVersion', 'entries'], 'catalog');
  if (value.schemaVersion !== CATALOG_SCHEMA_VERSION || !Array.isArray(value.entries)
      || value.entries.length < 1 || value.entries.length > 200) {
    throw new AvatarStoreError('catalog_invalid', 'unsupported avatar catalog');
  }
  const seen = new Set();
  const entries = value.entries.map((item) => {
    const entry = validateEntry(item, endpoints);
    if (seen.has(entry.id)) throw new AvatarStoreError('catalog_invalid', 'duplicate avatar identifier');
    seen.add(entry.id);
    return entry;
  });
  return Object.freeze({schemaVersion: CATALOG_SCHEMA_VERSION, entries: Object.freeze(entries)});
}

async function secureFetch(fetchImpl, initialUrl, kind, options = {}) {
  const endpoints = requireEndpointPolicy(options.endpointPolicy);
  let current = assertInitialUrl(initialUrl, kind, endpoints);
  const releaseChain = isReleaseRepoUrl(current, endpoints);
  for (let redirect = 0; redirect <= 5; redirect += 1) {
    const response = await fetchImpl(current.href, {
      method: 'GET',
      headers: {
        accept: kind === 'catalog' ? 'application/json' : '*/*',
        'user-agent': 'openclam-avatar-store',
      },
      redirect: 'manual',
      cache: 'no-store',
      signal: options.signal,
    });
    if (response.status >= 300 && response.status < 400) {
      if (redirect === 5) throw new AvatarStoreError('network_refused', 'too many download redirects');
      const location = response.headers.get('location');
      if (!location) throw new AvatarStoreError('network_refused', 'download redirect had no destination');
      current = assertRedirectUrl(
        new URL(location, current).href, kind, releaseChain, endpoints);
      continue;
    }
    assertRedirectUrl(current.href, kind, releaseChain, endpoints);
    if (!response.ok) {
      throw new AvatarStoreError('network_failed', `GitHub answered HTTP ${response.status}`);
    }
    return response;
  }
  throw new AvatarStoreError('network_refused', 'download redirect limit exceeded');
}

async function readBounded(response, maximum, signal) {
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > maximum) throw new AvatarStoreError('download_oversized', 'download is too large');
  if (!response.body) throw new AvatarStoreError('network_failed', 'download had no body');
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    if (signal && signal.aborted) throw new AvatarStoreError('cancelled', 'Download cancelled.');
    const {done, value} = await reader.read();
    if (done) break;
    const chunk = Buffer.from(value);
    total += chunk.length;
    if (total > maximum) {
      await reader.cancel().catch(() => {});
      throw new AvatarStoreError('download_oversized', 'download is too large');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, total);
}

async function sha256File(file) {
  const digest = createHash('sha256');
  const stream = fs.createReadStream(file);
  for await (const chunk of stream) digest.update(chunk);
  return digest.digest('hex');
}

async function verifiedFile(file, expectedBytes, expectedHash) {
  try {
    const stat = await fs.promises.stat(file);
    if (!stat.isFile() || stat.size !== expectedBytes) return false;
    return await sha256File(file) === expectedHash;
  } catch {
    return false;
  }
}

async function atomicWrite(file, bytes) {
  await fs.promises.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
  const temporary = `${file}.partial-${randomBytes(8).toString('hex')}`;
  try {
    await fs.promises.writeFile(temporary, bytes, {mode: 0o600, flag: 'wx'});
    await fs.promises.rename(temporary, file);
    await fs.promises.chmod(file, 0o600);
  } finally {
    await fs.promises.rm(temporary, {force: true}).catch(() => {});
  }
}

function timeoutSignal(parentSignal, milliseconds = NETWORK_TIMEOUT_MS) {
  const controller = new AbortController();
  let parentAbort = null;
  if (parentSignal) {
    parentAbort = () => controller.abort(parentSignal.reason);
    if (parentSignal.aborted) parentAbort();
    else parentSignal.addEventListener('abort', parentAbort, {once: true});
  }
  const timer = setTimeout(() => controller.abort(new Error('network timeout')), milliseconds);
  timer.unref?.();
  return {
    signal: controller.signal,
    dispose() {
      clearTimeout(timer);
      if (parentSignal && parentAbort) parentSignal.removeEventListener('abort', parentAbort);
    },
  };
}

function normalizeError(error) {
  if (error instanceof AvatarStoreError) return error;
  if (error && (error.name === 'AbortError' || error.code === 'ABORT_ERR')) {
    return new AvatarStoreError('cancelled', 'Download cancelled.');
  }
  return new AvatarStoreError('network_failed', String((error && error.message) || error || 'download failed'));
}

function validPngThumbnail(bytes, specification) {
  const signature = Buffer.from('89504e470d0a1a0a', 'hex');
  return Buffer.isBuffer(bytes) && bytes.length >= 24
    && bytes.subarray(0, 8).equals(signature)
    && bytes.readUInt32BE(8) === 13
    && bytes.subarray(12, 16).toString('ascii') === 'IHDR'
    && bytes.readUInt32BE(16) === specification.width
    && bytes.readUInt32BE(20) === specification.height;
}

class AvatarStore {
  constructor({
    cacheRoot,
    fetchImpl = globalThis.fetch,
    now = () => Date.now(),
    endpointPolicy = RELEASE_ENDPOINT_POLICY,
  }) {
    if (!cacheRoot || typeof fetchImpl !== 'function') throw new TypeError('AvatarStore needs cacheRoot and fetch');
    this.cacheRoot = path.resolve(cacheRoot);
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.endpointPolicy = endpointPolicy;
    this.memoryCatalog = null;
    this.catalogLoadedAt = 0;
    this.installationWrite = Promise.resolve();
  }

  catalogPath() { return path.join(this.cacheRoot, 'catalog-v1.json'); }
  installationPath() { return path.join(this.cacheRoot, 'installations-v1.json'); }
  packagePath(entry) {
    return path.join(this.cacheRoot, 'packages', `${entry.variants['macos-full'].sha256}.avtr`);
  }
  thumbnailPath(entry) {
    const extension = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp'}[entry.thumbnail.mime];
    return path.join(this.cacheRoot, 'thumbnails', `${entry.thumbnail.sha256}.${extension}`);
  }

  async cachedCatalog() {
    const endpoints = requireEndpointPolicy(this.endpointPolicy);
    try {
      const bytes = await fs.promises.readFile(this.catalogPath());
      if (bytes.length > CATALOG_MAX_BYTES) throw new AvatarStoreError('catalog_invalid', 'cached catalog is too large');
      let decoded;
      try { decoded = JSON.parse(bytes.toString('utf8')); } catch {
        throw new AvatarStoreError('catalog_invalid', 'cached catalog is not valid JSON');
      }
      return validateCatalog(decoded, endpoints);
    } catch (error) {
      if (error instanceof AvatarStoreError) throw error;
      throw new AvatarStoreError('catalog_unavailable', 'No saved avatar catalog is available.');
    }
  }

  async catalog({force = false, signal} = {}) {
    const endpoints = requireEndpointPolicy(this.endpointPolicy);
    if (!force && this.memoryCatalog
        && this.now() - this.catalogLoadedAt < CATALOG_MEMORY_TTL_MS) {
      return {catalog: this.memoryCatalog, source: 'memory', warning: ''};
    }
    let networkError = null;
    const timed = timeoutSignal(signal);
    try {
      const response = await secureFetch(
        this.fetchImpl,
        endpoints.catalogUrl,
        'catalog',
        {signal: timed.signal, endpointPolicy: endpoints},
      );
      const bytes = await readBounded(response, CATALOG_MAX_BYTES, timed.signal);
      let decoded;
      try { decoded = JSON.parse(bytes.toString('utf8')); } catch {
        throw new AvatarStoreError('catalog_invalid', 'catalog is not valid JSON');
      }
      const parsed = validateCatalog(decoded, endpoints);
      await atomicWrite(this.catalogPath(), Buffer.from(JSON.stringify(parsed)));
      this.memoryCatalog = parsed;
      this.catalogLoadedAt = this.now();
      return {catalog: parsed, source: 'network', warning: ''};
    } catch (error) {
      networkError = normalizeError(error);
    } finally {
      timed.dispose();
    }
    try {
      const cached = await this.cachedCatalog();
      this.memoryCatalog = cached;
      this.catalogLoadedAt = this.now();
      return {
        catalog: cached,
        source: 'cache',
        warning: networkError.code === 'catalog_invalid'
          ? 'The online catalog did not pass validation. Showing the last verified copy.'
          : 'You appear to be offline. Showing the saved catalog.',
      };
    } catch {
      throw new AvatarStoreError(
        networkError.code === 'catalog_invalid' ? 'catalog_invalid' : 'catalog_unavailable',
        networkError.code === 'catalog_invalid'
          ? 'The avatar catalog did not pass validation.'
          : 'Connect to the internet to load the Avatar Store.',
      );
    }
  }

  async entry(identifier) {
    requireEndpointPolicy(this.endpointPolicy);
    if (typeof identifier !== 'string' || !ID_RE.test(identifier)) {
      throw new AvatarStoreError('catalog_invalid', 'Invalid avatar selection.');
    }
    const {catalog} = await this.catalog();
    const entry = catalog.entries.find((item) => item.id === identifier);
    if (!entry) throw new AvatarStoreError('catalog_invalid', 'That avatar is not in the catalog.');
    return entry;
  }

  async packageCached(entry) {
    requireEndpointPolicy(this.endpointPolicy);
    const variant = entry.variants['macos-full'];
    return verifiedFile(this.packagePath(entry), variant.bytes, variant.sha256);
  }

  async thumbnail(identifier, {signal} = {}) {
    const entry = await this.entry(identifier);
    const file = this.thumbnailPath(entry);
    let bytes = null;
    if (await verifiedFile(file, entry.thumbnail.bytes, entry.thumbnail.sha256)) {
      bytes = await fs.promises.readFile(file);
      if (!validPngThumbnail(bytes, entry.thumbnail)) bytes = null;
    }
    if (!bytes) {
      await fs.promises.rm(file, {force: true}).catch(() => {});
      const timed = timeoutSignal(signal);
      try {
        const response = await secureFetch(
          this.fetchImpl, entry.thumbnail.url, 'thumbnail', {
            signal: timed.signal,
            endpointPolicy: this.endpointPolicy,
          });
        bytes = await readBounded(response, entry.thumbnail.bytes, timed.signal);
        if (bytes.length !== entry.thumbnail.bytes
            || createHash('sha256').update(bytes).digest('hex') !== entry.thumbnail.sha256) {
          throw new AvatarStoreError('integrity_failed', 'The avatar thumbnail did not pass verification.');
        }
        if (!validPngThumbnail(bytes, entry.thumbnail)) {
          throw new AvatarStoreError('integrity_failed', 'The avatar thumbnail dimensions did not pass verification.');
        }
        await atomicWrite(file, bytes);
      } finally {
        timed.dispose();
      }
    }
    return {
      id: entry.id,
      dataUrl: `data:${entry.thumbnail.mime};base64,${bytes.toString('base64')}`,
      width: entry.thumbnail.width,
      height: entry.thumbnail.height,
    };
  }

  async download(identifier, {signal, onProgress = () => {}} = {}) {
    const entry = await this.entry(identifier);
    const variant = entry.variants['macos-full'];
    const destination = this.packagePath(entry);
    await fs.promises.mkdir(path.dirname(destination), {recursive: true, mode: 0o700});
    if (await verifiedFile(destination, variant.bytes, variant.sha256)) {
      onProgress({id: entry.id, phase: 'validating', loaded: variant.bytes,
        total: variant.bytes, percent: 100, cached: true});
      return {entry, file: destination, fromCache: true};
    }
    await fs.promises.rm(destination, {force: true}).catch(() => {});
    const temporary = `${destination}.partial-${randomBytes(8).toString('hex')}`;
    const timed = timeoutSignal(signal, AVTR_DOWNLOAD_TIMEOUT_MS);
    let handle = null;
    try {
      const response = await secureFetch(this.fetchImpl, variant.url, 'package', {
        signal: timed.signal,
        endpointPolicy: this.endpointPolicy,
      });
      const declared = Number(response.headers.get('content-length') || 0);
      if (declared && declared !== variant.bytes) {
        throw new AvatarStoreError('integrity_failed', 'The avatar download size did not match the catalog.');
      }
      if (!response.body) throw new AvatarStoreError('network_failed', 'Avatar download had no body.');
      handle = await fs.promises.open(temporary, 'wx', 0o600);
      const digest = createHash('sha256');
      const reader = response.body.getReader();
      let loaded = 0;
      onProgress({id: entry.id, phase: 'downloading', loaded: 0,
        total: variant.bytes, percent: 0, cached: false});
      while (true) {
        if (timed.signal.aborted) throw new AvatarStoreError('cancelled', 'Download cancelled.');
        const {done, value} = await reader.read();
        if (done) break;
        const chunk = Buffer.from(value);
        loaded += chunk.length;
        if (loaded > variant.bytes) {
          await reader.cancel().catch(() => {});
          throw new AvatarStoreError('integrity_failed', 'The avatar download was larger than the catalog entry.');
        }
        await handle.write(chunk);
        digest.update(chunk);
        onProgress({id: entry.id, phase: 'downloading', loaded,
          total: variant.bytes,
          // 100 belongs to the verified state. A server that sends the
          // declared bytes and then stalls before EOF must never look done.
          percent: Math.min(99, Math.floor((loaded / variant.bytes) * 100)),
          cached: false});
      }
      await handle.sync();
      await handle.close();
      handle = null;
      if (loaded !== variant.bytes || digest.digest('hex') !== variant.sha256) {
        throw new AvatarStoreError('integrity_failed', 'The avatar download did not pass verification.');
      }
      await fs.promises.rename(temporary, destination);
      await fs.promises.chmod(destination, 0o600);
      onProgress({id: entry.id, phase: 'validating', loaded,
        total: variant.bytes, percent: 100, cached: false});
      return {entry, file: destination, fromCache: false};
    } catch (error) {
      if (timed.signal.aborted && !(signal && signal.aborted)) {
        throw new AvatarStoreError('network_failed', 'Avatar download timed out.');
      }
      throw normalizeError(error);
    } finally {
      timed.dispose();
      if (handle) await handle.close().catch(() => {});
      await fs.promises.rm(temporary, {force: true}).catch(() => {});
    }
  }

  readInstallations() {
    try {
      const value = JSON.parse(fs.readFileSync(this.installationPath(), 'utf8'));
      if (!plainObject(value)) return {};
      const safe = {};
      for (const [id, record] of Object.entries(value)) {
        if (!ID_RE.test(id) || !plainObject(record) || !ID_RE.test(String(record.slug || ''))
            || !Number.isSafeInteger(record.version) || record.version < 1) continue;
        safe[id] = {slug: record.slug, version: record.version};
      }
      return safe;
    } catch { return {}; }
  }

  async recordInstallation(entry, slug) {
    if (!entry || !ID_RE.test(entry.id) || !ID_RE.test(String(slug || ''))) return;
    const write = async () => {
      const records = this.readInstallations();
      records[entry.id] = {slug, version: entry.version};
      await atomicWrite(this.installationPath(), Buffer.from(JSON.stringify(records)));
    };
    // Downloads are deduplicated per catalog ID, not globally. Serialize the
    // tiny installation ledger so two different avatars completing together
    // cannot each overwrite the other's read-modify-write result.
    const pending = this.installationWrite.then(write, write);
    this.installationWrite = pending.catch(() => {});
    await pending;
  }
}

module.exports = {
  AVTR_MAX_BYTES,
  AVATAR_STORE_AVAILABLE,
  AvatarStore,
  AvatarStoreError,
  CATALOG_SCHEMA_VERSION,
  RELEASE_ENDPOINT_POLICY,
  assertInitialUrl,
  assertRedirectUrl,
  createGithubEndpointPolicy,
  normalizeError,
  secureFetch,
  validateCatalog,
  verifiedFile,
};
