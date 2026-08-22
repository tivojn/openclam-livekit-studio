import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { openClamPlugin } from "./src/channel.js";
import { registerOpenClamCli } from "./src/cli.js";
import { setOpenClamRuntime } from "./src/runtime.js";

export default defineChannelPluginEntry({
  id: "openclam",
  name: "OpenClam",
  description: "First-class OpenClam channel adapter for OpenClaw",
  plugin: openClamPlugin,
  setRuntime: setOpenClamRuntime,
  registerCliMetadata(api) {
    api.registerCli(registerOpenClamCli, {
      descriptors: [
        {
          name: "openclam",
          description: "Pair and inspect the OpenClam channel",
          hasSubcommands: true,
        },
      ],
    });
  },
});
