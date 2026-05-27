#!/usr/bin/env python3
"""
One-turn test with xAI Realtime API (text + audio transcript).

Usage:
    python test_xai_realtime_text.py "Your message here"
"""

import os
import sys
import asyncio
import json

try:
    import websockets
except ImportError:
    os.system(f"{sys.executable} -m pip install websockets -q")
    import websockets


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


async def run_one_turn(user_message: str = None):
    creds = get_xai_credentials()
    if not creds:
        print("ERROR: No xAI credentials found.")
        return

    print(f"Using: {creds['source']}")
    url = "wss://api.x.ai/v1/realtime"
    headers = {"Authorization": f"Bearer {creds['api_key']}"}

    async with websockets.connect(url, additional_headers=headers, ping_interval=20) as ws:
        # Configure session
        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "modalities": ["text", "audio"],
                "instructions": "You are a helpful, concise assistant.",
                "voice": "eve",
            }
        }))

        # Message
        if not user_message and len(sys.argv) > 1:
            user_message = " ".join(sys.argv[1:])
        if not user_message:
            user_message = input("You: ").strip()
        if not user_message:
            return

        print(f"You: {user_message}\n")

        await ws.send(json.dumps({
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": user_message}]
            }
        }))
        await ws.send(json.dumps({"type": "response.create"}))

        print("Grok: ", end="", flush=True)
        transcript = ""

        while True:
            event = json.loads(await ws.recv())
            etype = event.get("type")

            if etype == "response.output_audio_transcript.delta":
                delta = event.get("delta", "")
                print(delta, end="", flush=True)
                transcript += delta

            elif etype == "response.output_audio_transcript.done":
                print("\n")
                break

            elif etype == "response.done":
                print("\n")
                break

            elif etype == "error":
                print(f"\n[Error] {event}")
                break

        print(f"[One turn complete]")
        return transcript


if __name__ == "__main__":
    asyncio.run(run_one_turn())