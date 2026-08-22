import { createPluginRuntimeStore } from "openclaw/plugin-sdk/runtime-store";
const store = createPluginRuntimeStore({
    pluginId: "openclam",
    errorMessage: "OpenClam runtime is not initialized",
});
export const setOpenClamRuntime = store.setRuntime;
export const getOpenClamRuntime = store.getRuntime;
