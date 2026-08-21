import type { ProfileCatalog } from "./types";

// This catalog is intentionally closed. Adding a model is a reviewed server
// change, not a value the phone can smuggle into agent plugin constructors.
export const PROFILE_CATALOG = {
  llm: {
    managed: {
      livekit: {
        "google/gemma-4-31b-it": {},
      },
    },
    byok: {
      anthropic: {
        "claude-haiku-4-5": {},
        "claude-sonnet-4-6": {},
      },
      gemini: {
        "gemini-3.6-flash": {},
        "gemini-3.5-flash": {},
        "gemini-3.5-flash-lite": {},
      },
      openai: {
        "gpt-5.4-mini": {},
        "gpt-5.6-luna": {},
        "gpt-5.6-terra": {},
        "gpt-5.6-sol": {},
      },
      xai: {
        "grok-4.3": {},
        "grok-4.5": {},
      },
    },
  },
  stt: {
    managed: {
      livekit: {
        "deepgram/nova-3": {
          default_language: "multi",
          languages: ["multi", "en", "zh"],
        },
      },
    },
    byok: {
      deepgram: {
        "nova-3": {
          default_language: "multi",
          languages: ["multi", "en", "zh"],
        },
      },
      elevenlabs: {
        "scribe_v2_realtime": {
          default_language: "multi",
          languages: ["multi", "en", "zh"],
        },
      },
      openai: {
        "gpt-4o-transcribe": {
          default_language: "en",
          languages: ["en", "zh"],
        },
        "gpt-4o-mini-transcribe": {
          default_language: "en",
          languages: ["en", "zh"],
        },
        "whisper-1": {
          default_language: "en",
          languages: ["en", "zh"],
        },
      },
      xai: {
        "grok-transcribe": {
          // Required by the pinned plugin as an inverse-text-formatting hint.
          // Recognition is automatic only within xAI's documented 25-language
          // set and excludes Chinese; auto/multi/zh are deliberately not tuples.
          default_language: "en",
          languages: ["en"],
        },
      },
    },
  },
  tts: {
    managed: {
      livekit: {
        "fishaudio/s2.1-pro": {
          default_voice: "933563129e564b19a115bedd57b7406a",
          voices: [
            "bf322df2096a46f18c579d0baa36f41d",
            "536d3a5e000945adb7038665781a4aca",
            "9a9cf47702da476aa4629e2506d4a857",
            "79d0bd3e4e5444b18f7b6d89b5927bf1",
            "e3cd384158934cc9a01029cd7d278634",
            "933563129e564b19a115bedd57b7406a",
            "b347db033a6549378b48d00acb0d06cd",
          ],
        },
      },
    },
    byok: {
      deepgram: {
        "aura-2-andromeda-en": {
          default_voice: "aura-2-andromeda-en",
          voices: ["aura-2-andromeda-en"],
        },
      },
      elevenlabs: {
        "eleven_flash_v2_5": {
          default_voice: "EXAVITQu4vr4xnSDxMaL",
          voices: ["EXAVITQu4vr4xnSDxMaL", "JBFqnCBsd6RMkjVDRZzb"],
        },
        "eleven_multilingual_v2": {
          default_voice: "JBFqnCBsd6RMkjVDRZzb",
          voices: ["JBFqnCBsd6RMkjVDRZzb"],
        },
      },
      gemini: {
        "gemini-3.1-flash-tts-preview": {
          default_voice: "Sadachbia",
          voices: ["Sadachbia", "Kore"],
        },
      },
      openai: {
        "gpt-4o-mini-tts": {
          default_voice: "alloy",
          voices: ["alloy"],
        },
        "tts-1": {
          default_voice: "alloy",
          voices: ["alloy"],
        },
        "tts-1-hd": {
          default_voice: "alloy",
          voices: ["alloy"],
        },
      },
      xai: {
        "xai-tts": {
          default_voice: "ara",
          voices: ["ara", "eve", "leo", "rex", "sal"],
          // xAI's reviewed voices are multilingual. Provider-side detection
          // preserves the language of each generated reply.
          default_language: "auto",
          languages: ["auto"],
        },
      },
    },
  },
} as const satisfies ProfileCatalog;
