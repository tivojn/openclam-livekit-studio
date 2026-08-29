import asyncio
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from livekit.agents.types import TimedString

from openclam_livekit_agent.main import live_talk_room_options
from openclam_livekit_agent.tts_timing import (
    LIVE_TALK_TTS_TIMING_TOPIC,
    LiveTalkTTSTimingOutput,
)


def _room() -> tuple[object, AsyncMock]:
    publish_data = AsyncMock()
    room = SimpleNamespace(
        local_participant=SimpleNamespace(publish_data=publish_data)
    )
    return room, publish_data


def test_live_talk_room_output_exposes_audio_synchronized_timed_text() -> None:
    room, _publish_data = _room()
    options = live_talk_room_options(room)
    text_output = options.get_text_output_options()

    assert text_output is not None
    assert text_output.sync_transcription is True
    assert text_output.json_format is False
    assert isinstance(text_output.next_in_chain, LiveTalkTTSTimingOutput)


@pytest.mark.asyncio
async def test_only_timed_playback_text_is_published() -> None:
    room, publish_data = _room()
    output = LiveTalkTTSTimingOutput(room)

    await output.capture_text("unsynchronised LLM text")
    publish_data.assert_not_awaited()

    await output.capture_text(
        TimedString("Hello ", start_time=0.12, end_time=0.38)
    )
    await output.wait_for_pending()
    assert publish_data.await_count == 2
    start, payload = [
        json.loads(call.args[0]) for call in publish_data.await_args_list
    ]
    assert start == {
        "schema_version": 1,
        "generation": 1,
        "segment": 1,
        "sequence": 1,
        "event": "start",
    }
    assert payload == {
        "schema_version": 1,
        "generation": 1,
        "segment": 1,
        "sequence": 2,
        "text": "Hello",
        "start_time": 0.12,
        "end_time": 0.38,
    }
    assert publish_data.await_args.kwargs == {
        "reliable": True,
        "topic": LIVE_TALK_TTS_TIMING_TOPIC,
    }


@pytest.mark.asyncio
async def test_expressive_markup_never_becomes_a_mouth_cue() -> None:
    room, publish_data = _room()
    output = LiveTalkTTSTimingOutput(room)

    await output.capture_text(
        TimedString('<expr type="expression" ', end_time=0.1)
    )
    publish_data.assert_not_awaited()
    await output.capture_text(TimedString('label="happy"/>Hello ', end_time=0.2))
    await output.wait_for_pending()

    payload = json.loads(publish_data.await_args_list[-1].args[0])
    assert payload["text"] == "Hello"
    assert "expr" not in payload["text"]


@pytest.mark.asyncio
async def test_flush_starts_a_fresh_timing_segment() -> None:
    room, publish_data = _room()
    output = LiveTalkTTSTimingOutput(room)

    await output.capture_text(TimedString("First ", end_time=0.2))
    await output.wait_for_pending()
    output.flush()
    await output.wait_for_pending()
    await output.capture_text(TimedString("Second ", end_time=0.1))
    await output.wait_for_pending()

    first_start, first, end, second_start, second = [
        json.loads(call.args[0]) for call in publish_data.await_args_list
    ]
    assert first_start["event"] == "start"
    assert (first["generation"], first["segment"], first["sequence"]) == (1, 1, 2)
    assert end == {
        "schema_version": 1,
        "generation": 1,
        "segment": 1,
        "sequence": 3,
        "event": "end",
    }
    assert second_start["event"] == "start"
    assert (second["generation"], second["segment"], second["sequence"]) == (2, 2, 2)


@pytest.mark.asyncio
async def test_immediate_flush_preserves_cue_before_end_marker() -> None:
    room, publish_data = _room()
    output = LiveTalkTTSTimingOutput(room)

    await output.capture_text(TimedString("Now ", start_time=0.1, end_time=0.3))
    output.flush()
    await output.wait_for_pending()

    packets = [json.loads(call.args[0]) for call in publish_data.await_args_list]
    assert [packet.get("event", "cue") for packet in packets] == ["start", "cue", "end"]
    assert [(packet["generation"], packet["segment"], packet["sequence"]) for packet in packets] == [
        (1, 1, 1),
        (1, 1, 2),
        (1, 1, 3),
    ]


@pytest.mark.asyncio
async def test_burst_compacts_only_cues_and_preserves_lifecycle() -> None:
    room, publish_data = _room()
    output = LiveTalkTTSTimingOutput(room)

    for index in range(6):
        await output.capture_text(
            TimedString(f"word-{index} ", end_time=(index + 1) / 10)
        )
    output.flush()
    await output.wait_for_pending()

    packets = [json.loads(call.args[0]) for call in publish_data.await_args_list]
    assert [packet.get("event", "cue") for packet in packets] == [
        "start",
        "cue",
        "cue",
        "end",
    ]
    assert all(packet["generation"] == 1 for packet in packets)
    assert all(packet["segment"] == 1 for packet in packets)
    assert [packet["sequence"] for packet in packets] == [1, 6, 7, 8]


@pytest.mark.asyncio
async def test_timing_transport_failure_never_interrupts_tts() -> None:
    room, publish_data = _room()
    publish_data.side_effect = RuntimeError("room disconnected")
    output = LiveTalkTTSTimingOutput(room)

    await output.capture_text(TimedString("Still audible ", end_time=0.3))
    await output.wait_for_pending()
    assert publish_data.await_count == 2


@pytest.mark.asyncio
async def test_capture_and_flush_never_wait_for_congested_data_channel() -> None:
    room, publish_data = _room()
    blocked = asyncio.Event()

    async def congested_publish(*_args: object, **_kwargs: object) -> None:
        await blocked.wait()

    publish_data.side_effect = congested_publish
    output = LiveTalkTTSTimingOutput(room)

    await asyncio.wait_for(
        output.capture_text(TimedString("Audible now ", end_time=0.3)),
        timeout=0.01,
    )
    output.flush()
    await asyncio.wait_for(output.wait_for_pending(), timeout=0.8)

    # The reliable timing transport may time out or lose the end marker, but it
    # can never hold up TTS capture/flush or audible playback teardown.
    assert publish_data.await_count >= 1


@pytest.mark.asyncio
async def test_slow_reliable_publish_is_resilient_but_never_blocks_audio() -> None:
    room, publish_data = _room()

    async def slow_publish(*_args: object, **_kwargs: object) -> None:
        await asyncio.sleep(0.12)

    publish_data.side_effect = slow_publish
    output = LiveTalkTTSTimingOutput(room)

    await asyncio.wait_for(
        output.capture_text(TimedString("Audible immediately ", end_time=0.3)),
        timeout=0.02,
    )
    output.flush()
    await asyncio.wait_for(output.wait_for_pending(), timeout=0.8)

    assert publish_data.await_count == 3
