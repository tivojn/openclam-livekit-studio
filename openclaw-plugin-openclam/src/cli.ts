import type { OpenClawPluginApi } from "openclaw/plugin-sdk/channel-core";
import { getOpenClamConfig, listOpenClamAccountIds, resolveOpenClamAccount } from "./config.js";
import {
  pairOpenClam,
  replaceOpenClamDevicePairing,
  type PairOpenClamOptions,
} from "./pairing.js";

type CliRegistrar = Parameters<OpenClawPluginApi["registerCli"]>[0];

function collect(value: string, previous: string[]): string[] {
  return [...previous, value];
}

export const registerOpenClamCli: CliRegistrar = ({ program, config }) => {
  const root = program.command("openclam").description("Pair and inspect the OpenClam channel");
  root
    .command("pair")
    .description("Create a one-time pairing code for OpenClam iOS")
    .requiredOption("--bridge-url <url>", "HTTPS URL of the independent OpenClam bridge")
    .option("--gateway-label <label>", "Name shown to the iPhone")
    .option("--agent <agent-id>", "Advertise an agent using the same account ID", collect, [])
    .option("--map <account-id=agent-id>", "Advertise an account ID mapped to an agent", collect, [])
    .option("--default-account <account-id>", "Default avatar account")
    .option(
      "--bootstrap-secret-env <name>",
      "Environment variable holding the bridge bootstrap token",
      "OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN",
    )
    .option("--credential-directory <path>", "Parent directory for the new connection credential")
    .option("--replace", "Switch to a fresh connection and then revoke the old one", false)
    .option("--json", "Print machine-readable pairing details", false)
    .option("--allow-insecure-localhost", "Allow HTTP only for a localhost development bridge", false)
    .action(async (raw: Record<string, unknown>) => {
      const options: PairOpenClamOptions = {
        bridgeUrl: String(raw.bridgeUrl),
        gatewayLabel: typeof raw.gatewayLabel === "string" ? raw.gatewayLabel : undefined,
        agents: Array.isArray(raw.agent) ? raw.agent.map(String) : [],
        mappings: Array.isArray(raw.map) ? raw.map.map(String) : [],
        defaultAccount: typeof raw.defaultAccount === "string" ? raw.defaultAccount : undefined,
        bootstrapSecretEnv:
          typeof raw.bootstrapSecretEnv === "string" ? raw.bootstrapSecretEnv : undefined,
        credentialDirectory:
          typeof raw.credentialDirectory === "string" ? raw.credentialDirectory : undefined,
        replace: raw.replace === true,
        allowInsecureLocalhost: raw.allowInsecureLocalhost === true,
      };
      const result = await pairOpenClam(config, options);
      if (raw.json === true) {
        process.stdout.write(`${JSON.stringify({
          v: 1,
          code: result.code,
          connectionId: result.connectionId,
          expiresAt: result.expiresAt,
          gatewayLabel: result.gatewayLabel,
          accounts: result.accounts,
        })}\n`);
        return;
      }
      process.stdout.write(`Pairing code: ${result.code}\n`);
      process.stdout.write(`Expires: ${new Date(result.expiresAt).toISOString()}\n`);
      process.stdout.write(`Agents: ${result.accounts.map((account) => account.displayName).join(", ")}\n`);
      process.stdout.write("Enter this code in OpenClam on the iPhone.\n");
    });

  root
    .command("pair-device")
    .description("Create a fresh iPhone code from the existing OpenClam connection")
    .option("--json", "Print machine-readable pairing details", false)
    .option("--credential-directory <path>", "Parent directory for the new connection credential")
    .option("--allow-insecure-localhost", "Allow HTTP only for a localhost development bridge", false)
    .action(async (raw: Record<string, unknown>) => {
      const result = await replaceOpenClamDevicePairing(config, {
        credentialDirectory:
          typeof raw.credentialDirectory === "string" ? raw.credentialDirectory : undefined,
        allowInsecureLocalhost: raw.allowInsecureLocalhost === true,
      });
      if (raw.json === true) {
        process.stdout.write(`${JSON.stringify({
          v: 1,
          code: result.code,
          connectionId: result.connectionId,
          expiresAt: result.expiresAt,
          gatewayLabel: result.gatewayLabel,
          accounts: result.accounts,
        })}\n`);
        return;
      }
      process.stdout.write(`iPhone pairing code: ${result.code}\n`);
      process.stdout.write(`Valid until: ${new Date(result.expiresAt).toLocaleString()}\n`);
      process.stdout.write("Enter it in OpenClam on iPhone. This code replaces the previous iPhone pairing.\n");
    });

  root
    .command("status")
    .description("Show OpenClam pairing state without secrets")
    .action(() => {
      const section = getOpenClamConfig(config);
      const accounts = listOpenClamAccountIds(config).map((accountId) => {
        const account = resolveOpenClamAccount(config, accountId);
        return {
          accountId,
          agentId: account.agentId,
          displayName: account.displayName,
          enabled: account.enabled,
          configured: account.configured,
        };
      });
      process.stdout.write(
        `${JSON.stringify(
          {
            paired: Boolean(section.connectionId),
            gatewayLabel: section.gatewayLabel,
            connectionId: section.connectionId,
            bridgeUrl: section.bridgeUrl,
            accounts,
          },
          null,
          2,
        )}\n`,
      );
    });
};
