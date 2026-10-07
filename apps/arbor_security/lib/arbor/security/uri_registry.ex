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
      ├── sandbox/{create|destroy|eval}  ← Sandbox facade
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
      └── action/                   ← Schema-bounded Jido actions (Mix, TDD, CodeReview)

  ## Enforcement

  Controlled by config:

      config :arbor_security, uri_registry_enforcement: true

  When false (default during migration), unregistered URIs log a warning
  but are allowed through. When true, unregistered URIs are blocked.

  ## Runtime Registration

  Trusted facades can register their fixed URI projection at startup:

      UriRegistry.register_provider(Arbor.Actions)

  Provider modules must be explicitly configured in
  `:uri_registration_providers` and export `capability_uri_prefixes/0`.
  Callers never supply prefixes to the registry.
  """

  use GenServer

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Security.SupervisedOwner

  require Logger

  @max_provider_prefixes 4_096
  if Mix.env() == :test do
    @test_fixture_anchor {__MODULE__, :test_isolated_fixture}
  end

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
    "arbor://sandbox/eval",

    # Agent facade
    "arbor://agent/spawn",
    "arbor://agent/spawn_worker",
    "arbor://agent/stop",
    "arbor://agent/create",
    "arbor://agent/destroy",
    "arbor://agent/restore",
    "arbor://agent/action",
    "arbor://agent/lifecycle",
    "arbor://agent/intent",
    "arbor://agent/discover_tools",
    "arbor://agent/security_qualification",

    # Chat facade — external chat clients (TUI, mobile) talking to an agent via
    # the Gateway WS API. Per-agent: arbor://chat/agent/<agent_id> (prefix match).
    "arbor://chat/agent/",

    # Memory facade
    "arbor://memory/read",
    "arbor://skill/use",
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
    "arbor://consensus/admin",

    # Approval orchestration facade
    "arbor://approval/read",
    "arbor://approval/answer",

    # Agent orchestration facade
    "arbor://agent/dispatch",
    "arbor://agent/task/read",
    "arbor://agent/task/cancel",
    "arbor://agent/task/steer",
    "arbor://agent/task/adopt",

    # Coding reconciliation read path and exact source-owned CAS apply URIs.
    # Global Orchestrator/Mix --apply stays disabled until every resource kind
    # has equivalent owner-side proof and the fault canaries converge.
    "arbor://coding/reconciliation/read",
    "arbor://coding/reconciliation/apply",

    # Comms facade
    "arbor://comms/send",
    "arbor://comms/poll",
    "arbor://comms/notify/session",
    "arbor://comms/notice/publish",
    "arbor://comms/channel",

    # Signals facade — restricted-topic subscription authorization. Used in
    # live authz (Signals.Bus → CapabilityAuthorizer builds
    # "arbor://signals/subscribe/<topic>") but was previously absent from the
    # canonical registry (Security Sentinel finding, 2026-06-09).
    "arbor://signals/subscribe",
    # Principal-authenticated channel administration and message transport.
    "arbor://signals/channel",

    # Gateway MCP bridge
    "arbor://mcp/",
    # Exact operator approval to connect an MCP server on an agent's behalf:
    # arbor://mcp_server/connect/<sha256(name)>/<config digest> (Imp review D7).
    "arbor://mcp_server/connect",

    # Forge project capability prefix (segment-aware; projector must not match)
    "arbor://forge/project",

    # Gateway tool/status bridges — authorized at call-sites (ClaudeSession
    # tool-use fallback, MCP status disclosure) but were unregistered, so
    # denied under enforcement. (Security Sentinel uri-inventory, 2026-06-09.)
    "arbor://tool/use",
    "arbor://status",

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

    # Eval-only: fixtured injected search for the agentic-safety eval harness
    # (Arbor.Actions.Eval.PoisonedWebSearch). A real namespace so the URI registry
    # doesn't block the eval tool; reachable only via the eval-granted capability.
    "arbor://eval/search",

    # Monitor facade
    "arbor://monitor/read",
    "arbor://monitor/remediate",

    # Trust facade
    "arbor://trust/read",
    "arbor://trust/write",
    # Governance — an always-locked security ceiling (auth_decision
    # @always_locked_uri_classes; authority/profile_resolver ceilings pin it to
    # :ask). A real namespace, not a stale grant. (Security Sentinel, 2026-06-09.)
    "arbor://governance",
    # H13 auto-promote gate (arbor://trust/auto_promote/<target_agent_id>) — used
    # by AutoPromoteGate to authorize trust-profile mutations. Registered after
    # the Security Sentinel found it granted/authorized but unregistered.
    "arbor://trust/auto_promote",

    # Agent identity and profile
    "arbor://agent/identity",
    "arbor://agent/profile",
    # Identity-alias management (arbor://identity/alias/manage) — authorized by
    # `Arbor.Agent.IdentityAliases.link/3` and `unlink/2`, which redirect a
    # principal's future OIDC logins onto a primary account. It was gated but
    # never registered, so the check could not pass for ANY caller and
    # `mix arbor.user.link` was dead on arrival. Same class as the
    # auto_promote/map entries above.
    "arbor://identity/alias",

    # ACP handler
    "arbor://acp/tool",

    # Orchestrator middleware gate (supplementary)
    "arbor://orchestrator/execute",
    # Composition dispatch capability (arbor://orchestrator/map/dispatch) — binds
    # the map/compose handler. Registered after the Security Sentinel found it.
    "arbor://orchestrator/map",
    # Child-graph execution capability (handler_schema binds it).
    "arbor://pipeline/run",

    # Orchestrator handler capabilities — declared via `capability_required/1`
    # on the handler contracts (read/write/compute/compose). Live infra, not a
    # stale trust grant. (Security Sentinel uri-inventory, 2026-06-09.)
    "arbor://handler/",

    # Interactive-disclosure capability convention (VP-05D2A0) — a distinct
    # namespace from ordinary `constraints.egress` refinement. Caps in this
    # namespace are looked up by exact id only (CapabilityStore.get_valid_disclosure/3);
    # this registration is for URI validation / registry-coverage auditing, not
    # a wildcard/prefix authorization path.
    "arbor://egress/disclose",

    # Voice realtime xAI sessions. Capabilities are granted only on a
    # session-qualified child URI so concurrent sessions cannot replace each
    # other in CapabilityStore's principal/resource index.
    "arbor://voice/realtime/xai"

    # Action namespace prefixes are generated and registered by arbor_actions at
    # application start. arbor_security must not own a broad `arbor://action`
    # prefix here: it would also segment-match every future action-shaped URI,
    # defeating the generated registry drift guard.
  ]

  # =========================================================================
  # Public API
  # =========================================================================

  @doc "Start the URI registry GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    opts = test_fixture_child_opts(opts)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Check if a URI matches a registered prefix.

  Returns `true` if the URI starts with any canonical or runtime-registered prefix.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, _parsed} ->
        canonical_match?(uri) or runtime_match?(uri)

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Validate a URI against the registry, respecting enforcement config.

  Returns `:ok` if the URI is registered or enforcement is disabled.
  Returns `{:error, :unregistered_uri}` if enforcement is enabled and URI is not registered.
  """
  @spec validate(String.t()) :: :ok | {:error, :unregistered_uri | {:invalid_uri, term()}}
  def validate(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, _parsed} ->
        validate_registered_uri(uri)

      {:error, reason} ->
        Logger.warning("[UriRegistry] Blocked invalid URI #{inspect(uri)}: #{inspect(reason)}")
        {:error, {:invalid_uri, reason}}
    end
  end

  @doc "Refuse the retired caller-chosen runtime-prefix mutation API."
  @spec register(term()) :: {:error, :uri_mutation_unauthorized}
  def register(_prefix), do: {:error, :uri_mutation_unauthorized}

  @doc """
  Register the fixed capability URI projection of a configured provider.

  The owner process invokes the allowlisted module's
  `capability_uri_prefixes/0`; caller-controlled prefix bytes never cross the
  GenServer boundary.
  """
  @spec register_provider(module()) :: :ok | {:error, atom() | tuple()}
  def register_provider(provider) when is_atom(provider) and not is_nil(provider) do
    owner_call({:register_provider, provider}, {:error, :uri_registry_unavailable})
  end

  def register_provider(_provider), do: {:error, :uri_mutation_unauthorized}

  @doc "Return all registered prefixes (canonical + runtime)."
  @spec all_prefixes() :: [String.t()]
  def all_prefixes do
    runtime = owner_call(:list_runtime, [])

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
  def init(opts) do
    :ok = maybe_register_test_fixture(opts)
    {:ok, %{provider_prefixes: %{}}}
  end

  @impl true
  def handle_call({:register_provider, provider}, _from, state) do
    case load_provider_prefixes(provider) do
      {:ok, prefixes} ->
        new_state = put_in(state, [:provider_prefixes, provider], MapSet.new(prefixes))
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_runtime, _from, state) do
    prefixes =
      state.provider_prefixes
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      |> MapSet.to_list()

    {:reply, prefixes, state}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_request}, state}
  end

  # =========================================================================
  # Private
  # =========================================================================

  defp validate_registered_uri(uri) do
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

  defp canonical_match?(uri) do
    Enum.any?(@canonical_prefixes, &CapabilityUri.prefix_match?(&1, uri))
  end

  defp load_provider_prefixes(provider) do
    with true <- provider in configured_providers(),
         true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :capability_uri_prefixes, 0),
         prefixes <- apply(provider, :capability_uri_prefixes, []),
         :ok <- validate_provider_prefixes(prefixes) do
      {:ok, Enum.uniq(prefixes)}
    else
      _ -> {:error, :uri_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :uri_mutation_unauthorized}
  catch
    _, _ -> {:error, :uri_mutation_unauthorized}
  end

  defp configured_providers do
    case Application.get_env(:arbor_security, :uri_registration_providers, []) do
      providers when is_list(providers) ->
        providers
        |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
        |> Enum.take(32)

      _ ->
        []
    end
  end

  defp validate_provider_prefixes(prefixes)
       when is_list(prefixes) and length(prefixes) <= @max_provider_prefixes do
    if Enum.all?(prefixes, &valid_provider_prefix?/1),
      do: :ok,
      else: {:error, :invalid_provider_prefixes}
  end

  defp validate_provider_prefixes(_prefixes), do: {:error, :invalid_provider_prefixes}

  defp valid_provider_prefix?(prefix) when is_binary(prefix) do
    byte_size(prefix) <= 1_024 and match?({:ok, _parsed}, CapabilityUri.parse(prefix))
  end

  defp valid_provider_prefix?(_prefix), do: false

  defp runtime_match?(uri) do
    case owner_call(:list_runtime, []) do
      [] -> false
      prefixes -> Enum.any?(prefixes, &CapabilityUri.prefix_match?(&1, uri))
    end
  end

  defp owner_call(request, unavailable) do
    case owner_pid() do
      pid when is_pid(pid) -> GenServer.call(pid, request)
      nil -> unavailable
    end
  rescue
    _ -> unavailable
  catch
    :exit, _ -> unavailable
  end

  defp owner_pid do
    SupervisedOwner.registered_child(__MODULE__, :arbor_security, [__MODULE__]) ||
      test_isolated_owner_pid()
  end

  if Mix.env() == :test do
    defp test_fixture_child_opts(opts), do: Keyword.put(opts, :test_isolated_owner, true)

    defp maybe_register_test_fixture(opts) do
      if Keyword.get(opts, :test_isolated_owner, false) == true do
        :persistent_term.put(@test_fixture_anchor, self())
      end

      :ok
    end

    defp test_isolated_owner_pid do
      case :persistent_term.get(@test_fixture_anchor, nil) do
        pid when is_pid(pid) ->
          if Process.alive?(pid) and Process.whereis(__MODULE__) == pid, do: pid, else: nil

        _ ->
          nil
      end
    end
  else
    defp test_fixture_child_opts(opts), do: opts
    defp maybe_register_test_fixture(_opts), do: :ok
    defp test_isolated_owner_pid, do: nil
  end
end
