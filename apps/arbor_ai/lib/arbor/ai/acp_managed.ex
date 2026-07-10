defmodule Arbor.AI.AcpManaged do
  @moduledoc false
  # Internal orchestration for managed ACP sessions.
  # Public entry points live on `Arbor.AI` and must stay thin.

  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpManaged.Supervisor, as: ManagedSupervisor
  alias Arbor.AI.AcpPool
  alias Arbor.AI.AcpSession

  # Registry/orchestration-only opts. Deliberately excludes :agent_id so it is
  # forwarded into AcpSession / AcpPool (callback authorize identity) while still
  # being read from the original opts as principal_id fallback on register.
  @registry_only_opts [
    :server,
    :task_id,
    :principal_id,
    :owner,
    :owner_pid,
    :use_pool,
    :pooled,
    :return_to_pool,
    :session_module,
    :pool_module,
    :supervisor,
    :create_session,
    :session_id
  ]

  @doc false
  @spec start_session(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(provider, opts \\ []) when is_atom(provider) and is_list(opts) do
    opts = strip_caller_owner_opts(opts)
    use_pool? = Keyword.get(opts, :use_pool) || Keyword.get(opts, :pooled) || false

    if use_pool? do
      start_pooled(provider, opts)
    else
      start_non_pooled(provider, opts)
    end
  end

  @doc false
  @spec send_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(worker_session_id, content, opts \\ [])
      when is_binary(worker_session_id) and is_binary(content) and is_list(opts) do
    with {:ok, resolved} <- SessionRegistry.resolve(worker_session_id, opts) do
      session_mod = resolved.session_module
      # Invoke from the original facade caller process (not the registry).
      session_mod.send_message(
        resolved.session_pid,
        content,
        session_operation_opts(opts)
      )
    end
  end

  @doc false
  @spec deliver_task_control(String.t(), String.t(), map(), keyword()) ::
          {:ok, :queued | :delivered | :deferred, :same_session_follow_up} | {:error, term()}
  def deliver_task_control(task_id, principal_id, control, opts \\ [])
      when is_binary(task_id) and is_binary(principal_id) and is_map(control) and is_list(opts) do
    with {:ok, resolved} <- SessionRegistry.resolve_task_control(task_id, principal_id, opts) do
      control = control |> Map.delete(:task_id) |> Map.put("task_id", task_id)

      resolved.session_module.deliver_task_control(
        resolved.session_pid,
        control,
        timeout: Keyword.get(opts, :control_timeout, 5_000)
      )
    end
  end

  @doc false
  @spec session_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def session_status(worker_session_id, opts \\ [])
      when is_binary(worker_session_id) and is_list(opts) do
    with {:ok, resolved} <- SessionRegistry.resolve(worker_session_id, opts) do
      session_mod = resolved.session_module

      # Live status is optional enrichment. Failures must not invent "ready"
      # metadata and must not invalidate a still-live handle (busy prompt timeout).
      live =
        try do
          session_mod.status(resolved.session_pid)
        rescue
          _ -> :error
        catch
          :exit, _ -> :error
        end

      case live do
        map when is_map(map) ->
          provider_session_id =
            Map.get(map, :session_id) || Map.get(map, "session_id") || resolved.session_id

          model = Map.get(map, :model) || Map.get(map, "model") || resolved.model
          status = Map.get(map, :status) || Map.get(map, "status") || resolved.status

          provider =
            Map.get(map, :provider) || Map.get(map, "provider") || resolved.provider

          context_tokens =
            Map.get(map, :context_tokens) || Map.get(map, "context_tokens") || 0

          usage = Map.get(map, :usage) || Map.get(map, "usage") || %{}

          context_pressure =
            resolve_context_pressure(session_mod, resolved.session_pid, map)

          {:ok,
           %{
             worker_session_id: resolved.worker_session_id,
             session_id: provider_session_id,
             provider: provider_to_string(provider),
             model: model_to_string(model),
             status: status_to_string(status),
             pooled: resolved.pooled == true,
             context_pressure: context_pressure == true,
             context_tokens: context_tokens,
             usage: usage
           }}

        _ ->
          {:error, :session_unavailable}
      end
    end
  end

  @doc false
  @spec close_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close_session(worker_session_id, opts \\ [])
      when is_binary(worker_session_id) and is_list(opts) do
    SessionRegistry.close(worker_session_id, opts)
  end

  # -- Start paths ----------------------------------------------------

  defp start_non_pooled(provider, opts) do
    session_mod = Keyword.get(opts, :session_module, AcpSession)
    supervisor = Keyword.get(opts, :supervisor, ManagedSupervisor)
    registry_opts = Keyword.take(opts, [:server])

    # Owner is the live task caller; never a supplied owner option.
    session_opts =
      opts
      |> Keyword.drop(@registry_only_opts)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:owner, self())

    case ManagedSupervisor.start_session(session_mod, session_opts, supervisor: supervisor) do
      {:ok, session_pid} ->
        finalize_non_pooled_start(
          session_mod,
          session_pid,
          provider,
          opts,
          supervisor,
          registry_opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:managed_start_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:managed_start_exit, reason}}
  end

  defp finalize_non_pooled_start(
         session_mod,
         session_pid,
         provider,
         opts,
         supervisor,
         registry_opts
       ) do
    try do
      case create_or_resume(session_mod, session_pid, opts) do
        {:ok, session_info} ->
          register_attrs = %{
            session_pid: session_pid,
            session_module: session_mod,
            provider: provider,
            model: Keyword.get(opts, :model),
            session_id: extract_provider_session_id(session_info),
            status: "ready",
            pooled: false,
            return_to_pool: false,
            task_id: Keyword.get(opts, :task_id),
            principal_id: Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id)
          }

          case SessionRegistry.register(register_attrs, registry_opts) do
            {:ok, view} ->
              {:ok, view}

            {:error, reason} ->
              cleanup_failed_start(session_mod, session_pid, supervisor, pooled?: false)
              {:error, reason}
          end

        {:error, reason} ->
          cleanup_failed_start(session_mod, session_pid, supervisor, pooled?: false)
          {:error, reason}
      end
    rescue
      e ->
        cleanup_failed_start(session_mod, session_pid, supervisor, pooled?: false)
        {:error, {:managed_start_failed, Exception.message(e)}}
    catch
      :exit, reason ->
        cleanup_failed_start(session_mod, session_pid, supervisor, pooled?: false)
        {:error, {:managed_start_exit, reason}}
    end
  end

  defp start_pooled(provider, opts) do
    session_mod = Keyword.get(opts, :session_module, AcpSession)
    pool_mod = Keyword.get(opts, :pool_module, AcpPool)
    registry_opts = Keyword.take(opts, [:server])
    return_to_pool = Keyword.get(opts, :return_to_pool, true)

    checkout_opts =
      opts
      |> Keyword.drop([
        :use_pool,
        :pooled,
        :return_to_pool,
        :session_module,
        :pool_module,
        :supervisor,
        :server,
        :task_id,
        :principal_id,
        :session_id,
        :create_session
      ])

    case pool_mod.checkout(provider, checkout_opts) do
      {:ok, session_pid} ->
        finalize_pooled_start(
          session_mod,
          pool_mod,
          session_pid,
          provider,
          opts,
          return_to_pool,
          registry_opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:managed_start_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:managed_start_exit, reason}}
  end

  defp finalize_pooled_start(
         session_mod,
         pool_mod,
         session_pid,
         provider,
         opts,
         return_to_pool,
         registry_opts
       ) do
    cleanup_opts = [pooled?: true, return_to_pool: return_to_pool]

    try do
      case maybe_create_or_resume_pooled(session_mod, session_pid, opts) do
        :skip ->
          register_pooled(
            session_mod,
            pool_mod,
            session_pid,
            provider,
            opts,
            return_to_pool,
            registry_opts,
            %{},
            cleanup_opts
          )

        {:ok, session_info} ->
          register_pooled(
            session_mod,
            pool_mod,
            session_pid,
            provider,
            opts,
            return_to_pool,
            registry_opts,
            session_info,
            cleanup_opts
          )

        {:error, reason} ->
          cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
          {:error, reason}
      end
    rescue
      e ->
        cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
        {:error, {:managed_start_failed, Exception.message(e)}}
    catch
      :exit, reason ->
        cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
        {:error, {:managed_start_exit, reason}}
    end
  end

  defp register_pooled(
         session_mod,
         pool_mod,
         session_pid,
         provider,
         opts,
         return_to_pool,
         registry_opts,
         session_info,
         cleanup_opts
       ) do
    register_attrs = %{
      session_pid: session_pid,
      session_module: session_mod,
      pool_module: pool_mod,
      provider: provider,
      model: Keyword.get(opts, :model),
      session_id: extract_provider_session_id(session_info),
      status: "ready",
      pooled: true,
      return_to_pool: return_to_pool,
      task_id: Keyword.get(opts, :task_id),
      principal_id: Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id)
    }

    case SessionRegistry.register(register_attrs, registry_opts) do
      {:ok, view} ->
        {:ok, view}

      {:error, reason} ->
        cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
        {:error, reason}
    end
  end

  # Non-pooled starts always create or resume.
  defp create_or_resume(session_mod, session_pid, opts) do
    case Keyword.get(opts, :session_id) do
      sid when is_binary(sid) and sid != "" ->
        resume_opts = Keyword.take(opts, [:timeout, :cwd])

        case session_mod.resume_session(session_pid, sid, resume_opts) do
          {:ok, info} -> {:ok, info}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end

      _ ->
        create_opts = Keyword.take(opts, [:timeout, :cwd])

        case session_mod.create_session(session_pid, create_opts) do
          {:ok, info} -> {:ok, info}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end
    end
  end

  # Pooled path: explicit resume or create_session: true must succeed or fail.
  # :skip is only valid when neither was requested.
  defp maybe_create_or_resume_pooled(session_mod, session_pid, opts) do
    case Keyword.get(opts, :session_id) do
      sid when is_binary(sid) and sid != "" ->
        resume_opts = Keyword.take(opts, [:timeout, :cwd])

        case session_mod.resume_session(session_pid, sid, resume_opts) do
          {:ok, info} -> {:ok, info}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end

      _ ->
        if Keyword.get(opts, :create_session, false) do
          create_opts = Keyword.take(opts, [:timeout, :cwd])

          case session_mod.create_session(session_pid, create_opts) do
            {:ok, info} -> {:ok, info}
            {:error, reason} -> {:error, reason}
            other -> {:error, {:unexpected_result, other}}
          end
        else
          :skip
        end
    end
  end

  # -- Cleanup --------------------------------------------------------

  defp cleanup_failed_start(session_mod, session_pid, pool_or_sup, opts) do
    pooled? = Keyword.get(opts, :pooled?, false)
    return_to_pool? = Keyword.get(opts, :return_to_pool, true)

    cond do
      pooled? and return_to_pool? and is_atom(pool_or_sup) ->
        safe_pool_checkin(pool_or_sup, session_pid)

      pooled? and is_atom(pool_or_sup) ->
        safe_pool_hard_close(pool_or_sup, session_mod, session_pid)

      true ->
        terminate_session(session_mod, session_pid, pool_or_sup)
    end

    :ok
  end

  defp terminate_session(session_mod, session_pid, supervisor) do
    if function_exported?(session_mod, :close, 1) do
      try do
        session_mod.close(session_pid)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    _ = ManagedSupervisor.terminate_session(session_pid, supervisor: supervisor)
    :ok
  end

  defp safe_pool_checkin(pool_mod, session_pid) do
    try do
      if function_exported?(pool_mod, :checkin, 1) do
        pool_mod.checkin(session_pid)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp safe_pool_hard_close(pool_mod, session_mod, session_pid) do
    try do
      cond do
        function_exported?(pool_mod, :close_session, 1) ->
          pool_mod.close_session(session_pid)

        function_exported?(session_mod, :close, 1) ->
          session_mod.close(session_pid)

        true ->
          if is_pid(session_pid) and Process.alive?(session_pid) do
            Process.exit(session_pid, :shutdown)
          end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # -- Helpers --------------------------------------------------------

  defp strip_caller_owner_opts(opts) when is_list(opts) do
    Keyword.drop(opts, [:owner, :owner_pid, "owner", "owner_pid"])
  end

  defp session_operation_opts(opts) when is_list(opts) do
    Keyword.drop(opts, [
      :server,
      :task_id,
      :principal_id,
      :agent_id,
      :owner,
      :owner_pid,
      :use_pool,
      :pooled,
      :return_to_pool,
      :session_module,
      :pool_module,
      :supervisor,
      :create_session
    ])
  end

  # Prefer a live status field when present; otherwise call context_pressure?/1
  # when exported. Any failure fails closed to false (never invent pressure).
  defp resolve_context_pressure(session_mod, session_pid, live_map) when is_map(live_map) do
    case map_get_either(live_map, :context_pressure, "context_pressure") do
      :__missing__ ->
        call_context_pressure?(session_mod, session_pid)

      value ->
        value == true
    end
  end

  defp call_context_pressure?(session_mod, session_pid) do
    if function_exported?(session_mod, :context_pressure?, 1) do
      try do
        session_mod.context_pressure?(session_pid) == true
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  defp map_get_either(map, atom_key, string_key) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> :__missing__
    end
  end

  defp extract_provider_session_id(info) when is_map(info) do
    Map.get(info, "sessionId") ||
      Map.get(info, :sessionId) ||
      Map.get(info, "session_id") ||
      Map.get(info, :session_id)
  end

  defp extract_provider_session_id(_), do: nil

  defp provider_to_string(nil), do: nil
  defp provider_to_string(p) when is_atom(p), do: Atom.to_string(p)
  defp provider_to_string(p) when is_binary(p), do: p
  defp provider_to_string(p), do: inspect(p)

  defp model_to_string(nil), do: nil
  defp model_to_string(m) when is_binary(m), do: m
  defp model_to_string(m) when is_atom(m), do: Atom.to_string(m)
  defp model_to_string(m), do: to_string(m)

  defp status_to_string(nil), do: "ready"
  defp status_to_string(s) when is_atom(s), do: Atom.to_string(s)
  defp status_to_string(s) when is_binary(s), do: s
  defp status_to_string(s), do: inspect(s)
end
