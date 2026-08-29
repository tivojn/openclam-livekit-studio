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
import type {
  ActivityStatus,
  OpenClamAttachmentUpload,
  TurnSubmitFrame,
  WorkStep,
} from "../src/types.js";

function testFrame(capabilities?: TurnSubmitFrame["payload"]["capabilities"]): TurnSubmitFrame {
  return {
    v: 1,
    kind: "turn.submit",
    connectionId: randomUUID(),
    conversationId: randomUUID(),
    messageId: randomUUID(),
    seq: 1,
    sentAt: Date.now(),
    payload: {
      turnId: randomUUID(),
      accountId: "ara",
      text: "hello",
      ...(capabilities === undefined ? {} : { capabilities }),
    },
  };
}

function testContext(connectionId: string): any {
  return {
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
  };
}

function testSink() {
  return {
    activity: vi.fn(async (_status: ActivityStatus) => undefined),
    clearActivity: vi.fn(async () => undefined),
    work: vi.fn(async (_step: WorkStep) => undefined),
    partial: vi.fn(async (_text: string) => undefined),
    attachment: vi.fn(async (_attachment: OpenClamAttachmentUpload) => undefined),
    completed: vi.fn(async (_text: string) => undefined),
  };
}

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
      sink: {
        activity: vi.fn(async () => undefined),
        clearActivity: vi.fn(async () => undefined),
        partial: vi.fn(async () => undefined),
        attachment: vi.fn(async () => undefined),
        completed: vi.fn(async () => undefined),
      },
    });

    expect(inboundContext?.CommandAuthorized).toBe(false);
    expect(channel.inbound.dispatchReply).toHaveBeenCalledWith(
      expect.objectContaining({
        replyOptions: expect.objectContaining({
          sourceReplyDeliveryMode: "automatic",
        }),
      }),
    );
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
      sink: {
        activity: vi.fn(async () => undefined),
        clearActivity: vi.fn(async () => undefined),
        partial,
        attachment: vi.fn(async () => undefined),
        completed,
      },
    });

    for (const value of [partial.mock.calls[0]?.[0], completed.mock.calls[0]?.[0]]) {
      expect(Array.from(String(value))).toHaveLength(32_000);
      expect(String(value).endsWith("🙂")).toBe(true);
      expect(/[\uD800-\uDBFF]$/u.test(String(value))).toBe(false);
    }
  });

  it("uses only fixed activity enums and excludes reasoning, commentary, notices, and tool details", async () => {
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.replyOptions.onReplyStart();
          await params.replyOptions.onPlanUpdate({ explanation: "private plan" });
          await params.replyOptions.onToolStart({
            name: "web_search",
            args: { query: "private query", path: "/srv/private" },
          });
          await params.delivery.deliver({ text: "hidden reason", isReasoning: true });
          await params.delivery.deliver({ text: "hidden comment", isCommentary: true });
          await params.delivery.deliver({ text: "hidden status", isStatusNotice: true });
          await params.delivery.deliver({ text: "visible answer" });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame(["activity-v1"]);
    const sink = testSink();

    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
    });

    expect(sink.activity.mock.calls.map((call) => call[0])).toEqual([
      "thinking",
      "thinking",
      "planning",
      "searching",
      "finalizing",
    ]);
    expect(sink.completed).toHaveBeenCalledWith("visible answer");
    expect(JSON.stringify(sink.activity.mock.calls)).not.toContain("private");
    expect(JSON.stringify(sink.completed.mock.calls)).not.toContain("hidden");
  });

  it("always emits bounded Work lifecycle steps even when OpenClaw sends no optional callbacks", async () => {
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.delivery.deliver({ text: "Fast answer" });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame(["activity-v1", "work-v1"]);
    const sink = testSink();

    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
    });

    expect(sink.work.mock.calls.map((call) => call[0])).toEqual([
      expect.objectContaining({
        stepId: "reasoning", state: "running", title: "Understanding the request",
      }),
      expect.objectContaining({
        stepId: "reasoning", state: "completed", title: "Understanding the request",
      }),
      expect.objectContaining({
        stepId: "response", state: "completed", title: "Preparing the response",
      }),
    ]);
    expect(sink.completed).toHaveBeenCalledWith("Fast answer");
  });

  it("emits expandable work steps without raw arguments, commands, or output", async () => {
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.replyOptions.onReplyStart();
          await params.replyOptions.onPlanUpdate({
            title: "Inspect and create",
            steps: ["Read the source", "Create the image"],
          });
          await params.replyOptions.onToolStart({
            toolCallId: "call-1",
            name: "exec_command",
            args: {
              command: [
                "curl -H",
                "Authorization:" + "Bearer",
                "fixture-value",
                "/srv/openclaw/private",
              ].join(" "),
            },
          });
          await params.replyOptions.onCommandOutput({
            toolCallId: "call-1",
            name: "exec_command",
            status: "completed",
            output: [
              "Saved /srv/openclaw/private/out.png",
              ["api", "key"].join("_") + "=fixture-value",
            ].join(" "),
            cwd: "/srv/openclaw/private",
          });
          await params.delivery.deliver({ text: "Done" });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame(["activity-v1", "attachments-v1", "work-v1"]);
    const sink = testSink();

    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
    });

    const encoded = JSON.stringify(sink.work.mock.calls);
    expect(sink.work.mock.calls.length).toBeGreaterThanOrEqual(4);
    expect(encoded).toContain("Understanding the request");
    expect(encoded).toContain("Inspect and create");
    expect(encoded).toContain("Command output stays private");
    expect(encoded).not.toContain("/srv/openclaw/private");
    expect(encoded).not.toContain("fixture-value");
    expect(encoded).not.toContain("curl -H");
    expect(encoded).not.toContain("Saved ");
    expect(encoded).not.toContain("args");
  });

  it("stages official media, suppresses a path-bearing partial, and sends only a safe filename", async () => {
    const sourcePath = "/srv/openclaw-private/ara.jpeg";
    const source = `file://${sourcePath}`;
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.replyOptions.onPartialReply({ text: `Saved at ${sourcePath}` });
          await params.delivery.deliver({ text: `Saved at ${sourcePath}`, mediaUrl: source });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame(["activity-v1", "attachments-v1"]);
    const sink = testSink();
    const loadMedia = vi.fn(async () => ({
      buffer: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
      fileName: "ara.jpeg",
      mediaType: "image/jpeg",
    }));

    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
      loadMedia,
    });

    expect(sink.partial).not.toHaveBeenCalled();
    expect(loadMedia).toHaveBeenCalledWith(expect.objectContaining({ source }));
    expect(sink.attachment).toHaveBeenCalledTimes(1);
    expect(sink.completed).toHaveBeenCalledWith("Saved at ara.jpeg");
    expect(JSON.stringify({
      partial: sink.partial.mock.calls,
      completed: sink.completed.mock.calls,
      attachment: sink.attachment.mock.calls.map((call) => ({
        fileName: call[0].fileName,
        mediaType: call[0].mediaType,
      })),
    })).not.toContain(sourcePath);
  });

  it("suppresses and redacts generic host paths while preserving HTTPS links", async () => {
    const privatePaths = [
      "/root/.openclaw/workspace/report.pdf",
      "file:///opt/openclaw/output/image.png",
      String.raw`C:\Users\Ara\secret.pdf`,
      "D:/data/secret.pdf",
      String.raw`\\server\share\secret.pdf`,
    ];
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.replyOptions.onPartialReply({ text: `Path:${privatePaths[0]}` });
          await params.replyOptions.onPartialReply({ text: `[${privatePaths[1]}]` });
          for (const privatePath of privatePaths.slice(2)) {
            await params.replyOptions.onPartialReply({ text: `Saved at ${privatePath}` });
          }
          await params.delivery.deliver({
            text: `Path:${privatePaths[0]} [${privatePaths[1]}] ${privatePaths.slice(2).join(" and ")}. Docs: https://example.com/files/help`,
          });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame(["activity-v1"]);
    const sink = testSink();

    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
    });

    expect(sink.partial).not.toHaveBeenCalled();
    const completed = sink.completed.mock.calls[0]?.[0] ?? "";
    expect(completed).toContain("attached file");
    expect(completed).toContain("https://example.com/files/help");
    for (const privatePath of privatePaths) expect(completed).not.toContain(privatePath);
  });

  it("completes a media-only reply with a neutral caption", async () => {
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.delivery.deliver({ mediaUrl: "/tmp/generated.png" });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame(["attachments-v1"]);
    const sink = testSink();
    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
      loadMedia: async () => ({
        buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
        fileName: "generated.png",
        mediaType: "image/png",
      }),
    });
    expect(sink.attachment).toHaveBeenCalledTimes(1);
    expect(sink.completed).toHaveBeenCalledWith("Created 1 file.");
  });

  it("fails closed before uploading when any delivered payload is sensitive or an upstream error", async () => {
    const deliveries = [
      [{ mediaUrl: "/tmp/ordinary.png" }, { text: "/private/secret", sensitiveMedia: true }],
      [{ text: "/private/provider-error", isError: true }],
    ];
    for (const payloads of deliveries) {
      const channel = {
        reply: {
          finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
          dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
        },
        session: { recordInboundSession: vi.fn() },
        inbound: {
          dispatchReply: vi.fn(async (params: any) => {
            for (const payload of payloads) {
              try {
                await params.delivery.deliver(payload);
              } catch {
                // The real dispatcher may contain an individual delivery
                // callback error. The turn-level failure must still prevent
                // every staged upload after dispatch returns.
              }
            }
          }),
        },
      };
      setOpenClamRuntime({ channel } as any);
      const frame = testFrame(["attachments-v1"]);
      const sink = testSink();
      await expect(dispatchOpenClamTurn({
        ctx: testContext(frame.connectionId),
        frame,
        signal: new AbortController().signal,
        sink,
        loadMedia: async () => ({
          buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
          fileName: "ordinary.png",
          mediaType: "image/png",
        }),
      })).rejects.toThrow();
      expect(sink.attachment).not.toHaveBeenCalled();
      expect(sink.completed).not.toHaveBeenCalled();
    }
  });

  it("keeps legacy clients on existing kinds and appends a fixed upgrade notice", async () => {
    const source = "/opt/openclaw-private/legacy.png";
    const channel = {
      reply: {
        finalizeInboundContext: vi.fn((value: Record<string, unknown>) => value),
        dispatchReplyWithBufferedBlockDispatcher: vi.fn(),
      },
      session: { recordInboundSession: vi.fn() },
      inbound: {
        dispatchReply: vi.fn(async (params: any) => {
          await params.delivery.deliver({ text: `Done: ${source}`, mediaUrl: source });
        }),
      },
    };
    setOpenClamRuntime({ channel } as any);
    const frame = testFrame();
    const sink = testSink();
    const loadMedia = vi.fn();
    await dispatchOpenClamTurn({
      ctx: testContext(frame.connectionId),
      frame,
      signal: new AbortController().signal,
      sink,
      loadMedia,
    });
    expect(loadMedia).not.toHaveBeenCalled();
    expect(sink.attachment).not.toHaveBeenCalled();
    expect(sink.completed.mock.calls[0]?.[0]).toContain("Done: attached file");
    expect(sink.completed.mock.calls[0]?.[0]).toContain("Update OpenClam");
    expect(sink.completed.mock.calls[0]?.[0]).not.toContain(source);
  });
});
