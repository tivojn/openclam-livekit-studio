import type { ChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import { createOpenClamChannelBase } from "./channel-base.js";
import { startOpenClamAccount } from "./gateway.js";
import type { ResolvedOpenClamAccount } from "./types.js";

export const openClamPlugin: ChannelPlugin<ResolvedOpenClamAccount> = {
  ...createOpenClamChannelBase(),
  gateway: {
    startAccount: startOpenClamAccount,
  },
};
