defmodule Arbor.Voice.Session.TurnCore do
  @moduledoc """
  Pure bounded event reduction for a single voice text turn (VP-04E1/E3).

  Accumulates output text deltas, ignores validated input-transcript/audio
  payloads, tracks tool-bearing response waves, and a bounded set of seen
  tool-call ids. Stores no pids, clocks, functions, or outstanding-task
  authority (Session.pending owns outstanding calls).
  """

  @max_text_bytes 8192
  # Single-event DoS ceiling for backend :output_audio chunks (payload not retained).
  @max_audio_bytes 65_536
  @max_tool_id_bytes 256
  @max_seen_tool_ids 64

  alias Arbor.Voice.Session.JsonTerm

  @type state :: %{
          text_acc: binary(),
          seen_tool_ids: MapSet.t(String.t()),
          tool_wave: boolean()
        }

  @type admit_call :: %{id: String.t(), name: String.t(), arguments: map()}

  @type reduce_result ::
          {:continue, state()}
          | {:done, String.t()}
          | {:cycle_reset, state()}
          | {:admit_tool, state(), admit_call()}
          | {:error, :protocol_error}

  @doc "Construct empty pure turn state."
  @spec new() :: state()
  def new do
    %{text_acc: "", seen_tool_ids: MapSet.new(), tool_wave: false}
  end

  @doc """
  Reduce one backend event.

  Returns:
  * `{:continue, state}` — keep polling
  * `{:done, raw_text}` — terminal text ready (`tool_wave` was false)
  * `{:cycle_reset, state}` — any `turn_done` while `tool_wave` is true: intermediate
    provider boundary; pre-tool text cleared; never completes from this event
  * `{:admit_tool, state, call}` — new well-formed tool call; id marked; shell owns spawn
  * `{:error, :protocol_error}` — malformed, oversized, or backend error event
  """
  @spec reduce(state(), term()) :: reduce_result()
  def reduce(%{text_acc: acc, seen_tool_ids: %MapSet{}, tool_wave: wave} = state, event)
      when is_binary(acc) and is_boolean(wave) do
    if String.valid?(acc) do
      do_reduce(state, event)
    else
      {:error, :protocol_error}
    end
  end

  def reduce(_state, _event), do: {:error, :protocol_error}

  @doc "Byte budget for accumulated and terminal text."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "Byte ceiling for a single :output_audio event (payload never retained)."
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  @doc "Per-turn distinct tool-id ceiling."
  @spec max_seen_tool_ids() :: pos_integer()
  def max_seen_tool_ids, do: @max_seen_tool_ids

  @doc "Max nesting depth for tool arguments."
  @spec max_args_depth() :: pos_integer()
  def max_args_depth, do: JsonTerm.max_depth()

  @doc "Max Jason-encoded byte size for tool arguments."
  @spec max_args_encoded_bytes() :: pos_integer()
  def max_args_encoded_bytes, do: JsonTerm.max_encoded_bytes()

  @doc "JSON body for the empty-catalog tool rejection (VOICE-8)."
  @spec no_tools_installed_output() :: String.t()
  def no_tools_installed_output do
    Jason.encode!(%{"code" => "no_tools_installed"})
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp do_reduce(state, event) do
    case event do
      {:output_text_delta, delta} when is_binary(delta) ->
        reduce_text_delta(state, delta)

      {:turn_done, %{text: text}} when is_binary(text) ->
        reduce_turn_done(state, text)

      {:turn_done, payload} when is_map(payload) ->
        case Map.fetch(payload, :text) do
          {:ok, text} when is_binary(text) -> reduce_turn_done(state, text)
          _ -> {:error, :protocol_error}
        end

      {:input_transcript, text} when is_binary(text) ->
        if valid_ignored_text?(text), do: {:continue, state}, else: {:error, :protocol_error}

      {:output_audio, chunk} when is_binary(chunk) ->
        reduce_output_audio(state, chunk)

      {:tool_call, call} when is_map(call) ->
        reduce_tool_call(state, call)

      {:error, _reason} ->
        {:error, :protocol_error}

      _other ->
        {:error, :protocol_error}
    end
  end

  defp reduce_text_delta(%{text_acc: acc} = state, delta) do
    cond do
      byte_size(delta) > @max_text_bytes ->
        {:error, :protocol_error}

      not String.valid?(delta) ->
        {:error, :protocol_error}

      byte_size(acc) + byte_size(delta) > @max_text_bytes ->
        {:error, :protocol_error}

      true ->
        {:continue, %{state | text_acc: acc <> delta}}
    end
  end

  defp reduce_output_audio(state, chunk) do
    if byte_size(chunk) > @max_audio_bytes do
      {:error, :protocol_error}
    else
      {:continue, state}
    end
  end

  # Any turn_done while tool_wave is true is an intermediate provider boundary:
  # clear text_acc/tool_wave and continue — never complete, even if text is nonblank
  # and even if Session.pending is already empty.
  defp reduce_turn_done(%{tool_wave: true} = state, text) do
    cond do
      byte_size(text) > @max_text_bytes ->
        {:error, :protocol_error}

      not String.valid?(text) ->
        {:error, :protocol_error}

      true ->
        {:cycle_reset, %{state | tool_wave: false, text_acc: ""}}
    end
  end

  defp reduce_turn_done(%{text_acc: acc, tool_wave: false}, text) do
    cond do
      byte_size(text) > @max_text_bytes ->
        {:error, :protocol_error}

      not String.valid?(text) ->
        {:error, :protocol_error}

      String.trim(text) != "" ->
        {:done, text}

      String.trim(acc) != "" ->
        if byte_size(acc) > @max_text_bytes do
          {:error, :protocol_error}
        else
          {:done, acc}
        end

      true ->
        {:error, :protocol_error}
    end
  end

  defp reduce_tool_call(%{seen_tool_ids: %MapSet{} = seen} = state, call) do
    with {:ok, id} <- tool_call_id(call),
         {:ok, name, args} <- tool_call_fields(call) do
      cond do
        MapSet.member?(seen, id) ->
          {:continue, state}

        MapSet.size(seen) >= @max_seen_tool_ids ->
          {:error, :protocol_error}

        true ->
          next = %{
            state
            | seen_tool_ids: MapSet.put(seen, id),
              tool_wave: true
          }

          {:admit_tool, next, %{id: id, name: name, arguments: args}}
      end
    else
      :error -> {:error, :protocol_error}
    end
  end

  defp tool_call_id(%{id: id}) when is_binary(id), do: validate_tool_id(id)
  defp tool_call_id(%{"id" => id}) when is_binary(id), do: validate_tool_id(id)
  defp tool_call_id(_), do: :error

  defp validate_tool_id(id) do
    cond do
      byte_size(id) > @max_tool_id_bytes -> :error
      not String.valid?(id) -> :error
      String.trim(id) == "" -> :error
      true -> {:ok, id}
    end
  end

  defp tool_call_fields(%{name: name, arguments: args})
       when is_binary(name) and is_map(args) do
    with :ok <- validate_tool_name(name),
         :ok <- validate_arguments(args) do
      {:ok, name, args}
    end
  end

  defp tool_call_fields(%{"name" => name, "arguments" => args})
       when is_binary(name) and is_map(args) do
    with :ok <- validate_tool_name(name),
         :ok <- validate_arguments(args) do
      {:ok, name, args}
    end
  end

  defp tool_call_fields(_), do: :error

  defp validate_tool_name(name) do
    cond do
      byte_size(name) > @max_tool_id_bytes -> :error
      not String.valid?(name) -> :error
      String.trim(name) == "" -> :error
      true -> :ok
    end
  end

  # Fail closed before mark/spawn via shared strict JSON-term helper.
  defp validate_arguments(args) when is_map(args) do
    JsonTerm.validate(args)
  end

  defp validate_arguments(_), do: :error

  defp valid_ignored_text?(text) do
    byte_size(text) <= @max_text_bytes and String.valid?(text)
  end
end
