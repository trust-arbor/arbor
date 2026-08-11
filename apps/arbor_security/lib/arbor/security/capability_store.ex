defmodule Arbor.Security.CapabilityStore do
  @moduledoc """
  Capability storage with pluggable persistence.

  Stores capabilities indexed by ID and by principal for fast lookup.
  Handles expiration cleanup automatically.

  Capabilities are persisted via a configurable storage backend
  (implementing `Arbor.Contracts.Persistence.Store`) and restored on startup.

  ## Configuration

      config :arbor_security, :storage_backend, Arbor.Security.Store.JSONFile

  Set to `nil` to disable persistence (in-memory only).
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.Config
  alias Arbor.Security.SignalSync
  alias Arbor.Security.SystemAuthority
  alias Arbor.Signals

  # Runtime bridges — arbor_persistence is above Security, so avoid a compile-time dep.
  @persistence Arbor.Persistence
  @buffered_store Arbor.Persistence.BufferedStore
  @cap_store :arbor_security_capabilities

  # VP-05D2A0 — interactive-disclosure capability namespace, kept distinct
  # from ordinary `constraints.egress` refinement. Segment-aware membership
  # only (never String.starts_with?/2) — see CapabilityUri.prefix_match?/2.
  @disclosure_uri_prefix "arbor://egress/disclose"

  @cleanup_interval_ms 60_000
  @signal_events [
    :capability_granted,
    :capability_revoked,
    :capabilities_revoked_all,
    :capabilities_cascade_revoked,
    :capabilities_scope_revoked
  ]

  # Client API

  @doc """
  Start the capability store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a capability.

  Returns `{:ok, :stored}` on success, or `{:error, reason}` if quota is exceeded:
  - `{:error, {:quota_exceeded, :per_agent_capability_limit, context}}`
  - `{:error, {:quota_exceeded, :global_capability_limit, context}}`
  - `{:error, {:quota_exceeded, :delegation_depth_limit, context}}`
  """
  @spec put(Capability.t()) :: {:ok, :stored} | {:error, term()}
  def put(%Capability{} = cap) do
    GenServer.call(__MODULE__, {:put, cap})
  end

  @doc """
  Get a capability by ID.
  """
  @spec get(String.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def get(capability_id) do
    GenServer.call(__MODULE__, {:get, capability_id})
  end

  @doc """
  List capabilities for a principal.
  """
  @spec list_for_principal(String.t(), keyword()) :: {:ok, [Capability.t()]}
  def list_for_principal(principal_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_for_principal, principal_id, opts})
  end

  @doc """
  Find a capability that authorizes access to the given resource.

  The action is encoded in the resource URI: `arbor://{type}/{action}/{path}`
  """
  @spec find_authorizing(String.t(), String.t()) ::
          {:ok, Capability.t()} | {:error, :not_found}
  def find_authorizing(principal_id, resource_uri) do
    GenServer.call(__MODULE__, {:find_authorizing, principal_id, resource_uri})
  end

  @doc """
  Revoke a capability by ID.
  """
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(capability_id) do
    GenServer.call(__MODULE__, {:revoke, capability_id})
  end

  @doc """
  Revoke all capabilities for a principal.
  """
  @spec revoke_all(String.t()) :: {:ok, non_neg_integer()}
  def revoke_all(principal_id) do
    GenServer.call(__MODULE__, {:revoke_all, principal_id})
  end

  @doc """
  Cascade revoke a capability and all its delegated children.

  Revokes the specified capability and recursively revokes all capabilities
  that were delegated from it (directly or transitively).

  Returns `{:ok, count}` where count is the total number of capabilities revoked.
  """
  @spec cascade_revoke(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def cascade_revoke(capability_id) do
    GenServer.call(__MODULE__, {:cascade_revoke, capability_id})
  end

  @doc """
  Increment the usage counter for a capability.

  Returns `{:ok, new_count}` or `{:error, :not_found}`.
  """
  @spec increment_usage(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def increment_usage(capability_id) do
    GenServer.call(__MODULE__, {:increment_usage, capability_id})
  end

  @doc """
  Revoke all capabilities bound to a specific session.

  Called when a session ends to clean up session-scoped capabilities.
  Returns `{:ok, count}` of revoked capabilities.
  """
  @spec revoke_by_session(String.t()) :: {:ok, non_neg_integer()}
  def revoke_by_session(session_id) do
    GenServer.call(__MODULE__, {:revoke_by_scope, :session_id, session_id})
  end

  @doc """
  Revoke all capabilities bound to a specific task.

  Called when a task/pipeline execution ends to clean up task-scoped capabilities.
  Returns `{:ok, count}` of revoked capabilities.
  """
  @spec revoke_by_task(String.t()) :: {:ok, non_neg_integer()}
  def revoke_by_task(task_id) do
    GenServer.call(__MODULE__, {:revoke_by_scope, :task_id, task_id})
  end

  @doc """
  Get store statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  List capabilities for a principal that are current, stored, signed when
  required, delegation-chain valid, and scope-matched (VP-05D2A0 hardened
  replacement for the raw `list_for_principal/2` shortcut as an authorization
  candidate source). Excludes any capability in the `arbor://egress/disclose`
  namespace — disclosure caps never participate in ordinary refinement.

  `opts`: `:session_id`, `:task_id`, `:principal_scope` — the live request's
  scope, used for `Capability.scope_matches?/2` filtering.

  Fails closed to `{:ok, []}` if the store process itself is unreachable —
  callers treat an empty candidate list identically to "no covering cap".
  """
  @spec list_valid_for_principal(String.t(), keyword()) :: {:ok, [Capability.t()]}
  def list_valid_for_principal(principal_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_valid_for_principal, principal_id, opts})
  rescue
    _ -> {:ok, []}
  catch
    :exit, _ -> {:ok, []}
    :throw, _ -> {:ok, []}
  end

  @doc """
  Fetch and validate an exact disclosure capability by id in one linearized
  store call (VP-05D2A0). Checks: stored under this id, in the
  `arbor://egress/disclose` namespace, `principal_id` matches, current
  (`Capability.valid?/1`), ALWAYS signed (regardless of the global
  `capability_signing_required?` config), delegation-chain valid, and
  scope-matched against `scope_context` (`:session_id`/`:task_id`/`:principal_scope`).

  Because this all happens inside one `handle_call`, a concurrent `revoke/1`
  cannot interleave mid-check — whichever message the store's mailbox
  processes first determines the outcome.

  Fails closed to `{:error, :capability_store_unavailable}` if the store
  process itself is unreachable.
  """
  @spec get_valid_disclosure(String.t(), String.t(), keyword()) ::
          {:ok, Capability.t()} | {:error, atom()}
  def get_valid_disclosure(capability_id, principal_id, scope_context \\ []) do
    GenServer.call(
      __MODULE__,
      {:get_valid_disclosure, capability_id, principal_id, scope_context}
    )
  rescue
    _ -> {:error, :capability_store_unavailable}
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
    :throw, _ -> {:error, :capability_store_unavailable}
  end

  @doc false
  @spec get_valid_exact_ordinary(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Capability.t()} | {:error, atom()}
  def get_valid_exact_ordinary(capability_id, principal_id, resource_uri, scope_context \\ []) do
    GenServer.call(
      __MODULE__,
      {:get_valid_exact_ordinary, capability_id, principal_id, resource_uri, scope_context}
    )
  rescue
    _ -> {:error, :capability_store_unavailable}
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
    :throw, _ -> {:error, :capability_store_unavailable}
  end

  # ===========================================================================
  # Acknowledged exact mutation client API (Phase 4C C3A).
  #
  # Crash-journal-safe grant/revoke. The caller (the Arbor.Security facade)
  # supplies a fully signed capability built from a deterministic id +
  # granted_at. Returns bounded status + opaque capability id only; never a
  # Capability struct or persistence Record. Exit mapping at the client: a
  # definitively-down store (:noproc / not registered) is
  # :capability_store_unavailable; a timeout or other exit (which may occur
  # after a durable admission) is :outcome_unknown — never success.
  # ===========================================================================

  @doc """
  Acknowledged, crash-journal-safe exact put of an already-signed capability.

  Never replaces a different capability: a same-principal+resource occupant
  under a different id returns `:resource_conflict`, a mismatched occupant
  under the same id returns `:id_conflict`, and an exact durable replay
  returns `{:ok, :idempotent, id}`. A fresh grant is durably acknowledged and
  its authoritative record is decoded and verified before the live projection,
  cluster signal, or success advance.
  """
  @spec acknowledged_put(Capability.t()) ::
          {:ok, :applied | :idempotent, String.t()}
          | {:error,
             :id_conflict
             | :resource_conflict
             | :quota_exceeded
             | :capability_store_unavailable
             | :outcome_unknown}
  def acknowledged_put(%Capability{} = cap) do
    if Process.whereis(__MODULE__) == nil do
      {:error, :capability_store_unavailable}
    else
      GenServer.call(__MODULE__, {:acknowledged_put, cap}, acknowledged_call_timeout_ms())
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  @doc """
  Acknowledged, crash-journal-safe exact revoke by id.

  Authoritative absence is `{:ok, :idempotent, id}`; a durably-acknowledged
  deletion precedes live eviction and `{:ok, :applied, id}`. An ambiguous
  persistence result is never reported as applied (`:outcome_unknown`).

  Idempotent convergence: an authoritative-absent revoke that newly evicts a
  stale live projection emits exactly one restricted revocation signal (cluster
  sync) and advances no stat; a true replay (absent everywhere) emits no signal
  and advances no stat. Only an applied (durably-acknowledged) delete advances
  the revoked stat and emits its signal. The durable layer remains
  authoritative.
  """
  @spec acknowledged_revoke(String.t()) ::
          {:ok, :applied | :idempotent, String.t()}
          | {:error, :capability_store_unavailable | :outcome_unknown}
  def acknowledged_revoke(capability_id) when is_binary(capability_id) do
    if Process.whereis(__MODULE__) == nil do
      {:error, :capability_store_unavailable}
    else
      GenServer.call(
        __MODULE__,
        {:acknowledged_revoke, capability_id},
        acknowledged_call_timeout_ms()
      )
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  def acknowledged_revoke(_capability_id), do: {:error, :outcome_unknown}

  defp acknowledged_call_timeout_ms, do: 5_000

  # Server callbacks

  @impl true
  def init(_opts) do
    case subscribe_to_distributed_signals() do
      {:ok, signal_sync} ->
        state = %{
          by_id: %{},
          by_principal: %{},
          by_resource: %{},
          pending_intents: %{},
          by_issuer: %{},
          by_parent: %{},
          by_usage: %{},
          signal_sync: signal_sync,
          stats: %{
            total_granted: 0,
            total_revoked: 0,
            total_expired: 0,
            total_cascade_revoked: 0,
            restore_scanned: 0,
            restore_active: 0,
            restore_expired: 0,
            restore_superseded: 0,
            restore_rejected: 0
          }
        }

        case restore_from_store(state) do
          {:ok, restored} ->
            schedule_cleanup()
            {:ok, restored}

          {:error, reason} when is_atom(reason) ->
            _ = SignalSync.release(signal_sync)
            {:stop, {:capability_restore_failed, reason}}

          # Never let Serializer exception terms or other non-atoms reach OTP stop.
          {:error, _reason} ->
            _ = SignalSync.release(signal_sync)
            {:stop, {:capability_restore_failed, :invalid_capability_record}}
        end

      {:error, reason} ->
        {:stop, {:security_sync_subscription_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, cap}, _from, state) do
    case check_quotas(state, cap) do
      :ok ->
        # Deduplicate: if a capability with the same principal+resource already exists,
        # replace it instead of appending (prevents unbounded growth from re-grants)
        replaced_id = existing_capability_id(state, cap)

        case replaced_id do
          nil ->
            state = add_capability_to_state(state, cap)
            _ = persist_capability(cap, acknowledged: false)
            emit_capability_signal(:capability_granted, cap)
            {:reply, {:ok, :stored}, state}

          id ->
            existing_cap = Map.fetch!(state.by_id, id)

            case replace_persisted_capability(existing_cap, cap) do
              :ok ->
                {state, ^id} = maybe_replace_existing(state, cap)
                state = add_capability_to_state(state, cap)

                emit_revocation_signal(
                  :capability_revoked,
                  [existing_cap.id],
                  existing_cap.principal_id
                )

                emit_capability_signal(:capability_granted, cap)
                {:reply, {:ok, :stored}, state}

              {:error, reason} = error ->
                Logger.error(
                  "Capability replacement failed for #{cap.id}; " <>
                    "superseded #{id} was retained: #{inspect(reason)}"
                )

                {:reply, error, state}
            end
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get, capability_id}, _from, state) do
    result =
      case Map.get(state.by_id, capability_id) do
        nil -> {:error, :not_found}
        cap -> check_expiration(cap)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_for_principal, principal_id, opts}, _from, state) do
    include_expired = Keyword.get(opts, :include_expired, false)

    cap_ids = Map.get(state.by_principal, principal_id, [])

    caps =
      cap_ids
      |> Enum.map(&Map.get(state.by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_filter_expired(include_expired)

    {:reply, {:ok, caps}, state}
  end

  @impl true
  def handle_call({:find_authorizing, principal_id, resource_uri}, _from, state) do
    cap_ids = Map.get(state.by_principal, principal_id, [])

    result =
      cap_ids
      |> Enum.map(&Map.get(state.by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.find(fn cap ->
        Capability.valid?(cap) and authorizes_resource?(cap, resource_uri) and
          signature_acceptable?(cap) and delegation_chain_valid?(cap)
      end)
      |> case do
        nil -> {:error, :not_found}
        cap -> {:ok, cap}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_valid_for_principal, principal_id, opts}, _from, state) do
    now = DateTime.utc_now()

    scope_context = [
      session_id: Keyword.get(opts, :session_id),
      task_id: Keyword.get(opts, :task_id),
      principal_scope: Keyword.get(opts, :principal_scope)
    ]

    caps =
      state.by_principal
      |> Map.get(principal_id, [])
      |> Enum.map(&Map.get(state.by_id, &1))
      |> Enum.reject(&(is_nil(&1) or disclosure_namespaced?(&1)))
      |> Enum.filter(&candidate_cheaply_valid?(&1, principal_id, scope_context, now))
      |> verify_ordinary_candidates()

    {:reply, {:ok, caps}, state}
  rescue
    _ -> {:reply, {:ok, []}, state}
  catch
    :exit, _ -> {:reply, {:ok, []}, state}
    :throw, _ -> {:reply, {:ok, []}, state}
  end

  @impl true
  def handle_call(
        {:get_valid_disclosure, capability_id, principal_id, scope_context},
        _from,
        state
      ) do
    now = DateTime.utc_now()

    result =
      case Map.get(state.by_id, capability_id) do
        nil ->
          {:error, :not_found}

        cap ->
          cond do
            not disclosure_namespaced?(cap) ->
              {:error, :not_disclosure_capability}

            cap.principal_id != principal_id ->
              {:error, :disclosure_capability_wrong_principal}

            not candidate_cheaply_valid?(cap, principal_id, scope_context, now) ->
              {:error, :disclosure_capability_rejected}

            not disclosure_time_candidate?(cap, now) ->
              {:error, :disclosure_capability_rejected}

            not authority_signature_ok?(cap) or not delegation_chain_valid?(cap) ->
              {:error, :disclosure_capability_rejected}

            true ->
              {:ok, cap}
          end
      end

    {:reply, result, state}
  rescue
    _ -> {:reply, {:error, :disclosure_capability_validation_error}, state}
  catch
    :exit, _ -> {:reply, {:error, :disclosure_capability_validation_unavailable}, state}
    :throw, _ -> {:reply, {:error, :disclosure_capability_validation_unavailable}, state}
  end

  @impl true
  def handle_call(
        {:get_valid_exact_ordinary, capability_id, principal_id, resource_uri, scope_context},
        _from,
        state
      ) do
    now = DateTime.utc_now()

    result =
      case Map.get(state.by_id, capability_id) do
        %Capability{} = cap ->
          if exact_ordinary_capability_valid?(
               cap,
               capability_id,
               principal_id,
               resource_uri,
               scope_context,
               now
             ) do
            {:ok, cap}
          else
            {:error, :exact_capability_rejected}
          end

        _ ->
          {:error, :not_found}
      end

    {:reply, result, state}
  rescue
    _ -> {:reply, {:error, :exact_capability_validation_error}, state}
  catch
    :exit, _ -> {:reply, {:error, :exact_capability_validation_unavailable}, state}
    :throw, _ -> {:reply, {:error, :exact_capability_validation_unavailable}, state}
  end

  @impl true
  def handle_call({:revoke, capability_id}, _from, state) do
    case Map.get(state.by_id, capability_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      cap ->
        state =
          state
          |> deindex_resource(cap)
          |> update_in([:by_id], &Map.delete(&1, capability_id))
          |> update_in([:by_principal, cap.principal_id], fn ids ->
            List.delete(ids || [], capability_id)
          end)
          |> update_in([:stats, :total_revoked], &(&1 + 1))

        delete_persisted_capability(capability_id)
        emit_revocation_signal(:capability_revoked, [capability_id], cap.principal_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:revoke_all, principal_id}, _from, state) do
    cap_ids = Map.get(state.by_principal, principal_id, [])
    count = length(cap_ids)
    revoked_caps = Enum.map(cap_ids, &Map.get(state.by_id, &1))

    Enum.each(cap_ids, &delete_persisted_capability/1)

    state =
      Enum.reduce(revoked_caps, state, fn
        %Capability{} = cap, acc -> deindex_resource(acc, cap)
        _nil_cap, acc -> acc
      end)

    state =
      state
      |> update_in([:by_id], fn by_id ->
        Enum.reduce(cap_ids, by_id, &Map.delete(&2, &1))
      end)
      |> put_in([:by_principal, principal_id], [])
      |> update_in([:stats, :total_revoked], &(&1 + count))

    if count > 0 do
      emit_revocation_signal(:capabilities_revoked_all, cap_ids, principal_id)
    end

    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_capabilities: map_size(state.by_id),
        principals_with_capabilities: map_size(state.by_principal),
        quota_max_per_agent: Config.max_capabilities_per_agent(),
        quota_max_global: Config.max_global_capabilities(),
        quota_max_delegation_depth: Config.max_delegation_depth(),
        quota_enforcement_enabled: Config.quota_enforcement_enabled?()
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:increment_usage, capability_id}, _from, state) do
    case Map.get(state.by_id, capability_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _cap ->
        new_count = Map.get(state.by_usage, capability_id, 0) + 1
        state = put_in(state, [:by_usage, capability_id], new_count)
        {:reply, {:ok, new_count}, state}
    end
  end

  @impl true
  def handle_call({:revoke_by_scope, scope_field, scope_value}, _from, state) do
    matching_ids =
      state.by_id
      |> Enum.filter(fn {_id, cap} -> Map.get(cap, scope_field) == scope_value end)
      |> Enum.map(fn {id, _cap} -> id end)

    count = length(matching_ids)
    Enum.each(matching_ids, &delete_persisted_capability/1)

    state =
      state
      |> revoke_capability_ids(matching_ids)
      |> update_in([:stats, :total_revoked], &(&1 + count))

    if count > 0 do
      emit_revocation_signal(:capabilities_scope_revoked, matching_ids, nil)
    end

    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call({:cascade_revoke, capability_id}, _from, state) do
    case Map.get(state.by_id, capability_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _cap ->
        # Collect all capability IDs to revoke (this one + all children recursively)
        all_ids = collect_cascade_ids(state, [capability_id], [])
        count = length(all_ids)

        Enum.each(all_ids, &delete_persisted_capability/1)

        state =
          state
          |> revoke_capability_ids(all_ids)
          |> update_in([:stats, :total_revoked], &(&1 + count))
          |> update_in([:stats, :total_cascade_revoked], &(&1 + count))

        emit_revocation_signal(:capabilities_cascade_revoked, all_ids, nil)
        {:reply, {:ok, count}, state}
    end
  end

  # ===========================================================================
  # Acknowledged exact mutation handlers (Phase 4C C3A).
  #
  # Acknowledged put pre-arms a bounded uncertainty intent, then runs the body
  # against that armed state. Any rescue/exit/throw replies :outcome_unknown
  # with the ARMED state (incoming + pending intent), not the raw incoming
  # state, so a post-admission ambiguity retains the ledger entry. Durable
  # admission is the only irreversible effect; uncommitted live mutations are
  # not retained; finalize_acknowledged_put_intent/2 clears the exact-id
  # intent on every definitive outcome and keeps it on :outcome_unknown.
  # Retry reconciles idempotently from durable truth.
  # ===========================================================================
  @impl true
  def handle_call({:acknowledged_put, signed_cap}, _from, state) do
    # Arm a bounded, fail-closed resource intent BEFORE any potentially
    # ambiguous mutation. The intent is threaded as the rescue/catch fallback
    # state so it survives an exit at or after a durable admission (where the
    # only irreversible effect may have already committed). A single funnel
    # (finalize_acknowledged_put_intent/2) clears it on every definitive
    # outcome and retains it on :outcome_unknown.
    case arm_admission_intent(state, signed_cap) do
      {:ok, armed} ->
        try do
          do_acknowledged_put(signed_cap, armed)
        rescue
          _ -> {:reply, {:error, :outcome_unknown}, armed}
        catch
          _, _ -> {:reply, {:error, :outcome_unknown}, armed}
        end
        |> finalize_acknowledged_put_intent(signed_cap.id)

      {:error, :id_conflict} ->
        # A mismatched same-id retry against a retained outcome-unknown intent:
        # return the established :id_conflict result on the ORIGINAL (un-armed)
        # state so the earlier intent is neither mutated nor finalized and keeps
        # blocking its resource until the original retry converges.
        {:reply, {:error, :id_conflict}, state}

      {:error, :at_capacity} ->
        {:reply, {:error, :quota_exceeded}, state}
    end
  end

  @impl true
  def handle_call({:acknowledged_revoke, capability_id}, _from, state) do
    incoming = state

    try do
      do_acknowledged_revoke(capability_id, state)
    rescue
      _ -> {:reply, {:error, :outcome_unknown}, incoming}
    catch
      _, _ -> {:reply, {:error, :outcome_unknown}, incoming}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = cleanup_expired(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # Handle distributed capability signals from other nodes
  @impl true
  def handle_info({:signal_received, signal}, state) do
    state = handle_distributed_signal(signal, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case SignalSync.handle_info(message, state.signal_sync) do
      {:ok, signal_sync} ->
        {:noreply, %{state | signal_sync: signal_sync}}

      {:stop, reason, signal_sync} ->
        {:stop, reason, %{state | signal_sync: signal_sync}}

      :unhandled ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    SignalSync.release(Map.get(state, :signal_sync))
  end

  # Private functions

  defp check_expiration(cap) do
    if expired?(cap) do
      {:error, :capability_expired}
    else
      {:ok, cap}
    end
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp maybe_filter_expired(caps, true), do: caps
  defp maybe_filter_expired(caps, false), do: Enum.reject(caps, &expired?/1)

  defp index_by_issuer(state, %{issuer_id: nil}), do: state

  defp index_by_issuer(state, cap) do
    update_in(state, [:by_issuer, cap.issuer_id], fn
      nil -> [cap.id]
      ids -> [cap.id | ids]
    end)
  end

  defp index_by_parent(state, %{parent_capability_id: nil}), do: state

  defp index_by_parent(state, cap) do
    update_in(state, [:by_parent, cap.parent_capability_id], fn
      nil -> [cap.id]
      ids -> [cap.id | ids]
    end)
  end

  defp signature_acceptable?(cap) do
    cond do
      # Signature present — verify it
      Capability.signed?(cap) ->
        case SystemAuthority.verify_capability_signature(cap) do
          :ok -> true
          {:error, _} -> false
        end

      # No signature, but signing is required — reject
      Config.capability_signing_required?() ->
        false

      # No signature, signing not required — backward compat accept
      true ->
        true
    end
  end

  defp authorizes_resource?(cap, resource_uri) do
    Capability.grants_access?(cap, resource_uri)
  end

  # ===========================================================================
  # Shared candidate validation (VP-05D2A0). Cheap checks run over the whole
  # candidate set first. Ordinary signatures are then verified in one batched
  # SystemAuthority call, rather than one nested GenServer call per capability.
  # ===========================================================================

  defp disclosure_namespaced?(%{resource_uri: uri}) do
    CapabilityUri.prefix_match?(@disclosure_uri_prefix, uri)
  end

  defp candidate_cheaply_valid?(cap, principal_id, scope_context, now) do
    cap.principal_id == principal_id and current_at?(cap, now) and
      Capability.scope_matches?(cap, scope_context)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp current_at?(%Capability{} = cap, %DateTime{} = now) do
    expires_ok? =
      is_nil(cap.expires_at) or
        (match?(%DateTime{}, cap.expires_at) and DateTime.compare(cap.expires_at, now) == :gt)

    not_before_ok? =
      is_nil(cap.not_before) or
        (match?(%DateTime{}, cap.not_before) and DateTime.compare(now, cap.not_before) != :lt)

    expires_ok? and not_before_ok? and is_integer(cap.delegation_depth) and
      cap.delegation_depth >= 0
  end

  defp verify_ordinary_candidates(caps) do
    signed = Enum.filter(caps, &Capability.signed?/1)
    valid_signed_ids = valid_signature_ids(signed)
    signing_required? = Config.capability_signing_required?()

    Enum.filter(caps, fn cap ->
      signature_valid? =
        if Capability.signed?(cap) do
          MapSet.member?(valid_signed_ids, cap.id)
        else
          not signing_required?
        end

      signature_valid? and delegation_chain_valid?(cap)
    end)
  end

  defp valid_signature_ids([]), do: MapSet.new()

  defp valid_signature_ids(caps) do
    case SystemAuthority.verify_capability_signatures(caps) do
      {:ok, ids} when is_list(ids) -> MapSet.new(ids)
      _ -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  defp authority_signature_ok?(cap) do
    Capability.signed?(cap) and safe_verify_authority_capability_signature(cap) == :ok
  end

  # Exact-capability mode is an identity check, not a covering-capability
  # lookup. Keep every predicate here so a revoke cannot interleave between
  # selecting the stored id and validating its live authorization shape.
  defp exact_ordinary_capability_valid?(
         %Capability{} = cap,
         capability_id,
         principal_id,
         resource_uri,
         scope_context,
         now
       ) do
    cap.id == capability_id and cap.principal_id == principal_id and
      cap.resource_uri == resource_uri and not disclosure_namespaced?(cap) and
      current_at?(cap, now) and exact_scope_matches?(cap, scope_context) and
      Capability.signed?(cap) and safe_verify_capability_signature(cap) == :ok and
      exact_delegation_chain_valid?(cap)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp exact_scope_matches?(cap, scope_context) when is_list(scope_context) do
    cap.session_id == Keyword.get(scope_context, :session_id) and
      cap.task_id == Keyword.get(scope_context, :task_id) and
      cap.principal_scope == Keyword.get(scope_context, :principal_scope)
  rescue
    _ -> false
  end

  defp exact_scope_matches?(_cap, _scope_context), do: false

  defp exact_delegation_chain_valid?(%{parent_capability_id: nil, delegation_chain: []}), do: true

  defp exact_delegation_chain_valid?(
         %{parent_capability_id: parent_id, delegation_chain: [_ | _]} = cap
       )
       when not is_nil(parent_id) do
    case Signer.verify_delegation_chain(cap, &Arbor.Security.lookup_public_key/1) do
      :ok -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp exact_delegation_chain_valid?(_cap), do: false

  defp safe_verify_capability_signature(cap) do
    SystemAuthority.verify_capability_signature(cap)
  rescue
    _ -> {:error, :verification_unavailable}
  catch
    :exit, _ -> {:error, :verification_unavailable}
    :throw, _ -> {:error, :verification_unavailable}
  end

  defp disclosure_time_candidate?(
         %Capability{granted_at: %DateTime{} = granted_at, expires_at: %DateTime{} = expires_at},
         %DateTime{} = now
       ) do
    max_ttl = Config.disclosure_capability_max_ttl_seconds()
    validity_seconds = DateTime.diff(expires_at, granted_at, :second)
    remaining_seconds = DateTime.diff(expires_at, now, :second)

    DateTime.compare(granted_at, now) != :gt and validity_seconds > 0 and
      validity_seconds <= max_ttl and remaining_seconds <= max_ttl
  end

  defp disclosure_time_candidate?(_cap, _now), do: false

  # Verifier-exit containment: this runs INSIDE the store's own handle_call,
  # so an unreachable/crashing SystemAuthority must not crash CapabilityStore
  # itself (that would take down every in-flight capability operation, not
  # just this one request).
  defp safe_verify_authority_capability_signature(cap) do
    SystemAuthority.verify_authority_capability_signature(cap)
  rescue
    _ -> {:error, :verification_unavailable}
  catch
    :exit, _ -> {:error, :verification_unavailable}
    :throw, _ -> {:error, :verification_unavailable}
  end

  defp delegation_chain_valid?(%{delegation_chain: nil}), do: true
  defp delegation_chain_valid?(%{delegation_chain: []}), do: true

  defp delegation_chain_valid?(cap) do
    if Config.delegation_chain_verification_enabled?() do
      key_lookup = &Arbor.Security.lookup_public_key/1

      case Signer.verify_delegation_chain(cap, key_lookup) do
        :ok -> true
        {:error, _} -> false
      end
    else
      true
    end
  end

  defp cleanup_expired(state) do
    now = DateTime.utc_now()

    {expired_entries, _} =
      Enum.split_with(state.by_id, fn {_id, cap} ->
        cap.expires_at != nil and DateTime.compare(now, cap.expires_at) == :gt
      end)

    expired_ids = Enum.map(expired_entries, fn {id, _} -> id end)

    if expired_ids == [] do
      state
    else
      Enum.each(expired_ids, &delete_persisted_capability/1)

      state
      |> remove_expired_from_resource_index(expired_entries)
      |> remove_expired_capabilities(expired_ids)
      |> remove_expired_from_principals(expired_ids)
      |> update_in([:stats, :total_expired], &(&1 + length(expired_ids)))
    end
  end

  defp remove_expired_from_resource_index(state, expired_entries) do
    Enum.reduce(expired_entries, state, fn {_id, cap}, acc -> deindex_resource(acc, cap) end)
  end

  defp remove_expired_capabilities(state, expired_ids) do
    update_in(state, [:by_id], fn by_id ->
      Enum.reduce(expired_ids, by_id, &Map.delete(&2, &1))
    end)
  end

  defp remove_expired_from_principals(state, expired_ids) do
    update_in(state, [:by_principal], fn by_principal ->
      Map.new(by_principal, &remove_expired_from_principal(&1, expired_ids))
    end)
  end

  defp remove_expired_from_principal({principal, ids}, expired_ids) do
    {principal, ids -- expired_ids}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  # ===========================================================================
  # Cascade Revocation Helpers
  # ===========================================================================

  # Recursively collect all capability IDs that should be revoked
  # (the root + all children in the delegation tree)
  defp collect_cascade_ids(_state, [], acc), do: acc

  defp collect_cascade_ids(state, [cap_id | rest], acc) do
    children = Map.get(state.by_parent, cap_id, [])
    collect_cascade_ids(state, children ++ rest, [cap_id | acc])
  end

  # Revoke multiple capability IDs, cleaning up all indexes
  defp revoke_capability_ids(state, cap_ids) do
    Enum.reduce(cap_ids, state, &revoke_single_capability_if_exists/2)
  end

  defp revoke_single_capability_if_exists(cap_id, state) do
    case Map.get(state.by_id, cap_id) do
      nil -> state
      cap -> remove_capability_from_indexes(state, cap_id, cap)
    end
  end

  defp remove_capability_from_indexes(state, cap_id, cap) do
    state
    |> update_in([:by_id], &Map.delete(&1, cap_id))
    |> update_in([:by_principal, cap.principal_id], &List.delete(&1 || [], cap_id))
    |> deindex_resource(cap)
    |> update_in([:by_usage], &Map.delete(&1, cap_id))
    |> deindex_by_issuer(cap)
    |> deindex_by_parent(cap)
  end

  defp deindex_by_issuer(state, %{issuer_id: nil}), do: state

  defp deindex_by_issuer(state, cap) do
    update_in(state, [:by_issuer, cap.issuer_id], fn
      nil -> nil
      ids -> List.delete(ids, cap.id)
    end)
  end

  # Remove a capability from its parent's children list
  defp deindex_by_parent(state, %{parent_capability_id: nil}), do: state

  defp deindex_by_parent(state, cap) do
    update_in(state, [:by_parent, cap.parent_capability_id], fn
      nil -> nil
      ids -> List.delete(ids, cap.id)
    end)
  end

  # ===========================================================================
  # Quota Enforcement (Phase 7)
  # ===========================================================================

  # If a capability with the same principal_id + resource_uri already exists,
  # remove the old one so re-grants don't cause unbounded growth.
  # Returns {updated_state, replaced_cap_id | nil}.
  defp existing_capability_id(state, cap) do
    cap_ids = Map.get(state.by_principal, cap.principal_id, [])

    Enum.find(cap_ids, fn id ->
      case Map.get(state.by_id, id) do
        %{resource_uri: uri} -> uri == cap.resource_uri
        _ -> false
      end
    end)
  end

  defp maybe_replace_existing(state, cap) do
    existing_id = existing_capability_id(state, cap)

    case existing_id do
      nil ->
        {state, nil}

      id ->
        existing_cap = Map.fetch!(state.by_id, id)
        state = remove_capability_from_indexes(state, id, existing_cap)

        {state, id}
    end
  end

  defp add_capability_to_state(state, cap) do
    state
    |> put_in([:by_id, cap.id], cap)
    |> update_in([:by_principal, cap.principal_id], fn
      nil -> [cap.id]
      ids -> [cap.id | ids]
    end)
    |> index_resource(cap)
    |> index_by_issuer(cap)
    |> index_by_parent(cap)
    |> update_in([:stats, :total_granted], &(&1 + 1))
  end

  defp check_quotas(state, cap) do
    if Config.quota_enforcement_enabled?() do
      with :ok <- check_delegation_depth(cap),
           :ok <- check_per_agent_limit(state, cap) do
        check_global_limit(state)
      end
    else
      :ok
    end
  end

  defp check_delegation_depth(cap) do
    max_depth = Config.max_delegation_depth()
    depth = Map.get(cap, :delegation_depth, 0)

    cond do
      depth < 0 ->
        {:error,
         {:quota_exceeded, :delegation_depth_limit,
          %{depth: depth, limit: max_depth, reason: :negative_depth}}}

      depth > max_depth ->
        {:error, {:quota_exceeded, :delegation_depth_limit, %{depth: depth, limit: max_depth}}}

      true ->
        :ok
    end
  end

  defp check_per_agent_limit(state, cap) do
    max_per_agent = Config.max_capabilities_per_agent()
    agent_cap_ids = Map.get(state.by_principal, cap.principal_id, [])
    current_count = length(agent_cap_ids)

    if current_count >= max_per_agent do
      {:error,
       {:quota_exceeded, :per_agent_capability_limit,
        %{agent_id: cap.principal_id, current: current_count, limit: max_per_agent}}}
    else
      :ok
    end
  end

  defp check_global_limit(state) do
    max_global = Config.max_global_capabilities()
    current_count = map_size(state.by_id)

    if current_count >= max_global do
      {:error,
       {:quota_exceeded, :global_capability_limit, %{current: current_count, limit: max_global}}}
    else
      :ok
    end
  end

  # ===========================================================================
  # Acknowledged mutation helpers (Phase 4C C3A). Redacting persistence wrappers
  # never surface capability ids, metadata, signatures, backend records, or
  # exception terms in logs — only a bounded reason atom / op label. There is no
  # durable audit log in this module (audit is best-effort, observed-applied
  # only — see Arbor.Security.acknowledged_grant/1).
  # ===========================================================================

  defp do_acknowledged_put(signed_cap, state) do
    id = signed_cap.id
    ident = grant_identity(signed_cap)
    live_cap = Map.get(state.by_id, id)

    case acknowledged_authoritative_get(id) do
      {:ok, record} ->
        ack_put_durable_present(state, id, ident, record)

      {:error, :not_found} ->
        ack_put_durable_absent(state, signed_cap, id, ident, live_cap)

      {:error, _reason} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  defp ack_put_durable_present(state, id, ident, record) do
    case decode_and_verify_capability(record, id) do
      {:ok, stored} ->
        if grant_identity(stored) == ident do
          # exact already-applied => idempotent classification
          ack_classify_exact_replay(state, stored, id)
        else
          # mismatched durable occupant of this id is never overwritten
          # (id conflict).
          {:reply, {:error, :id_conflict}, state}
        end

      {:error, :unverifiable} ->
        # malformed/unverifiable durable occupant; preserve, leave for reobservation
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  # Classify a durable-present exact (already-applied) grant, or a CAS conflict
  # that reobserved our exact grant: ghost check, same-id live mismatch, else
  # idempotent live projection. Shared by the present-replay and CAS-conflict
  # paths so both converge identically.
  defp ack_classify_exact_replay(state, stored, id) do
    live_cap = Map.get(state.by_id, id)

    case same_resource_occupancy(state, stored) do
      :occupied ->
        {:reply, {:error, :resource_conflict}, state}

      :vacant ->
        if live_cap != nil and grant_identity(live_cap) != grant_identity(stored) do
          # Same-id live identity mismatch; fail closed and never overwrite it
          # (id conflict).
          {:reply, {:error, :id_conflict}, state}
        else
          # Identity-exact live state or no live state: project idempotently.
          case project_capability_idempotent(state, stored) do
            {:ok, state, :added} ->
              # Durable-only convergence that newly projected into live: emit
              # the restricted cluster-sync signal exactly once.
              emit_capability_signal(:capability_granted, stored)
              {:reply, {:ok, :idempotent, id}, state}

            {:ok, state, :already_present} ->
              # True replay (live already identity-exact): no duplicate signal.
              {:reply, {:ok, :idempotent, id}, state}

            {:error, :cannot_canonicalize} ->
              {:reply, {:error, :outcome_unknown}, state}
          end
        end
    end
  end

  defp ack_put_durable_absent(state, signed_cap, id, ident, live_cap) do
    cond do
      not is_nil(live_cap) and grant_identity(live_cap) != ident ->
        # mismatched live occupant under our id is never overwritten (id conflict).
        {:reply, {:error, :id_conflict}, state}

      not is_nil(live_cap) and grant_identity(live_cap) == ident ->
        # LIVE-EXACT, durable absent => durable repair via CAS(:not_found)
        ack_put_durable_repair(state, signed_cap, id, ident)

      is_nil(live_cap) ->
        ack_put_fresh_grant(state, signed_cap, id, ident)

      true ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  defp ack_put_durable_repair(state, signed_cap, id, ident) do
    case same_resource_occupancy(state, signed_cap) do
      :occupied -> {:reply, {:error, :resource_conflict}, state}
      :vacant -> ack_admit_via_cas(state, signed_cap, id, ident, :idempotent)
    end
  end

  # Shared CAS admission for both the durable-repair (:idempotent) and fresh
  # (:applied) paths: CAS(:not_found) insert, authoritative reobserve+verify,
  # then idempotent live projection. Side effects (stat + cluster signal) fire
  # only on the :applied status. A CAS conflict is reobserved and classified.
  defp ack_admit_via_cas(state, signed_cap, id, ident, status) do
    case acknowledged_cas_insert(signed_cap) do
      {:ok, _stored} ->
        ack_commit_reobserved(state, id, ident, status)

      {:error, :conflict} ->
        ack_classify_cas_conflict(state, id, ident)

      {:error, _reason} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  defp ack_commit_reobserved(state, id, ident, status) do
    case acknowledged_reobserve(id, ident) do
      {:ok, verified} ->
        ack_project_committed(state, verified, id, status)

      _ ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  defp ack_project_committed(state, verified, id, status) do
    case project_capability_idempotent(state, verified) do
      {:ok, state, kind} ->
        ack_emit_committed(state, verified, id, status, kind)

      {:error, :cannot_canonicalize} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  defp ack_emit_committed(state, verified, id, :applied, _kind) do
    state = update_in(state, [:stats, :total_granted], &(&1 + 1))
    emit_capability_signal(:capability_granted, verified)
    {:reply, {:ok, :applied, id}, state}
  end

  defp ack_emit_committed(state, verified, id, :idempotent, :added) do
    # Durable-only convergence that newly projected into live: emit the
    # restricted cluster-sync signal exactly once.
    emit_capability_signal(:capability_granted, verified)
    {:reply, {:ok, :idempotent, id}, state}
  end

  defp ack_emit_committed(state, _verified, id, :idempotent, :already_present) do
    # True replay (live already identity-exact): no signal, no duplicate.
    {:reply, {:ok, :idempotent, id}, state}
  end

  defp ack_put_fresh_grant(state, signed_cap, id, ident) do
    case same_resource_occupancy(state, signed_cap) do
      :occupied ->
        # Never replace a different same-principal/resource capability
        # (resource conflict).
        {:reply, {:error, :resource_conflict}, state}

      :vacant ->
        case check_quotas(state, signed_cap) do
          {:error, _quota} ->
            {:reply, {:error, :quota_exceeded}, state}

          :ok ->
            ack_fresh_grant_commit(state, signed_cap, id, ident)
        end
    end
  end

  defp ack_fresh_grant_commit(state, signed_cap, id, ident) do
    ack_admit_via_cas(state, signed_cap, id, ident, :applied)
  end

  # A CAS(:not_found) conflict means a concurrent writer admitted a record under
  # this id between the read and the admission. Reobserve and classify: only an
  # exact already-applied state is idempotent; a different occupant is
  # :id_conflict (never overwritten); absence/ambiguous => :outcome_unknown.
  defp ack_classify_cas_conflict(state, id, ident) do
    case acknowledged_authoritative_get(id) do
      {:ok, record} ->
        case decode_and_verify_capability(record, id) do
          {:ok, stored} ->
            if grant_identity(stored) == ident do
              ack_classify_exact_replay(state, stored, id)
            else
              {:reply, {:error, :id_conflict}, state}
            end

          {:error, :unverifiable} ->
            {:reply, {:error, :outcome_unknown}, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :outcome_unknown}, state}

      {:error, _reason} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  defp do_acknowledged_revoke(capability_id, state) do
    case acknowledged_authoritative_get(capability_id) do
      {:error, :not_found} ->
        # authoritative absence = idempotent success
        ack_idempotent_revoke_reply(state, capability_id)

      {:ok, record} ->
        case acknowledged_cas_delete(capability_id, record) do
          :ok ->
            principal_id = ack_revoke_principal(state, capability_id, record)
            state = revoke_capability_ids(state, [capability_id])
            state = update_in(state, [:stats, :total_revoked], &(&1 + 1))
            emit_revocation_signal(:capability_revoked, [capability_id], principal_id)
            {:reply, {:ok, :applied, capability_id}, state}

          {:error, :conflict} ->
            # observed record concurrently changed/removed; reobserve + classify
            classify_revoke_conflict(state, capability_id)

          {:error, _reason} ->
            # ambiguous persistence never reported as applied
            {:reply, {:error, :outcome_unknown}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  # A CAS delete conflict means the observed record was concurrently changed or
  # removed. Only authoritative absence is idempotent (already revoked); a still
  # present (concurrently changed) record is never deleted => :outcome_unknown.
  defp classify_revoke_conflict(state, capability_id) do
    case acknowledged_authoritative_get(capability_id) do
      {:error, :not_found} ->
        ack_idempotent_revoke_reply(state, capability_id)

      {:ok, _record} ->
        {:reply, {:error, :outcome_unknown}, state}

      {:error, _reason} ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  # Idempotent revoke (authoritative absence): unconditionally purge the exact
  # id from EVERY projection index so dangling refs cannot survive. Emits the
  # restricted cluster-sync convergence signal ONLY when it newly evicts live
  # state; a true replay (already absent) emits none and updates no stat (the
  # durable layer is authoritative; the applied CAS-delete path keeps stat+
  # signal via revoke_capability_ids/2).
  defp ack_idempotent_revoke_reply(state, capability_id) do
    {state, newly_evicted?, principal_id} = ensure_ack_evicted(state, capability_id)

    if newly_evicted? do
      emit_revocation_signal(:capability_revoked, [capability_id], principal_id)
    end

    {:reply, {:ok, :idempotent, capability_id}, state}
  end

  # Purge the exact id from every projection index, returning the updated
  # state, whether live state was newly evicted, and the evicted cap's
  # principal (nil if already absent). The purge is UNCONDITIONAL: even when
  # by_id is already absent, dangling refs in by_principal/by_resource/
  # by_issuer/by_parent/by_usage must not survive.
  defp ensure_ack_evicted(state, capability_id) do
    {principal_id, newly_evicted?} =
      case Map.get(state.by_id, capability_id) do
        %Capability{principal_id: p} when is_binary(p) -> {p, true}
        _ -> {nil, false}
      end

    state =
      state
      |> remove_dangling_refs_for_id(capability_id)
      |> update_in([:by_id], &Map.delete(&1, capability_id))

    {state, newly_evicted?, principal_id}
  end

  defp ack_revoke_principal(state, capability_id, record) do
    case Map.get(state.by_id, capability_id) do
      %Capability{principal_id: principal_id} when is_binary(principal_id) ->
        principal_id

      _ ->
        best_effort_principal_from_record(record)
    end
  end

  defp best_effort_principal_from_record(record) do
    with {:ok, data} <- extract_capability_payload(record),
         {:ok, %Capability{principal_id: principal_id}} <- Serializer.deserialize(data) do
      principal_id
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Identity over ALL signed fields (the canonical authority payload). Two
  # capabilities with equal signing_payload are the exact same grant for a
  # stable authority; deterministic across journal retries.
  defp grant_identity(%Capability{} = cap), do: Capability.signing_payload(cap)

  # ---------------------------------------------------------------------------
  # Bounded uncertainty ledger (pending_intents).
  #
  # Arm the exact resource intent before any potentially ambiguous mutation.
  # Always fail closed at the configured per-principal and global ceilings —
  # even when ordinary quota_enforcement is disabled — so retained
  # :outcome_unknown intents cannot grow without bound. When ordinary quotas
  # are enabled, live+pending share those ceilings; when disabled, only the
  # pending ledger itself is counted (live ordinary put semantics stay open).
  # Idempotent per cap.id so an exact retry re-arms without growing the ledger.
  # Never walks the full live by_id map for per-principal admission: live
  # counts use the bounded by_principal list + map_size(by_id) only.
  # ---------------------------------------------------------------------------
  defp arm_admission_intent(state, %Capability{} = cap) do
    with :ok <- intent_identity_check(state, cap),
         :ok <- uncertainty_within_bounds?(state, cap) do
      {:ok, put_intent(state, cap)}
    end
  end

  # A pending intent under this id is a retained outcome-unknown admission that
  # may have durably committed. An exact same-id retry (identical canonical
  # signed identity) re-arms without growth; a mismatched same-id retry is a
  # different grant claiming an id already occupied by an uncertain admission,
  # so it is rejected as :id_conflict BEFORE any mutation. The earlier intent
  # is left byte-for-byte intact (never re-armed, never finalized) and keeps
  # blocking its resource until the original retry converges.
  defp intent_identity_check(state, %Capability{} = cap) do
    ident = grant_identity(cap)

    case Map.get(state.pending_intents, cap.id) do
      nil -> :ok
      {_principal, _resource, ^ident} -> :ok
      _mismatched -> {:error, :id_conflict}
    end
  end

  defp put_intent(state, %Capability{} = cap) do
    %{state | pending_intents: Map.put(state.pending_intents, cap.id, intent_value(cap))}
  end

  # Identity-safe intent value: the canonical {principal, resource} occupancy
  # key (same shape resource_key/1 produces) paired with the exact canonical
  # signed grant identity (Capability.signing_payload/1). The payload lets an
  # exact same-id retry re-arm idempotently while a mismatched same-id retry is
  # rejected at arm time without overwriting the retained uncertainty lock.
  defp intent_value(%Capability{} = cap) do
    {principal_id, resource} = resource_key(cap)
    {principal_id, resource, grant_identity(cap)}
  end

  defp uncertainty_within_bounds?(state, %Capability{} = cap) do
    if Config.quota_enforcement_enabled?() do
      case intent_within_per_agent?(state, cap) do
        :ok -> intent_within_global?(state, cap)
        error -> error
      end
    else
      case pending_within_per_agent?(state, cap) do
        :ok -> pending_within_global?(state, cap)
        error -> error
      end
    end
  end

  # Live count via bounded by_principal list (same source ordinary per-agent
  # quota uses) + pending ledger for this principal. Never Enum over by_id.
  # Exclude cap.id so re-arming/replay does not double-count. +1 for self.
  defp intent_within_per_agent?(state, %Capability{principal_id: p, id: cap_id}) do
    live = live_principal_count(state, p, cap_id)
    pending = pending_principal_count(state, p, cap_id)

    if live + pending + 1 > Config.max_capabilities_per_agent(),
      do: {:error, :at_capacity},
      else: :ok
  end

  defp intent_within_global?(state, %Capability{id: cap_id}) do
    live = map_size(state.by_id) - if(Map.has_key?(state.by_id, cap_id), do: 1, else: 0)
    pending = pending_global_count(state, cap_id)

    if live + pending + 1 > Config.max_global_capabilities(),
      do: {:error, :at_capacity},
      else: :ok
  end

  # Ordinary quotas disabled: bound pending uncertainty alone (no live quota).
  defp pending_within_per_agent?(state, %Capability{principal_id: p, id: cap_id}) do
    pending = pending_principal_count(state, p, cap_id)

    if pending + 1 > Config.max_capabilities_per_agent(),
      do: {:error, :at_capacity},
      else: :ok
  end

  defp pending_within_global?(state, %Capability{id: cap_id}) do
    pending = pending_global_count(state, cap_id)

    if pending + 1 > Config.max_global_capabilities(),
      do: {:error, :at_capacity},
      else: :ok
  end

  defp live_principal_count(state, principal_id, exclude_id) do
    ids = Map.get(state.by_principal, principal_id, [])
    n = length(ids)
    if exclude_id in ids, do: n - 1, else: n
  end

  defp pending_principal_count(state, principal_id, exclude_id) do
    Enum.count(state.pending_intents, fn
      {^exclude_id, _} -> false
      {_, {^principal_id, _, _}} -> true
      _ -> false
    end)
  end

  defp pending_global_count(state, exclude_id) do
    map_size(state.pending_intents) -
      if(Map.has_key?(state.pending_intents, exclude_id), do: 1, else: 0)
  end

  defp clear_intent(state, id),
    do: %{state | pending_intents: Map.delete(state.pending_intents, id)}

  # Single funnel: clear the exact-id intent on every DEFINITIVE outcome;
  # retain it on :outcome_unknown (a durable admission may have committed).
  defp finalize_acknowledged_put_intent({:reply, {:error, :outcome_unknown}, state}, _id),
    do: {:reply, {:error, :outcome_unknown}, state}

  defp finalize_acknowledged_put_intent({:reply, result, state}, id),
    do: {:reply, result, clear_intent(state, id)}

  # Decode + verify an authoritative record for an exact id. Reuses the
  # battle-tested restore validators; any failure/exit => :unverifiable.
  defp decode_and_verify_capability(record, expected_id) do
    with {:ok, data} <- extract_capability_payload(record),
         :ok <- validate_capability_source(expected_id, data),
         {:ok, cap} <- deserialize_restore_capability(data),
         :ok <- validate_deserialized_capability(expected_id, cap),
         :ok <- ack_verify_authority_signature(cap) do
      {:ok, cap}
    else
      _ -> {:error, :unverifiable}
    end
  end

  defp ack_verify_authority_signature(%Capability{} = cap) do
    SystemAuthority.verify_authority_capability_signature(cap)
  rescue
    _ -> {:error, :verification_unavailable}
  catch
    :exit, _ -> {:error, :verification_unavailable}
    :throw, _ -> {:error, :verification_unavailable}
  end

  # Same-resource conflict detection:
  #   - Live: O(1) Map.get on the canonical by_resource index (derived only from
  #     live/restored by_id projection; never from by_principal).
  #   - Uncertainty: O(|pending_intents|) scan over the in-memory ledger, which
  #     is itself bounded by the configured per-principal/global ceilings — not
  #     asymptotic O(1). Do not claim pure O(1) for the combined check.
  # Never scans the full live by_id map or the authoritative durable inventory
  # per grant. Post-admission ambiguity (CAS committed while this GenServer
  # retained its incoming live state) is captured by pending_intents instead of
  # a durable scan. by_principal is never an authority source because it may be
  # stale; by_resource is the single live authority and is maintained on every
  # mutation path.
  defp same_resource_occupancy(state, %Capability{} = cap) do
    if resource_occupied_by_other?(state, cap), do: :occupied, else: :vacant
  end

  # The {principal_id, canonical_resource(resource_uri)} key shared by the
  # canonical index and the uncertainty ledger.
  defp resource_key(%Capability{principal_id: principal_id, resource_uri: resource_uri}) do
    {principal_id, canonical_resource(resource_uri)}
  end

  defp index_resource(state, %Capability{} = cap) do
    key = resource_key(cap)

    %{
      state
      | by_resource:
          Map.update(state.by_resource, key, MapSet.new([cap.id]), &MapSet.put(&1, cap.id))
    }
  end

  defp deindex_resource(state, %Capability{} = cap) do
    key = resource_key(cap)
    %{state | by_resource: remove_id_from_resource_index(state.by_resource, key, cap.id)}
  end

  # Bounded sweep removing an id from any by_resource bucket (used only by the
  # dangling-ref purge path where the cap may no longer be in by_id). Bounded by
  # map_size(by_resource) (<= max_global capabilities).
  defp deindex_resource_by_id(by_resource, id) do
    by_resource
    |> Map.new(fn {key, ids} -> {key, MapSet.delete(ids, id)} end)
    |> drop_empty_resource_buckets()
  end

  defp remove_id_from_resource_index(by_resource, key, id) do
    case Map.get(by_resource, key) do
      nil ->
        by_resource

      ids ->
        by_resource |> Map.put(key, MapSet.delete(ids, id)) |> drop_empty_resource_buckets()
    end
  end

  defp drop_empty_resource_buckets(by_resource) do
    Map.reject(by_resource, fn {_key, ids} -> MapSet.size(ids) == 0 end)
  end

  # Occupied iff another id (live or pending) for this principal+resource
  # exists. Live half is O(1) by_resource lookup; pending half is a
  # quota-bounded O(|pending_intents|) scan. The exact cap.id is always
  # excluded so an exact retry reobserves and converges instead of conflicting
  # with itself.
  defp resource_occupied_by_other?(state, %Capability{} = cap) do
    # Destructure the canonical resource key once (council readability nit):
    # replaces the raw elem(key, N) lookups in the pending occupancy scan.
    {principal, resource} = resource_key(cap)
    cap_id = cap.id

    live_other? =
      state.by_resource
      |> Map.get({principal, resource}, MapSet.new())
      |> MapSet.delete(cap_id)
      |> MapSet.size() > 0

    pending_other? =
      Enum.any?(state.pending_intents, fn
        {^cap_id, _} -> false
        {_id, {^principal, ^resource, _payload}} -> true
        _other -> false
      end)

    live_other? or pending_other?
  end

  # Canonicalize a capability resource URI for same-resource comparison so
  # semantically-equal URIs (e.g. differing only in canonical form) compare as
  # the same resource. Falls back to the raw URI if parsing fails.
  defp canonical_resource(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, parsed} -> CapabilityUri.canonical(parsed)
      {:error, _} -> uri
    end
  rescue
    _ -> uri
  end

  # Idempotent live projection for the EXACT id only. Never reuses the
  # non-idempotent add_capability_to_state/2. Never removes/edits a different
  # id (same-resource occupants survive reobservation); never leaves a ghost
  # (dangling or duplicate ref). A same-id mismatch occupant is NOT overwritten
  # (returns :cannot_canonicalize => caller fails closed).
  defp project_capability_idempotent(state, %Capability{} = cap) do
    id = cap.id
    existing = Map.get(state.by_id, id)

    cond do
      existing != nil and grant_identity(existing) == grant_identity(cap) ->
        # Persistence may normalize atom map keys to strings. Grant identity is
        # the signed canonical payload, so replace only an identity-exact live
        # representation with the verified authoritative representation.
        state = put_in(state, [:by_id, id], cap)
        {:ok, canonicalize_index_for_id(state, cap), :already_present}

      is_nil(existing) ->
        state = remove_dangling_refs_for_id(state, id)
        {:ok, clean_add_capability(state, cap), :added}

      true ->
        {:error, :cannot_canonicalize}
    end
  end

  defp canonicalize_index_for_id(state, %Capability{} = cap) do
    id = cap.id

    by_principal =
      prepend_id_once(purge_id_from_index_map(state.by_principal, id), cap.principal_id, id)

    by_issuer =
      if cap.issuer_id do
        prepend_id_once(purge_id_from_index_map(state.by_issuer, id), cap.issuer_id, id)
      else
        purge_id_from_index_map(state.by_issuer, id)
      end

    by_parent =
      if cap.parent_capability_id do
        prepend_id_once(
          purge_id_from_index_map(state.by_parent, id),
          cap.parent_capability_id,
          id
        )
      else
        purge_id_from_index_map(state.by_parent, id)
      end

    %{state | by_principal: by_principal, by_issuer: by_issuer, by_parent: by_parent}
    |> index_resource(cap)
  end

  defp remove_dangling_refs_for_id(state, id) do
    %{
      state
      | by_principal: purge_id_from_index_map(state.by_principal, id),
        by_resource: deindex_resource_by_id(state.by_resource, id),
        by_issuer: purge_id_from_index_map(state.by_issuer, id),
        by_parent: purge_id_from_index_map(state.by_parent, id),
        by_usage: Map.delete(state.by_usage, id)
    }
  end

  defp clean_add_capability(state, %Capability{} = cap) do
    id = cap.id
    state = put_in(state, [:by_id, id], cap)
    by_principal = prepend_id_once(state.by_principal, cap.principal_id, id)

    by_issuer =
      if cap.issuer_id do
        prepend_id_once(state.by_issuer, cap.issuer_id, id)
      else
        state.by_issuer
      end

    by_parent =
      if cap.parent_capability_id do
        prepend_id_once(state.by_parent, cap.parent_capability_id, id)
      else
        state.by_parent
      end

    %{state | by_principal: by_principal, by_issuer: by_issuer, by_parent: by_parent}
    |> index_resource(cap)
  end

  defp prepend_id_once(map, key, id) do
    Map.update(map, key, [id], fn
      nil -> [id]
      ids -> if id in ids, do: ids, else: [id | ids]
    end)
  end

  defp purge_id_from_index_map(map, id) do
    Map.new(map, fn
      {key, ids} when is_list(ids) -> {key, Enum.reject(ids, &(&1 == id))}
      {key, other} -> {key, other}
    end)
  end

  # Redacting authoritative-read wrappers (never surface id/metadata/signature/record).
  defp acknowledged_authoritative_get(capability_id) do
    if Process.whereis(@cap_store) do
      apply(@buffered_store, :authoritative_get, [capability_id, [name: @cap_store]])
    else
      {:error, :acknowledged_read_failed}
    end
  rescue
    _ -> {:error, :acknowledged_read_failed}
  catch
    _, _ -> {:error, :acknowledged_read_failed}
  end

  defp acknowledged_cas_insert(%Capability{} = cap) do
    if Process.whereis(@cap_store) do
      data = Serializer.serialize(cap)
      record = Record.new(cap.id, data)

      case apply(@buffered_store, :acknowledged_compare_and_swap, [
             cap.id,
             :not_found,
             record,
             [name: @cap_store]
           ]) do
        {:ok, _stored} -> {:ok, :inserted}
        {:error, :conflict} -> {:error, :conflict}
        {:error, _reason} -> {:error, :cas_failed}
      end
    else
      {:error, :cas_failed}
    end
  rescue
    _ -> {:error, :cas_failed}
  catch
    _, _ -> {:error, :cas_failed}
  end

  defp acknowledged_cas_delete(capability_id, %Record{} = observed) do
    if Process.whereis(@cap_store) do
      case apply(@buffered_store, :acknowledged_compare_and_delete, [
             capability_id,
             observed,
             [name: @cap_store]
           ]) do
        :ok -> :ok
        {:error, :conflict} -> {:error, :conflict}
        {:error, _reason} -> {:error, :cas_delete_failed}
      end
    else
      {:error, :cas_delete_failed}
    end
  rescue
    _ -> {:error, :cas_delete_failed}
  catch
    _, _ -> {:error, :cas_delete_failed}
  end

  defp acknowledged_reobserve(id, ident) do
    case acknowledged_authoritative_get(id) do
      {:ok, record} ->
        case decode_and_verify_capability(record, id) do
          {:ok, %Capability{} = verified} ->
            if grant_identity(verified) == ident,
              do: {:ok, verified},
              else: {:error, :identity_mismatch}

          {:error, _reason} ->
            {:error, :unverifiable}
        end

      {:error, :not_found} ->
        {:error, :reobserve_missing}

      {:error, _reason} ->
        {:error, :reobserve_failed}
    end
  end

  # ===========================================================================
  # Distributed Signal Subscription
  # ===========================================================================

  defp subscribe_to_distributed_signals do
    SignalSync.establish(
      :capability_store,
      @signal_events,
      Config.distributed_signals_enabled?()
    )
  end

  defp handle_distributed_signal(signal, state) do
    # Ignore signals originating from this node (we already have the state)
    origin_node = signal.data[:origin_node] || signal.data["origin_node"]

    if origin_node in [node(), Atom.to_string(node())] do
      state
    else
      handle_remote_signal(signal.type, signal.data, state)
    end
  catch
    _, reason ->
      Logger.warning("[CapabilityStore] Failed to handle distributed signal: #{inspect(reason)}")
      state
  end

  defp handle_remote_signal(:capability_granted, data, state) do
    cap_id = data[:capability_id] || data["capability_id"]
    sync_remote_capability(cap_id, state)
  end

  defp handle_remote_signal(type, data, state)
       when type in [
              :capability_revoked,
              :capabilities_revoked_all,
              :capabilities_cascade_revoked,
              :capabilities_scope_revoked
            ] do
    cap_ids = data[:capability_ids] || data["capability_ids"] || []

    if cap_ids != [] do
      Logger.debug("[CapabilityStore] Evicting #{length(cap_ids)} remotely revoked capabilities")
      Enum.each(cap_ids, &authoritative_delete_persisted_capability/1)
      revoke_capability_ids(state, cap_ids)
    else
      state
    end
  end

  defp handle_remote_signal(_type, _data, state), do: state

  defp sync_remote_capability(nil, state), do: state

  defp sync_remote_capability(cap_id, state) do
    case load_capability_from_backend(cap_id) do
      {:ok, cap} ->
        Logger.debug("[CapabilityStore] Synced remote capability #{cap_id}")
        add_capability_to_indexes(state, cap)

      {:error, _} ->
        state
    end
  end

  defp add_capability_to_indexes(state, cap) do
    principal_ids = Map.get(state.by_principal, cap.principal_id, [])
    updated_ids = if cap.id in principal_ids, do: principal_ids, else: [cap.id | principal_ids]

    state
    |> put_in([:by_id, cap.id], cap)
    |> put_in([:by_principal, cap.principal_id], updated_ids)
    |> index_resource(cap)
    |> index_by_issuer(cap)
    |> index_by_parent(cap)
  end

  defp load_capability_from_backend(cap_id) do
    if Process.whereis(@cap_store) do
      case apply(@buffered_store, :get, [cap_id, [name: @cap_store]]) do
        {:ok, %Record{data: data}} ->
          Serializer.deserialize(data)

        error ->
          error
      end
    else
      {:error, :store_unavailable}
    end
  catch
    _, reason -> {:error, reason}
  end

  # ===========================================================================
  # Distributed Signal Emission
  # ===========================================================================

  defp emit_capability_signal(type, cap) do
    if Config.distributed_signals_enabled?() do
      Signals.emit(
        :security,
        type,
        %{
          capability_id: cap.id,
          principal_id: cap.principal_id,
          resource_uri: cap.resource_uri,
          origin_node: node()
        },
        scope: :cluster
      )
    end
  catch
    _, _ -> :ok
  end

  defp emit_revocation_signal(type, cap_ids, principal_id) do
    if Config.distributed_signals_enabled?() do
      Signals.emit(
        :security,
        type,
        %{
          capability_ids: cap_ids,
          principal_id: principal_id,
          origin_node: node()
        },
        scope: :cluster
      )
    end
  catch
    _, _ -> :ok
  end

  # ===========================================================================
  # Persistence via BufferedStore
  # ===========================================================================

  @cap_store :arbor_security_capabilities

  defp replace_persisted_capability(existing_cap, replacement_cap) do
    with :ok <- persist_capability(replacement_cap, acknowledged: true),
         :ok <- delete_replaced_persisted_capability(existing_cap.id, replacement_cap.id) do
      :ok
    else
      {:error, reason} -> compensate_replacement(existing_cap, replacement_cap, reason)
      other -> compensate_replacement(existing_cap, replacement_cap, {:invalid_result, other})
    end
  end

  defp compensate_replacement(existing_cap, replacement_cap, original_reason) do
    restore_result = persist_capability(existing_cap, acknowledged: true)

    delete_result =
      if existing_cap.id == replacement_cap.id do
        :ok
      else
        authoritative_delete_persisted_capability(replacement_cap.id)
      end

    case {restore_result, delete_result} do
      {:ok, :ok} ->
        {:error, {:capability_replacement_failed, original_reason}}

      _ ->
        {:error,
         {:capability_replacement_outcome_unknown,
          %{
            original: original_reason,
            restore_existing: restore_result,
            delete_replacement: delete_result
          }}}
    end
  end

  defp delete_replaced_persisted_capability(replaced_id, replacement_id)
       when replaced_id == replacement_id,
       do: :ok

  defp delete_replaced_persisted_capability(replaced_id, _replacement_id) do
    authoritative_delete_persisted_capability(replaced_id)
  end

  defp authoritative_delete_persisted_capability(capability_id) do
    if Process.whereis(@cap_store) do
      case apply(@buffered_store, :acknowledged_delete, [capability_id, [name: @cap_store]]) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error(
            "Failed to authoritatively delete capability #{capability_id}: " <>
              "#{inspect(reason)}"
          )

          error

        other ->
          Logger.error(
            "Invalid authoritative delete result for capability #{capability_id}: " <>
              "#{inspect(other)}"
          )

          {:error, :invalid_persistence_result}
      end
    else
      {:error, :capability_store_unavailable}
    end
  catch
    _, reason ->
      Logger.error(
        "Authoritative delete failed for capability #{capability_id}: #{inspect(reason)}"
      )

      {:error, reason}
  end

  defp persist_capability(cap, opts) do
    if Process.whereis(@cap_store) do
      data = Serializer.serialize(cap)
      record = Record.new(cap.id, data)

      result =
        if Keyword.get(opts, :acknowledged, false) do
          apply(@buffered_store, :acknowledged_put, [cap.id, record, [name: @cap_store]])
        else
          apply(@buffered_store, :put, [cap.id, record, [name: @cap_store]])
        end

      case result do
        :ok ->
          :ok

        {:ok, _stored} ->
          :ok

        {:error, reason} = error ->
          Logger.warning("Failed to persist capability #{cap.id}: #{inspect(reason)}")
          error

        other ->
          Logger.warning("Invalid persistence result for capability #{cap.id}: #{inspect(other)}")
          {:error, :invalid_persistence_result}
      end
    else
      if Keyword.get(opts, :acknowledged, false),
        do: {:error, :capability_store_unavailable},
        else: :ok
    end
  catch
    _, reason ->
      Logger.warning("Failed to persist capability #{cap.id}: #{inspect(reason)}")
      {:error, reason}
  end

  defp delete_persisted_capability(cap_id) do
    if Process.whereis(@cap_store) do
      apply(@buffered_store, :delete, [cap_id, [name: @cap_store]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("Failed to delete persisted capability #{cap_id}: #{inspect(reason)}")
      :ok
  end

  defp restore_from_store(state) do
    with :ok <- ensure_cap_store_available(),
         :ok <- ensure_hydration_ready(),
         {:ok, keys} <- list_restored_keys(),
         {:ok, candidates, counters} <- load_restore_candidates(keys),
         {:ok, winners, counters} <- select_restore_winners(candidates, counters),
         :ok <- enforce_restored_quotas(winners) do
      state = rebuild_restore_indexes(state, winners, counters)
      {:ok, state}
    end
  rescue
    _ ->
      {:error, :restore_error}
  catch
    _, _ ->
      {:error, :restore_error}
  end

  defp ensure_cap_store_available do
    if Process.whereis(@cap_store) do
      :ok
    else
      {:error, :capability_store_unavailable}
    end
  end

  defp ensure_hydration_ready do
    case apply(@persistence, :buffered_store_hydration_status, [@cap_store]) do
      {:ok, %{status: :ready}} ->
        :ok

      {:ok, %{status: :failed, reason: reason}} when is_atom(reason) ->
        {:error, map_hydration_failure_reason(reason)}

      {:ok, %{status: :failed}} ->
        {:error, :hydration_failed}

      {:ok, %{status: :unavailable}} ->
        {:error, :hydration_unavailable}

      {:error, _} ->
        {:error, :hydration_failed}

      _other ->
        {:error, :hydration_failed}
    end
  end

  defp map_hydration_failure_reason(reason)
       when reason in [
              :inventory_limit_exceeded,
              :incomplete_inventory,
              :invalid_backend_response,
              :backend_unavailable
            ],
       do: reason

  defp map_hydration_failure_reason(:invalid_backend_record), do: :invalid_capability_record
  defp map_hydration_failure_reason(_), do: :hydration_failed

  defp list_restored_keys do
    case apply(@buffered_store, :list, [[name: @cap_store]]) do
      {:ok, keys} when is_list(keys) -> {:ok, keys}
      {:error, _} -> {:error, :incomplete_inventory}
      _ -> {:error, :incomplete_inventory}
    end
  end

  defp load_restore_candidates(keys) do
    counters = %{
      restore_scanned: 0,
      restore_active: 0,
      restore_expired: 0,
      restore_superseded: 0,
      restore_rejected: 0
    }

    Enum.reduce_while(keys, {:ok, [], counters}, fn key, {:ok, acc, counters} ->
      case load_restore_candidate(key) do
        {:ok, cap} ->
          counters = Map.update!(counters, :restore_scanned, &(&1 + 1))
          {:cont, {:ok, [cap | acc], counters}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp load_restore_candidate(key) when is_binary(key) do
    case apply(@buffered_store, :get, [key, [name: @cap_store]]) do
      {:ok, value} ->
        with {:ok, data} <- extract_capability_payload(value),
             :ok <- validate_capability_source(key, data),
             {:ok, cap} <- deserialize_restore_capability(data),
             :ok <- validate_deserialized_capability(key, cap) do
          {:ok, cap}
        else
          {:error, reason} when is_atom(reason) -> {:error, reason}
          {:error, _} -> {:error, :invalid_capability_record}
          _ -> {:error, :invalid_capability_record}
        end

      {:error, :not_found} ->
        {:error, :incomplete_inventory}

      {:error, _} ->
        {:error, :incomplete_inventory}

      _ ->
        {:error, :incomplete_inventory}
    end
  end

  defp load_restore_candidate(_key), do: {:error, :invalid_capability_record}

  # Every Serializer failure is a closed invalid record — never surface exception
  # terms or admit lossy defaults (signature nil, empty chain, depth 3, etc.).
  defp deserialize_restore_capability(data) when is_map(data) do
    case Serializer.deserialize(data) do
      {:ok, %Capability{} = cap} -> {:ok, cap}
      {:error, _} -> {:error, :invalid_capability_record}
      _ -> {:error, :invalid_capability_record}
    end
  rescue
    _ -> {:error, :invalid_capability_record}
  catch
    _, _ -> {:error, :invalid_capability_record}
  end

  defp deserialize_restore_capability(_), do: {:error, :invalid_capability_record}

  defp extract_capability_payload(%Record{data: data}) when is_map(data), do: {:ok, data}
  defp extract_capability_payload(data) when is_map(data), do: {:ok, data}
  defp extract_capability_payload(_), do: {:error, :invalid_capability_record}

  defp validate_capability_source(key, data) when is_map(data) do
    id = Map.get(data, "id")
    principal_id = Map.get(data, "principal_id")
    resource_uri = Map.get(data, "resource_uri")
    granted_at = Map.get(data, "granted_at")
    expires_at = Map.get(data, "expires_at")
    not_before = Map.get(data, "not_before")
    signed_at = Map.get(data, "signed_at")
    issuer_signature = Map.get(data, "issuer_signature")
    delegation_chain = Map.get(data, "delegation_chain")
    parent_capability_id = Map.get(data, "parent_capability_id")
    constraints = Map.get(data, "constraints")
    metadata = Map.get(data, "metadata")
    delegation_depth = Map.get(data, "delegation_depth")
    max_uses = Map.get(data, "max_uses")
    allowed_delegatees = Map.get(data, "allowed_delegatees")
    session_id = Map.get(data, "session_id")
    task_id = Map.get(data, "task_id")
    principal_scope = Map.get(data, "principal_scope")
    issuer_id = Map.get(data, "issuer_id")

    issue =
      cond do
        not (is_binary(id) and id != "" and id == key) ->
          :id

        not (is_binary(principal_id) and principal_id != "") ->
          :principal_id

        not (is_binary(resource_uri) and resource_uri != "") ->
          :resource_uri

        not valid_required_datetime_source?(granted_at) ->
          :granted_at

        not valid_optional_datetime_source?(expires_at) ->
          :expires_at

        # Serializer maps malformed optional datetimes to nil; reject bad source
        # not_before/signed_at before deserialize so future-use restrictions and
        # signing timestamps cannot be silently dropped on restore.
        not valid_optional_datetime_source?(not_before) ->
          :not_before

        not valid_optional_datetime_source?(signed_at) ->
          :signed_at

        # Non-nil issuer_signature that is not valid hex would decode to nil and
        # drop a persisted signature — reject before decode.
        not valid_optional_issuer_signature_source?(issuer_signature) ->
          :issuer_signature

        not valid_delegation_chain_source?(delegation_chain, parent_capability_id) ->
          :delegation_chain

        # Serializer defaults non-map constraints/metadata via || %{} or crashes;
        # reject non-map so restore cannot invent empty maps.
        not valid_required_map_source?(constraints) ->
          :constraints

        not valid_required_map_source?(metadata) ->
          :metadata

        # Serializer defaults missing/nil depth to 3; require a concrete non-neg int.
        not valid_delegation_depth_source?(delegation_depth) ->
          :delegation_depth

        not valid_optional_positive_integer_source?(max_uses) ->
          :max_uses

        not valid_optional_binary_list_source?(allowed_delegatees) ->
          :allowed_delegatees

        not valid_optional_binary_source?(session_id) ->
          :session_id

        not valid_optional_binary_source?(task_id) ->
          :task_id

        not valid_optional_binary_source?(principal_scope) ->
          :principal_scope

        not valid_optional_nonempty_binary_source?(issuer_id) ->
          :issuer_id

        true ->
          nil
      end

    case issue do
      nil ->
        :ok

      field ->
        Logger.error("Capability restore rejected persisted record: invalid #{field}")

        {:error, :invalid_capability_record}
    end
  end

  defp validate_capability_source(_key, _data), do: {:error, :invalid_capability_record}

  defp valid_required_datetime_source?(iso) when is_binary(iso) do
    match?({:ok, %DateTime{}, _}, DateTime.from_iso8601(iso))
  end

  defp valid_required_datetime_source?(_), do: false

  defp valid_optional_datetime_source?(nil), do: true

  defp valid_optional_datetime_source?(iso) when is_binary(iso) do
    match?({:ok, %DateTime{}, _}, DateTime.from_iso8601(iso))
  end

  defp valid_optional_datetime_source?(_), do: false

  defp valid_optional_issuer_signature_source?(nil), do: true

  defp valid_optional_issuer_signature_source?(hex) when is_binary(hex) and hex != "" do
    # Reject odd-length / non-hex so decode_optional_binary cannot nil-out a
    # non-nil persisted signature.
    match?({:ok, _}, Base.decode16(hex, case: :mixed))
  end

  defp valid_optional_issuer_signature_source?(_), do: false

  defp valid_required_map_source?(value) when is_map(value), do: true
  defp valid_required_map_source?(_), do: false

  defp valid_optional_positive_integer_source?(nil), do: true

  defp valid_optional_positive_integer_source?(value)
       when is_integer(value) and value > 0,
       do: true

  defp valid_optional_positive_integer_source?(_), do: false

  defp valid_optional_binary_list_source?(nil), do: true

  defp valid_optional_binary_list_source?(values) when is_list(values),
    do: Enum.all?(values, &is_binary/1)

  defp valid_optional_binary_list_source?(_), do: false

  defp valid_optional_binary_source?(nil), do: true
  defp valid_optional_binary_source?(value), do: is_binary(value)

  defp valid_optional_nonempty_binary_source?(nil), do: true

  defp valid_optional_nonempty_binary_source?(value),
    do: is_binary(value) and value != ""

  # Capability.new/1 defines 10 as the hard contract ceiling. A lower runtime
  # quota is enforced separately over restored winners.
  defp valid_delegation_depth_source?(depth)
       when is_integer(depth) and depth >= 0 and depth <= 10,
       do: true

  defp valid_delegation_depth_source?(_), do: false

  # Serializer lossily maps an absent/non-list chain to []; persisted records
  # must carry the concrete list plus parent/chain coherence.
  defp valid_delegation_chain_source?(chain, parent_capability_id) when is_list(chain) do
    records_valid? = Enum.all?(chain, &valid_delegation_record_source?/1)

    parent_ok? =
      is_nil(parent_capability_id) or
        (is_binary(parent_capability_id) and parent_capability_id != "")

    coherent? =
      case {parent_capability_id, chain} do
        {nil, []} -> true
        {nil, [_ | _]} -> false
        {parent, []} when not is_nil(parent) -> false
        {parent, [_ | _]} when is_binary(parent) -> true
        _ -> false
      end

    records_valid? and parent_ok? and coherent?
  end

  defp valid_delegation_chain_source?(_chain, _parent), do: false

  defp valid_delegation_record_source?(record) when is_map(record) do
    delegator_id = Map.get(record, "delegator_id")
    signature = Map.get(record, "delegator_signature")
    constraints = Map.get(record, "constraints")
    delegated_at = Map.get(record, "delegated_at")

    is_binary(delegator_id) and delegator_id != "" and
      valid_required_signature_source?(signature) and is_map(constraints) and
      valid_optional_datetime_source?(delegated_at)
  end

  defp valid_delegation_record_source?(_), do: false

  defp valid_required_signature_source?(hex) when is_binary(hex) and hex != "" do
    match?({:ok, decoded} when byte_size(decoded) > 0, Base.decode16(hex, case: :mixed))
  end

  defp valid_required_signature_source?(_), do: false

  defp validate_deserialized_capability(key, %Capability{} = cap) do
    cond do
      not (is_binary(cap.id) and cap.id != "" and cap.id == key) ->
        {:error, :invalid_capability_record}

      not (is_binary(cap.principal_id) and cap.principal_id != "") ->
        {:error, :invalid_capability_record}

      not (is_binary(cap.resource_uri) and cap.resource_uri != "") ->
        {:error, :invalid_capability_record}

      not match?(%DateTime{}, cap.granted_at) ->
        {:error, :invalid_capability_record}

      not (is_nil(cap.expires_at) or match?(%DateTime{}, cap.expires_at)) ->
        {:error, :invalid_capability_record}

      not (is_nil(cap.not_before) or match?(%DateTime{}, cap.not_before)) ->
        {:error, :invalid_capability_record}

      not (is_nil(cap.signed_at) or match?(%DateTime{}, cap.signed_at)) ->
        {:error, :invalid_capability_record}

      not (is_nil(cap.issuer_signature) or is_binary(cap.issuer_signature)) ->
        {:error, :invalid_capability_record}

      cap.issuer_signature == "" ->
        {:error, :invalid_capability_record}

      not is_list(cap.delegation_chain) ->
        {:error, :invalid_capability_record}

      not Enum.all?(cap.delegation_chain, &valid_deserialized_delegation_record?/1) ->
        {:error, :invalid_capability_record}

      not is_map(cap.constraints) ->
        {:error, :invalid_capability_record}

      not is_map(cap.metadata) ->
        {:error, :invalid_capability_record}

      not (is_integer(cap.delegation_depth) and cap.delegation_depth >= 0 and
               cap.delegation_depth <= 10) ->
        {:error, :invalid_capability_record}

      not (is_nil(cap.max_uses) or (is_integer(cap.max_uses) and cap.max_uses > 0)) ->
        {:error, :invalid_capability_record}

      not valid_deserialized_binary_list?(cap.allowed_delegatees) ->
        {:error, :invalid_capability_record}

      not valid_deserialized_optional_binary?(cap.session_id) ->
        {:error, :invalid_capability_record}

      not valid_deserialized_optional_binary?(cap.task_id) ->
        {:error, :invalid_capability_record}

      not valid_deserialized_optional_binary?(cap.principal_scope) ->
        {:error, :invalid_capability_record}

      not valid_deserialized_optional_nonempty_binary?(cap.issuer_id) ->
        {:error, :invalid_capability_record}

      not valid_deserialized_delegation_coherence?(cap) ->
        {:error, :invalid_capability_record}

      true ->
        :ok
    end
  end

  defp validate_deserialized_capability(_key, _cap), do: {:error, :invalid_capability_record}

  defp valid_deserialized_binary_list?(nil), do: true

  defp valid_deserialized_binary_list?(values) when is_list(values),
    do: Enum.all?(values, &is_binary/1)

  defp valid_deserialized_binary_list?(_), do: false

  defp valid_deserialized_optional_binary?(nil), do: true
  defp valid_deserialized_optional_binary?(value), do: is_binary(value)

  defp valid_deserialized_optional_nonempty_binary?(nil), do: true

  defp valid_deserialized_optional_nonempty_binary?(value),
    do: is_binary(value) and value != ""

  defp valid_deserialized_delegation_record?(
         %{
           delegator_id: delegator_id,
           delegator_signature: signature,
           constraints: constraints
         } = record
       ) do
    delegated_at = Map.get(record, :delegated_at)

    is_binary(delegator_id) and delegator_id != "" and is_binary(signature) and
      byte_size(signature) > 0 and is_map(constraints) and
      valid_deserialized_optional_datetime?(delegated_at)
  end

  defp valid_deserialized_delegation_record?(_), do: false

  defp valid_deserialized_optional_datetime?(nil), do: true
  defp valid_deserialized_optional_datetime?(%DateTime{}), do: true
  defp valid_deserialized_optional_datetime?(_), do: false

  defp valid_deserialized_delegation_coherence?(%Capability{
         parent_capability_id: nil,
         delegation_chain: []
       }),
       do: true

  defp valid_deserialized_delegation_coherence?(%Capability{
         parent_capability_id: parent,
         delegation_chain: [_ | _]
       })
       when is_binary(parent) and parent != "",
       do: true

  defp valid_deserialized_delegation_coherence?(_), do: false

  defp select_restore_winners(candidates, counters) do
    now = DateTime.utc_now()

    grouped =
      Enum.group_by(candidates, fn cap -> {cap.principal_id, cap.resource_uri} end)

    {winners, counters} =
      Enum.reduce(grouped, {[], counters}, fn {_pair, group}, {acc, counters} ->
        sorted = sort_caps_by_recency_desc(group)
        [winner | rest] = sorted
        superseded = length(rest)

        counters = Map.update!(counters, :restore_superseded, &(&1 + superseded))

        cond do
          expired_at?(winner, now) ->
            counters = Map.update!(counters, :restore_expired, &(&1 + 1))
            {acc, counters}

          not is_nil(winner.max_uses) ->
            # Usage counters are intentionally process-local today. Restoring a
            # limited-use grant would reset its consumed budget and expand
            # authority, so omit it until consumption has durable accounting.
            counters = Map.update!(counters, :restore_rejected, &(&1 + 1))
            {acc, counters}

          true ->
            counters = Map.update!(counters, :restore_active, &(&1 + 1))
            {[winner | acc], counters}
        end
      end)

    # Deterministic winner list so index rebuild never depends on map iteration.
    {:ok, sort_caps_by_recency_desc(winners), counters}
  end

  # Live put prepends to by_principal, so the first ID is the newest insertion.
  # Restore mirrors that selection order for find_authorizing/2: granted_at DESC,
  # then capability id DESC as a stable tie-breaker.
  defp sort_caps_by_recency_desc(caps) do
    Enum.sort(caps, &capability_recency_desc?/2)
  end

  defp capability_recency_desc?(a, b) do
    case DateTime.compare(a.granted_at, b.granted_at) do
      :gt -> true
      :lt -> false
      :eq -> a.id >= b.id
    end
  end

  defp expired_at?(%{expires_at: nil}, _now), do: false

  defp expired_at?(%{expires_at: expires_at}, now) do
    DateTime.compare(now, expires_at) == :gt
  end

  defp enforce_restored_quotas(winners) do
    if Config.quota_enforcement_enabled?() do
      with :ok <- enforce_restored_delegation_depth_quota(winners),
           :ok <- enforce_restored_global_quota(winners) do
        enforce_restored_per_principal_quotas(winners)
      end
    else
      :ok
    end
  end

  defp enforce_restored_delegation_depth_quota(winners) do
    max_depth = Config.max_delegation_depth()

    if Enum.any?(winners, &(&1.delegation_depth > max_depth)) do
      {:error, :restored_delegation_depth_exceeded}
    else
      :ok
    end
  end

  defp enforce_restored_global_quota(winners) do
    max_global = Config.max_global_capabilities()

    if length(winners) > max_global do
      {:error, :restored_global_quota_exceeded}
    else
      :ok
    end
  end

  defp enforce_restored_per_principal_quotas(winners) do
    max_per = Config.max_capabilities_per_agent()

    winners
    |> Enum.frequencies_by(& &1.principal_id)
    |> Enum.reduce_while(:ok, fn {_principal, count}, :ok ->
      if count > max_per do
        {:halt, {:error, :restored_per_principal_quota_exceeded}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp rebuild_restore_indexes(state, winners, counters) do
    # winners are already recency-desc sorted; materialize every runtime index
    # from that order so find_authorizing/list order is restart-stable.
    ordered = sort_caps_by_recency_desc(winners)
    by_id = Map.new(ordered, fn cap -> {cap.id, cap} end)
    by_principal = restore_index_by(ordered, & &1.principal_id)

    by_resource = build_restore_resource_index(ordered)

    by_issuer =
      ordered
      |> Enum.reject(fn cap -> is_nil(cap.issuer_id) end)
      |> restore_index_by(& &1.issuer_id)

    by_parent =
      ordered
      |> Enum.reject(fn cap -> is_nil(cap.parent_capability_id) end)
      |> restore_index_by(& &1.parent_capability_id)

    restore_stats = Map.put(counters, :total_granted, counters.restore_active)

    %{
      state
      | by_id: by_id,
        by_principal: by_principal,
        by_resource: by_resource,
        by_issuer: by_issuer,
        by_parent: by_parent,
        stats: Map.merge(state.stats, restore_stats)
    }
  end

  defp restore_index_by(caps, key_fun) do
    caps
    |> Enum.group_by(key_fun)
    |> Map.new(fn {key, group} ->
      ids =
        group
        |> sort_caps_by_recency_desc()
        |> Enum.map(& &1.id)

      {key, ids}
    end)
  end

  # Canonical live principal/resource index, rebuilt from the restored
  # authoritative projection. Derived ONLY from the restored winners (mirrors
  # by_id), never from by_principal, so a stale by_principal cannot hide a
  # same-resource conflict. pending_intents is in-memory only and stays empty
  # after restart (occupancy is rebuilt from the complete restored projection).
  defp build_restore_resource_index(ordered) do
    Enum.reduce(ordered, %{}, fn cap, acc ->
      Map.update(acc, resource_key(cap), MapSet.new([cap.id]), &MapSet.put(&1, cap.id))
    end)
  end
end
