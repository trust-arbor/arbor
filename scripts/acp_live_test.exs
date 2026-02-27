#!/usr/bin/env elixir
# Live integration test: AcpSession → Claude adapter → Claude CLI
# Run: MIX_ENV=test mix run scripts/acp_live_test.exs

alias Arbor.AI.AcpSession

IO.puts("=== ACP Live Integration Test (Claude) ===\n")

# Collect streaming events
{:ok, events} = Agent.start_link(fn -> [] end)

stream_cb = fn update ->
  Agent.update(events, fn list -> [update | list] end)
  kind = Map.get(update, "kind", "?")
  case kind do
    "text" ->
      text = Map.get(update, "text", "")
      IO.write(text)
    "thinking" ->
      IO.write(".")
    _ ->
      nil
  end
end

IO.puts("1. Starting AcpSession with Claude adapter...")
t0 = System.monotonic_time(:millisecond)

{:ok, session} = AcpSession.start_link(
  provider: :claude,
  stream_callback: stream_cb,
  adapter_opts: [max_thinking_tokens: 5000]
)

IO.puts("   Started in #{System.monotonic_time(:millisecond) - t0}ms")
IO.puts("   Status: #{inspect(AcpSession.status(session))}")

# Wait for the transport + initialize handshake
IO.puts("   Waiting for initialize handshake...")
Process.sleep(5_000)
IO.puts("   Status: #{inspect(AcpSession.status(session))}")

IO.puts("\n2. Creating session...")
t1 = System.monotonic_time(:millisecond)

case AcpSession.create_session(session, cwd: File.cwd!()) do
  {:ok, session_info} ->
    IO.puts("   Created in #{System.monotonic_time(:millisecond) - t1}ms")
    IO.puts("   Session ID: #{Map.get(session_info, "sessionId", "N/A")}")
    IO.puts("   Keys: #{inspect(Map.keys(session_info))}")

    IO.puts("\n3. Sending prompt: 'What is 2+2? Reply with just the number.'\n")
    t2 = System.monotonic_time(:millisecond)
    IO.write("   Response: ")

    case AcpSession.send_message(session, "What is 2+2? Reply with just the number.", timeout: 120_000) do
      {:ok, result} ->
        IO.puts("")
        IO.puts("   Duration: #{System.monotonic_time(:millisecond) - t2}ms")
        IO.puts("   Stop reason: #{inspect(Map.get(result, "stopReason"))}")
        IO.puts("   Result keys: #{inspect(Map.keys(result))}")

      {:error, reason} ->
        IO.puts("\n   ERROR: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("   ERROR creating session: #{inspect(reason)}")
end

# Event summary
event_list = Agent.get(events, & &1) |> Enum.reverse()
IO.puts("\n4. Events received: #{length(event_list)}")

kinds = event_list |> Enum.map(&Map.get(&1, "kind", "unknown")) |> Enum.frequencies()
for {kind, count} <- Enum.sort(kinds) do
  IO.puts("   #{kind}: #{count}")
end

# Cleanup
IO.puts("\n5. Closing...")
AcpSession.close(session)
Agent.stop(events)
IO.puts("=== Done ===")
