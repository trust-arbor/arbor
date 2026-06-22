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
          adapter: ExMCP.ACP.Adapters.ClaudeSDK,
          adapter_opts: [model: "opus", cli_path: "/usr/local/bin/claude"]
        }
      }

  ## Claude adapter

  Uses `ExMCP.ACP.Adapters.ClaudeSDK` — the SDK-protocol-based adapter
  that talks to Claude Code via the same stream-json control protocol
  as `@anthropic-ai/claude-agent-sdk`. The older
  `ExMCP.ACP.Adapters.Claude` (stream-json without the SDK control
  channel) is still available in ex_mcp for callers that need it; the
  SDK adapter is the recommended path for new integrations and
  supports SDK interrupt cancellation, runtime model/mode/effort
  config, partial tool-call lifecycle events, plan updates, and the
  stdio permission prompt control channel used by the HITL bridge.
  """

  @native_providers %{
    gemini: %{command: ["gemini", "--experimental-acp"]},
    opencode: %{command: ["opencode", "acp"]},
    goose: %{command: ["goose", "--acp"]},
    copilot: %{command: ["github-copilot", "--acp"]},
    kiro: %{command: ["kiro", "--acp"]},
    qwen_code: %{command: ["qwen-code", "--acp"]},
    hermes: %{command: ["hermes", "acp"]},
    # Cursor CLI is a native ACP server: `cursor-agent acp` (stdio, JSON-RPC 2.0,
    # newline-delimited). Auth out-of-band via `cursor-agent login`, or pass
    # `CURSOR_API_KEY` / `CURSOR_AUTH_TOKEN` through adapter_opts[:env]. Modes:
    # agent, plan, ask. Authenticate methodId is "cursor_login".
    cursor: %{command: ["cursor-agent", "acp"]}
  }

  @adapted_providers %{
    claude: %{
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.ClaudeSDK,
      # `permission_mode: :bypass` keeps existing Arbor flows
      # (heartbeat, ChatLive, agent loops) running without prompting:
      # ClaudeSDK encodes `:bypass` as `--permission-mode bypassPermissions`,
      # which skips all tool-use prompts. Functionally equivalent to
      # the legacy adapter's `--dangerously-skip-permissions` flag but
      # routed through the modern permission_mode CLI surface.
      #
      # Pipelines or per-turn callers that want a tighter constraint
      # should override via adapter_opts, e.g.
      #   permission_mode: :default, allowed_tools: ["WebSearch", "WebFetch"]
      # That routes Claude's permission requests through the SDK's
      # stdio permission_prompt control channel into Arbor's HITL bridge
      # (see `apps/arbor_ai/lib/arbor/ai/acp_session/handler.ex`).
      adapter_opts: [model: "sonnet", permission_mode: :bypass]
    },
    codex: %{
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.Codex,
      adapter_opts: []
    },
    pi: %{
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.Pi,
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
        opts = maybe_inject_alternate_endpoint(provider, opts)
        {:ok, merge_opts(provider_config, opts)}

      {:error, _} = error ->
        error
    end
  end

  # When the Claude CLI is pointed at an OpenAI/Anthropic-compatible endpoint
  # that ISN'T api.anthropic.com (e.g. an Ollama server serving the Anthropic
  # Messages API at /v1/messages), the spawned `claude` subprocess needs:
  #
  #   * `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` in its OS env so it talks
  #     to that endpoint instead of Anthropic (these reach the subprocess via
  #     `adapter_opts[:env]`, which `PortRunner.safe_env/2` merges into the
  #     spawned process environment — note `ANTHROPIC_API_KEY` is cleared by
  #     the runner, so `ANTHROPIC_AUTH_TOKEN` is the working auth channel).
  #   * an endpoint-native model name (e.g. `granite3.1-moe:1b`), NOT a Claude
  #     model id — set via `adapter_opts[:model]` → `--model`.
  #   * a lean tool surface (`--tools ""`) and no local settings
  #     (`--setting-sources ""`), because small local models can't drive the
  #     full agent tool loop in reasonable time.
  #
  # Driven entirely by env / config so CI can opt in without code changes and
  # the normal Anthropic path is untouched when `ANTHROPIC_BASE_URL` is unset
  # (or points at api.anthropic.com).
  defp maybe_inject_alternate_endpoint(:claude, opts) do
    base_url = System.get_env("ANTHROPIC_BASE_URL")

    if alternate_endpoint?(base_url) do
      auth_token = System.get_env("ANTHROPIC_AUTH_TOKEN") || "alternate"
      model = alternate_model()

      base_adapter = Keyword.get(opts, :adapter_opts, [])

      env =
        [
          {"ANTHROPIC_BASE_URL", base_url},
          {"ANTHROPIC_AUTH_TOKEN", auth_token},
          # Trim the CLI's non-essential side calls (e.g. session title
          # generation) so a slow local model isn't doing extra round-trips.
          {"DISABLE_NON_ESSENTIAL_MODEL_CALLS", "1"},
          {"DISABLE_TELEMETRY", "1"},
          {"DISABLE_AUTOUPDATER", "1"}
        ]
        |> Keyword.merge(Keyword.get(base_adapter, :env, []))

      adapter_opts =
        base_adapter
        |> Keyword.put(:env, env)
        |> Keyword.put_new(:tools, "")
        |> Keyword.put_new(:extra_args, ["--setting-sources", ""])
        |> maybe_put_model(model)

      opts
      |> Keyword.put(:adapter_opts, adapter_opts)
      |> maybe_put_top_model(model)
    else
      opts
    end
  end

  defp maybe_inject_alternate_endpoint(_provider, opts), do: opts

  # Treat any base URL that is set and not the canonical Anthropic host as an
  # alternate endpoint. An empty string means "unset".
  defp alternate_endpoint?(nil), do: false
  defp alternate_endpoint?(""), do: false

  defp alternate_endpoint?(url) when is_binary(url) do
    not String.contains?(url, "api.anthropic.com")
  end

  # Model the alternate endpoint should serve. Prefer an explicit env var so CI
  # can pick the model without touching config; fall back to app config.
  defp alternate_model do
    System.get_env("ARBOR_ACP_ALTERNATE_MODEL") ||
      Application.get_env(:arbor_ai, :acp_alternate_model)
  end

  defp maybe_put_model(adapter_opts, nil), do: adapter_opts
  defp maybe_put_model(adapter_opts, model), do: Keyword.put(adapter_opts, :model, model)

  defp maybe_put_top_model(opts, nil), do: opts
  defp maybe_put_top_model(opts, model), do: Keyword.put(opts, :model, model)

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
