import { createOpenClamChannelBase } from "./channel-base.js";
import { startOpenClamAccount } from "./gateway.js";
import { openClamOutbound } from "./outbound.js";
export const openClamPlugin = {
    ...createOpenClamChannelBase(),
    outbound: openClamOutbound,
    gateway: {
        startAccount: startOpenClamAccount,
    },
};
