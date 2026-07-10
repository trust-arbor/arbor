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

  ## Native agent env / args (static config)

  Native ACP agents (a bare `command:`) accept optional operator-configured
  `env:` and `args:`, useful for agents that can talk to multiple backends or
  need an API key / endpoint without a separate external login step:

      config :arbor_ai, :acp_providers, %{
        cursor: %{
          command: ["cursor-agent", "acp"],
          # `args` are appended to the spawned command list:
          args: ["--model", "claude-4-sonnet"],
          # `env` values may be literals OR {:system, "VAR"} references resolved
          # from the OS env at spawn — the by-reference form keeps secrets out of
          # this config file AND the JSON engine context. Unset refs are dropped
          # with a logged warning.
          env: [{"CURSOR_API_KEY", {:system, "CURSOR_API_KEY"}}]
        }
      }

  External authentication (e.g. `cursor-agent login`) remains the default —
  `env`/`args` are purely additive overrides. They are **static-config only**:
  per-launch / secret-bearing launch options are taint- and reference-gated and
  tracked separately (roadmap: acp-launch-options-and-secrets).

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

  require Logger

  @native_providers %{
    gemini: %{command: ["gemini", "--experimental-acp"]},
    # Grok CLI runs its agent over stdio (`grok agent stdio` — JSON-RPC over stdio, per
    # `grok agent --help`). ACP-compliance to be confirmed at first run. Auth out-of-band
    # via `grok login`.
    grok: %{command: ["grok", "agent", "stdio"]},
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
    # ── Permission policy for CLI-agent tools (TWO LAYERS) ──────────────────────────────────
    # ACP tool-use is gated in two places; configure via `adapter_opts` here or per-deployment
    # via `config :arbor_ai, :acp_providers, %{claude: %{adapter_opts: [...]}}`:
    #
    #   Layer 1 — the CLI's OWN permission (adapter_opts):
    #     permission_mode: :bypass  -> `--permission-mode bypassPermissions`; the CLI runs every
    #                                  tool WITHOUT asking (≈ --dangerously-skip-permissions).
    #     permission_mode: :default -> the CLI ASKS for each tool; the request is routed over the
    #                                  SDK stdio permission channel into Arbor's handler (Layer 2).
    #     permission_mode: :deny    -> deny.
    #     allowed_tools:    ["Read","Grep","Glob","LS","Bash"]  -> CLI auto-runs these without
    #                                  asking (use for read-only RECON); others still ask.
    #     disallowed_tools: [...]    -> hard-block these tools.
    #
    #   Layer 2 — Arbor's capability handler (`acp_session/handler.ex`): when the CLI ASKS
    #     (:default mode), Arbor authorizes `arbor://acp/tool/<ToolName>` against the session's
    #     agent_id capabilities. No cap → DENIED. So for :default you must ALSO grant the agent
    #     `arbor://acp/tool/<Tool>` caps, or the ask is rejected.
    #
    # RECON use (e.g. the coding-recon eval): the simplest working policy is `permission_mode:
    # :bypass` (CLI recons freely in its sandboxed cwd — read-only intent). For a tighter policy,
    # use `:default` + `allowed_tools: [read-only tools]` AND grant the matching acp/tool caps.
    # NOTE (2026-07-03): an eval Claude run hit Layer 2 (denied `cd; grep`) despite this :bypass
    # default — the eval's `acp_start_session` wasn't threading the catalog adapter_opts. Fix:
    # ensure the ACP start path merges these adapter_opts (or pass permission_mode explicitly).
    claude: %{
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.ClaudeSDK,
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
  Return task-control capabilities for an ACP provider.

  Stable ACP has no standard in-flight steering request.  The follow-up path is
  therefore always available. `native_steer_configured` preserves an operator's
  future-provider intent, but configuration is not an acknowledgement and never
  reports implemented native delivery.
  """
  @spec task_control_capabilities(atom()) :: %{
          native_steer: boolean(),
          native_steer_acknowledged: false,
          native_steer_configured: boolean(),
          same_session_follow_up: true,
          fallback_mode: :same_session_follow_up
        }
  def task_control_capabilities(provider) when is_atom(provider) do
    config = Application.get_env(:arbor_ai, :acp_providers, %{}) |> Map.get(provider, %{})

    task_control =
      Map.get(config, :task_control) || Map.get(config, "task_control") || %{}

    native_steer =
      Map.get(task_control, :native_steer) || Map.get(task_control, "native_steer") || false

    %{
      native_steer: false,
      native_steer_acknowledged: false,
      native_steer_configured: native_steer == true,
      same_session_follow_up: true,
      fallback_mode: :same_session_follow_up
    }
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
        %{command: command} = native ->
          # Static-config-only env/args for native agents (the stdio transport,
          # ExMCP.Transport.Stdio, reads top-level :command/:cd/:env). These come
          # from the operator-trusted provider config — NOT from per-launch opts.
          # Per-launch / secret-bearing options are taint- and reference-gated and
          # deferred — see .arbor/roadmap inbox acp-launch-options-and-secrets.
          [command: append_args(command, Map.get(native, :args))]
          |> put_static_env(Map.get(native, :env))

        %{transport_mod: mod, adapter: adapter} ->
          adapter_opts =
            Map.get(provider_config, :adapter_opts, [])
            |> Keyword.merge(Keyword.get(opts, :adapter_opts, []))

          [transport_mod: mod, adapter: adapter, adapter_opts: adapter_opts]
      end

    # Forward non-adapter opts. NOTE: :env/:args are intentionally absent — they
    # are static-config-only for native agents (above), so a caller can't inject
    # launch env/flags into a spawned coding agent. Per-launch model selection is
    # handled at the ACP layer (AcpSession.maybe_select_model/3), not here.
    forward_keys = [:model, :system_prompt, :cwd, :timeout, :name, :event_listener]

    Enum.reduce(forward_keys, base, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Keyword.put(acc, key, value)
      end
    end)
  end

  # Append operator-configured extra CLI args to a native agent's command list.
  # For native (stdio) agents, "args" are just extra elements of the :command
  # list the transport spawns. Static config only.
  defp append_args(command, nil), do: command
  defp append_args(command, []), do: command

  defp append_args(command, args) when is_list(args),
    do: command ++ Enum.map(args, &to_string/1)

  # Thread an operator-configured environment into the native stdio transport.
  # Values may be literal strings or `{:system, "VAR"}` references resolved from
  # the OS env at spawn — the by-reference form keeps secrets (API keys, tokens)
  # out of both the arbor config file and the JSON engine context. An unset
  # reference is dropped AND logged (fail-loud: never silently spawn with a
  # missing/empty key, per the "ceilings that fail open are silent" rule).
  defp put_static_env(client_opts, env) when env in [nil, []], do: client_opts

  defp put_static_env(client_opts, env) when is_list(env) do
    case resolve_env(env) do
      [] -> client_opts
      resolved -> Keyword.put(client_opts, :env, resolved)
    end
  end

  defp resolve_env(env) do
    Enum.flat_map(env, fn
      {key, {:system, var}} ->
        case System.get_env(var) do
          nil ->
            Logger.warning(
              "ACP env #{inspect(key)} references unset OS var #{inspect(var)} — dropping it"
            )

            []

          value ->
            [{to_string(key), value}]
        end

      {key, value} ->
        [{to_string(key), to_string(value)}]
    end)
  end
end
