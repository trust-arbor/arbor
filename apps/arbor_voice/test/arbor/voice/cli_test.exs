defmodule Arbor.Voice.CLITest do
  use ExUnit.Case, async: true
  alias Arbor.Voice.CLI
  alias Arbor.Voice.CLI.Transport, as: RealTransport
  @moduletag :fast

  defmodule Transport do
    def authenticate(key, target) do
      record({:authenticate, key, target})
      {:ok, "human_operator", "signed-request-private-sentinel"}
    end

    def connect do
      record(:connect)
      Process.get(:cli_connection, {:ok, :"server@127.0.0.1", :"cli@127.0.0.1"})
    end

    def call(server, module, function, args) do
      record({:call, server, module, function, args})
      Process.get(:cli_call).(function, args)
    end

    def now, do: Process.get(:cli_time, 0)
    def wait(ms), do: Process.put(:cli_time, now() + ms)

    def emit(text) do
      record({:output, text})
      :ok
    end

    def record(event), do: Process.put(:cli_events, [event | Process.get(:cli_events, [])])
  end

  test "strict arguments reject alternate identity, token, file audio and duplicate opts before effects" do
    for args <- [
          ["talk", "agent_a", "--user", "human_other"],
          ["talk", "agent_a", "--session-token", "secret"],
          ["talk", "agent_a", "--audio", "/tmp/audio"],
          ["talk", "agent_a", "--seconds", "1", "--seconds", "2"],
          ["talk", "agent_a", "--seconds", "0"],
          ["talk", "agent_a", "--seconds", "11"],
          ["talk", "agent_a", "--input", "-1"],
          ["talk", "agent_a", "--output", "65536"],
          ["talk", "agent_bad/path"],
          ["permission", "--request", "--request"]
        ] do
      assert {:error, :invalid_arguments} = CLI.run(args, Transport)
    end

    assert Process.get(:cli_events, []) == []
  end

  test "loopback keeps audio on server and signs the existing principal" do
    Process.put(:cli_call, fn
      :start_desk_turn, ["human_operator", "agent_a", opts] ->
        assert opts[:mode] == :loopback
        assert opts[:duration_ms] == 3_000
        assert opts[:input_device] == 7
        assert opts[:output_device] == :default
        assert opts[:signed_request] == "signed-request-private-sentinel"
        refute Keyword.has_key?(opts, :session_token)
        {:ok, "operation_a"}

      :desk_turn_status, ["operation_a"] ->
        {:ok,
         %{
           terminal: true,
           state: :complete,
           error: nil,
           result: %{capture_frames: 48_000, capture_duration_ms: 3_000, disposition: :played}
         }}
    end)

    assert :ok = CLI.run(["talk", "agent_a", "--loopback", "--input", "7"], Transport)
    output = outputs()
    assert output =~ "Loopback complete"
    refute output =~ "private-sentinel"
    refute Enum.any?(events(), &match?({:call, _, _, :cancel_desk_turn, _}, &1))
  end

  test "status polling renews lease through cleanup pending and prints bounded transcript after closure" do
    Process.put(:cli_call, fn
      :start_desk_turn, _ ->
        {:ok, "operation_a"}

      :desk_turn_status, _ ->
        case Transport.now() do
          0 ->
            {:ok, %{terminal: false, state: :capture}}

          250 ->
            {:ok, %{terminal: false, state: :cleanup_pending}}

          500 ->
            {:ok,
             %{
               terminal: true,
               state: :complete,
               error: nil,
               result: %{
                 input_transcript: "hello",
                 reply: "world\e[31m",
                 disposition: :screen_only
               }
             }}
        end
    end)

    assert :ok = CLI.run(["talk", "agent_a"], Transport)
    assert outputs() =~ "Recording"
    assert outputs() =~ "Waiting for audio cleanup"
    assert outputs() =~ "You: hello"
    refute outputs() =~ "\e"
    assert Transport.now() == 500
  end

  test "caller transport failure cancels exact operation without exposing private error" do
    Process.put(:cli_call, fn
      :start_desk_turn, _ -> {:ok, "operation_a"}
      :desk_turn_status, _ -> raise "private-provider-payload"
      :cancel_desk_turn, ["operation_a"] -> {:error, :cleanup_pending}
    end)

    assert {:error, :connection_failed} = CLI.run(["talk", "agent_a"], Transport)

    assert Enum.any?(
             events(),
             &match?({:call, _, Arbor.Voice, :cancel_desk_turn, ["operation_a"]}, &1)
           )

    refute outputs() =~ "private-provider-payload"
  end

  test "security regression: terminal authorization denial overrides a completed reply" do
    Process.put(:cli_call, fn
      :start_desk_turn, _ ->
        {:ok, "operation_a"}

      :desk_turn_status, _ ->
        {:ok,
         %{
           terminal: true,
           state: :complete,
           error: :conversation_unauthorized,
           result: %{
             input_transcript: "private input",
             reply: "private reply",
             disposition: :played
           }
         }}

      :cancel_desk_turn, _ ->
        :ok
    end)

    assert {:error, :conversation_unauthorized} = CLI.run(["talk", "agent_a"], Transport)
    refute outputs() =~ "private"
    refute outputs() =~ "complete"
  end

  test "fixed deadline cancels even if remote status never becomes terminal" do
    Process.put(:cli_call, fn
      :start_desk_turn, _ -> {:ok, "operation_a"}
      :desk_turn_status, _ -> {:ok, %{terminal: false, state: :cleanup_pending}}
      :cancel_desk_turn, _ -> :ok
    end)

    assert {:error, :deadline_exceeded} = CLI.run(["talk", "agent_a"], Transport)
    assert Transport.now() == 65_000
    assert Enum.any?(events(), &match?({:call, _, _, :cancel_desk_turn, ["operation_a"]}, &1))
  end

  test "different host cannot trigger device or permission operations" do
    Process.put(:cli_connection, {:ok, :server@remote, :cli@local})

    for command <- [["devices"], ["permission", "--request"], ["talk", "agent_a"]] do
      assert {:error, _} = CLI.run(command, Transport)
    end

    refute Enum.any?(events(), &match?({:call, _, _, _, _}, &1))
  end

  test "permission request is explicit and plain permission only queries" do
    Process.put(:cli_call, fn
      :microphone_permission, [] -> :not_determined
      :request_microphone_permission, [] -> :authorized
    end)

    assert :ok = CLI.run(["permission"], Transport)
    refute Enum.any?(events(), &match?({:call, _, _, :request_microphone_permission, _}, &1))
    assert :ok = CLI.run(["permission", "--request"], Transport)
    assert outputs() =~ "authorized"
  end

  test "devices use canonical facade fields and suppress terminal controls" do
    Process.put(:cli_call, fn :devices, [] ->
      {:ok,
       [
         %{
           id: 1,
           name: "Speaker\e[2J",
           max_input_channels: 0,
           max_output_channels: 2,
           default_sample_rate: 48_000
         }
       ]}
    end)

    assert :ok = CLI.run(["devices"], Transport)
    assert outputs() =~ "0 in / 2 out"
    refute outputs() =~ "\e"
  end

  test "malformed completed result fails closed and cancels without raw print" do
    Process.put(:cli_call, fn
      :start_desk_turn, _ ->
        {:ok, "operation_a"}

      :desk_turn_status, _ ->
        {:ok, %{terminal: true, state: :complete, error: nil, result: %{pcm: "private-pcm"}}}

      :cancel_desk_turn, _ ->
        :ok
    end)

    assert {:error, :invalid_result} = CLI.run(["talk", "agent_a"], Transport)
    refute outputs() =~ "private-pcm"
  end

  test "transport signs with the real public Security key-file API without starting applications" do
    {_public, private} = :crypto.generate_key(:eddsa, :ed25519)
    path = Path.join(System.tmp_dir!(), "voice-cli-#{System.unique_integer([:positive])}.key")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, ^path} =
             Arbor.Security.write_key_file(path, %{
               agent_id: "human_cli_operator",
               private_key: private
             })

    assert {:ok, "human_cli_operator", proof} =
             RealTransport.authenticate(path, "agent_voice")

    assert proof.agent_id == "human_cli_operator"

    assert {:ok, payload} =
             Arbor.Security.conversation_session_request_payload(
               "human_cli_operator",
               "agent_voice"
             )

    assert proof.payload == payload
    assert byte_size(proof.signature) == 64
  end

  defp events, do: Process.get(:cli_events, [])
  defp outputs, do: for({:output, text} <- events(), into: "", do: text)
end
