import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  createFrame,
  encodeFrame,
  parseBridgeInbound,
  parseClientFrame,
  safeTurnErrorPayload,
} from "../src/protocol.js";

describe("agent connector v1 frames", () => {
  it("accepts a bounded text submit", () => {
    const connectionId = randomUUID();
    const frame = {
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId: randomUUID(),
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId: randomUUID(), accountId: "ara", text: "hello" },
    };
    expect(parseClientFrame(JSON.stringify(frame), connectionId)).toEqual(frame);
  });

  it("rejects an adapter-only kind on the client socket", () => {
    const connectionId = randomUUID();
    const frame = createFrame({
      kind: "assistant.completed",
      connectionId,
      conversationId: randomUUID(),
      seq: 1,
      payload: { turnId: randomUUID(), text: "not allowed" },
    });
    expect(() => parseClientFrame(encodeFrame(frame), connectionId)).toThrow("invalid_client_kind");
  });

  it("rejects unknown fields instead of silently accepting protocol drift", () => {
    const connectionId = randomUUID();
    const frame = {
      v: 1,
      kind: "heartbeat",
      connectionId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: {},
      text: "must not be logged or accepted",
    };
    expect(() => parseClientFrame(JSON.stringify(frame), connectionId)).toThrow("invalid_frame");
  });

  it("accepts only the strict sequence-free relay persistence receipt", () => {
    const connectionId = randomUUID();
    const receipt = {
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: 7, messageId: randomUUID() },
    };
    expect(parseBridgeInbound(JSON.stringify(receipt), connectionId)).toEqual(receipt);
    expect(() => parseBridgeInbound(JSON.stringify({ ...receipt, seq: 8 }), connectionId)).toThrow(
      "invalid_frame",
    );
    expect(() => parseClientFrame(JSON.stringify(receipt), connectionId)).toThrow(
      "invalid_client_kind",
    );
  });

  it("bounds multilingual error text by Unicode code point without splitting emoji", () => {
    const payload = safeTurnErrorPayload({
      turnId: randomUUID(),
      code: "agent_failed",
      message: "失败🙂".repeat(200),
      retryable: true,
    });
    const message = String(payload.message);
    expect(Array.from(message)).toHaveLength(240);
    expect(/[\uD800-\uDBFF]$/u.test(message)).toBe(false);
  });
});
