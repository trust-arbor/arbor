defmodule Arbor.AI.AcpManaged do
  @moduledoc false
  # Internal orchestration for managed ACP sessions.
  # Public entry points live on `Arbor.AI` and must stay thin.

  alias Arbor.AI.AcpManaged.SessionRegistry
  alias Arbor.AI.AcpManaged.Supervisor, as: ManagedSupervisor
  alias Arbor.AI.AcpPool
  alias Arbor.AI.AcpSession
  alias Arbor.AI.OwnedOperation

  @default_operation_timeout_ms 120_000
  @cleanup_timeout_ms 500
  @default_inventory_items 64
  @max_inventory_items 1_000
  @max_inventory_id_bytes 256
  @task_read_uri "arbor://agent/task/read"
  @inventory_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/

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

    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms),
         :ok <- validate_resume_option(opts) do
      use_pool? = Keyword.get(opts, :use_pool) || Keyword.get(opts, :pooled) || false

      if use_pool? do
        start_pooled(provider, opts)
      else
        start_non_pooled(provider, opts)
      end
    end
  end

  @doc false
  @spec send_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(worker_session_id, content, opts \\ [])
      when is_binary(worker_session_id) and is_binary(content) and is_list(opts) do
    with {:ok, opts, _timeout} <-
           Arbor.AI.Timeout.start_deadline(opts, @default_operation_timeout_ms),
         {:ok, registry_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts),
         {:ok, resolved} <- SessionRegistry.resolve(worker_session_id, registry_opts),
         {:ok, operation_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts),
         operation_opts = session_operation_opts(operation_opts) do
      safe_send_message(resolved, content, operation_opts)
    end
  end

  @doc false
  @spec deliver_task_control(String.t(), String.t(), map(), keyword()) ::
          {:ok, :queued | :delivered | :deferred, :same_session_follow_up} | {:error, term()}
  def deliver_task_control(task_id, principal_id, control, opts \\ [])
      when is_binary(task_id) and is_binary(principal_id) and is_map(control) and is_list(opts) do
    with {:ok, opts, timeout} <- Arbor.AI.Timeout.normalize(opts, 5_000),
         {:ok, requested_control_timeout} <-
           Arbor.AI.Timeout.select(opts, [:control_timeout], timeout, 1, true),
         control_timeout = min_timeout(timeout, requested_control_timeout),
         opts =
           opts
           |> Enum.reject(fn {key, _value} -> key == :control_timeout end)
           |> Keyword.put(:timeout, control_timeout),
         {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, control_timeout),
         {:ok, registry_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts),
         {:ok, resolved} <-
           SessionRegistry.resolve_task_control(task_id, principal_id, registry_opts) do
      control = control |> Map.delete(:task_id) |> Map.put("task_id", task_id)

      with {:ok, _operation_opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
        safe_deliver_task_control(resolved, control, remaining)
      end
    end
  end

  @doc false
  @spec session_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def session_status(worker_session_id, opts \\ [])
      when is_binary(worker_session_id) and is_list(opts) do
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 5_000),
         {:ok, registry_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts),
         {:ok, resolved} <- SessionRegistry.resolve(worker_session_id, registry_opts),
         {:ok, _operation_opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      session_mod = resolved.session_module

      # Live status is optional enrichment. Failures must not invent "ready"
      # metadata and must not invalidate a still-live handle (busy prompt timeout).
      live = safe_status(session_mod, resolved.session_pid, remaining)

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
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 5_000),
         {:ok, opts, _remaining} <- Arbor.AI.Timeout.remaining(opts) do
      SessionRegistry.close(worker_session_id, opts)
    end
  end

  @doc false
  @spec public_session_inventory(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def public_session_inventory(opts) do
    with {:ok, normalized} <- normalize_inventory_options(opts, false),
         :ok <- authorize_session_inventory(normalized),
         result <- fetch_session_inventory(normalized, []) do
      normalize_session_inventory_result(result)
    end
  end

  @doc false
  @spec session_inventory(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def session_inventory(opts) do
    with {:ok, normalized} <- normalize_inventory_options(opts, true),
         :ok <- authorize_session_inventory(normalized),
         result <- fetch_session_inventory(normalized, normalized.registry_opts) do
      normalize_session_inventory_result(result)
    end
  end

  defp fetch_session_inventory(normalized, registry_opts) do
    SessionRegistry.inventory(normalized.filters, normalized.max_items, registry_opts)
  end

  defp authorize_session_inventory(%{caller_id: caller_id, filters: filters}) do
    resource_uri =
      case filters.task_id do
        nil -> @task_read_uri
        task_id -> @task_read_uri <> "/" <> task_id
      end

    auth_opts =
      [verify_identity: false]
      |> maybe_put_principal_scope(filters.principal_id)

    try do
      case Arbor.Security.authorize(caller_id, resource_uri, :read, auth_opts) do
        {:ok, :authorized} -> :ok
        _ -> {:error, {:unauthorized, :task_read_required}}
      end
    rescue
      _ -> {:error, {:unauthorized, :task_read_required}}
    catch
      _, _ -> {:error, {:unauthorized, :task_read_required}}
    end
  end

  defp maybe_put_principal_scope(opts, nil), do: opts

  defp maybe_put_principal_scope(opts, principal_id),
    do: Keyword.put(opts, :principal_scope, principal_id)

  defp normalize_session_inventory_result({:ok, inventory}) when is_map(inventory),
    do: {:ok, inventory}

  defp normalize_session_inventory_result(_result),
    do: {:error, :session_inventory_unavailable}

  defp normalize_inventory_options(opts, allow_server?) when is_list(opts) or is_map(opts) do
    entries = if is_list(opts), do: opts, else: Map.to_list(opts)
    keys = Enum.map(entries, &inventory_option_key/1)

    allowed =
      [:caller_id, :task_id, :principal_id, :max_items] ++
        if(allow_server?, do: [:server], else: [])

    cond do
      :invalid in keys -> {:error, :invalid_session_inventory_options}
      Enum.any?(keys, &(&1 not in allowed)) -> {:error, :invalid_session_inventory_options}
      length(keys) != length(Enum.uniq(keys)) -> {:error, :invalid_session_inventory_options}
      true -> build_inventory_options(entries, allow_server?)
    end
  rescue
    _ -> {:error, :invalid_session_inventory_options}
  catch
    _, _ -> {:error, :invalid_session_inventory_options}
  end

  defp normalize_inventory_options(_opts, _allow_server?),
    do: {:error, :invalid_session_inventory_options}

  defp inventory_option_key({key, _value}) when is_atom(key), do: key
  defp inventory_option_key(_entry), do: :invalid

  defp build_inventory_options(entries, allow_server?) do
    with {:ok, caller_id} <- normalize_inventory_id(Keyword.get(entries, :caller_id)),
         {:ok, task_id} <- normalize_optional_inventory_id(Keyword.get(entries, :task_id), true),
         {:ok, principal_id} <-
           normalize_optional_inventory_id(Keyword.get(entries, :principal_id), false),
         {:ok, max_items} <- normalize_inventory_max_items(Keyword.get(entries, :max_items)),
         {:ok, server} <- normalize_inventory_server(entries, allow_server?) do
      registry_opts = if is_nil(server), do: [], else: [server: server]

      {:ok,
       %{
         caller_id: caller_id,
         filters: %{task_id: task_id, principal_id: principal_id},
         max_items: max_items,
         registry_opts: registry_opts
       }}
    else
      _ -> {:error, :invalid_session_inventory_options}
    end
  end

  defp normalize_inventory_id(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_inventory_id_bytes do
    if String.valid?(value) and String.trim(value) == value and
         Regex.match?(@inventory_id_pattern, value) do
      {:ok, value}
    else
      {:error, :invalid_inventory_id}
    end
  end

  defp normalize_inventory_id(_value), do: {:error, :invalid_inventory_id}

  defp normalize_optional_inventory_id(nil, _task_id?), do: {:ok, nil}

  defp normalize_optional_inventory_id(value, true) do
    with {:ok, value} <- normalize_inventory_id(value), do: {:ok, value}
  end

  defp normalize_optional_inventory_id(value, false) do
    with {:ok, value} <- normalize_inventory_id(value), do: {:ok, value}
  end

  defp normalize_inventory_max_items(nil), do: {:ok, @default_inventory_items}

  defp normalize_inventory_max_items(value)
       when is_integer(value) and value > 0 and value <= @max_inventory_items,
       do: {:ok, value}

  defp normalize_inventory_max_items(_value), do: {:error, :invalid_max_items}

  defp normalize_inventory_server(_entries, false), do: {:ok, nil}

  defp normalize_inventory_server(entries, true) do
    case Keyword.fetch(entries, :server) do
      {:ok, server} -> {:ok, server}
      :error -> {:ok, nil}
    end
  end

  # -- Start paths ----------------------------------------------------

  defp start_non_pooled(provider, opts) do
    session_mod = Keyword.get(opts, :session_module, AcpSession)
    supervisor = Keyword.get(opts, :supervisor, ManagedSupervisor)

    # Owner is the live task caller; never a supplied owner option.
    with {:ok, phase_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts) do
      session_opts =
        phase_opts
        |> Keyword.drop(@registry_only_opts)
        |> Keyword.put(:provider, provider)
        |> Keyword.put(:owner, self())

      start_opts = [supervisor: supervisor, deadline_ms: Keyword.fetch!(phase_opts, :deadline_ms)]

      ManagedSupervisor.start_session(session_mod, session_opts, start_opts)
    end
    |> case do
      {:ok, session_pid} ->
        finalize_non_pooled_start(
          session_mod,
          session_pid,
          provider,
          opts,
          supervisor
        )

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  rescue
    exception ->
      {:error, {:managed_start_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, reason ->
      {:error, {:managed_start_exit, Arbor.LLM.sanitize_external_reason(reason)}}

    kind, reason ->
      {:error, {:managed_start_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp finalize_non_pooled_start(
         session_mod,
         session_pid,
         provider,
         opts,
         supervisor
       ) do
    try do
      case create_or_resume(session_mod, session_pid, opts) do
        {:ok, session_info} ->
          case provider_session_id_for_start(session_info, opts) do
            {:ok, provider_session_id} ->
              register_attrs = %{
                session_pid: session_pid,
                session_module: session_mod,
                provider: provider,
                model: Keyword.get(opts, :model),
                session_id: provider_session_id,
                status: "ready",
                pooled: false,
                return_to_pool: false,
                task_id: Keyword.get(opts, :task_id),
                principal_id: Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id)
              }

              case register_before_deadline(register_attrs, opts) do
                {:ok, view} ->
                  {:ok, view}

                {:error, reason} ->
                  cleanup_failed_start(session_mod, session_pid, supervisor,
                    pooled?: false,
                    deadline_opts: opts
                  )

                  {:error, reason}
              end

            {:error, reason} ->
              cleanup_failed_start(session_mod, session_pid, supervisor,
                pooled?: false,
                deadline_opts: opts
              )

              {:error, reason}
          end

        {:error, reason} ->
          cleanup_failed_start(session_mod, session_pid, supervisor,
            pooled?: false,
            deadline_opts: opts
          )

          {:error, Arbor.LLM.sanitize_external_reason(reason)}
      end
    rescue
      exception ->
        cleanup_failed_start(session_mod, session_pid, supervisor,
          pooled?: false,
          deadline_opts: opts
        )

        {:error, {:managed_start_failed, Arbor.LLM.external_exception_message(exception)}}
    catch
      :exit, reason ->
        cleanup_failed_start(session_mod, session_pid, supervisor,
          pooled?: false,
          deadline_opts: opts
        )

        {:error, {:managed_start_exit, Arbor.LLM.sanitize_external_reason(reason)}}

      kind, reason ->
        cleanup_failed_start(session_mod, session_pid, supervisor,
          pooled?: false,
          deadline_opts: opts
        )

        {:error, {:managed_start_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
    end
  end

  defp start_pooled(provider, opts) do
    session_mod = Keyword.get(opts, :session_module, AcpSession)
    pool_mod = Keyword.get(opts, :pool_module, AcpPool)
    return_to_pool = Keyword.get(opts, :return_to_pool, true)

    with {:ok, phase_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts) do
      # Pass task_id into the pool so SessionProfile scopes local reuse by task.
      # Drop only managed/registry opts and child-unsupported keys that the pool
      # must not treat as AcpSession start options (session_id/create_session are
      # applied after checkout on a fresh or compatible local process).
      checkout_opts =
        phase_opts
        |> Keyword.drop([
          :use_pool,
          :pooled,
          :return_to_pool,
          :session_module,
          :pool_module,
          :supervisor,
          :server,
          :principal_id,
          :session_id,
          :create_session
        ])

      pool_mod.checkout(provider, checkout_opts)
    end
    |> case do
      {:ok, session_pid} ->
        finalize_pooled_start(
          session_mod,
          pool_mod,
          session_pid,
          provider,
          opts,
          return_to_pool
        )

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  rescue
    exception ->
      {:error, {:managed_start_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, reason ->
      {:error, {:managed_start_exit, Arbor.LLM.sanitize_external_reason(reason)}}

    kind, reason ->
      {:error, {:managed_start_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp finalize_pooled_start(
         session_mod,
         pool_mod,
         session_pid,
         provider,
         opts,
         return_to_pool
       ) do
    continuity =
      if Keyword.has_key?(opts, :session_id) or Keyword.get(opts, :create_session, false),
        do: :provider_session,
        else: :pooled_pre_session

    cleanup_opts = [
      pooled?: true,
      return_to_pool: return_to_pool,
      continuity: continuity,
      deadline_opts: opts
    ]

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
            %{},
            cleanup_opts,
            allow_missing_identity: true
          )

        {:ok, session_info} ->
          register_pooled(
            session_mod,
            pool_mod,
            session_pid,
            provider,
            opts,
            return_to_pool,
            session_info,
            cleanup_opts
          )

        {:error, reason} ->
          cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
          {:error, Arbor.LLM.sanitize_external_reason(reason)}
      end
    rescue
      exception ->
        cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
        {:error, {:managed_start_failed, Arbor.LLM.external_exception_message(exception)}}
    catch
      :exit, reason ->
        cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
        {:error, {:managed_start_exit, Arbor.LLM.sanitize_external_reason(reason)}}

      kind, reason ->
        cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
        {:error, {:managed_start_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
    end
  end

  defp register_pooled(
         session_mod,
         pool_mod,
         session_pid,
         provider,
         opts,
         return_to_pool,
         session_info,
         cleanup_opts,
         registration_opts \\ []
       ) do
    session_id_result =
      if Keyword.get(registration_opts, :allow_missing_identity, false) do
        {:ok, nil}
      else
        provider_session_id_for_start(session_info, opts)
      end

    case session_id_result do
      {:ok, provider_session_id} ->
        register_attrs = %{
          session_pid: session_pid,
          session_module: session_mod,
          pool_module: pool_mod,
          provider: provider,
          model: Keyword.get(opts, :model),
          session_id: provider_session_id,
          status: "ready",
          pooled: true,
          return_to_pool: return_to_pool,
          task_id: Keyword.get(opts, :task_id),
          principal_id: Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id)
        }

        case register_before_deadline(register_attrs, opts) do
          {:ok, view} ->
            {:ok, view}

          {:error, reason} ->
            cleanup_failed_start(session_mod, session_pid, pool_mod, cleanup_opts)
            {:error, reason}
        end

      {:error, reason} ->
        cleanup_failed_start(
          session_mod,
          session_pid,
          pool_mod,
          Keyword.put(cleanup_opts, :continuity, :provider_session)
        )

        {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  end

  # Non-pooled starts always create or resume.
  defp create_or_resume(session_mod, session_pid, opts) do
    with {:ok, phase_opts} <- session_phase_opts(opts) do
      OwnedOperation.run(
        fn ->
          case Keyword.fetch(opts, :session_id) do
            {:ok, sid} ->
              with {:ok, sid} <- AcpSession.validate_provider_session_id(sid),
                   result <- session_mod.resume_session(session_pid, sid, phase_opts),
                   {:ok, info} <- normalize_session_result(result),
                   :ok <- AcpSession.validate_resume_session_response(info, sid) do
                {:ok, info}
              else
                {:error, reason} -> {:error, reason}
              end

            :error ->
              session_mod.create_session(session_pid, phase_opts)
          end
        end,
        phase_opts,
        :timeout
      )
      |> normalize_session_result()
    end
  end

  # Pooled path: explicit resume or create_session: true must succeed or fail.
  # :skip is only valid when neither was requested.
  defp maybe_create_or_resume_pooled(session_mod, session_pid, opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, sid} ->
        with {:ok, phase_opts} <- session_phase_opts(opts) do
          OwnedOperation.run(
            fn ->
              with {:ok, sid} <- AcpSession.validate_provider_session_id(sid),
                   result <- session_mod.resume_session(session_pid, sid, phase_opts),
                   {:ok, info} <- normalize_session_result(result),
                   :ok <- AcpSession.validate_resume_session_response(info, sid) do
                {:ok, info}
              else
                {:error, reason} -> {:error, reason}
              end
            end,
            phase_opts,
            :timeout
          )
          |> normalize_session_result()
        end

      _ ->
        if Keyword.get(opts, :create_session, false) do
          with {:ok, phase_opts} <- session_phase_opts(opts) do
            OwnedOperation.run(
              fn -> session_mod.create_session(session_pid, phase_opts) end,
              phase_opts,
              :timeout
            )
            |> normalize_session_result()
          end
        else
          case Arbor.AI.Timeout.ensure_active(opts) do
            :ok -> :skip
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp session_phase_opts(opts) do
    with {:ok, phase_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts) do
      {:ok, Keyword.take(phase_opts, [:timeout, :deadline_ms, :cwd])}
    end
  end

  defp normalize_session_result({:ok, info}), do: {:ok, info}

  defp normalize_session_result({:error, {:operation_failed, :exit, reason}}),
    do: {:error, {:managed_start_exit, reason}}

  defp normalize_session_result({:error, reason}), do: {:error, reason}

  defp normalize_session_result(other),
    do: {:error, {:unexpected_result, Arbor.LLM.sanitize_external_reason(other)}}

  defp register_before_deadline(attrs, opts) do
    with {:ok, registry_opts, _remaining} <- Arbor.AI.Timeout.remaining(opts),
         registry_opts =
           Keyword.take(registry_opts, [:server, :timeout, :deadline_ms]),
         result <- SessionRegistry.register(attrs, registry_opts),
         :ok <- Arbor.AI.Timeout.ensure_active(opts) do
      result
    end
  end

  # -- Cleanup --------------------------------------------------------

  defp cleanup_failed_start(session_mod, session_pid, pool_or_sup, opts) do
    pooled? = Keyword.get(opts, :pooled?, false)
    return_to_pool? = Keyword.get(opts, :return_to_pool, true)
    continuity = Keyword.get(opts, :continuity, :provider_session)
    deadline_opts = Keyword.get(opts, :deadline_opts, expired_cleanup_opts())

    return_to_pool? =
      pooled? and return_to_pool? and continuity == :pooled_pre_session and is_atom(pool_or_sup)

    result =
      OwnedOperation.run(
        fn ->
          cond do
            return_to_pool? ->
              pool_checkin(pool_or_sup, session_pid, deadline_opts)

            pooled? and is_atom(pool_or_sup) ->
              pool_hard_close(pool_or_sup, session_mod, session_pid, deadline_opts)

            true ->
              close_session_process(session_mod, session_pid, deadline_opts)
          end
        end,
        deadline_opts,
        :timeout
      )

    unless return_to_pool? and result == :ok do
      terminate_session_process(session_pid)
    end

    :ok
  end

  defp pool_checkin(pool_mod, session_pid, opts) do
    cond do
      function_exported?(pool_mod, :checkin, 2) -> pool_mod.checkin(session_pid, opts)
      function_exported?(pool_mod, :checkin, 1) -> pool_mod.checkin(session_pid)
      true -> {:error, :pool_checkin_unavailable}
    end
  end

  defp pool_hard_close(pool_mod, session_mod, session_pid, opts) do
    cond do
      function_exported?(pool_mod, :close_session, 2) ->
        pool_mod.close_session(session_pid, opts)

      function_exported?(pool_mod, :close_session, 1) ->
        pool_mod.close_session(session_pid)

      true ->
        close_session_process(session_mod, session_pid, opts)
    end
  end

  defp close_session_process(session_mod, session_pid, opts) do
    cond do
      function_exported?(session_mod, :close, 2) -> session_mod.close(session_pid, opts)
      function_exported?(session_mod, :close, 1) -> session_mod.close(session_pid)
      true -> terminate_session_process(session_pid)
    end
  end

  defp terminate_session_process(session_pid) when is_pid(session_pid) do
    if Process.alive?(session_pid), do: Process.exit(session_pid, :kill)
    :ok
  end

  defp terminate_session_process(_session_pid), do: :ok

  defp expired_cleanup_opts do
    deadline = System.monotonic_time(:millisecond) - 1
    [timeout: @cleanup_timeout_ms, deadline_ms: deadline]
  end

  # -- Helpers --------------------------------------------------------

  defp validate_resume_option(opts) do
    case Keyword.fetch(opts, :session_id) do
      :error ->
        :ok

      {:ok, session_id} ->
        case AcpSession.validate_provider_session_id(session_id) do
          {:ok, _session_id} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp provider_session_id_for_start(session_info, opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, session_id} -> AcpSession.validate_provider_session_id(session_id)
      :error -> AcpSession.provider_session_id(session_info)
    end
  end

  defp strip_caller_owner_opts(opts) when is_list(opts) do
    Enum.reject(opts, fn
      {key, _value} -> key in [:owner, :owner_pid, "owner", "owner_pid"]
      _invalid -> false
    end)
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

  defp min_timeout(:infinity, timeout), do: timeout
  defp min_timeout(timeout, :infinity), do: timeout
  defp min_timeout(left, right), do: min(left, right)

  defp safe_send_message(resolved, content, opts) do
    case resolved.session_module.send_message(resolved.session_pid, content, opts) do
      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}

      result ->
        case Arbor.AI.Timeout.ensure_active(opts) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    exception ->
      {:error, {:managed_send_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:managed_send_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp safe_deliver_task_control(resolved, control, timeout) do
    case resolved.session_module.deliver_task_control(
           resolved.session_pid,
           control,
           timeout: timeout
         ) do
      {:error, reason} -> {:error, Arbor.LLM.sanitize_external_reason(reason)}
      result -> result
    end
  rescue
    exception ->
      {:error, {:managed_control_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:managed_control_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp safe_status(session_mod, session_pid, :infinity) do
    session_mod.status(session_pid)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_status(session_mod, session_pid, timeout) do
    Arbor.LLM.run_with_deadline(
      fn -> session_mod.status(session_pid) end,
      timeout,
      :managed_status_timeout
    )
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

  defp provider_to_string(nil), do: nil
  defp provider_to_string(p) when is_atom(p), do: Atom.to_string(p)
  defp provider_to_string(p) when is_binary(p), do: p
  defp provider_to_string(p), do: Arbor.LLM.inspect_external_reason(p)

  defp model_to_string(nil), do: nil
  defp model_to_string(m) when is_binary(m), do: m
  defp model_to_string(m) when is_atom(m), do: Atom.to_string(m)
  defp model_to_string(m), do: Arbor.LLM.inspect_external_reason(m)

  defp status_to_string(nil), do: "ready"
  defp status_to_string(s) when is_atom(s), do: Atom.to_string(s)
  defp status_to_string(s) when is_binary(s), do: s
  defp status_to_string(s), do: Arbor.LLM.inspect_external_reason(s)
end
