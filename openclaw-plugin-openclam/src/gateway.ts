import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { OpenClamBridgeClient } from "./bridge-client.js";
import type { ResolvedOpenClamAccount } from "./types.js";

const clients = new Map<string, OpenClamBridgeClient>();

export async function startOpenClamAccount(
  ctx: ChannelGatewayContext<ResolvedOpenClamAccount>,
): Promise<void> {
  const account = ctx.account;
  if (!account.enabled) return;
  if (!account.configured) {
    throw new Error(`OpenClam account "${account.accountId}" is not paired`);
  }
  let client = clients.get(account.connectionId);
  if (!client) {
    client = new OpenClamBridgeClient(
      account.connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
    );
    clients.set(account.connectionId, client);
  }
  try {
    await client.attach(ctx);
  } finally {
    if (client.accountCount === 0) clients.delete(account.connectionId);
  }
}
export function resetOpenClamClientsForTest(): void {
  for (const client of clients.values()) void client.stop();
  clients.clear();
}
