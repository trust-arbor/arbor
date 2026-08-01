defmodule Arbor.AI.RouteConcurrency do
  @moduledoc """
  Node-local exact-route concurrency admission authority for Arbor AI.

  Supervised GenServer shell over `Arbor.AI.RouteConcurrencyCore`. Admits
  opaque unforgeable leases per exact `{provider, runtime}` and monitors
  each caller so owner death reclaims capacity.

  ## Scope (load-bearing)

  This authority is **node-local only** — process-local to one BEAM node.
  It is **not** cluster-global, partition-tolerant, or multi-node coherent.
  Cluster leases are deferred architecture work. The reviewed production
  profile explicitly treats these limits as node-local deployment policy, not
  observed cluster capacity. Cluster-global authority remains separately
  tracked work.

  Callers must not lazy-start this process; it is started under
  `Arbor.AI.Supervisor` (and the arbor_ai test helper).

  ## Owner PID (not authenticated identity)

  Acquire derives the owner from GenServer.call `from` as a **lifecycle PID**
  only — the process to monitor for capacity reclaim on death. It is not an
  authenticated principal, trust identity, or capability subject.
  """

  use GenServer

  alias Arbor.AI.RouteConcurrencyCore

  @lease_tag :route_concurrency_lease
  @config_key :provider_route_concurrency_limits

  # Side-effecting acquire/release MUST NOT use a finite GenServer.call timeout.
  # A timed-out acquire is an indeterminate commit: the authority can later admit
  # and monitor a still-live long-lived caller while Dispatch has returned
  # :unavailable and never received a lease to release. This node-local server
  # only performs bounded in-memory reducer work, so :infinity is unambiguous.
  # Snapshot is read-only and may remain bounded.
  @side_effect_call_timeout :infinity
  @snapshot_call_timeout 1_000

  # Opaque lease binds the exact authority **PID** resolved at acquire time so
  # release/1 never targets a rebound registered name or the production default.
  @type lease :: {:route_concurrency_lease, pid(), reference()}
  @type acquire_error ::
          :unconfigured_route | :at_capacity | :malformed_route | :unavailable
  @type snapshot_error :: :unavailable | :malformed

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    opts = if is_list(opts), do: opts, else: []
    id = Keyword.get(opts, :name, __MODULE__)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Start the node-local authority.

  Options:
    * `:name` — registered name (default `__MODULE__`)
    * `:limits` — nested limit map override (tests). Production loads
      `Application.get_env(:arbor_ai, :provider_route_concurrency_limits, %{})`.

  Malformed configured limits fail startup with `{:error, :malformed_config}`
  (never `:ignore` and never silently substituted with an empty map).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Atomically acquire a lease for an exact `{provider, runtime}`.

  Owner is the GenServer.call `from` lifecycle PID (monitor target only — not
  an authenticated identity). Returns an opaque lease bound to the exact
  authority **PID** resolved for this call, or a bounded error.

  Option `:route_concurrency_server` is an internal test seam (pid or name).
  Production callers omit it and use the supervised default.
  """
  @spec acquire(term(), term(), keyword()) :: {:ok, lease()} | {:error, acquire_error()}
  def acquire(provider, runtime, opts \\ []) when is_list(opts) do
    # Resolve name → PID once at acquire; store that PID in the lease so a
    # later Process.register rebinding cannot divert release.
    case resolve_pid(server(opts)) do
      {:ok, authority_pid} ->
        # :infinity — finite timeout would make admit/monitor vs client error indeterminate.
        case call_pid(authority_pid, {:acquire, provider, runtime}, @side_effect_call_timeout) do
          {:ok, token} when is_reference(token) ->
            {:ok, {@lease_tag, authority_pid, token}}

          {:error, reason}
          when reason in [:unconfigured_route, :at_capacity, :malformed_route, :unavailable] ->
            {:error, reason}

          _ ->
            {:error, :unavailable}
        end

      :error ->
        {:error, :unavailable}
    end
  end

  @doc """
  Idempotent release against the authority **PID** bound into the lease.

  Missing/forged/unavailable leases and transport failures are no-ops (`:ok`).
  Never raises. An already-absent valid token is idempotent success.
  """
  @spec release(term()) :: :ok
  def release({@lease_tag, authority_pid, token})
      when is_pid(authority_pid) and is_reference(token) do
    # :infinity — release is side-effecting; a timed-out free would be indeterminate.
    case call_pid(authority_pid, {:release, token}, @side_effect_call_timeout) do
      :ok -> :ok
      {:error, _} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def release(_lease), do: :ok

  @doc """
  Bounded exact snapshot of configured routes and in-use counts.

  Returns `%{{provider, runtime} => %{concurrency_limit: n, concurrency_in_use: u}}`.
  """
  @spec snapshot(keyword()) ::
          {:ok,
           %{
             optional({String.t(), String.t()}) => %{
               concurrency_limit: non_neg_integer(),
               concurrency_in_use: non_neg_integer()
             }
           }}
          | {:error, snapshot_error()}
  def snapshot(opts \\ []) when is_list(opts) do
    # Read-only: bounded timeout is safe (no capacity commit).
    case resolve_pid(server(opts)) do
      {:ok, pid} ->
        case call_pid(pid, :snapshot, @snapshot_call_timeout) do
          {:ok, snap} when is_map(snap) ->
            case RouteConcurrencyCore.validate_snapshot(snap) do
              {:ok, validated} -> {:ok, validated}
              {:error, :malformed} -> {:error, :malformed}
            end

          {:error, :unavailable} ->
            {:error, :unavailable}

          {:error, :malformed} ->
            {:error, :malformed}

          _ ->
            {:error, :malformed}
        end

      :error ->
        {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) when is_list(opts) do
    raw =
      case Keyword.fetch(opts, :limits) do
        {:ok, limits} -> limits
        :error -> Application.get_env(:arbor_ai, @config_key, %{})
      end

    case RouteConcurrencyCore.new(raw) do
      {:ok, state} ->
        {:ok, state}

      {:error, :malformed_config} ->
        # Explicit fail-closed startup — never :ignore, never empty-map substitute.
        {:stop, :malformed_config}
    end
  end

  @impl true
  def handle_call({:acquire, provider, runtime}, {owner, _tag}, state) when is_pid(owner) do
    # `owner` is the caller's lifecycle PID for Process.monitor reclaim only —
    # not an authenticated identity or trust principal.
    token = make_ref()

    case RouteConcurrencyCore.acquire(state, provider, runtime, owner, token) do
      {:ok, state2, effects} ->
        case apply_acquire_effects(state2, effects) do
          {:ok, state3} ->
            {:reply, {:ok, token}, state3}

          {:error, :monitor_bind_failed, rolled_back} ->
            # Roll back capacity if monitor binding cannot complete.
            {:reply, {:error, :unavailable}, rolled_back}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, token}, _from, state) when is_reference(token) do
    {:ok, state2, effects} = RouteConcurrencyCore.release(state, token)
    state3 = apply_release_effects(state2, effects)
    {:reply, :ok, state3}
  end

  def handle_call({:release, _token}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    snap = RouteConcurrencyCore.snapshot(state)

    case RouteConcurrencyCore.validate_snapshot(snap) do
      {:ok, validated} -> {:reply, {:ok, validated}, state}
      {:error, :malformed} -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :malformed_route}, state}

  @impl true
  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    {:ok, state2, effects} = RouteConcurrencyCore.owner_down(state, mon_ref)
    state3 = apply_release_effects(state2, effects)
    {:noreply, state3}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Shell helpers
  # ---------------------------------------------------------------------------

  defp server(opts) when is_list(opts) do
    Keyword.get(opts, :route_concurrency_server, __MODULE__)
  end

  defp call_pid(pid, message, timeout)
       when is_pid(pid) and (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    try do
      GenServer.call(pid, message, timeout)
    catch
      :exit, _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp resolve_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: :error
  end

  defp resolve_pid(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      _ -> :error
    end
  end

  defp resolve_pid(_), do: :error

  # Acquire path: monitor + bind must succeed or we roll the lease back.
  defp apply_acquire_effects(state, effects) when is_list(effects) do
    Enum.reduce_while(effects, {:ok, state}, fn
      {:monitor, owner, lease_token}, {:ok, acc}
      when is_pid(owner) and is_reference(lease_token) ->
        mon_ref = Process.monitor(owner)

        case RouteConcurrencyCore.bind_monitor(acc, lease_token, mon_ref) do
          {:ok, bound} ->
            {:cont, {:ok, bound}}

          {:error, _} ->
            Process.demonitor(mon_ref, [:flush])
            {:ok, rolled, _} = RouteConcurrencyCore.release(acc, lease_token)
            {:halt, {:error, :monitor_bind_failed, rolled}}
        end

      _other, acc ->
        {:cont, acc}
    end)
  rescue
    _ ->
      # Bounded failure — attempt pure rollback of any unmonitored lease tokens.
      rolled =
        Enum.reduce(effects, state, fn
          {:monitor, _owner, lease_token}, acc when is_reference(lease_token) ->
            {:ok, next, _} = RouteConcurrencyCore.release(acc, lease_token)
            next

          _, acc ->
            acc
        end)

      {:error, :monitor_bind_failed, rolled}
  end

  # Release/DOWN path: demonitor best-effort; never raise into callers.
  defp apply_release_effects(state, effects) when is_list(effects) do
    Enum.reduce(effects, state, fn
      {:demonitor, mon_ref}, acc when is_reference(mon_ref) ->
        try do
          Process.demonitor(mon_ref, [:flush])
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        acc

      _, acc ->
        acc
    end)
  end
end
