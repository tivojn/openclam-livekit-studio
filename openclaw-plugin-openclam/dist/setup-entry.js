import { defineSetupPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { openClamSetupPlugin } from "./src/channel.setup.js";
export default defineSetupPluginEntry(openClamSetupPlugin);
