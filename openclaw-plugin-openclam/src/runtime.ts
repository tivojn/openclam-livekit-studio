import type { PluginRuntime } from "openclaw/plugin-sdk/channel-core";
import { createPluginRuntimeStore } from "openclaw/plugin-sdk/runtime-store";

const store = createPluginRuntimeStore<PluginRuntime>({
  pluginId: "openclam",
  errorMessage: "OpenClam runtime is not initialized",
});

export const setOpenClamRuntime = store.setRuntime;
export const getOpenClamRuntime = store.getRuntime;
