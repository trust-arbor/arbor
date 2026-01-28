defmodule Arbor.Historian.Collector.StreamRouter do
  @moduledoc """
  Pure routing functions that determine which streams a signal belongs to.

  Each signal is routed to multiple streams based on its properties:
  - `"global"` - always (every signal)
  - `"agent:{id}"` - if signal has agent_id in data or source
  - `"category:{name}"` - based on signal category
  - `"session:{id}"` - if signal has session_id in data
  - `"correlation:{id}"` - if signal has a correlation_id
  """

  alias Arbor.Common.SafeAtom

  @doc """
  Route a signal to all applicable stream IDs.

  Returns a list of stream ID strings the signal should be appended to.
  Always includes `"global"`.

  ## Examples

      iex> route(%Signal{type: "arbor.activity.agent_started", data: %{agent_id: "a1"}})
      ["global", "category:activity", "agent:a1"]
  """
  @spec route(struct()) :: [String.t()]
  def route(signal) do
    ["global"]
    |> maybe_add_category(signal)
    |> maybe_add_agent(signal)
    |> maybe_add_session(signal)
    |> maybe_add_correlation(signal)
  end

  @doc "Build a stream ID for an agent."
  @spec stream_id_for_agent(String.t()) :: String.t()
  def stream_id_for_agent(agent_id), do: "agent:#{agent_id}"

  @doc "Build a stream ID for a category."
  @spec stream_id_for_category(atom()) :: String.t()
  def stream_id_for_category(category), do: "category:#{category}"

  @doc "Build a stream ID for a session."
  @spec stream_id_for_session(String.t()) :: String.t()
  def stream_id_for_session(session_id), do: "session:#{session_id}"

  @doc "Build a stream ID for a correlation chain."
  @spec stream_id_for_correlation(String.t()) :: String.t()
  def stream_id_for_correlation(correlation_id), do: "correlation:#{correlation_id}"

  # Private helpers

  defp maybe_add_category(streams, signal) do
    case extract_category(signal) do
      nil -> streams
      category -> streams ++ ["category:#{category}"]
    end
  end

  defp maybe_add_agent(streams, signal) do
    case extract_agent_id(signal) do
      nil -> streams
      agent_id -> streams ++ ["agent:#{agent_id}"]
    end
  end

  defp maybe_add_session(streams, signal) do
    case extract_session_id(signal) do
      nil -> streams
      session_id -> streams ++ ["session:#{session_id}"]
    end
  end

  defp maybe_add_correlation(streams, signal) do
    corr_id = Map.get(signal, :correlation_id) || Map.get(signal, :jido_correlation_id)

    case corr_id do
      nil -> streams
      "" -> streams
      correlation_id -> streams ++ ["correlation:#{correlation_id}"]
    end
  rescue
    _ -> streams
  end

  defp extract_category(signal) do
    cond do
      # Trust-arbor Signal: has :category atom field
      is_atom(Map.get(signal, :category)) and Map.get(signal, :category) != nil ->
        signal.category

      # CloudEvents / jido_signal: type is string like "arbor.activity.agent_started"
      is_binary(signal.type) ->
        case signal.type do
          "arbor." <> rest ->
            rest |> String.split(".", parts: 2) |> List.first() |> SafeAtom.to_category()

          type ->
            type |> String.split(".", parts: 2) |> List.first() |> SafeAtom.to_category()
        end

      true ->
        nil
    end
  end

  defp extract_agent_id(signal) do
    data = signal.data || %{}

    cond do
      is_map(data) and is_binary(data[:agent_id]) -> data[:agent_id]
      is_map(data) and is_binary(data["agent_id"]) -> data["agent_id"]
      is_binary(signal.source) and String.contains?(signal.source, "agent/") -> parse_agent_from_source(signal.source)
      true -> nil
    end
  end

  defp extract_session_id(signal) do
    data = signal.data || %{}

    cond do
      is_map(data) and is_binary(data[:session_id]) -> data[:session_id]
      is_map(data) and is_binary(data["session_id"]) -> data["session_id"]
      true -> nil
    end
  end

  defp parse_agent_from_source(source) do
    case Regex.run(~r{agent/([^/]+)}, source) do
      [_, agent_id] -> agent_id
      _ -> nil
    end
  end
end
