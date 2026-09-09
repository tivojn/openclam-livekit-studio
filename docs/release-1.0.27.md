# OpenClam Studio 1.0.27 / iOS 1.0.6 (77)

Live Talk adds **Connected OpenClaw** as a conversation source on Mac and iPhone.
Every spoken turn uses the agent selected in the chat, with its existing model,
conversation and tools. The agent's reply drives Tia's motions and is spoken by
the selected Live Talk voice. Listening and speaking services remain independent.

Select Connected OpenClaw in Continuous Live Talk settings, select an OpenClaw
agent in the chat, and start the call. Existing Live Talk choices remain available.
The app checks the connection before starting and keeps the chosen agent for the
call. The implementation preserves interruption, transcript and duplicate-reply
guards and does not send OpenClaw credentials to the voice broker.

Validation covers agent/broker contracts, Mac conversation routing and call
ownership, 73 iOS Live Talk simulator tests, and a deployed synthetic-speech call
with a context-dependent follow-up. See [routing and validation details](connected-openclaw-live-talk.md).
OpenClaw model/tool latency determines how quickly speech begins.

This update does not change Tia's model, hair, appearance assets or motion files.
Public source and the public Mac DMG continue to exclude proprietary Tia assets.

Paused speech fragments remain one complete request. Transcript validation uses
conversation boundaries instead of a 1.2-second packet gap, fixing rejected
requests such as “Can you do a … kung fu punch?” Rapid follow-ups begin after
an explicitly claimed request, even before its assistant audio starts.
