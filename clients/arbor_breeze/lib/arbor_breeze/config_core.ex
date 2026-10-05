defmodule ArborBreeze.ConfigCore do
  @moduledoc "Pure parsing and precedence for non-credential terminal preferences."

  @max_bytes 4_096
  @default_url "http://127.0.0.1:4000"

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    if String.valid?(bytes) do
      bytes
      |> String.split("\n")
      |> Enum.reduce_while({:ok, %{}}, &parse_line/2)
    else
      {:error, :configuration_unavailable}
    end
  end

  def parse(_), do: {:error, :configuration_unavailable}

  def resolve(options, preferences, gateway_env) do
    url =
      cond do
        Keyword.has_key?(options, :url) -> options[:url]
        Map.has_key?(preferences, :url) -> preferences.url
        not is_nil(gateway_env) -> gateway_env
        true -> @default_url
      end

    options = Keyword.put(options, :url, url)

    if options[:operation] == :chat and not Keyword.has_key?(options, :agent) and
         Map.has_key?(preferences, :agent) do
      Keyword.put(options, :agent, preferences.agent)
    else
      options
    end
  end

  defp parse_line(line, {:ok, preferences}) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        {:cont, {:ok, preferences}}

      true ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> add_preference(String.trim(key), String.trim(value), preferences)
          _ -> {:halt, {:error, :configuration_unavailable}}
        end
    end
  end

  # Legacy credential selectors and other settings are discarded, never retained.
  defp add_preference("url", value, preferences), do: put(preferences, :url, value, 2_048)
  defp add_preference("agent", value, preferences), do: put(preferences, :agent, value, 256)
  defp add_preference(_, _, preferences), do: {:cont, {:ok, preferences}}

  defp put(preferences, key, value, limit) do
    if not Map.has_key?(preferences, key) and byte_size(value) in 1..limit and
         not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, value) do
      {:cont, {:ok, Map.put(preferences, key, value)}}
    else
      {:halt, {:error, :configuration_unavailable}}
    end
  end
end
