defmodule Arbor.Voice.Session.TurnCore do
  @moduledoc """
  Pure bounded event reduction for a single voice text turn (VP-04E1).

  Accumulates output text deltas, ignores validated input-transcript/audio
  payloads, treats nonblank terminal text as authoritative (with delta
  fallback), and tracks a bounded set of seen tool-call ids. Stores no pids,
  clocks, functions, or side effects.
  """

  @max_text_bytes 8192
  @max_tool_id_bytes 256
  @max_seen_tool_ids 64

  @type state :: %{
          text_acc: binary(),
          seen_tool_ids: MapSet.t(String.t())
        }

  @type reduce_result ::
          {:continue, state()}
          | {:done, String.t()}
          | {:reject_tool, state(), String.t()}
          | {:error, :protocol_error}

  @doc "Construct empty pure turn state."
  @spec new() :: state()
  def new do
    %{text_acc: "", seen_tool_ids: MapSet.new()}
  end

  @doc """
  Reduce one backend event.

  Returns:
  * `{:continue, state}` — keep polling (ignored/benign event or duplicate tool id)
  * `{:done, raw_text}` — terminal text ready for transcript + reply
  * `{:reject_tool, state, call_id}` — new well-formed tool call; shell must mark
    (already applied in returned state), send one `no_tools_installed` output,
    then continue polling
  * `{:error, :protocol_error}` — malformed, oversized, or backend error event
  """
  @spec reduce(state(), term()) :: reduce_result()
  def reduce(%{text_acc: acc, seen_tool_ids: %MapSet{}} = state, event)
      when is_binary(acc) do
    # Reject malformed core state without raising on MapSet or String ops.
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

  @doc "JSON body for the empty-catalog tool rejection (VOICE-8 partial)."
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
        # Validated shape only; payload is never retained.
        {:continue, state}

      {:tool_call, call} when is_map(call) ->
        reduce_tool_call(state, call)

      {:error, _reason} ->
        {:error, :protocol_error}

      _other ->
        {:error, :protocol_error}
    end
  end

  defp reduce_text_delta(%{text_acc: acc} = state, delta) do
    # Byte bound first, then UTF-8 — never trim/concat invalid binaries.
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

  defp reduce_turn_done(%{text_acc: acc}, text) do
    # Byte bound first, then UTF-8 — never String.trim invalid binaries.
    cond do
      byte_size(text) > @max_text_bytes ->
        {:error, :protocol_error}

      not String.valid?(text) ->
        {:error, :protocol_error}

      String.trim(text) != "" ->
        # Nonblank terminal is authoritative.
        {:done, text}

      String.trim(acc) != "" ->
        # Blank terminal falls back to nonblank accumulated deltas.
        if byte_size(acc) > @max_text_bytes do
          {:error, :protocol_error}
        else
          {:done, acc}
        end

      true ->
        # Both terminal and accumulator blank — protocol error, not empty success.
        {:error, :protocol_error}
    end
  end

  defp reduce_tool_call(%{seen_tool_ids: %MapSet{} = seen} = state, call) do
    with {:ok, id} <- tool_call_id(call),
         :ok <- tool_call_shape(call) do
      cond do
        MapSet.member?(seen, id) ->
          {:continue, state}

        MapSet.size(seen) >= @max_seen_tool_ids ->
          {:error, :protocol_error}

        true ->
          next = %{state | seen_tool_ids: MapSet.put(seen, id)}
          {:reject_tool, next, id}
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

  # Require name + arguments keys so malformed calls fail closed (VOICE-8).
  defp tool_call_shape(%{name: name, arguments: args})
       when is_binary(name) and is_map(args),
       do: validate_tool_name(name)

  defp tool_call_shape(%{"name" => name, "arguments" => args})
       when is_binary(name) and is_map(args),
       do: validate_tool_name(name)

  defp tool_call_shape(_), do: :error

  defp validate_tool_name(name) do
    cond do
      byte_size(name) > @max_tool_id_bytes -> :error
      not String.valid?(name) -> :error
      String.trim(name) == "" -> :error
      true -> :ok
    end
  end

  defp valid_ignored_text?(text) do
    byte_size(text) <= @max_text_bytes and String.valid?(text)
  end
end
