import { DurableObject } from "cloudflare:workers";
import { decryptJson, encryptJson } from "./crypto";
import { isRecord, parseClaimRequest } from "./validation";
import type {
  AuthenticatedLeaseClaimRequest,
  CredentialBundle,
  EncryptedLeaseRecord,
  LeaseBinding,
  LeaseClaimResponse,
} from "./types";

const RECORD_KEY = "lease";

interface CreateLeaseRequest extends LeaseBinding {
  schema_version: 1;
  lease_id: string;
  bundle: CredentialBundle;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

export class CredentialLease extends DurableObject<Env> {
  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/internal/create") {
      return this.create(await request.json<CreateLeaseRequest>());
    }
    if (request.method === "POST" && url.pathname === "/internal/claim") {
      return this.claim(
        url.searchParams.get("lease_id") ?? "",
        await request.json(),
        Date.now(),
      );
    }
    if (request.method === "POST" && url.pathname === "/internal/delete") {
      await this.ctx.storage.deleteAll();
      return json({ deleted: true });
    }
    return json({ error: "not_found" }, 404);
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }

  private async create(value: CreateLeaseRequest): Promise<Response> {
    if (await this.ctx.storage.get(RECORD_KEY)) {
      return json({ error: "lease_exists" }, 409);
    }

    const binding: LeaseBinding = {
      room_name: value.room_name,
      agent_name: value.agent_name,
      profile_hash: value.profile_hash,
      expires_at: value.expires_at,
    };
    const record: EncryptedLeaseRecord = {
      schema_version: 1,
      ...binding,
      encrypted_payload: await encryptJson(
        value.bundle,
        this.env.BYOK_KEK_B64,
        value.lease_id,
      ),
    };

    await this.ctx.storage.put(RECORD_KEY, record);
    await this.ctx.storage.setAlarm(value.expires_at);
    return json({ created: true }, 201);
  }

  private async claim(
    leaseId: string,
    value: unknown,
    now: number,
  ): Promise<Response> {
    if (!isRecord(value)) {
      return json({ error: "invalid_claim" }, 400);
    }
    const {
      auth_timestamp: authTimestamp,
      auth_nonce: authNonce,
      ...publicClaim
    } = value;
    const claim = {
      ...parseClaimRequest(publicClaim),
      auth_timestamp: authTimestamp,
      auth_nonce: authNonce,
    } as AuthenticatedLeaseClaimRequest;
    const record = await this.ctx.storage.get<EncryptedLeaseRecord>(RECORD_KEY);
    if (record === undefined) {
      return json({ error: "lease_not_found" }, 404);
    }

    // The object serializes claims. Delete before decrypting so replay remains
    // impossible even if ciphertext/configuration is corrupt.
    await this.ctx.storage.deleteAll();
    if (record.expires_at <= now) {
      return json({ error: "lease_expired" }, 410);
    }
    if (
      claim.room_name !== record.room_name ||
      claim.agent_name !== record.agent_name ||
      claim.profile_hash !== record.profile_hash
    ) {
      return json({ error: "lease_binding_mismatch" }, 403);
    }
    if (
      !Number.isSafeInteger(claim.auth_timestamp) ||
      Math.abs(Math.floor(now / 1_000) - claim.auth_timestamp) > 30 ||
      !/^[A-Za-z0-9_-]{24}$/.test(claim.auth_nonce)
    ) {
      return json({ error: "claim_authentication_expired" }, 401);
    }

    try {
      const bundle = await decryptJson<CredentialBundle>(
        record.encrypted_payload,
        this.env.BYOK_KEK_B64,
        leaseId,
      );
      const response: LeaseClaimResponse = {
        schema_version: 1,
        lease_id: leaseId,
        profile_hash: record.profile_hash,
        profile: bundle.profile,
        credentials: bundle.credentials,
      };
      return json(response);
    } catch {
      return json({ error: "lease_decryption_failed" }, 500);
    }
  }
}
