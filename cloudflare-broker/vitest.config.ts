import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          OPENCLAM_BROKER_AGENT_TOKEN: "test-agent-broker-secret-that-is-long-enough",
          AUTH_MODE: "pilot",
          BYOK_KEK_B64: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
          BYOK_LEASE_TTL_SECONDS: "120",
          CORS_ORIGIN: "https://app.openclam.test",
          LIVEKIT_AGENT_NAME: "openclam-livekit-pilot",
          LIVEKIT_API_KEY: "test-livekit-api-key",
          LIVEKIT_API_SECRET: "test-livekit-api-secret-test-livekit-api-secret",
          LIVEKIT_TOKEN_TTL_SECONDS: "600",
          LIVEKIT_URL: "wss://test.livekit.cloud",
          PILOT_APP_TOKEN_NEXT: "test-next-pilot-token-that-is-long-enough",
          PILOT_APP_TOKEN: "test-pilot-app-token-that-is-long-enough",
        },
      },
    }),
  ],
  test: {
    restoreMocks: true,
  },
});
