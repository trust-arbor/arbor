defmodule Arbor.Dashboard.ConversationNavigationCore do
  @moduledoc false

  @max_query_bytes 4_096
  @max_query_fields 64
  @max_agent_bytes 256
  @agent_slug ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @invalid_escape ~r/%(?![0-9A-Fa-f]{2})/

  # Navigation syntax only. The destination still requires its ordinary
  # browser session proof and host authorization before any private access.
  def target_path(target)
      when is_binary(target) and byte_size(target) <= @max_agent_bytes do
    if String.valid?(target) and Regex.match?(@agent_slug, target),
      do: {:ok, "/conversation/" <> target},
      else: {:error, :invalid_target}
  end

  def target_path(_target), do: {:error, :invalid_target}

  # Use the original query rather than decoded params, which lose duplicate
  # selectors. Never forward unrelated query fields, including credentials.
  def legacy_destination(query)
      when is_binary(query) and byte_size(query) <= @max_query_bytes do
    fields = String.split(query, "&", parts: @max_query_fields + 1)

    if length(fields) <= @max_query_fields and String.valid?(query) do
      fields
      |> Enum.reduce_while({:ok, nil}, &select_target/2)
      |> destination()
    else
      {:error, :invalid_target}
    end
  end

  def legacy_destination(_query), do: {:error, :invalid_target}

  defp select_target(field, {:ok, selected}) do
    with false <- Regex.match?(@invalid_escape, field),
         [key, value] <- String.split(field, "=", parts: 2) |> with_value(),
         key = URI.decode_www_form(key),
         value = URI.decode_www_form(value),
         true <- String.valid?(key) and String.valid?(value) do
      cond do
        key == "agent_id" and is_nil(selected) ->
          {:cont, {:ok, value}}

        key == "agent_id" or String.starts_with?(key, "agent_id[") ->
          {:halt, {:error, :invalid_target}}

        true ->
          {:cont, {:ok, selected}}
      end
    else
      _ -> {:halt, {:error, :invalid_target}}
    end
  end

  defp with_value([key]), do: [key, ""]
  defp with_value(pair), do: pair

  defp destination({:ok, nil}), do: {:ok, "/"}
  defp destination({:ok, target}), do: target_path(target)
  defp destination(error), do: error
end
