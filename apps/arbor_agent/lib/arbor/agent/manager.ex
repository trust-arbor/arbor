defmodule Arbor.Agent.Manager do
  @moduledoc """
  Stateless coordination for agent lifecycle.

  Wraps `Arbor.Agent.Supervisor` and `Arbor.Agent.Registry` with
  signal emissions so all consumers (dashboard, CLI, gateway) stay in sync.

  No GenServer — just function calls. Nothing to crash.

  ## Signal Events

  All lifecycle events are emitted on the `:agent` signal category:

  - `{:agent, :started}` — agent started with `%{agent_id, model_config}`
  - `{:agent, :stopped}` — agent stopped with `%{agent_id}`
  - `{:agent, :chat_message}` — external chat message with `%{role, content, sender}`

  Consumers subscribe via `Arbor.Signals.subscribe("agent.*", handler)` or
  `Arbor.Web.SignalLive.subscribe_raw(socket, "agent.*")`.
  """

  alias Arbor.Agent.{APIAgent, Claude, Lifecycle, ProfileStore, SystemLifecycleAuthority}
  alias Arbor.Contracts.Security.CapabilityUri

  require Logger

  @default_sender "Unknown Sender"

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start an agent under the Arbor.Agent.Supervisor.

  Creates a cryptographic identity via `Lifecycle.create/2`, then starts
  the agent process. The agent_id is derived from the Ed25519 public key.

  Returns `{:ok, agent_id, pid}` or `{:error, reason}`.
  """
  @spec start_agent(map(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_agent(model_config, opts \\ []) do
    cond do
      # Explicit node targeting
      Keyword.has_key?(opts, :spawn_on) ->
        target = Keyword.fetch!(opts, :spawn_on)
        spawn_on_remote(target, model_config, Keyword.delete(opts, :spawn_on))

      # Capability-based scheduling
      Keyword.has_key?(opts, :requirements) ->
        requirements = Keyword.fetch!(opts, :requirements)
        strategy = Keyword.get(opts, :strategy, :least_loaded)
        clean_opts = opts |> Keyword.delete(:requirements) |> Keyword.delete(:strategy)

        case schedule_and_spawn(requirements, strategy, model_config, clean_opts) do
          {:ok, _, _} = result -> result
          {:error, _} = error -> error
        end

      # Local spawn (default)
      true ->
        do_start_agent(model_config, opts)
    end
  end

  defp schedule_and_spawn(requirements, strategy, model_config, opts) do
    scheduler = Arbor.Cartographer.Scheduler

    if Code.ensure_loaded?(scheduler) do
      case apply(scheduler, :select_node, [[requirements: requirements, strategy: strategy]]) do
        {:ok, node} ->
          if node == Node.self() do
            do_start_agent(model_config, opts)
          else
            Logger.info("Scheduler selected #{node} for requirements: #{inspect(requirements)}")
            spawn_on_remote(node, model_config, opts)
          end

        {:error, :no_matching_node} ->
          {:error, {:no_matching_node, requirements}}
      end
    else
      {:error, :scheduler_not_available}
    end
  end

  defp spawn_on_remote(target_node, model_config, opts) do
    case :net_adm.ping(target_node) do
      :pong ->
        case :rpc.call(
               target_node,
               __MODULE__,
               :start_agent,
               [model_config, opts],
               60_000
             ) do
          {:ok, agent_id, pid} ->
            Logger.info("Agent #{agent_id} started on remote node #{target_node}")
            {:ok, agent_id, pid}

          {:error, _} = error ->
            error

          {:badrpc, reason} ->
            {:error, {:remote_spawn_failed, target_node, reason}}
        end

      :pang ->
        {:error, {:node_unreachable, target_node}}
    end
  end

  defp do_start_agent(model_config, opts) do
    display_name = Keyword.get(opts, :display_name, default_display_name(model_config))

    template =
      Keyword.get(opts, :template) ||
        Map.get(model_config, :template) ||
        resolve_template(model_config)

    # Build a fully-resolved AgentSpec — single source of truth for all agent config.
    # This resolves template, model, tools in one pure function.
    spec_opts =
      [
        display_name: display_name,
        template: template,
        model_config: model_config
      ] ++
        Keyword.take(opts, [
          :capabilities,
          :initial_goals,
          :delegator_id,
          :tenant_context,
          :character
        ])

    with {:ok, spec} <- Arbor.Agent.Spec.new(spec_opts),
         lifecycle_opts =
           spec
           |> Arbor.Agent.Spec.to_lifecycle_opts()
           |> Keyword.put(:actor_authority, Keyword.get(opts, :actor_authority)),
         {:ok, profile} <- Lifecycle.create(display_name, lifecycle_opts) do
      # Persist model config for resume
      updated_profile = put_in(profile.metadata[:last_model_config], model_config)

      try do
        ProfileStore.store_profile(updated_profile)
      rescue
        e ->
          Logger.warning(
            "[Manager] Failed to persist agent profile on create: #{Exception.message(e)}"
          )
      end

      agent_id = updated_profile.agent_id

      # Start via Lifecycle — creates BranchSupervisor with all sub-processes
      # and registers in Agent.Registry
      start_opts =
        Keyword.merge(opts,
          model: spec.model,
          provider: spec.provider,
          model_config: model_config
        )

      case Lifecycle.start(agent_id, start_opts) do
        {:ok, pid} ->
          connect_mcp_servers(agent_id)
          safe_emit(:started, %{agent_id: agent_id, pid: pid, model_config: model_config})
          {:ok, agent_id, pid}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Resume a previously created agent from its persisted profile.

  Restores the agent's identity, capabilities, and last model configuration,
  then starts the agent process under supervision.

  Returns `{:ok, agent_id, pid}` or `{:error, reason}`.
  """
  @spec resume_agent(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def resume_agent(agent_id, opts \\ []) do
    with {:ok, profile} <- Lifecycle.restore(agent_id) do
      # Prefer caller-provided model_config, fall back to persisted, then default
      model_config =
        Keyword.get(opts, :model_config) ||
          get_in(profile.metadata, [:last_model_config]) ||
          get_in(profile.metadata, ["last_model_config"]) ||
          default_model_config()

      # Persisted configs have string keys — atomize
      model_config = atomize_model_config(model_config)

      # Sync model config to profile if it changed (prevents stale provider bugs)
      sync_model_config(agent_id, profile, model_config)

      # Start via Lifecycle — creates BranchSupervisor with all sub-processes
      start_opts =
        Keyword.merge(opts,
          model:
            model_config[:id] || model_config["id"] || model_config[:model] ||
              model_config["model"],
          provider: model_config[:provider] || model_config["provider"],
          model_config: model_config
        )

      case Lifecycle.start(agent_id, start_opts) do
        {:ok, pid} ->
          connect_mcp_servers(agent_id)
          safe_emit(:started, %{agent_id: agent_id, pid: pid, model_config: model_config})
          {:ok, agent_id, pid}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Start or resume a system agent with stable identity.

  Searches for an existing profile matching `display_name` and `template`.
  If found, resumes that agent. If not found, creates a new identity and starts fresh.

  This is the preferred way to start system agents (like DebugAgent) that need
  stable identity across restarts.

  The `model_config` map must include a `:module` key specifying the GenServer module.

  ## Options

  - `:template` — agent template module (required for identity matching)
  - `:display_name` — display name for the agent (default: from model_config)
  - All other options from `start_agent/2` and `resume_agent/2`

  ## Examples

      Manager.start_or_resume(DebugAgent, "debug-agent",
        template: Diagnostician,
        model_config: %{id: "haiku", provider: :anthropic, runtime: :arbor}
      )
  """
  @spec start_or_resume(module(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_or_resume(module, display_name, opts \\ []) do
    template = Keyword.get(opts, :template)
    model_config = Keyword.get(opts, :model_config, default_model_config())
    model_config = Map.put(model_config, :module, module)

    case find_existing_profile(display_name, template) do
      {:ok, agent_id} ->
        Logger.info("[Manager] Resuming #{display_name} with identity #{agent_id}")
        resume_agent(agent_id, Keyword.put(opts, :model_config, model_config))

      :not_found ->
        Logger.info("[Manager] Creating new identity for #{display_name}")

        start_agent(
          model_config,
          Keyword.merge(opts, display_name: display_name)
        )
    end
  end

  @doc """
  Stop a running agent by ID.

  Stops the lifecycle (session, executor, host) first, then the supervised process.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) do
    # Stop lifecycle components (session, executor, host) first
    try do
      Lifecycle.stop(agent_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Then stop the supervised agent process
    Arbor.Agent.Supervisor.stop_agent_by_id(agent_id)

    safe_emit(:stopped, %{agent_id: agent_id})
    :ok
  end

  @doc """
  Stop an agent by its observed owner PID (Phase 4C C2B exact-owner stop).

  Terminates the observed BranchSupervisor process directly via
  `Arbor.Agent.Supervisor.stop_agent/1` — NO re-resolution by mutable logical
  agent id, NO registry lookup, NO `Lifecycle.stop/1`. The rest_for_one
  supervisor cascade tears down session/executor/host. Ordinary by-id
  `stop_agent/1` / `Lifecycle` behavior is unchanged.
  """
  @spec stop_owner(pid()) :: :ok | {:error, :not_found}
  def stop_owner(owner_pid) when is_pid(owner_pid) do
    Arbor.Agent.Supervisor.stop_agent(owner_pid)
  end

  @doc """
  Set the auto_start flag on an agent's persisted profile.

  Auto-start agents are started with no human present, by
  `Arbor.Agent.Bootstrap` on boot and by `Arbor.Agent.Reconciler` when absent,
  through the system lifecycle principal (`Arbor.Agent.SystemLifecycleAuthority`).
  That principal holds no rights of its own: this call is the human's
  delegation. It requires the human's `:actor_authority`; the legacy arity
  fails closed with `{:error, :capability_mutation_unauthorized}`.

  Enabling first checks that the human holds every
  `SystemLifecycleAuthority.delegated_resources/1` right over the agent (so only
  a human who holds them can delegate them), grants the missing ones to the
  principal with the human's authority, and only then persists
  `auto_start: true`. If a grant or the write fails, the grants made by this
  call are revoked and the flag stays unchanged.

  Disabling revokes the principal's delegated capabilities for the agent, then
  persists `auto_start: false`. If a revocation fails, the flag stays unchanged
  and the call can be retried.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_auto_start(String.t(), boolean()) :: {:error, :capability_mutation_unauthorized}
  def set_auto_start(_agent_id, _enabled), do: {:error, :capability_mutation_unauthorized}

  @spec set_auto_start(String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def set_auto_start(agent_id, enabled, opts)
      when is_binary(agent_id) and is_boolean(enabled) and is_list(opts) do
    with {:ok, actor_authority} <- auto_start_actor_authority(opts),
         {:ok, profile} <- ProfileStore.load_profile(agent_id),
         {:ok, principal_id} <- SystemLifecycleAuthority.principal_id() do
      resources = SystemLifecycleAuthority.delegated_resources(agent_id)

      if enabled,
        do: enable_auto_start(profile, principal_id, resources, actor_authority),
        else: disable_auto_start(profile, principal_id, resources, actor_authority)
    end
  end

  def set_auto_start(_agent_id, _enabled, _opts), do: {:error, :invalid_args}

  defp auto_start_actor_authority(opts) do
    case Keyword.get(opts, :actor_authority) do
      nil -> {:error, :capability_mutation_unauthorized}
      authority -> {:ok, authority}
    end
  end

  defp enable_auto_start(profile, principal_id, resources, actor_authority) do
    with {:ok, actor_id} <- auto_start_actor_id(actor_authority),
         :ok <- require_actor_holds(actor_id, resources),
         {:ok, held} <- delegated_capabilities(principal_id, resources),
         held_uris =
           held
           |> Enum.filter(&Arbor.Security.capability_authorizes?(&1, &1.resource_uri))
           |> MapSet.new(& &1.resource_uri),
         missing = Enum.reject(resources, &MapSet.member?(held_uris, &1)),
         {:ok, granted} <- grant_delegations(principal_id, missing, actor_authority) do
      case store_auto_start(profile, true) do
        :ok ->
          :ok

        {:error, _} = error ->
          _ = revoke_delegations(granted, actor_authority)
          error
      end
    end
  end

  defp disable_auto_start(profile, principal_id, resources, actor_authority) do
    with {:ok, held} <- delegated_capabilities(principal_id, resources),
         :ok <- revoke_delegations(Enum.map(held, & &1.id), actor_authority) do
      store_auto_start(profile, false)
    end
  end

  defp auto_start_actor_id(actor_authority) do
    case Arbor.Security.signing_authority_principal(actor_authority) do
      {:ok, actor_id} -> {:ok, actor_id}
      _ -> {:error, :capability_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :capability_mutation_unauthorized}
  catch
    _, _ -> {:error, :capability_mutation_unauthorized}
  end

  # Delegation may not exceed what the human holds over the agent.
  defp require_actor_holds(actor_id, resources) do
    with {:ok, capabilities} <- Arbor.Security.list_capabilities(actor_id),
         true <-
           Enum.all?(resources, fn resource ->
             Enum.any?(capabilities, &Arbor.Security.capability_authorizes?(&1, resource))
           end) do
      :ok
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  defp delegated_capabilities(principal_id, resources) do
    case Arbor.Security.list_capabilities(principal_id) do
      {:ok, capabilities} -> {:ok, Enum.filter(capabilities, &(&1.resource_uri in resources))}
      {:error, reason} -> {:error, {:auto_start_delegation_lookup_failed, reason}}
    end
  end

  defp grant_delegations(principal_id, resources, actor_authority) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, granted} ->
      case Arbor.Security.grant(
             principal: principal_id,
             resource: resource,
             actor_authority: actor_authority
           ) do
        {:ok, capability} ->
          {:cont, {:ok, [capability.id | granted]}}

        {:error, reason} ->
          _ = revoke_delegations(granted, actor_authority)
          {:halt, {:error, {:auto_start_delegation_failed, reason}}}
      end
    end)
  end

  defp revoke_delegations(capability_ids, actor_authority) do
    Enum.reduce_while(capability_ids, :ok, fn capability_id, :ok ->
      case Arbor.Security.revoke(capability_id, actor_authority: actor_authority) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:auto_start_revocation_failed, reason}}}
      end
    end)
  end

  defp store_auto_start(profile, enabled) do
    case ProfileStore.store_profile(%{profile | auto_start: enabled}) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:auto_start_store_failed, other}}
    end
  end

  @doc """
  Update an agent's display name.

  Persists the new name in the agent's profile. Emits an
  `agent.display_name_changed` signal so the dashboard updates.
  """
  @spec set_display_name(String.t(), String.t()) :: :ok | {:error, term()}
  def set_display_name(agent_id, name)
      when is_binary(agent_id) and is_binary(name) and byte_size(name) >= 1 do
    case ProfileStore.load_profile(agent_id) do
      {:ok, profile} ->
        updated = %{profile | display_name: name}
        ProfileStore.store_profile(updated)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Set the MCP server configuration for an agent.

  The config is a list of server connection specs stored in the agent's
  profile metadata. On next start/resume, the agent will auto-connect
  to these MCP servers.

  This call is the operator's consent: for each server it grants the agent a
  capability bound to that server's exact config
  (`Arbor.Security.mcp_server_approval_uri/2`) and revokes approvals for
  servers no longer listed. `Arbor.Gateway.connect_mcp_server/2` refuses an
  agent-bound connection without it, so metadata written any other way (or
  edited afterwards) does not connect (Imp review D7, 2026-09-28). Every server
  needs a non-empty `:name`.

  ## Server Config

  Each server spec is a map with:
  - `:name` — unique server name (required)
  - `:transport` — `:stdio`, `:http`, `:sse`, or `:beam` (default: `:stdio`)
  - `:command` — command for stdio transport
  - `:url` — URL for HTTP/SSE transport
  - `:env` — environment variables map
  - `:auto_discover` — discover tools/resources on connect (default: true)

  ## Example

      Manager.set_mcp_config(
        agent_id,
        [
          %{name: "github", transport: :stdio, command: ["npx", "@modelcontextprotocol/server-github"]},
          %{name: "filesystem", transport: :stdio, command: ["npx", "@modelcontextprotocol/server-filesystem", "/workspace"]}
        ],
        actor_authority: operator_authority
      )
  """
  @spec set_mcp_config(String.t(), [map()]) ::
          {:error, :capability_mutation_unauthorized}
  def set_mcp_config(_agent_id, _servers), do: {:error, :capability_mutation_unauthorized}

  @spec set_mcp_config(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def set_mcp_config(agent_id, servers, opts)
      when is_binary(agent_id) and is_list(servers) and is_list(opts) do
    actor_authority = Keyword.get(opts, :actor_authority)

    with {:ok, profile} <- ProfileStore.load_profile(agent_id),
         false <- is_nil(actor_authority),
         {:ok, approval_uris} <- mcp_server_approval_uris(servers),
         :ok <- reconcile_mcp_server_approvals(agent_id, approval_uris, actor_authority) do
      metadata = Map.put(profile.metadata || %{}, :mcp_servers, servers)
      ProfileStore.store_profile(%{profile | metadata: metadata})
    else
      true -> {:error, :capability_mutation_unauthorized}
      {:error, _} = error -> error
    end
  end

  defp mcp_server_approval_uris(servers) do
    Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
      name = is_map(server) && (Map.get(server, :name) || Map.get(server, "name"))

      case is_binary(name) && Arbor.Security.mcp_server_approval_uri(name, server) do
        {:ok, uri} -> {:cont, {:ok, [uri | acc]}}
        _invalid -> {:halt, {:error, {:invalid_mcp_server, server}}}
      end
    end)
  end

  # Grant each wanted approval the agent lacks and revoke held approvals that
  # are no longer wanted, so the capability set mirrors the configured list.
  defp reconcile_mcp_server_approvals(agent_id, wanted, actor_authority) do
    prefix = Arbor.Security.mcp_server_approval_prefix()

    with {:ok, caps} <- Arbor.Security.list_capabilities(agent_id) do
      held =
        Enum.filter(caps, &CapabilityUri.prefix_match?(prefix, &1.resource_uri))

      held_uris = MapSet.new(held, & &1.resource_uri)
      wanted = MapSet.new(wanted)

      with :ok <-
             grant_missing(agent_id, MapSet.difference(wanted, held_uris), actor_authority) do
        held
        |> Enum.reject(&MapSet.member?(wanted, &1.resource_uri))
        |> revoke_all(actor_authority)
      end
    end
  end

  defp grant_missing(agent_id, uris, actor_authority) do
    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      case Arbor.Security.grant(
             principal: agent_id,
             resource: uri,
             actor_authority: actor_authority
           ) do
        {:ok, _cap} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mcp_server_approval_failed, reason}}}
      end
    end)
  end

  defp revoke_all(caps, actor_authority) do
    Enum.reduce_while(caps, :ok, fn cap, :ok ->
      case Arbor.Security.revoke(cap.id, actor_authority: actor_authority) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mcp_server_approval_revoke_failed, reason}}}
      end
    end)
  end

  @doc """
  Connect to MCP servers configured in an agent's profile.

  Reads `profile.metadata["mcp_servers"]` or `profile.metadata[:mcp_servers]`
  and connects to each via `Arbor.Gateway.connect_mcp_server/2`.

  Called automatically on agent start/resume. Can also be called manually.
  """
  @spec connect_mcp_servers(String.t()) :: :ok
  def connect_mcp_servers(agent_id) when is_binary(agent_id) do
    with {:ok, profile} <- ProfileStore.load_profile(agent_id) do
      servers =
        get_in(profile.metadata, [:mcp_servers]) ||
          get_in(profile.metadata, ["mcp_servers"]) ||
          []

      connect_mcp_server_list(agent_id, servers)
    else
      _ -> :ok
    end
  end

  @doc """
  Connect to MCP servers from a list of server configs.

  Uses runtime bridge to Arbor.Gateway (no compile-time dependency).
  """
  @spec connect_mcp_server_list(String.t(), [map()]) :: :ok
  def connect_mcp_server_list(_agent_id, []), do: :ok

  def connect_mcp_server_list(agent_id, servers) when is_list(servers) do
    if gateway_available?() do
      Enum.each(servers, &connect_single_mcp_server(agent_id, &1))
    end

    :ok
  end

  @doc """
  Find a running agent by ID.

  Returns `{:ok, pid, metadata}` or `:not_found`.
  """
  @spec find_agent(String.t()) :: {:ok, pid(), map()} | :not_found
  def find_agent(agent_id) do
    case Arbor.Agent.Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.pid, entry.metadata}
      {:error, :not_found} -> :not_found
    end
  end

  @doc """
  Find an agent by display name (searches persisted profiles).

  Returns `{:ok, agent_id}` if a profile with that display_name exists,
  or `:not_found`. The agent may or may not be running.
  """
  @spec find_agent_by_name(String.t()) :: {:ok, String.t()} | :not_found
  def find_agent_by_name(display_name) when is_binary(display_name) do
    profiles = Arbor.Agent.Lifecycle.list_agents()

    case Enum.find(profiles, fn p -> p.display_name == display_name end) do
      %{agent_id: agent_id} -> {:ok, agent_id}
      nil -> :not_found
    end
  rescue
    _ -> :not_found
  end

  @doc """
  Find the first running agent (any ID).

  Returns `{:ok, agent_id, pid, metadata}` or `:not_found`.
  """
  @spec find_first_agent() :: {:ok, String.t(), pid(), map()} | :not_found
  def find_first_agent do
    case Arbor.Agent.Registry.list() do
      {:ok, [entry | _]} -> {:ok, entry.agent_id, entry.pid, entry.metadata}
      {:ok, []} -> :not_found
      _ -> :not_found
    end
  end

  @doc """
  Find the first running agent belonging to a specific principal.

  Checks registry metadata for `created_by` matching the principal_id.
  Falls back to `find_first_agent/0` if no principal-scoped agents are found,
  ensuring backward compatibility during migration to multi-user.

  Returns `{:ok, agent_id, pid, metadata}` or `:not_found`.
  """
  @spec find_agent_for_principal(String.t()) ::
          {:ok, String.t(), pid(), map()} | :not_found
  def find_agent_for_principal(principal_id) when is_binary(principal_id) do
    case Arbor.Agent.Registry.list() do
      {:ok, entries} ->
        # First try: find agents created by this principal
        case Enum.find(entries, fn e ->
               Map.get(e.metadata, :created_by) == principal_id or
                 Map.get(e.metadata, "created_by") == principal_id
             end) do
          %{agent_id: id, pid: pid, metadata: meta} ->
            {:ok, id, pid, meta}

          nil ->
            # Fallback: if no agents have created_by set (pre-multi-user agents),
            # return the first one for backward compatibility
            case entries do
              [entry | _] -> {:ok, entry.agent_id, entry.pid, entry.metadata}
              [] -> :not_found
            end
        end

      _ ->
        :not_found
    end
  end

  @doc """
  List all running agents belonging to a specific principal.

  Returns agents whose metadata `created_by` matches the principal_id,
  plus any agents without a `created_by` field (pre-multi-user agents).
  """
  @spec list_agents_for_principal(String.t()) :: [map()]
  def list_agents_for_principal(principal_id) when is_binary(principal_id) do
    case Arbor.Agent.Registry.list() do
      {:ok, entries} ->
        Enum.filter(entries, fn e ->
          created_by = Map.get(e.metadata, :created_by) || Map.get(e.metadata, "created_by")
          # Include if created by this principal OR if no creator set (legacy)
          created_by == principal_id or created_by == nil
        end)

      _ ->
        []
    end
  end

  @doc """
  Send a message to the agent and emit the conversation as signals.

  This allows external callers (e.g., Claude Code via Tidewave) to have
  conversations with the agent that are visible to any signal subscriber.

  The first argument may be a bare string or an
  `Arbor.Contracts.Session.UserMessage` envelope (engagement-tagged, with an
  authoritative `sent_at`). The envelope is passed through unchanged to the
  live Session path.

  The `sender` label identifies who sent the message for signals (e.g., "Hysun",
  "Unknown Sender"). If no `:agent_id` is provided, uses the first running agent.
  """
  @spec chat(
          String.t() | Arbor.Contracts.Session.UserMessage.t(),
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def chat(input, sender \\ @default_sender, opts \\ []) do
    input
    |> chat_response(sender, opts)
    |> handle_query_result()
  end

  @doc """
  Send a message to the agent and return the structured runtime response.

  This is the same dispatch path as `chat/3`, but preserves fields such as
  tool-call history, usage, model, and provider for orchestration callers that
  need artifacts rather than final assistant text only.

  Accepts a bare string or an `Arbor.Contracts.Session.UserMessage` envelope.
  """
  @spec chat_response(
          String.t() | Arbor.Contracts.Session.UserMessage.t(),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def chat_response(input, sender \\ @default_sender, opts \\ []) do
    agent_result =
      case Keyword.get(opts, :agent_id) do
        nil ->
          find_first_agent()

        id ->
          case find_agent(id) do
            {:ok, pid, meta} -> {:ok, id, pid, meta}
            :not_found -> :not_found
          end
      end

    case agent_result do
      {:ok, _agent_id, _pid, metadata} ->
        safe_emit(:chat_message, %{
          role: :user,
          content: chat_signal_content(input),
          sender: sender
        })

        dispatch_query_response(metadata, input, opts)

      :not_found ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Authenticated chat: deliver a route-free `UserMessage` + opaque delivery
  receipt to the live Session via `SessionManager`, returning assistant text.

  Does not touch APIAgent/Claude. Receipt is the dedicated 3rd argument — never
  placed in opts, signals, or process state.
  """
  @spec chat_authenticated(
          Arbor.Contracts.Session.UserMessage.t(),
          String.t(),
          Arbor.Contracts.Security.DeliveryReceipt.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def chat_authenticated(
        %Arbor.Contracts.Session.UserMessage{} = message,
        sender,
        receipt,
        opts
      )
      when is_binary(sender) and is_list(opts) and
             is_struct(receipt, Arbor.Contracts.Security.DeliveryReceipt) do
    case chat_response_authenticated(message, sender, receipt, opts) do
      {:ok, %Arbor.Contracts.Pipeline.Response{} = response} ->
        {:ok, Arbor.Contracts.Pipeline.Response.content(response)}

      other ->
        other
    end
  end

  def chat_authenticated(_message, _sender, _receipt, _opts), do: {:error, :invalid_args}

  @doc """
  Authenticated structured chat: same Session bridge as `chat_authenticated/4`,
  returning a type-projected `%Arbor.Contracts.Pipeline.Response{}`.

  Emits the user `chat_message` signal only. The assistant signal is emitted by
  `MessageFacade` **after** call-local secret admission, so a malicious Session
  cannot surface proof/bearer material via signals before reject. Does not
  receive or forward the raw session proof.
  """
  @spec chat_response_authenticated(
          Arbor.Contracts.Session.UserMessage.t(),
          String.t(),
          Arbor.Contracts.Security.DeliveryReceipt.t(),
          keyword()
        ) ::
          {:ok, Arbor.Contracts.Pipeline.Response.t()} | {:error, term()}
  def chat_response_authenticated(
        %Arbor.Contracts.Session.UserMessage{} = message,
        sender,
        receipt,
        opts
      )
      when is_binary(sender) and is_list(opts) and
             is_struct(receipt, Arbor.Contracts.Security.DeliveryReceipt) do
    agent_id = Keyword.get(opts, :agent_id)
    timeout = Keyword.get(opts, :timeout)

    cond do
      not is_binary(agent_id) ->
        {:error, :invalid_args}

      not (is_integer(timeout) and timeout > 0) ->
        {:error, :invalid_args}

      true ->
        do_chat_response_authenticated(message, sender, receipt, agent_id, timeout)
    end
  end

  def chat_response_authenticated(_message, _sender, _receipt, _opts),
    do: {:error, :invalid_args}

  @doc false
  # Only MessageFacade's authenticated journal continuation supplies this
  # dedicated private argument. It is never an option on Arbor.Agent messaging.
  def chat_command_authenticated(message, sender, receipt, binding, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    timeout = Keyword.get(opts, :timeout)

    if is_struct(message, Arbor.Contracts.Session.UserMessage) and is_binary(sender) and
         is_struct(receipt, Arbor.Contracts.Security.DeliveryReceipt) and is_map(binding) and
         is_binary(agent_id) and is_integer(timeout) and timeout > 0 do
      do_chat_response_authenticated(message, sender, receipt, agent_id, timeout, binding)
    else
      {:error, :invalid_args}
    end
  end

  defp do_chat_response_authenticated(
         message,
         _sender,
         receipt,
         agent_id,
         timeout,
         binding \\ nil
       ) do
    case find_agent(agent_id) do
      {:ok, _pid, _meta} ->
        # Observability has no private-conversation read authority. Consumers
        # obtain content through the authenticated transcript, not this topic.
        safe_emit(:chat_message, %{
          role: :user,
          channel: :private_conversation
        })

        result =
          if binding do
            Arbor.Agent.SessionManager.send_conversation_command(
              agent_id,
              message,
              receipt,
              binding,
              timeout
            )
          else
            Arbor.Agent.SessionManager.send_authenticated_message(
              agent_id,
              message,
              receipt,
              timeout
            )
          end

        case result do
          # Outer shape only — MessageFacade owns closed projection, secret
          # admission, assistant signal, and receipt cleanup.
          {:ok, %Arbor.Contracts.Pipeline.Response{} = response} ->
            {:ok, response}

          {:ok, _other} ->
            {:error, :malformed_response}

          {:error, _} = err ->
            err

          _other ->
            {:error, :malformed_response}
        end

      :not_found ->
        {:error, :agent_not_found}
    end
  end

  @doc false
  def consult_authenticated(
        %Arbor.Contracts.Session.UserMessage{} = message,
        sender,
        %Arbor.Contracts.Security.DeliveryReceipt{} = receipt,
        parent_voice_id,
        opts
      )
      when is_binary(sender) and is_list(opts) do
    agent_id = Keyword.get(opts, :agent_id)
    timeout = Keyword.get(opts, :timeout)

    with true <- is_binary(agent_id) and is_integer(timeout) and timeout > 0,
         {:ok, _pid, _meta} <- find_agent(agent_id),
         {:ok, %Arbor.Contracts.Pipeline.Response{} = response} <-
           Arbor.Agent.SessionManager.consult_authenticated(
             agent_id,
             message,
             receipt,
             parent_voice_id,
             timeout
           ) do
      {:ok, Arbor.Contracts.Pipeline.Response.content(response)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_args}
    end
  end

  def consult_authenticated(_, _, _, _, _), do: {:error, :invalid_args}

  # ── Channels (unified message containers) ──────────────────────────

  @doc """
  Create a channel with the given members.

  Returns `{:ok, channel_id}` on success. Bridges to `Arbor.Comms.create_channel/2`.
  """
  @spec create_channel(String.t(), [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_channel(name, member_specs, opts \\ []) do
    members =
      Enum.map(member_specs, fn spec ->
        %{id: spec.id, name: spec.name, type: spec.type}
      end)

    if comms_available?() do
      apply(Arbor.Comms, :create_channel, [name, Keyword.put(opts, :members, members)])
    else
      {:error, :comms_unavailable}
    end
  end

  @doc "Send a message to a channel by ID."
  @spec channel_send(String.t(), String.t(), String.t(), atom(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def channel_send(channel_id, sender_id, sender_name, sender_type, content) do
    if comms_available?() do
      apply(Arbor.Comms, :send_to_channel, [
        channel_id,
        sender_id,
        sender_name,
        sender_type,
        content
      ])
    else
      {:error, :comms_unavailable}
    end
  end

  @doc "Add a member to a channel."
  @spec join_channel(String.t(), map()) :: :ok | {:error, term()}
  def join_channel(channel_id, member) do
    if comms_available?() do
      apply(Arbor.Comms, :join_channel, [channel_id, member])
    else
      {:error, :comms_unavailable}
    end
  end

  @doc "Remove a member from a channel."
  @spec leave_channel(String.t(), String.t()) :: :ok | {:error, term()}
  def leave_channel(channel_id, member_id) do
    if comms_available?() do
      apply(Arbor.Comms, :leave_channel, [channel_id, member_id])
    else
      {:error, :comms_unavailable}
    end
  end

  @doc "List all active channels as `[{channel_id, pid}]`."
  @spec list_channels() :: [{String.t(), pid()}]
  def list_channels do
    if comms_available?() do
      apply(Arbor.Comms, :list_channels, [])
    else
      []
    end
  end

  defp comms_available? do
    Code.ensure_loaded?(Arbor.Comms) and
      function_exported?(Arbor.Comms, :create_channel, 2)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp default_model_config do
    %{
      id: Arbor.Agent.LLMDefaults.default_model(),
      label: "Default",
      provider: Arbor.Agent.LLMDefaults.default_provider(),
      runtime: :arbor,
      module: Arbor.Agent.APIAgent,
      start_opts: []
    }
  end

  defp default_display_name(%{name: name}) when is_binary(name), do: name
  defp default_display_name(%{id: id}) when is_binary(id), do: id
  defp default_display_name(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp default_display_name(_), do: "Agent"

  # Phase 3 of priorities-2026-06-02 item 9: backend toggle (`:cli`/`:api`)
  # retired in favor of the runtime axis. :acp runtime → cli_agent template;
  # :arbor runtime (default) → api_agent template.
  defp resolve_template(%{runtime: :acp}), do: "cli_agent"
  defp resolve_template(%{runtime: :arbor}), do: "api_agent"
  defp resolve_template(_), do: "api_agent"

  defp atomize_model_config(config) when is_map(config) do
    known_keys = ~w(id label provider runtime module name start_opts)

    config
    |> Enum.map(fn
      {k, v} when is_binary(k) ->
        atom_key =
          if k in known_keys do
            String.to_existing_atom(k)
          else
            k
          end

        {atom_key, atomize_value(atom_key, v)}

      {k, v} ->
        {k, atomize_value(k, v)}
    end)
    |> Map.new()
  end

  defp atomize_model_config(config), do: config

  defp atomize_value(key, value) when key in [:runtime, :provider] and is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp atomize_value(:module, value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp atomize_value(_key, value), do: value

  defp sync_model_config(agent_id, profile, model_config) do
    persisted_config =
      get_in(profile.metadata, [:last_model_config]) ||
        get_in(profile.metadata, ["last_model_config"])

    if persisted_config != nil and atomize_model_config(persisted_config) != model_config do
      Logger.info(
        "[Manager] Syncing model config for #{agent_id}: " <>
          "#{inspect(persisted_config)} → #{inspect(model_config)}"
      )

      updated_profile = put_in(profile.metadata[:last_model_config], model_config)

      try do
        ProfileStore.store_profile(updated_profile)
      rescue
        e ->
          Logger.warning(
            "[Manager] Failed to persist model config update: #{Exception.message(e)}"
          )
      end
    end
  end

  @doc false
  # Shared with Bootstrap, which resolves config seeds to existing profiles.
  @spec find_existing_profile(String.t(), term()) :: {:ok, String.t()} | :not_found
  def find_existing_profile(display_name, template) do
    normalized_template = normalize_template_ref(template)

    case Lifecycle.list_agents() do
      profiles when is_list(profiles) ->
        match =
          Enum.find(profiles, fn p ->
            name_matches? =
              p.display_name == display_name or
                (p.character && p.character.name == display_name)

            template_matches? =
              normalized_template == nil or
                normalize_template_ref(p.template) == normalized_template

            name_matches? and template_matches?
          end)

        if match, do: {:ok, match.agent_id}, else: :not_found

      _ ->
        :not_found
    end
  end

  defp normalize_template_ref(nil), do: nil
  defp normalize_template_ref(name) when is_binary(name), do: name

  defp normalize_template_ref(mod) when is_atom(mod) do
    Arbor.Agent.TemplateStore.module_to_name(mod)
  end

  defp dispatch_query_response(metadata, input, opts) do
    # Use host_pid from BranchSupervisor metadata (new path),
    # fall back to direct PID lookup for backward compatibility.
    host_pid = metadata[:host_pid]

    runtime =
      metadata[:runtime] || get_in(metadata, [:model_config, :runtime]) ||
        infer_runtime(metadata[:model_config])

    query_pid =
      cond do
        host_pid && Process.alive?(host_pid) ->
          host_pid

        # Fallback: look up via ExecutorRegistry (council agents, legacy)
        true ->
          agent_id = metadata[:agent_id]

          if agent_id do
            case Registry.lookup(Arbor.Agent.ExecutorRegistry, {:host, agent_id}) do
              [{pid, _}] -> pid
              [] -> nil
            end
          end
      end

    if query_pid do
      query_runtime(runtime, query_pid, input, opts)
    else
      {:error, :agent_host_not_found}
    end
  end

  defp chat_signal_content(%Arbor.Contracts.Session.UserMessage{content: content}), do: content
  defp chat_signal_content(input), do: input

  # Phase 3: runtime axis replaces the :cli/:api backend toggle. The
  # legacy :acp provider mapping (old shape) goes through APIAgent →
  # :arbor runtime; new callers should set runtime explicitly.
  defp infer_runtime(%{provider: :acp}), do: :arbor
  defp infer_runtime(_), do: :arbor

  defp query_runtime(:acp, pid, input, opts) do
    Claude.query(pid, input,
      timeout: Keyword.get(opts, :timeout, :infinity),
      permission_mode: :bypass
    )
  end

  defp query_runtime(:arbor, pid, input, opts), do: APIAgent.query(pid, input, opts)
  defp query_runtime(_, pid, input, opts), do: APIAgent.query(pid, input, opts)

  defp handle_query_result({:ok, response}) do
    text = response[:text] || response.text || ""
    safe_emit(:chat_message, %{role: :assistant, content: text, sender: "Agent"})
    {:ok, text}
  end

  defp handle_query_result({:error, _} = error), do: error

  defp connect_single_mcp_server(agent_id, server) do
    server_name = server[:name] || server["name"]

    if server_name do
      config =
        server
        |> Map.put(:agent_id, agent_id)
        |> Map.put(:server_name, server_name)
        |> Map.put_new(:auto_discover, true)

      case apply(Arbor.Gateway, :connect_mcp_server, [server_name, config]) do
        {:ok, _pid} ->
          Logger.info("[Manager] Connected MCP server '#{server_name}' for #{agent_id}")

        {:error, :mcp_server_not_approved} ->
          Logger.warning(
            "[Manager] MCP server '#{server_name}' for #{agent_id} is not approved for its " <>
              "current config; not connecting. Approve it with Arbor.Agent.set_mcp_config/2."
          )

        {:error, reason} ->
          Logger.warning(
            "[Manager] Failed to connect MCP server '#{server_name}' for #{agent_id}: #{inspect(reason)}"
          )
      end
    end
  end

  defp gateway_available? do
    Code.ensure_loaded?(Arbor.Gateway) and
      function_exported?(Arbor.Gateway, :connect_mcp_server, 2) and
      Process.whereis(Arbor.Gateway.MCP.ClientSupervisor) != nil
  end

  defp safe_emit(type, data) do
    Arbor.Signals.emit(:agent, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
