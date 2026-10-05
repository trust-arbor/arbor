defmodule ArborBreeze.Config do
  @moduledoc """
  Bounded legacy URL/target preferences. Credentials and unscoped state are not
  read. Trusted embeddings may inject the home, environment reader and bounded
  file reader; none of those sources is a command-line option.
  """

  alias ArborBreeze.ConfigCore
  @max_bytes 4_096

  def default_sources do
    %{
      home: System.user_home!(),
      get_env: &System.get_env/1,
      read_config: &read_config/1
    }
  end

  def resolve(options, sources \\ nil) do
    sources = sources || default_sources()

    with true <- valid_sources?(sources),
         {:ok, preferences} <- preferences(options, sources),
         gateway_env <- gateway_env(options, preferences, sources) do
      {:ok, ConfigCore.resolve(options, preferences, gateway_env)}
    else
      _ -> {:error, :configuration_unavailable}
    end
  rescue
    _ -> {:error, :configuration_unavailable}
  catch
    _, _ -> {:error, :configuration_unavailable}
  end

  defp preferences(options, sources) do
    if Keyword.has_key?(options, :url) and
         (options[:operation] != :chat or Keyword.has_key?(options, :agent)) do
      {:ok, %{}}
    else
      with {:ok, root} <- preference_root(sources) do
        case sources.read_config.(Path.join(root, "tui.conf")) do
          {:ok, bytes} -> ConfigCore.parse(bytes)
          {:error, :enoent} -> {:ok, %{}}
          _ -> {:error, :configuration_unavailable}
        end
      end
    end
  end

  defp preference_root(sources) do
    root =
      case sources.get_env.("ARBOR_HOME") do
        nil -> Path.join(sources.home, ".arbor")
        explicit -> explicit
      end

    if is_binary(root) and byte_size(root) in 1..2_048 and String.valid?(root) and
         not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, root) and Path.type(root) == :absolute,
       do: {:ok, root},
       else: {:error, :configuration_unavailable}
  end

  defp gateway_env(options, preferences, sources) do
    if Keyword.has_key?(options, :url) or Map.has_key?(preferences, :url),
      do: nil,
      else: sources.get_env.("ARBOR_GATEWAY_URL")
  end

  defp valid_sources?(sources) do
    is_map(sources) and map_size(sources) == 3 and is_binary(sources[:home]) and
      is_function(sources[:get_env], 1) and is_function(sources[:read_config], 1)
  end

  defp read_config(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path) do
      File.open(path, [:read, :binary], fn file -> IO.binread(file, @max_bytes + 1) end)
      |> normalize_read()
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp normalize_read({:ok, :eof}), do: {:ok, ""}
  defp normalize_read({:ok, bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp normalize_read(_), do: {:error, :configuration_unavailable}
end
