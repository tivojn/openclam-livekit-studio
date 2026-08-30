import { OpenClamBridgeClient } from "./bridge-client.js";
const clients = new Map();
export function findOpenClamClient(connectionId) {
    return clients.get(connectionId.toLowerCase());
}
export async function startOpenClamAccount(ctx) {
    const account = ctx.account;
    if (!account.enabled)
        return;
    if (!account.configured) {
        throw new Error(`OpenClam account "${account.accountId}" is not paired`);
    }
    const connectionId = account.connectionId.toLowerCase();
    let client = clients.get(connectionId);
    if (!client) {
        client = new OpenClamBridgeClient(account.connectionId, account.bridgeUrl, account.adapterTokenFile, account.stateFile);
        clients.set(connectionId, client);
    }
    try {
        await client.attach(ctx);
    }
    finally {
        if (client.accountCount === 0)
            clients.delete(connectionId);
    }
}
export function resetOpenClamClientsForTest() {
    for (const client of clients.values())
        void client.stop();
    clients.clear();
}
