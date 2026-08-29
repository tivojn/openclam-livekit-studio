from __future__ import annotations

import asyncio
import json
import logging
import math
from collections import deque

from livekit import rtc
from livekit.agents.tts._provider_format import TranscriptMarkupStripper
from livekit.agents.types import TimedString
from livekit.agents.voice import io

LIVE_TALK_TTS_TIMING_TOPIC = "openclam.tts-timing.v1"
LIVE_TALK_TTS_TIMING_SCHEMA_VERSION = 1
LIVE_TALK_TTS_TIMING_MAX_TEXT_CHARACTERS = 512
LIVE_TALK_TTS_TIMING_MAX_PENDING_PACKETS = 4
LIVE_TALK_TTS_TIMING_PUBLISH_TIMEOUT_SECONDS = 0.2

logger = logging.getLogger("openclam-livekit-pilot")


def _finite_timestamp(value: object) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) and result >= 0 else None


class LiveTalkTTSTimingOutput(io.TextOutput):
    """Publish the audio-synchronizer's clean timed words to the foreground app.

    This output is deliberately chained *after* LiveKit's
    ``TranscriptSynchronizer``.  Providers with native alignment therefore keep
    their timing, while providers without it use LiveKit's audio-paced timing.
    It does not infer mouth shapes on the server and never publishes provider
    credentials or raw audio.
    """

    def __init__(self, room: rtc.Room) -> None:
        super().__init__(label="OpenClamTTSTiming", next_in_chain=None)
        self._room = room
        self._stripper = TranscriptMarkupStripper()
        self._generation = 1
        self._segment = 1
        self._sequence = 0
        self._generation_started = False
        self._pending_payloads: deque[tuple[str, int, str]] = deque()
        self._publisher_task: asyncio.Task[None] | None = None

    async def _publish_pending(self) -> None:
        while self._pending_payloads:
            _kind, _generation, payload = self._pending_payloads.popleft()
            try:
                await asyncio.wait_for(
                    self._room.local_participant.publish_data(
                        payload,
                        reliable=True,
                        topic=LIVE_TALK_TTS_TIMING_TOPIC,
                    ),
                    timeout=LIVE_TALK_TTS_TIMING_PUBLISH_TIMEOUT_SECONDS,
                )
            except TimeoutError:
                logger.warning("synchronized TTS timing publish timed out")
            except asyncio.CancelledError:
                raise
            except Exception:
                # Lip timing is an enhancement. A data-packet failure must never
                # interrupt or delay the authoritative audible TTS response.
                logger.warning(
                    "failed to publish synchronized TTS timing", exc_info=True
                )

    def _drop_oldest_cue(self) -> bool:
        for index, (kind, _generation, _payload) in enumerate(
            self._pending_payloads
        ):
            if kind == "cue":
                del self._pending_payloads[index]
                return True
        return False

    def _drop_oldest_complete_generation(self) -> bool:
        starts = {
            generation
            for kind, generation, _payload in self._pending_payloads
            if kind == "start"
        }
        for kind, generation, _payload in self._pending_payloads:
            if kind == "end" and generation in starts:
                self._pending_payloads = deque(
                    entry
                    for entry in self._pending_payloads
                    if entry[1] != generation
                )
                return True
        return False

    def _enqueue_payload(self, payload: dict[str, object]) -> None:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            # flush() is synchronous. If teardown happens outside the room's
            # event loop, dropping this optional marker is safer than blocking.
            return
        serialized = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        kind = str(payload.get("event") or "cue")
        generation = int(payload["generation"])
        while (
            len(self._pending_payloads)
            >= LIVE_TALK_TTS_TIMING_MAX_PENDING_PACKETS
        ):
            if self._drop_oldest_cue():
                continue
            if (
                kind in {"start", "end"}
                and self._drop_oldest_complete_generation()
            ):
                continue
            # Cues are expendable. A mandatory boundary only reaches this
            # fallback if the queue contains an in-flight generation's end and
            # no wholly queued generation that can be compacted together.
            if kind == "cue":
                return
            logger.warning("preserving TTS timing boundary beyond soft queue cap")
            break
        self._pending_payloads.append((kind, generation, serialized))
        if self._publisher_task is None or self._publisher_task.done():
            self._publisher_task = loop.create_task(self._publish_pending())

    async def wait_for_pending(self) -> None:
        """Test/teardown hook; capture_text and flush never await transport."""
        task = self._publisher_task
        if task is not None:
            await task

    def _start_generation(self) -> None:
        if self._generation_started:
            return
        self._sequence += 1
        self._enqueue_payload(
            {
                "schema_version": LIVE_TALK_TTS_TIMING_SCHEMA_VERSION,
                "generation": self._generation,
                "segment": self._segment,
                "sequence": self._sequence,
                "event": "start",
            }
        )
        self._generation_started = True

    async def capture_text(self, text: str) -> None:
        # A plain string would be an unsynchronised LLM transcript.  It must not
        # outrank the playback samples.  TranscriptSynchronizer supplies a
        # TimedString once the corresponding audio is actually being played.
        if not isinstance(text, TimedString):
            return
        end_time = _finite_timestamp(text.end_time)
        if end_time is None:
            return
        clean_text = self._stripper.push(str(text))
        if not clean_text:
            return
        clean_text = clean_text[:LIVE_TALK_TTS_TIMING_MAX_TEXT_CHARACTERS]
        self._start_generation()
        self._sequence += 1
        payload: dict[str, object] = {
            "schema_version": LIVE_TALK_TTS_TIMING_SCHEMA_VERSION,
            "generation": self._generation,
            "segment": self._segment,
            "sequence": self._sequence,
            "text": clean_text,
            "end_time": end_time,
        }
        start_time = _finite_timestamp(text.start_time)
        if start_time is not None and start_time <= end_time:
            payload["start_time"] = start_time
        self._enqueue_payload(payload)

    def flush(self) -> None:
        # Any buffered remainder here is markup/spacing without a trustworthy
        # audio timestamp, so it is intentionally not promoted to a mouth cue.
        self._stripper.flush()
        self._stripper = TranscriptMarkupStripper()
        self._start_generation()
        self._sequence += 1
        self._enqueue_payload(
            {
                "schema_version": LIVE_TALK_TTS_TIMING_SCHEMA_VERSION,
                "generation": self._generation,
                "segment": self._segment,
                "sequence": self._sequence,
                "event": "end",
            },
        )
        self._generation += 1
        self._segment += 1
        self._sequence = 0
        self._generation_started = False

    def on_detached(self) -> None:
        self._pending_payloads.clear()
        if self._publisher_task is not None and not self._publisher_task.done():
            self._publisher_task.cancel()
        self._publisher_task = None
        super().on_detached()
