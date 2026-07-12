defmodule Arbor.AI.AcpManaged.SessionRegistry do
  @moduledoc """
  AI-owned managed ACP session registry.

  Mints opaque durable handles (`acp_worker_*`) for live `AcpSession` processes
  (pooled or non-pooled). Registry entries keep PIDs, monitor refs, and
  ownership private; public views are JSON-clean.

  ## Ownership and authority

  * The owner PID is always the live GenServer caller at register time.
    Caller-supplied owner options are never authority.
  * Same live owner may resolve/status/send/close.
  * Cross-process access requires BOTH the same non-empty `task_id` and
    `principal_id`. Handle alone and `task_id` alone are not authority.
  * Owner death immediately closes a non-pooled session or checks a pooled
    session back in when `return_to_pool` applies.
  * Session death removes the handle.
  * Close is idempotent; stale handles fail predictably (`:not_found` on
    resolve/status/send, success-with-already-closed on close).
  """

  use GenServer

  require Logger

  @type public_view :: %{
          worker_session_id: String.t(),
          session_id: String.t() | nil,
          provider: String.t(),
          model: String.t() | nil,
          status: String.t(),
          pooled: boolean()
        }

  @type entry :: %{
          worker_session_id: String.t(),
          session_pid: pid(),
          session_ref: reference(),
          session_module: module(),
          pool_module: module() | nil,
          owner_pid: pid(),
          owner_ref: reference(),
          provider: atom() | String.t(),
          model: String.t() | nil,
          session_id: String.t() | nil,
          status: String.t(),
          pooled: boolean(),
          return_to_pool: boolean(),
          task_id: String.t() | nil,
          principal_id: String.t() | nil
        }

  @registry_name __MODULE__
  @handle_prefix "acp_worker_"

  # -- Public API -----------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Register a live session under an opaque managed handle.

  Owner is always the GenServer caller. Monitors owner and session before
  publishing the handle. Returns a JSON-clean public view.
  """
  @spec register(map(), keyword()) :: {:ok, public_view()} | {:error, term()}
  def register(attrs, opts \\ []) when is_map(attrs) do
    call({:register, normalize_register_attrs(attrs)}, opts)
  end

  @doc """
  Resolve a managed handle for an authorized caller.

  Returns an internal resolve map (includes `session_pid` / `session_module`)
  for the facade to invoke the session **from the original caller process**.
  Not a public Engine-facing result - never put the resolve map in context.
  """
  @spec resolve(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def resolve(worker_session_id, opts \\ []) when is_binary(worker_session_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:resolve, worker_session_id, caller}, server_opts)
  end

  @doc false
  @spec resolve_task_control(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_task_control(task_id, principal_id, opts \\ [])
      when is_binary(task_id) and is_binary(principal_id) and is_list(opts) do
    timeout_keys = Arbor.LLM.timeout_option_keys()

    call(
      {:resolve_task_control, normalize_id(task_id), normalize_id(principal_id)},
      Enum.filter(opts, fn
        {key, _value} when is_atom(key) -> key == :server or key in timeout_keys
        _invalid -> true
      end)
    )
  end

  @doc """
  Return JSON-clean status metadata when authorized.
  """
  @spec status(String.t(), keyword() | map()) :: {:ok, public_view()} | {:error, term()}
  def status(worker_session_id, opts \\ []) when is_binary(worker_session_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:status, worker_session_id, caller}, server_opts)
  end

  @doc """
  Close or check in a managed session when authorized.

  Idempotent: unknown/already-closed handles return success with
  `status: "already_closed"`.

  An explicit `return_to_pool: true|false` option overrides the stored pooled
  close policy for this close only. Owner-death cleanup still uses the stored
  default from registration.
  """
  @spec close(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def close(worker_session_id, opts \\ []) when is_binary(worker_session_id) do
    {server_opts, caller} = split_caller_opts(opts)
    return_to_pool_override = return_to_pool_override(opts)
    call({:close, worker_session_id, caller, return_to_pool_override}, server_opts)
  end

  @doc false
  @spec public_view(map()) :: public_view()
  def public_view(entry) when is_map(entry) do
    %{
      worker_session_id: entry.worker_session_id,
      session_id: entry.session_id,
      provider: provider_string(entry.provider),
      model: entry.model,
      status: status_string(entry.status),
      pooled: entry.pooled == true
    }
  end

  @doc false
  def handle_prefix, do: @handle_prefix

  # -- GenServer ------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, by_ref: %{}}}
  end

  @impl true
  def handle_call({:register, attrs}, {owner_pid, _tag}, state) do
    case do_register(attrs, owner_pid, state) do
      {:ok, view, state} -> {:reply, {:ok, view}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve, worker_session_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized(state, worker_session_id, caller) do
      {:ok, entry} ->
        {:reply, {:ok, resolve_view(entry)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Task control has no worker handle authority. It must find exactly one live
  # task/principal pair; duplicate registrations are an explicit ambiguity.
  def handle_call({:resolve_task_control, task_id, principal_id}, _from, state) do
    matches =
      state.sessions
      |> Map.values()
      |> Enum.filter(fn entry ->
        entry.task_id == task_id and entry.principal_id == principal_id and
          non_empty_id?(task_id) and non_empty_id?(principal_id) and
          Process.alive?(entry.session_pid)
      end)

    case matches do
      [entry] -> {:reply, {:ok, resolve_view(entry)}, state}
      [] -> {:reply, {:error, :not_found}, state}
      _ -> {:reply, {:error, :ambiguous_task_control_session}, state}
    end
  end

  def handle_call({:status, worker_session_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized(state, worker_session_id, caller) do
      {:ok, entry} ->
        {:reply, {:ok, public_view(entry)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:close, worker_session_id, caller, return_to_pool_override},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}

    case Map.fetch(state.sessions, worker_session_id) do
      :error ->
        {:reply, {:ok, already_closed_view(worker_session_id)}, state}

      {:ok, entry} ->
        if authorized?(entry, caller) do
          entry = apply_return_to_pool_override(entry, return_to_pool_override)
          {result, state} = do_close(state, entry)
          {:reply, {:ok, result}, state}
        else
          {:reply, {:error, :not_authorized}, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _by_ref} ->
        {:noreply, state}

      {{:owner, worker_session_id}, by_ref} ->
        state = %{state | by_ref: by_ref}
        state = handle_owner_down(state, worker_session_id, pid, reason)
        {:noreply, state}

      {{:session, worker_session_id}, by_ref} ->
        state = %{state | by_ref: by_ref}
        state = handle_session_down(state, worker_session_id, pid, reason)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------

  # Convert every GenServer.call exit (including timeout) into an error tuple
  # so acquisition cleanup in AcpManaged always runs after a failed register.
  defp call(message, opts) do
    with {:ok, opts, timeout} <- Arbor.AI.Timeout.normalize(opts, 5_000) do
      server = Keyword.get(opts, :server, @registry_name)

      try do
        GenServer.call(server, message, timeout)
      catch
        :exit, {:noproc, _} ->
          {:error, :registry_unavailable}

        :exit, {:normal, _} ->
          {:error, :registry_unavailable}

        :exit, {:shutdown, _} ->
          {:error, :registry_unavailable}

        :exit, {:timeout, _} ->
          {:error, :timeout}

        :exit, reason ->
          {:error, {:registry_call_failed, Arbor.LLM.sanitize_external_reason(reason)}}
      end
    end
  end

  defp split_caller_opts(opts) when is_list(opts) do
    timeout_keys = Arbor.LLM.timeout_option_keys()

    server_opts =
      Enum.filter(opts, fn
        {key, _value} when is_atom(key) -> key == :server or key in timeout_keys
        _invalid -> true
      end)

    caller = %{
      owner_pid: nil,
      task_id: normalize_id(Keyword.get(opts, :task_id)),
      principal_id: normalize_id(Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id))
    }

    {server_opts, caller}
  end

  defp split_caller_opts(opts) when is_map(opts) do
    server =
      case Map.get(opts, :server) || Map.get(opts, "server") do
        nil -> []
        name -> [server: name]
      end

    timeout = map_timeout_options(opts)

    principal =
      normalize_id(
        Map.get(opts, :principal_id) ||
          Map.get(opts, "principal_id") ||
          Map.get(opts, :agent_id) ||
          Map.get(opts, "agent_id")
      )

    caller = %{
      owner_pid: nil,
      task_id: normalize_id(Map.get(opts, :task_id) || Map.get(opts, "task_id")),
      principal_id: principal
    }

    {server ++ timeout, caller}
  end

  defp map_timeout_options(opts) do
    Enum.reduce(Arbor.LLM.timeout_option_keys(), [], fn key, acc ->
      acc = if Map.has_key?(opts, key), do: [{key, Map.get(opts, key)} | acc], else: acc
      string_key = Atom.to_string(key)

      if Map.has_key?(opts, string_key),
        do: [{key, Map.get(opts, string_key)} | acc],
        else: acc
    end)
  end

  # Explicit close may override stored policy; :default keeps registration value.
  defp return_to_pool_override(opts) when is_list(opts) do
    case Keyword.fetch(opts, :return_to_pool) do
      {:ok, v} -> truthy?(v)
      :error -> :default
    end
  end

  defp return_to_pool_override(opts) when is_map(opts) do
    cond do
      Map.has_key?(opts, :return_to_pool) -> truthy?(Map.get(opts, :return_to_pool))
      Map.has_key?(opts, "return_to_pool") -> truthy?(Map.get(opts, "return_to_pool"))
      true -> :default
    end
  end

  defp apply_return_to_pool_override(entry, :default), do: entry

  defp apply_return_to_pool_override(entry, override) when is_boolean(override) do
    %{entry | return_to_pool: override}
  end

  defp normalize_register_attrs(attrs) do
    %{
      session_pid: Map.get(attrs, :session_pid) || Map.get(attrs, "session_pid"),
      session_module:
        Map.get(attrs, :session_module) || Map.get(attrs, "session_module") ||
          Arbor.AI.AcpSession,
      pool_module: Map.get(attrs, :pool_module) || Map.get(attrs, "pool_module"),
      provider: Map.get(attrs, :provider) || Map.get(attrs, "provider"),
      model: normalize_model(Map.get(attrs, :model) || Map.get(attrs, "model")),
      session_id: normalize_id(Map.get(attrs, :session_id) || Map.get(attrs, "session_id")),
      status: Map.get(attrs, :status) || Map.get(attrs, "status") || "ready",
      pooled: truthy?(Map.get(attrs, :pooled) || Map.get(attrs, "pooled")),
      return_to_pool:
        case Map.fetch(attrs, :return_to_pool) do
          {:ok, v} ->
            truthy?(v)

          :error ->
            case Map.fetch(attrs, "return_to_pool") do
              {:ok, v} -> truthy?(v)
              :error -> truthy?(Map.get(attrs, :pooled) || Map.get(attrs, "pooled"))
            end
        end,
      task_id: normalize_id(Map.get(attrs, :task_id) || Map.get(attrs, "task_id")),
      principal_id:
        normalize_id(
          Map.get(attrs, :principal_id) ||
            Map.get(attrs, "principal_id") ||
            Map.get(attrs, :agent_id) ||
            Map.get(attrs, "agent_id")
        )
    }
  end

  defp do_register(attrs, owner_pid, state) do
    with true <- is_pid(owner_pid) || {:error, :invalid_owner_pid},
         true <- Process.alive?(owner_pid) || {:error, :owner_dead},
         session_pid when is_pid(session_pid) <- attrs.session_pid,
         true <- Process.alive?(session_pid) || {:error, :session_dead},
         true <- is_atom(attrs.session_module) || {:error, :invalid_session_module} do
      # Monitor both before publishing the handle so a mid-register death is observed.
      owner_ref = Process.monitor(owner_pid)
      session_ref = Process.monitor(session_pid)
      worker_session_id = mint_handle()

      entry = %{
        worker_session_id: worker_session_id,
        session_pid: session_pid,
        session_ref: session_ref,
        session_module: attrs.session_module,
        pool_module: attrs.pool_module,
        owner_pid: owner_pid,
        owner_ref: owner_ref,
        provider: attrs.provider,
        model: attrs.model,
        session_id: attrs.session_id,
        status: status_string(attrs.status),
        pooled: attrs.pooled == true,
        return_to_pool: attrs.return_to_pool == true,
        task_id: attrs.task_id,
        principal_id: attrs.principal_id
      }

      state =
        state
        |> put_entry(entry)
        |> put_ref(entry.owner_ref, {:owner, worker_session_id})
        |> put_ref(entry.session_ref, {:session, worker_session_id})

      {:ok, public_view(entry), state}
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_register, state}
      nil -> {:error, :invalid_session_pid, state}
      other when not is_pid(other) -> {:error, :invalid_session_pid, state}
    end
  end

  defp resolve_view(entry) do
    %{
      worker_session_id: entry.worker_session_id,
      session_pid: entry.session_pid,
      session_module: entry.session_module,
      pool_module: entry.pool_module,
      provider: entry.provider,
      model: entry.model,
      session_id: entry.session_id,
      status: entry.status,
      pooled: entry.pooled,
      return_to_pool: entry.return_to_pool
    }
  end

  defp fetch_authorized(state, worker_session_id, caller) do
    case Map.fetch(state.sessions, worker_session_id) do
      :error ->
        {:error, :not_found}

      {:ok, entry} ->
        if authorized?(entry, caller) do
          if Process.alive?(entry.session_pid) do
            {:ok, entry}
          else
            {:error, :not_found}
          end
        else
          {:error, :not_authorized}
        end
    end
  end

  defp authorized?(entry, caller) do
    owner_match?(entry, caller) or principal_task_match?(entry, caller)
  end

  defp owner_match?(entry, caller) do
    is_pid(caller.owner_pid) and is_pid(entry.owner_pid) and caller.owner_pid == entry.owner_pid and
      Process.alive?(entry.owner_pid)
  end

  # Cross-process resume requires BOTH non-empty task_id and principal_id.
  # Task IDs alone are predictable identifiers, not capabilities.
  defp principal_task_match?(entry, caller) do
    non_empty_id?(entry.task_id) and non_empty_id?(caller.task_id) and
      entry.task_id == caller.task_id and
      non_empty_id?(entry.principal_id) and non_empty_id?(caller.principal_id) and
      entry.principal_id == caller.principal_id
  end

  defp non_empty_id?(id), do: is_binary(id) and id != ""

  defp do_close(state, entry) do
    state = drop_entry(state, entry)
    release_session(entry, :close)

    result =
      entry
      |> public_view()
      |> Map.put(:status, "closed")
      |> Map.put(:active, false)

    {result, state}
  end

  defp handle_owner_down(state, worker_session_id, _pid, reason) do
    case Map.pop(state.sessions, worker_session_id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        Logger.debug(
          "AcpManaged: owner died for #{worker_session_id} (#{inspect(reason)}); releasing"
        )

        state = %{state | sessions: sessions}
        state = drop_ref(state, entry.session_ref)
        safe_demonitor(entry.session_ref)
        release_session(entry, :owner_death)
        state
    end
  end

  defp handle_session_down(state, worker_session_id, _pid, reason) do
    case Map.pop(state.sessions, worker_session_id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        Logger.debug(
          "AcpManaged: session died for #{worker_session_id} (#{inspect(reason)}); dropping handle"
        )

        state = %{state | sessions: sessions}
        state = drop_ref(state, entry.owner_ref)
        safe_demonitor(entry.owner_ref)
        state
    end
  end

  defp release_session(entry, reason) do
    cond do
      entry.pooled and entry.return_to_pool ->
        checkin_pooled(entry, reason)

      entry.pooled ->
        hard_close_pooled(entry, reason)

      true ->
        close_session_process(entry, reason)
    end
  end

  defp checkin_pooled(entry, reason) do
    pool_mod = entry.pool_module || Arbor.AI.AcpPool

    Task.start(fn ->
      try do
        if function_exported?(pool_mod, :checkin, 1) do
          pool_mod.checkin(entry.session_pid)
        end
      rescue
        error ->
          Logger.debug(
            "AcpManaged: pool checkin failed after #{reason}: #{Exception.message(error)}"
          )
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # Hard-close pooled sessions through the pool when possible so the pool
  # entry is removed rather than left as a leaked checkout.
  defp hard_close_pooled(entry, reason) do
    pool_mod = entry.pool_module || Arbor.AI.AcpPool

    Task.start(fn ->
      try do
        cond do
          function_exported?(pool_mod, :close_session, 1) ->
            pool_mod.close_session(entry.session_pid)

          true ->
            close_session_process_inline(entry)
        end
      rescue
        error ->
          Logger.debug(
            "AcpManaged: pool hard-close failed after #{reason}: #{Exception.message(error)}"
          )
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp close_session_process(entry, reason) do
    Task.start(fn ->
      try do
        close_session_process_inline(entry)
      rescue
        error ->
          Logger.debug(
            "AcpManaged: session close failed after #{reason}: #{Exception.message(error)}"
          )
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp close_session_process_inline(entry) do
    session_mod = entry.session_module || Arbor.AI.AcpSession
    pid = entry.session_pid

    if is_pid(pid) and Process.alive?(pid) do
      if function_exported?(session_mod, :close, 1) do
        session_mod.close(pid)
      else
        Process.exit(pid, :shutdown)
      end
    end

    :ok
  end

  defp put_entry(state, entry) do
    %{state | sessions: Map.put(state.sessions, entry.worker_session_id, entry)}
  end

  defp put_ref(state, ref, tag) do
    %{state | by_ref: Map.put(state.by_ref, ref, tag)}
  end

  defp drop_entry(state, entry) do
    safe_demonitor(entry.owner_ref)
    safe_demonitor(entry.session_ref)

    %{
      state
      | sessions: Map.delete(state.sessions, entry.worker_session_id),
        by_ref:
          state.by_ref
          |> Map.delete(entry.owner_ref)
          |> Map.delete(entry.session_ref)
    }
  end

  defp drop_ref(state, ref) do
    %{state | by_ref: Map.delete(state.by_ref, ref)}
  end

  defp safe_demonitor(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp safe_demonitor(_), do: :ok

  defp mint_handle do
    @handle_prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp already_closed_view(worker_session_id) do
    %{
      worker_session_id: worker_session_id,
      session_id: nil,
      provider: nil,
      model: nil,
      status: "already_closed",
      pooled: false,
      active: false
    }
  end

  defp provider_string(nil), do: nil
  defp provider_string(p) when is_atom(p), do: Atom.to_string(p)
  defp provider_string(p) when is_binary(p), do: p
  defp provider_string(p), do: inspect(p)

  defp status_string(nil), do: "ready"
  defp status_string(s) when is_atom(s), do: Atom.to_string(s)
  defp status_string(s) when is_binary(s), do: s
  defp status_string(s), do: inspect(s)

  defp normalize_model(nil), do: nil
  defp normalize_model(m) when is_binary(m), do: m
  defp normalize_model(m) when is_atom(m), do: Atom.to_string(m)
  defp normalize_model(m), do: to_string(m)

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_), do: nil

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?("true"), do: true
  defp truthy?("false"), do: false
  defp truthy?(1), do: true
  defp truthy?(0), do: false
  defp truthy?(_), do: false
end
