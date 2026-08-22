import { DurableObject } from "cloudflare:workers";
import {
  decryptPairingClientToken,
  encryptPairingClientToken,
  installationVerifier,
  pairingVerifier,
  randomToken,
  tokenVerifier,
} from "./crypto";
import type {
  PairingRecord,
  RedeemFailureRecord,
  RedeemPairingRequest,
} from "./types";

const PAIRING_PREFIX = "pairing:";
const CONNECTION_PREFIX = "connection:";
const FAILURE_PREFIX = "failure:";
const MAX_INSTALLATION_REDEEM_FAILURES = 5;

interface InternalCreateRequest {
  record: PairingRecord;
}

interface InternalDeleteRequest {
  verifier: string;
}

interface InternalDeleteConnectionRequest {
  connectionId: string;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function pairingTtlMilliseconds(env: Env): number {
  const seconds = Number(env.PAIRING_TTL_SECONDS);
  if (!Number.isInteger(seconds) || seconds < 60 || seconds > 600) {
    throw new Error("invalid_pairing_ttl");
  }
  return seconds * 1_000;
}

function pairingKey(verifier: string): string {
  return `${PAIRING_PREFIX}${verifier}`;
}

function failureKey(verifier: string): string {
  return `${FAILURE_PREFIX}${verifier}`;
}

function connectionKey(connectionId: string): string {
  return `${CONNECTION_PREFIX}${connectionId}`;
}

export class PairingCoordinator extends DurableObject<Env> {
  private operationQueue: Promise<void> = Promise.resolve();

  override async fetch(request: Request): Promise<Response> {
    return this.enqueue(() => this.route(request));
  }

  override async alarm(): Promise<void> {
    await this.enqueue(() => this.cleanup(Date.now()));
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/internal/create") {
      return this.create(await request.json<InternalCreateRequest>());
    }
    if (request.method === "POST" && url.pathname === "/internal/delete") {
      return this.delete(await request.json<InternalDeleteRequest>());
    }
    if (
      request.method === "POST" &&
      url.pathname === "/internal/delete-connection"
    ) {
      return this.deleteConnection(
        await request.json<InternalDeleteConnectionRequest>(),
      );
    }
    if (request.method === "POST" && url.pathname === "/internal/redeem") {
      return this.redeem(await request.json<RedeemPairingRequest>(), Date.now());
    }
    return json({ error: "not_found" }, 404);
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.operationQueue.then(operation);
    this.operationQueue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private async create(value: InternalCreateRequest): Promise<Response> {
    const key = pairingKey(value.record.verifier);
    const byConnection = connectionKey(value.record.connectionId);
    const [existingPairing, existingConnection] = await Promise.all([
      this.ctx.storage.get(key),
      this.ctx.storage.get(byConnection),
    ]);
    if (existingPairing !== undefined || existingConnection !== undefined) {
      return json({ error: "pairing_collision" }, 409);
    }
    await this.ctx.storage.put({
      [key]: value.record,
      [byConnection]: value.record.verifier,
    });
    await this.scheduleCleanup(value.record.expiresAt);
    return json({ created: true }, 201);
  }

  private async delete(value: InternalDeleteRequest): Promise<Response> {
    const key = pairingKey(value.verifier);
    const record = await this.ctx.storage.get<PairingRecord>(key);
    await this.ctx.storage.delete([
      key,
      ...(record === undefined ? [] : [connectionKey(record.connectionId)]),
    ]);
    return json({ deleted: true });
  }

  private async deleteConnection(
    value: InternalDeleteConnectionRequest,
  ): Promise<Response> {
    const byConnection = connectionKey(value.connectionId);
    let verifier = await this.ctx.storage.get<string>(byConnection);
    if (verifier === undefined) {
      // Supports records created before the connection index was introduced.
      const pairings = await this.ctx.storage.list<PairingRecord>({
        prefix: PAIRING_PREFIX,
      });
      verifier = [...pairings.values()].find(
        (record) => record.connectionId === value.connectionId,
      )?.verifier;
    }
    await this.ctx.storage.delete([
      byConnection,
      ...(verifier === undefined ? [] : [pairingKey(verifier)]),
    ]);
    return json({ deleted: true });
  }

  private async redeem(
    value: RedeemPairingRequest,
    now: number,
  ): Promise<Response> {
    const installationHash = await installationVerifier(
      value.installationId,
      this.env.TOKEN_VERIFIER_PEPPER,
    );
    const failuresKey = failureKey(installationHash);
    const failures = await this.ctx.storage.get<RedeemFailureRecord>(failuresKey);
    if (
      failures !== undefined &&
      failures.expiresAt > now &&
      failures.count >= MAX_INSTALLATION_REDEEM_FAILURES
    ) {
      return json({ error: "pairing_locked" }, 423);
    }

    const verifier = await pairingVerifier(value.code, this.env.PAIRING_CODE_PEPPER);
    const key = pairingKey(verifier);
    const record = await this.ctx.storage.get<PairingRecord>(key);
    if (record === undefined) {
      return this.failedRedeem(failuresKey, failures, now, "not_found", 404);
    }
    if (record.expiresAt <= now) {
      return this.failedRedeem(
        failuresKey,
        failures,
        now,
        "pairing_expired",
        410,
      );
    }
    if (
      record.consumedAt !== undefined &&
      record.installationVerifier !== installationHash
    ) {
      return this.failedRedeem(
        failuresKey,
        failures,
        now,
        "pairing_consumed",
        409,
      );
    }

    let clientToken: string;
    let consumed = record;
    if (record.consumedAt !== undefined) {
      if (
        record.installationVerifier === undefined ||
        record.encryptedClientToken === undefined
      ) {
        return this.failedRedeem(
          failuresKey,
          failures,
          now,
          "pairing_consumed",
          409,
        );
      }
      try {
        clientToken = await decryptPairingClientToken(
          record.encryptedClientToken,
          this.env.PENDING_EVENT_KEK_B64,
          record.connectionId,
          installationHash,
        );
      } catch {
        return json({ error: "unavailable" }, 503);
      }
    } else {
      clientToken = randomToken();
      consumed = {
        ...record,
        consumedAt: now,
        installationVerifier: installationHash,
        encryptedClientToken: await encryptPairingClientToken(
          clientToken,
          this.env.PENDING_EVENT_KEK_B64,
          record.connectionId,
          installationHash,
        ),
      };
      // Persist the one encrypted retry credential before activation. If the
      // activation response is lost, the same installation derives and retries
      // the exact same verifier instead of minting a second identity.
      await this.ctx.storage.put(key, consumed);
    }

    const clientTokenVerifier = await tokenVerifier(
      clientToken,
      this.env.TOKEN_VERIFIER_PEPPER,
      "client",
      record.connectionId,
    );
    const session = this.env.CONNECTOR_SESSIONS.get(
      this.env.CONNECTOR_SESSIONS.idFromName(record.connectionId),
    );
    const activated = await session.fetch("https://session.internal/internal/activate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        connectionId: record.connectionId,
        clientTokenVerifier,
        installationVerifier: installationHash,
        pairedAt: consumed.consumedAt ?? now,
      }),
    });
    if (!activated.ok) {
      return json({ error: "unavailable" }, 503);
    }

    await this.ctx.storage.delete(failuresKey);
    return json({
      v: 1,
      connectionId: record.connectionId,
      gatewayLabel: record.gatewayLabel,
      accounts: record.accounts,
      clientToken,
    });
  }

  private async failedRedeem(
    key: string,
    existing: RedeemFailureRecord | undefined,
    now: number,
    error: "not_found" | "pairing_consumed" | "pairing_expired",
    status: number,
  ): Promise<Response> {
    const ttl = pairingTtlMilliseconds(this.env);
    const current = existing?.expiresAt !== undefined && existing.expiresAt > now
      ? existing.count
      : 0;
    const updated: RedeemFailureRecord = {
      count: current + 1,
      expiresAt: now + ttl,
    };
    await this.ctx.storage.put(key, updated);
    await this.scheduleCleanup(updated.expiresAt);
    if (updated.count >= MAX_INSTALLATION_REDEEM_FAILURES) {
      return json({ error: "pairing_locked" }, 423);
    }
    return json({ error }, status);
  }

  private async cleanup(now: number): Promise<void> {
    let nextExpiry: number | undefined;
    const pairings = await this.ctx.storage.list<PairingRecord>({ prefix: PAIRING_PREFIX });
    const ttl = pairingTtlMilliseconds(this.env);
    for (const [key, record] of pairings) {
      const cleanupAt = record.expiresAt + ttl;
      if (cleanupAt <= now) {
        if (record.consumedAt === undefined) {
          const session = this.env.CONNECTOR_SESSIONS.get(
            this.env.CONNECTOR_SESSIONS.idFromName(record.connectionId),
          );
          const expired = await session.fetch(
            "https://session.internal/internal/expire",
            {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                connectionId: record.connectionId,
                unpairedCleanupAt: cleanupAt,
                now,
              }),
            },
          );
          if (
            !expired.ok &&
            expired.status !== 404 &&
            expired.status !== 409
          ) {
            throw new Error("session_cleanup_failed");
          }
        }
        await this.ctx.storage.delete([key, connectionKey(record.connectionId)]);
      } else {
        if (record.expiresAt <= now && record.encryptedClientToken !== undefined) {
          const { encryptedClientToken: _expiredToken, ...withoutRetryToken } = record;
          await this.ctx.storage.put(key, withoutRetryToken);
        }
        const nextRecordExpiry = record.expiresAt > now ? record.expiresAt : cleanupAt;
        nextExpiry = Math.min(nextExpiry ?? nextRecordExpiry, nextRecordExpiry);
      }
    }
    const failures = await this.ctx.storage.list<RedeemFailureRecord>({
      prefix: FAILURE_PREFIX,
    });
    for (const [key, record] of failures) {
      if (record.expiresAt <= now) {
        await this.ctx.storage.delete(key);
      } else {
        nextExpiry = Math.min(nextExpiry ?? record.expiresAt, record.expiresAt);
      }
    }
    if (nextExpiry !== undefined) await this.ctx.storage.setAlarm(nextExpiry);
  }

  private async scheduleCleanup(timestamp: number): Promise<void> {
    const existing = await this.ctx.storage.getAlarm();
    if (existing === null || timestamp < existing) {
      await this.ctx.storage.setAlarm(timestamp);
    }
  }
}
