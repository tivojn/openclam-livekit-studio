import type { ChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import { createOpenClamChannelBase } from "./channel-base.js";
import type { ResolvedOpenClamAccount } from "./types.js";

export const openClamSetupPlugin: ChannelPlugin<ResolvedOpenClamAccount> =
  createOpenClamChannelBase();
