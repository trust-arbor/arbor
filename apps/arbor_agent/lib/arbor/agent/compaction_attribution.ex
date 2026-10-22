defmodule Arbor.Agent.CompactionAttribution do
  @moduledoc false

  # Compaction Laundering (arxiv 2610.29869): role labels inside untrusted
  # content must stay data, never a new turn header. Attribution is a JSON
  # record so role/name stay structured fields and content is quoted.

  @summary_role :summary

  @doc "Dedicated role for synthetic summary and omission records."
  @spec summary_role() :: :summary
  def summary_role, do: @summary_role

  @spec format_turn(map(), keyword()) :: String.t()
  def format_turn(message, opts \\ []) when is_map(message) and is_list(opts) do
    text = Keyword.get(opts, :text)
    timestamp = Keyword.get(opts, :timestamp)

    record = %{
      "role" => role_of(message),
      "content" => content_of(message, text)
    }

    record =
      case name_of(message) do
        nil -> record
        name -> Map.put(record, "name", name)
      end

    record =
      case timestamp do
        %DateTime{} = dt -> Map.put(record, "timestamp", DateTime.to_iso8601(dt))
        _other -> record
      end

    Jason.encode!(record)
  end

  @spec format_turns([map()]) :: String.t()
  def format_turns(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", &format_turn/1)
  end

  defp role_of(message) do
    case Map.get(message, :role) || Map.get(message, "role") do
      nil -> "unknown"
      role -> to_string(role)
    end
  end

  defp name_of(message) do
    case Map.get(message, :name) || Map.get(message, "name") do
      name when is_binary(name) and name != "" -> name
      name when is_atom(name) -> Atom.to_string(name)
      _other -> nil
    end
  end

  defp content_of(_message, text) when is_binary(text), do: text

  defp content_of(message, _text) do
    case Map.get(message, :content) || Map.get(message, "content") do
      content when is_binary(content) -> content
      content -> to_string(content)
    end
  end
end
