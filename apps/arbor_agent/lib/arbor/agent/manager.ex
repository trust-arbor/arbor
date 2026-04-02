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

  alias Arbor.Agent.{APIAgent, Claude, Lifecycle, ProfileStore}

  require Logger

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

    lifecycle_opts =
      [template: template] ++
        Keyword.take(opts, [
          :trust_tier,
          :capabilities,
          :initial_goals,
          :delegator_id,
          :delegator_private_key,
          :tenant_context
        ])

    with {:ok, profile} <- Lifecycle.create(display_name, lifecycle_opts) do
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
        model_config: %{id: "haiku", provider: :anthropic, backend: :api}
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
  Set auto_start flag on an agent's persisted profile.

  When `enabled` is `true`, the agent will be automatically started by
  `Arbor.Agent.Bootstrap` on application boot.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_auto_start(String.t(), boolean()) :: :ok | {:error, term()}
  def set_auto_start(agent_id, enabled) when is_binary(agent_id) and is_boolean(enabled) do
    case ProfileStore.load_profile(agent_id) do
      {:ok, profile} ->
        updated = %{profile | auto_start: enabled}
        ProfileStore.store_profile(updated)

      {:error, _} = error ->
        error
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

  ## Server Config

  Each server spec is a map with:
  - `:name` — unique server name (required)
  - `:transport` — `:stdio`, `:http`, `:sse`, or `:beam` (default: `:stdio`)
  - `:command` — command for stdio transport
  - `:url` — URL for HTTP/SSE transport
  - `:env` — environment variables map
  - `:auto_discover` — discover tools/resources on connect (default: true)

  ## Example

      Manager.set_mcp_config(agent_id, [
        %{name: "github", transport: :stdio, command: ["npx", "@modelcontextprotocol/server-github"]},
        %{name: "filesystem", transport: :stdio, command: ["npx", "@modelcontextprotocol/server-filesystem", "/workspace"]}
      ])
  """
  @spec set_mcp_config(String.t(), [map()]) :: :ok | {:error, term()}
  def set_mcp_config(agent_id, servers) when is_binary(agent_id) and is_list(servers) do
    case ProfileStore.load_profile(agent_id) do
      {:ok, profile} ->
        metadata = Map.put(profile.metadata || %{}, :mcp_servers, servers)
        updated = %{profile | metadata: metadata}
        ProfileStore.store_profile(updated)

      {:error, _} = error ->
        error
    end
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

  The `sender` label identifies who sent the message (e.g., "Opus", "Hysun").
  If no `:agent_id` is provided, uses the first running agent.
  """
  @spec chat(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(input, sender \\ "Opus", opts \\ []) do
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
      {:ok, _agent_id, pid, metadata} ->
        safe_emit(:chat_message, %{role: :user, content: input, sender: sender})
        dispatch_query(pid, metadata, input, opts)

      :not_found ->
        {:error, :agent_not_found}
    end
  end

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
      backend: :api,
      module: Arbor.Agent.APIAgent,
      start_opts: []
    }
  end

  defp default_display_name(%{name: name}) when is_binary(name), do: name
  defp default_display_name(%{id: id}) when is_binary(id), do: id
  defp default_display_name(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp default_display_name(_), do: "Agent"

  defp resolve_template(%{backend: :cli}), do: "cli_agent"
  defp resolve_template(%{backend: :api}), do: "api_agent"
  defp resolve_template(_), do: "api_agent"

  defp atomize_model_config(config) when is_map(config) do
    known_keys = ~w(id label provider backend module name start_opts)

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

  defp atomize_value(key, value) when key in [:backend, :provider] and is_binary(value) do
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

  defp find_existing_profile(display_name, template) do
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

  defp dispatch_query(_pid, metadata, input, opts) do
    # Use host_pid from BranchSupervisor metadata (new path),
    # fall back to direct PID lookup for backward compatibility.
    host_pid = metadata[:host_pid]

    backend =
      metadata[:backend] || get_in(metadata, [:model_config, :backend]) ||
        infer_backend(metadata[:model_config])

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
      result = query_backend(backend, query_pid, input, opts)
      handle_query_result(result)
    else
      {:error, :agent_host_not_found}
    end
  end

  # ACP provider uses APIAgent, so route to :api backend
  defp infer_backend(%{provider: :acp}), do: :api
  defp infer_backend(_), do: :api

  defp query_backend(:cli, pid, input, opts) do
    Claude.query(pid, input,
      timeout: Keyword.get(opts, :timeout, :infinity),
      permission_mode: :bypass
    )
  end

  defp query_backend(:api, pid, input, _opts), do: APIAgent.query(pid, input)
  defp query_backend(_, pid, input, _opts), do: APIAgent.query(pid, input)

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
