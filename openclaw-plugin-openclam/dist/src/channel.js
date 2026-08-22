import { createOpenClamChannelBase } from "./channel-base.js";
import { startOpenClamAccount } from "./gateway.js";
export const openClamPlugin = {
    ...createOpenClamChannelBase(),
    gateway: {
        startAccount: startOpenClamAccount,
    },
};
