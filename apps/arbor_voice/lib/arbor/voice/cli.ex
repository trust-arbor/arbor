defmodule Arbor.Voice.CLI do
  @moduledoc false

  @switches [
    key_file: [:string, :keep],
    seconds: [:integer, :keep],
    input: [:integer, :keep],
    output: [:integer, :keep],
    loopback: [:boolean, :keep]
  ]
  @usage "Usage: mix arbor.voice devices | permission [--request] | talk AGENT [--loopback] [--seconds 3] [--input ID] [--output ID] [--key-file PATH]"
  @public_errors [
    :invalid_desk_options,
    :conversation_unauthorized,
    :device_busy,
    :device_unavailable,
    :permission_denied,
    :unsupported_format,
    :capture_failed,
    :playback_failed,
    :invalid_presentation,
    :cleanup_pending,
    :lease_expired,
    :cancelled,
    :timeout,
    :start_failed,
    :budget_exhausted,
    :turn_failed,
    :transcript_record_failed,
    :session_stopped,
    :presentation_busy,
    :desk_unavailable
  ]

  def run(argv, transport \\ Arbor.Voice.CLI.Transport) do
    case parse(argv) do
      {:ok, :help} -> transport.emit(@usage)
      {:ok, command} -> execute(command, transport)
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(args) when args in [[], ["help"], ["--help"]], do: {:ok, :help}
  def parse(["devices"]), do: {:ok, :devices}
  def parse(["permission"]), do: {:ok, {:permission, false}}
  def parse(["permission", "--request"]), do: {:ok, {:permission, true}}

  def parse(["talk", agent | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    keys = Keyword.keys(opts)
    seconds = Keyword.get(opts, :seconds, 3)

    if valid_agent?(agent) and rest == [] and invalid == [] and
         length(keys) == length(Enum.uniq(keys)) and seconds in 1..10 and
         Enum.all?([:input, :output], &(Keyword.get(opts, &1, 0) in 0..65_535)) and
         valid_path?(Keyword.get(opts, :key_file, "~/.arbor/operator.key")) do
      {:ok, {:talk, agent, opts}}
    else
      {:error, :invalid_arguments}
    end
  end

  def parse(_), do: {:error, :invalid_arguments}

  defp execute({:talk, agent, opts}, transport) do
    key = Keyword.get(opts, :key_file, "~/.arbor/operator.key")

    with {:ok, principal, proof} <- transport.authenticate(key, agent),
         {:ok, server, origin} <- transport.connect(),
         true <- same_host?(server, origin) do
      request = [
        signed_request: proof,
        origin_node: origin,
        mode: if(Keyword.get(opts, :loopback, false), do: :loopback, else: :conversation),
        duration_ms: Keyword.get(opts, :seconds, 3) * 1_000,
        input_device: Keyword.get(opts, :input, :default),
        output_device: Keyword.get(opts, :output, :default)
      ]

      case transport.call(server, Arbor.Voice, :start_desk_turn, [principal, agent, request]) do
        {:ok, id} when is_binary(id) and byte_size(id) in 1..256 ->
          await(server, id, transport)

        {:error, reason} when reason in @public_errors ->
          {:error, reason}

        _ ->
          {:error, :start_failed}
      end
    else
      false -> {:error, :different_host}
      _ -> {:error, :authentication_or_connection_failed}
    end
  rescue
    _ -> {:error, :authentication_or_connection_failed}
  catch
    _, _ -> {:error, :authentication_or_connection_failed}
  end

  defp execute(command, transport) do
    with {:ok, server, origin} <- transport.connect(),
         true <- same_host?(server, origin) do
      case command do
        :devices ->
          show_devices(transport.call(server, Arbor.Multimedia, :devices, []), transport)

        {:permission, request?} ->
          function = if request?, do: :request_microphone_permission, else: :microphone_permission
          show_permission(transport.call(server, Arbor.Multimedia, function, []), transport)
      end
    else
      _ -> {:error, :different_host_or_unavailable}
    end
  rescue
    _ -> {:error, :connection_failed}
  catch
    _, _ -> {:error, :connection_failed}
  end

  defp await(server, id, transport) do
    result =
      try do
        poll(server, id, transport, transport.now() + 65_000, nil)
      rescue
        _ -> {:error, :connection_failed}
      catch
        _, _ -> {:error, :connection_failed}
      end

    if result != :ok do
      try do
        transport.call(server, Arbor.Voice, :cancel_desk_turn, [id])
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    result
  end

  defp poll(server, id, transport, deadline, previous) do
    if transport.now() >= deadline do
      {:error, :deadline_exceeded}
    else
      case transport.call(server, Arbor.Voice, :desk_turn_status, [id]) do
        {:ok, %{terminal: true, state: :complete, error: nil, result: result}}
        when is_map(result) ->
          show_result(result, transport)

        {:ok, %{terminal: true, error: reason}} when reason in @public_errors ->
          {:error, reason}

        {:ok, %{terminal: true}} ->
          {:error, :turn_failed}

        {:ok, %{terminal: false, state: state}}
        when state in [:admitting, :capture, :starting, :turn, :presenting, :cleanup_pending] ->
          if state != previous, do: transport.emit(cue(state))
          transport.wait(250)
          poll(server, id, transport, deadline, state)

        _ ->
          {:error, :status_unavailable}
      end
    end
  end

  defp cue(:admitting), do: "Checking conversation access…"
  defp cue(:capture), do: "Recording — speak now."
  defp cue(:starting), do: "Connecting voice…"
  defp cue(:turn), do: "Working on it."
  defp cue(:presenting), do: "Playing response…"
  defp cue(:cleanup_pending), do: "Waiting for audio cleanup…"

  defp show_result(%{capture_frames: frames, capture_duration_ms: ms, disposition: :played}, t)
       when is_integer(frames) and frames > 0 and is_integer(ms) and ms in 1..30_000 do
    t.emit("Loopback complete: #{frames} frames, #{ms} ms. Devices closed.")
    :ok
  end

  defp show_result(%{input_transcript: input, reply: reply, disposition: disposition}, t)
       when is_binary(input) and byte_size(input) <= 65_536 and is_binary(reply) and
              byte_size(reply) <= 65_536 and disposition in [:played, :screen_only] do
    t.emit("You: " <> display(input))
    t.emit("Assistant: " <> display(reply))

    t.emit(
      if disposition == :played,
        do: "Voice turn complete. Devices closed.",
        else: "Voice turn complete. Response is on screen; devices closed."
    )

    :ok
  end

  defp show_result(_, _), do: {:error, :invalid_result}

  defp show_devices({:ok, devices}, t) when is_list(devices) and length(devices) <= 128 do
    if Enum.all?(devices, &valid_device?/1) do
      Enum.each(devices, fn d ->
        t.emit(
          "#{d.id}: #{display(d.name)} (#{d.max_input_channels} in / #{d.max_output_channels} out, #{d.default_sample_rate} Hz)"
        )
      end)

      if devices == [], do: t.emit("No audio devices found.")
      :ok
    else
      {:error, :invalid_result}
    end
  end

  defp show_devices(_, _), do: {:error, :device_unavailable}

  defp valid_device?(%{
         id: id,
         name: name,
         max_input_channels: input,
         max_output_channels: output,
         default_sample_rate: rate
       }),
       do:
         is_integer(id) and id in 0..65_535 and is_binary(name) and byte_size(name) <= 256 and
           String.valid?(name) and is_integer(input) and input in 0..256 and is_integer(output) and
           output in 0..256 and is_number(rate) and rate >= 8_000 and rate <= 192_000

  defp valid_device?(_), do: false

  defp show_permission(status, t)
       when status in [
              :authorized,
              :denied,
              :restricted,
              :not_determined,
              :unavailable,
              :not_required
            ] do
    t.emit("Microphone permission: #{status}.")
    :ok
  end

  defp show_permission(_, _), do: {:error, :permission_unavailable}

  defp same_host?(server, origin) when is_atom(server) and is_atom(origin) do
    case {String.split(Atom.to_string(server), "@"), String.split(Atom.to_string(origin), "@")} do
      {[_server, host], [_origin, host]} when host != "nohost" and host != "" -> true
      _ -> false
    end
  end

  defp same_host?(_, _), do: false

  defp valid_agent?(agent),
    do:
      is_binary(agent) and byte_size(agent) in 1..256 and String.valid?(agent) and
        Regex.match?(~r/\Aagent_[A-Za-z0-9_-]+\z/, agent)

  defp valid_path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..4096 and String.valid?(path) and
        not String.contains?(path, <<0>>)

  defp display(text),
    do:
      String.replace(
        text,
        ~r/[\x00-\x08\x0B-\x1F\x7F-\x9F\x{202A}-\x{202E}\x{2066}-\x{2069}]/u,
        ""
      )
end

defmodule Arbor.Voice.CLI.Transport do
  @moduledoc false
  alias Arbor.Voice.Config
  alias Mix.Tasks.Arbor.Helpers

  def authenticate(key_path, agent) do
    path = Path.expand(key_path)

    with {:ok, security} <- Config.security_module(),
         {:ok, principal} <- security.key_file_principal(path),
         {:ok, payload} <- security.conversation_session_request_payload(principal, agent),
         {:ok, ^principal, signed} <- security.sign_key_file_request(path, payload) do
      {:ok, principal, signed}
    else
      _ -> {:error, :operator_authentication_failed}
    end
  end

  def connect do
    Helpers.ensure_distribution()

    case Helpers.read_metadata() do
      {:ok, %{node: server}} when is_binary(server) ->
        if Helpers.node_alive?(server),
          do: {:ok, Helpers.node_atom(server), node()},
          else: {:error, :server_unavailable}

      _ ->
        {:error, :server_unavailable}
    end
  end

  # Enumeration can use the full internal five-second cleanup grace plus its
  # caller margin. Status calls stay below the three-second Desk renewal lease.
  def call(server, Arbor.Multimedia, :devices, []),
    do: :erpc.call(server, Arbor.Multimedia, :devices, [], 6_000)

  def call(server, module, function, args), do: :erpc.call(server, module, function, args, 2_000)
  def now, do: System.monotonic_time(:millisecond)
  def wait(ms), do: Process.sleep(ms)
  def emit(text), do: Mix.shell().info(text)
end
