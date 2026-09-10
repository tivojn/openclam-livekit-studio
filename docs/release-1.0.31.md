# OpenClam Studio 1.0.31

Live Talk gains a second engine, **OpenAI GPT-Live-1**, selectable in
Settings → AI & Voice → Continuous Live Talk → Live Talk engine before a call.
One full-duplex model listens and speaks for the whole call with the OpenAI key
stored in the Mac Keychain, answers while the user is still talking, and
delegates actions to the same foreground OpenClaw route. Thirteen OpenAI
voices are available; Marin is the default. The existing LiveKit pipeline
engine remains the default and every previous choice stays available.

While GPT-Live-1 is selected the Listening and Voice stages are not used but
keep their saved choices. Email drafts are unavailable in that engine, lip-sync
follows the audio, and OpenAI bills the voice session per minute plus backend
model usage.

Server rollout: the LiveKit agent moves to LiveKit Agents 1.8.1 with Silero VAD
and the credential broker catalog gains the GPT-Live-1 rows. Existing pipeline
clients remain compatible. See [details](gpt-live-1-live-talk.md).
