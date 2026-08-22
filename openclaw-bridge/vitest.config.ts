import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          BRIDGE_BOOTSTRAP_TOKEN:
            "test-bootstrap-token-that-is-at-least-forty-characters-long",
          PAIRING_CODE_PEPPER:
            "test-pairing-pepper-that-is-at-least-thirty-two-characters",
          TOKEN_VERIFIER_PEPPER:
            "test-token-pepper-that-is-at-least-thirty-two-characters",
          PENDING_EVENT_KEK_B64:
            "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=",
        },
      },
    }),
  ],
  test: {
    restoreMocks: true,
  },
});
