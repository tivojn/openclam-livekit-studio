import { randomUUID } from "node:crypto";
import { describe, expect, it, vi } from "vitest";

vi.mock("openclaw/plugin-sdk/inbound-envelope", () => ({
  resolveInboundRouteEnvelopeBuilderWithRuntime: () => ({
    route: { agentId: "research", accountId: "ara", sessionKey: "agent:research:openclam:test" },
    buildEnvelope: () => ({ storePath: "/private/session.json", body: "hello" }),
  }),
}));

import { dispatchOpenClamTurn } from "../src/inbound.js";
import { setOpenClamRuntime } from "../src/runtime.js";
import type { TurnSubmitFrame } from "../src/types.js";

describe("OpenClam inbound authorization", () => {
  it("does not grant paired text implicit command authority", async () => {
    let inboundContext: Record<string, unknown> | undefined;
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => {
          inboundContext = value;
          return value;
        }),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.replyOptions.onPartialReply({ text: "reply" });
          await params.delivery.deliver({ text: "reply" });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
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
    } satisfies TurnSubmitFrame;

    await dispatchOpenClamTurn({
      ctx: {
        cfg: {},
        account: {
          accountId: "ara",
          agentId: "research",
          displayName: "Ara",
          enabled: true,
          configured: true,
          bridgeUrl: "https://bridge.example",
          connectionId,
          adapterTokenFile: "/private/token",
          stateFile: "/private/state",
        },
      } as any,
      frame,
      signal: new AbortController().signal,
      sink: { partial: vi.fn(async () => undefined), completed: vi.fn(async () => undefined) },
    });

    expect(inboundContext?.CommandAuthorized).toBe(false);
  });

  it("does not split an emoji at the 32,000-code-point reply boundary", async () => {
    const reply = `${"a".repeat(31_999)}🙂b`;
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.replyOptions.onPartialReply({ text: reply });
          await params.delivery.deliver({ text: reply });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
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
    } satisfies TurnSubmitFrame;
    const partial = vi.fn(async (_text: string) => undefined);
    const completed = vi.fn(async (_text: string) => undefined);

    await dispatchOpenClamTurn({
      ctx: {
        cfg: {},
        account: {
          accountId: "ara",
          agentId: "research",
          displayName: "Ara",
          enabled: true,
          configured: true,
          bridgeUrl: "https://bridge.example",
          connectionId,
          adapterTokenFile: "/private/token",
          stateFile: "/private/state",
        },
      } as any,
      frame,
      signal: new AbortController().signal,
      sink: { partial, completed },
    });

    for (const value of [partial.mock.calls[0]?.[0], completed.mock.calls[0]?.[0]]) {
      expect(Array.from(String(value))).toHaveLength(32_000);
      expect(String(value).endsWith("🙂")).toBe(true);
      expect(/[\uD800-\uDBFF]$/u.test(String(value))).toBe(false);
    }
  });
});
