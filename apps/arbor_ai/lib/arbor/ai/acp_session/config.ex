defmodule Arbor.AI.AcpSession.Config do
  @moduledoc """
  Provider configuration for ACP sessions.

  Maps provider atoms to transport options for `ExMCP.ACP.Client`.
  Native ACP agents just need a command; adapted agents need an adapter module
  and transport via `ExMCP.ACP.AdapterTransport`.

  ## Configuration

  Override defaults via application config:

      config :arbor_ai, :acp_providers, %{
        claude: %{
          transport_mod: ExMCP.ACP.AdapterTransport,
          adapter: ExMCP.ACP.Adapters.Claude,
          adapter_opts: [model: "opus", cli_path: "/usr/local/bin/claude"]
        }
      }
  """

  @native_providers %{
    gemini: %{command: ["gemini", "--acp"]},
    opencode: %{command: ["opencode", "--acp"]},
    goose: %{command: ["goose", "--acp"]},
    copilot: %{command: ["github-copilot", "--acp"]},
    kiro: %{command: ["kiro", "--acp"]},
    qwen_code: %{command: ["qwen-code", "--acp"]}
  }

  @adapted_providers %{
    claude: %{
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.Claude,
      adapter_opts: [model: "sonnet"]
    },
    codex: %{
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.Codex,
      adapter_opts: []
    }
  }

  @doc """
  Resolve provider configuration, merging defaults with application overrides.

  Returns a map with transport options for `ExMCP.ACP.Client.start_link/1`.
  """
  @spec resolve(atom(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def resolve(provider, opts \\ []) do
    user_overrides = Application.get_env(:arbor_ai, :acp_providers, %{})

    config =
      case Map.get(user_overrides, provider) do
        nil -> default_config(provider)
        override -> {:ok, override}
      end

    case config do
      {:ok, provider_config} ->
        {:ok, merge_opts(provider_config, opts)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all known providers and whether they are native ACP or adapted.
  """
  @spec list_providers() :: [{atom(), :native | :adapted}]
  def list_providers do
    user_overrides = Application.get_env(:arbor_ai, :acp_providers, %{})

    native =
      @native_providers
      |> Map.keys()
      |> Enum.map(&{&1, :native})

    adapted =
      @adapted_providers
      |> Map.keys()
      |> Enum.map(&{&1, :adapted})

    custom =
      user_overrides
      |> Map.keys()
      |> Enum.reject(
        &(Map.has_key?(@native_providers, &1) or Map.has_key?(@adapted_providers, &1))
      )
      |> Enum.map(&{&1, :custom})

    native ++ adapted ++ custom
  end

  @doc """
  Check if a provider uses an adapter (non-native ACP).
  """
  @spec adapted?(atom()) :: boolean()
  def adapted?(provider) do
    user_overrides = Application.get_env(:arbor_ai, :acp_providers, %{})

    case Map.get(user_overrides, provider) do
      %{adapter: _} -> true
      nil -> Map.has_key?(@adapted_providers, provider)
      _ -> false
    end
  end

  @doc """
  Resolve raw client options without provider lookup.

  Used for testing — pass transport options directly.
  """
  @spec raw_opts(keyword()) :: keyword()
  def raw_opts(opts), do: opts

  # -- Private --

  defp default_config(provider) do
    case Map.get(@native_providers, provider) do
      nil ->
        case Map.get(@adapted_providers, provider) do
          nil -> {:error, {:unknown_provider, provider}}
          config -> {:ok, config}
        end

      config ->
        {:ok, config}
    end
  end

  defp merge_opts(provider_config, opts) do
    base =
      case provider_config do
        %{command: command} ->
          [command: command]

        %{transport_mod: mod, adapter: adapter} ->
          adapter_opts =
            Map.get(provider_config, :adapter_opts, [])
            |> Keyword.merge(Keyword.get(opts, :adapter_opts, []))

          [transport_mod: mod, adapter: adapter, adapter_opts: adapter_opts]
      end

    # Forward non-adapter opts
    forward_keys = [:model, :system_prompt, :cwd, :timeout, :name, :event_listener]

    Enum.reduce(forward_keys, base, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Keyword.put(acc, key, value)
      end
    end)
  end
end
