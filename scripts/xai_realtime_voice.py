#!/usr/bin/env python3
"""
Improved one-turn voice conversation with xAI Realtime API.

Fixes:
- Proper audio buffer handling
- Separate input (16kHz) and output (24kHz) sample rates
- Buffered playback for clean audio

Usage:
    python test_xai_realtime_voice.py
"""

import os
import sys
import asyncio
import json
import queue
import base64

import numpy as np
import sounddevice as sd

try:
    import websockets
except ImportError:
    os.system(f"{sys.executable} -m pip install websockets -q")
    import websockets


# Input (mic) settings - good for speech recognition
INPUT_SAMPLE_RATE = 16000
# Output (playback) settings - xAI voices usually sound best at 24kHz
OUTPUT_SAMPLE_RATE = 24000

CHANNELS = 1
DTYPE = 'int16'
BLOCK_SIZE = 3200
RECORD_SECONDS = 6


def get_xai_credentials():
    try:
        from hermes_cli.auth import resolve_xai_oauth_runtime_credentials
        result = resolve_xai_oauth_runtime_credentials()
        if result and result.get("api_key"):
            return {"api_key": result["api_key"], "source": "xai-oauth"}
    except Exception:
        pass

    api_key = os.getenv("XAI_API_KEY")
    if api_key:
        return {"api_key": api_key.strip(), "source": "env"}
    return None


class AudioRecorder:
    def __init__(self):
        self.q = queue.Queue()
        self.recording = False
        self.stream = None

    def callback(self, indata, frames, time, status):
        if self.recording:
            self.q.put(indata.copy())

    def start(self):
        self.recording = True
        self.stream = sd.InputStream(
            samplerate=INPUT_SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCK_SIZE,
            callback=self.callback
        )
        self.stream.start()
        print(f"🎙️  Recording for {RECORD_SECONDS} seconds...")

    def stop(self):
        self.recording = False
        if self.stream:
            self.stream.stop()
            self.stream.close()
        print("⏹️  Recording stopped.")

    def get_audio(self):
        chunks = []
        while not self.q.empty():
            chunks.append(self.q.get())
        if chunks:
            return np.concatenate(chunks)
        return np.array([], dtype=DTYPE)


async def run_voice_conversation():
    creds = get_xai_credentials()
    if not creds:
        print("ERROR: No xAI credentials found.")
        return

    print(f"Using credentials from: {creds['source']}")
    url = "wss://api.x.ai/v1/realtime"
    headers = {"Authorization": f"Bearer {creds['api_key']}"}

    async with websockets.connect(url, additional_headers=headers, ping_interval=20) as ws:
        # Configure session
        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "modalities": ["audio", "text"],
                "instructions": "You are a helpful voice assistant. Keep responses short and natural.",
                "voice": "ara",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "turn_detection": None,
            }
        }))

        await ws.send(json.dumps({"type": "input_audio_buffer.clear"}))

        # Record
        recorder = AudioRecorder()
        recorder.start()
        await asyncio.sleep(RECORD_SECONDS)
        recorder.stop()

        audio_data = recorder.get_audio()
        if len(audio_data) == 0:
            print("No audio recorded.")
            return

        print(f"Sent {len(audio_data)} samples of audio.")

        # Send audio
        audio_b64 = base64.b64encode(audio_data.tobytes()).decode()
        await ws.send(json.dumps({
            "type": "input_audio_buffer.append",
            "audio": audio_b64
        }))
        await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
        await ws.send(json.dumps({"type": "response.create"}))

        print("\n🔊 Receiving response...\n")

        audio_chunks = []
        transcript = ""

        while True:
            event = json.loads(await ws.recv())
            etype = event.get("type")

            if etype == "response.output_audio.delta":
                chunk = base64.b64decode(event["delta"])
                audio_chunks.append(chunk)

            elif etype == "response.output_audio_transcript.delta":
                transcript += event.get("delta", "")

            elif etype == "response.output_audio_transcript.done":
                if transcript:
                    print(f"Transcript: {transcript}")

            elif etype == "response.done":
                break

            elif etype == "error":
                print(f"\n[Error] {event}")
                break

        # Play the full response at the correct sample rate (24kHz)
        if audio_chunks:
            full_audio = b"".join(audio_chunks)
            audio_array = np.frombuffer(full_audio, dtype=np.int16)
            print(f"Playing {len(audio_array)} samples at {OUTPUT_SAMPLE_RATE}Hz...")
            sd.play(audio_array, OUTPUT_SAMPLE_RATE)
            sd.wait()

        print("\n[One-turn voice conversation complete]")


if __name__ == "__main__":
    asyncio.run(run_voice_conversation())