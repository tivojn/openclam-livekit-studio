import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { OpenClamBridgeClient } from "./bridge-client.js";
import type { ResolvedOpenClamAccount } from "./types.js";

const clients = new Map<string, OpenClamBridgeClient>();

export function findOpenClamClient(connectionId: string): OpenClamBridgeClient | undefined {
  return clients.get(connectionId.toLowerCase());
}

export async function startOpenClamAccount(
  ctx: ChannelGatewayContext<ResolvedOpenClamAccount>,
): Promise<void> {
  const account = ctx.account;
  if (!account.enabled) return;
  if (!account.configured) {
    throw new Error(`OpenClam account "${account.accountId}" is not paired`);
  }
  const connectionId = account.connectionId.toLowerCase();
  let client = clients.get(connectionId);
  if (!client) {
    client = new OpenClamBridgeClient(
      account.connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
    );
    clients.set(connectionId, client);
  }
  try {
    await client.attach(ctx);
  } finally {
    if (client.accountCount === 0) clients.delete(connectionId);
  }
}
export function resetOpenClamClientsForTest(): void {
  for (const client of clients.values()) void client.stop();
  clients.clear();
}
