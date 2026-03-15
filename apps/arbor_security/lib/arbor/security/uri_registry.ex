defmodule Arbor.Security.UriRegistry do
  @moduledoc """
  Canonical URI registry for deny-by-default authorization.

  All valid capability URIs must be registered here. When enforcement is
  enabled, `Security.authorize/4` rejects any URI that doesn't match a
  registered prefix — preventing shadow capabilities where an unregistered
  URI path could bypass authorization.

  ## URI Hierarchy

      arbor://
      ├── shell/exec/              ← Shell facade
      ├── historian/query/          ← Historian facade
      ├── persistence/{read|write}/ ← Persistence facade
      ├── sandbox/{create|destroy}  ← Sandbox facade
      ├── agent/{spawn|stop|...}    ← Agent facade
      ├── memory/{read|write|...}/  ← Memory facade
      ├── consensus/{propose|...}   ← Consensus facade
      ├── mcp/{server}/             ← Gateway MCP bridge
      ├── fs/{read|write|...}/      ← FileGuard
      ├── code/{hot_load|...}/      ← Code operations
      ├── ai/{generate|request}/    ← AI facade
      ├── acp/tool/                 ← ACP handler
      ├── net/{http|search}         ← Network operations
      ├── orchestrator/execute/     ← Pipeline middleware gate
      └── actions/execute/          ← Legacy action-level (transitional)

  ## Enforcement

  Controlled by config:

      config :arbor_security, uri_registry_enforcement: true

  When false (default during migration), unregistered URIs log a warning
  but are allowed through. When true, unregistered URIs are blocked.

  ## Runtime Registration

  New facades can register URIs at startup:

      UriRegistry.register("arbor://my_facade/operation")
  """

  use GenServer

  require Logger

  # Canonical URI prefixes — the authoritative set of valid capability URIs.
  # Each entry is a prefix: "arbor://shell/exec" matches "arbor://shell/exec/git".
  @canonical_prefixes [
    # Shell facade
    "arbor://shell/exec",

    # Historian facade
    "arbor://historian/query",

    # Persistence facade
    "arbor://persistence/read",
    "arbor://persistence/write",
    "arbor://persistence/append",

    # Sandbox facade
    "arbor://sandbox/create",
    "arbor://sandbox/destroy",

    # Agent facade
    "arbor://agent/spawn",
    "arbor://agent/stop",
    "arbor://agent/create",
    "arbor://agent/destroy",
    "arbor://agent/restore",
    "arbor://agent/action",
    "arbor://agent/lifecycle",
    "arbor://agent/intent",

    # Memory facade
    "arbor://memory/read",
    "arbor://memory/write",
    "arbor://memory/search",
    "arbor://memory/init",
    "arbor://memory/cleanup",
    "arbor://memory/index",
    "arbor://memory/recall",
    "arbor://memory/add_knowledge",

    # Consensus facade
    "arbor://consensus/propose",
    "arbor://consensus/ask",
    "arbor://consensus/decide",
    "arbor://consensus/cancel",
    "arbor://consensus/force_approve",
    "arbor://consensus/force_reject",

    # Comms facade
    "arbor://comms/send",
    "arbor://comms/poll",
    "arbor://comms/channel",

    # Gateway MCP bridge
    "arbor://mcp/",

    # FileGuard (filesystem operations)
    "arbor://fs/read",
    "arbor://fs/write",
    "arbor://fs/execute",
    "arbor://fs/delete",
    "arbor://fs/list",

    # Code operations
    "arbor://code/hot_load",
    "arbor://code/read",
    "arbor://code/write",
    "arbor://code/reload",
    "arbor://code/compile",

    # AI facade
    "arbor://ai/generate",
    "arbor://ai/request",

    # Network operations
    "arbor://net/http",
    "arbor://net/search",

    # Monitor facade
    "arbor://monitor/read",
    "arbor://monitor/remediate",

    # Trust facade
    "arbor://trust/read",
    "arbor://trust/write",

    # Agent identity and profile
    "arbor://agent/identity",
    "arbor://agent/profile",

    # ACP handler
    "arbor://acp/tool",

    # Orchestrator middleware gate (supplementary)
    "arbor://orchestrator/execute",

    # Legacy action-level URIs (transitional — will be removed)
    "arbor://actions/execute"
  ]

  # =========================================================================
  # Public API
  # =========================================================================

  @doc "Start the URI registry GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a URI matches a registered prefix.

  Returns `true` if the URI starts with any canonical or runtime-registered prefix.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(uri) when is_binary(uri) do
    # Check compile-time prefixes first (fast path)
    canonical_match?(uri) or runtime_match?(uri)
  end

  @doc """
  Validate a URI against the registry, respecting enforcement config.

  Returns `:ok` if the URI is registered or enforcement is disabled.
  Returns `{:error, :unregistered_uri}` if enforcement is enabled and URI is not registered.
  """
  @spec validate(String.t()) :: :ok | {:error, :unregistered_uri}
  def validate(uri) when is_binary(uri) do
    if registered?(uri) do
      :ok
    else
      if enforcement_enabled?() do
        Logger.warning("[UriRegistry] Blocked unregistered URI: #{uri}")
        {:error, :unregistered_uri}
      else
        Logger.debug("[UriRegistry] Unregistered URI (allowed, enforcement off): #{uri}")
        :ok
      end
    end
  end

  @doc """
  Register a new URI prefix at runtime.

  Used by facades that register their URIs at startup.
  """
  @spec register(String.t()) :: :ok
  def register(prefix) when is_binary(prefix) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:register, prefix})
    else
      Logger.debug("[UriRegistry] Not running, skipping registration of #{prefix}")
      :ok
    end
  end

  @doc "Return all registered prefixes (canonical + runtime)."
  @spec all_prefixes() :: [String.t()]
  def all_prefixes do
    runtime =
      if Process.whereis(__MODULE__) do
        GenServer.call(__MODULE__, :list_runtime)
      else
        []
      end

    @canonical_prefixes ++ runtime
  end

  @doc "Return only the canonical (compile-time) prefixes."
  @spec canonical_prefixes() :: [String.t()]
  def canonical_prefixes, do: @canonical_prefixes

  @doc "Check if enforcement is enabled."
  @spec enforcement_enabled?() :: boolean()
  def enforcement_enabled? do
    Application.get_env(:arbor_security, :uri_registry_enforcement, true)
  end

  # =========================================================================
  # GenServer callbacks
  # =========================================================================

  @impl true
  def init(_opts) do
    {:ok, %{runtime_prefixes: MapSet.new()}}
  end

  @impl true
  def handle_call({:register, prefix}, _from, state) do
    new_state = %{state | runtime_prefixes: MapSet.put(state.runtime_prefixes, prefix)}
    {:reply, :ok, new_state}
  end

  def handle_call(:list_runtime, _from, state) do
    {:reply, MapSet.to_list(state.runtime_prefixes), state}
  end

  # =========================================================================
  # Private
  # =========================================================================

  defp canonical_match?(uri) do
    Enum.any?(@canonical_prefixes, &String.starts_with?(uri, &1))
  end

  defp runtime_match?(uri) do
    if Process.whereis(__MODULE__) do
      case GenServer.call(__MODULE__, :list_runtime) do
        [] -> false
        prefixes -> Enum.any?(prefixes, &String.starts_with?(uri, &1))
      end
    else
      false
    end
  end
end
