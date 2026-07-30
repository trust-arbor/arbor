defmodule Arbor.AI.RouteConcurrencyCore do
  @moduledoc """
  Pure CRC reducer for node-local exact-route concurrency admission.

  State transitions and monitor/demonitor *decisions* live here as data.
  The GenServer shell is the only place that may call `make_ref/0`,
  `Process.monitor/1`, `Process.demonitor/2`, GenServer, or Application config.

  Exact route key is `{provider_string, runtime_string}`. No alias expansion,
  fuzzy matching, prefix matching, or untrusted atom creation.
  """

  @max_providers 64
  @max_runtimes_per_provider 16
  @max_total_routes 256
  @max_limit 10_000
  @max_segment_bytes 64
  @segment_re ~r/^[A-Za-z0-9_.-]+$/

  @type route_key :: {String.t(), String.t()}
  @type lease_token :: reference()
  @type mon_ref :: reference()

  @type lease :: %{
          route: route_key(),
          owner: pid(),
          monitor_ref: mon_ref() | nil
        }

  @type state :: %{
          limits: %{optional(route_key()) => non_neg_integer()},
          leases: %{optional(lease_token()) => lease()},
          by_route: %{optional(route_key()) => MapSet.t(lease_token())},
          by_monitor: %{optional(mon_ref()) => lease_token()}
        }

  @type effect ::
          {:monitor, pid(), lease_token()}
          | {:demonitor, mon_ref()}

  @type acquire_error :: :unconfigured_route | :at_capacity | :malformed_route

  @doc "Construct empty admission state from a bounded nested limit map."
  @spec new(term()) :: {:ok, state()} | {:error, :malformed_config}
  def new(raw_limits) do
    case normalize_limits(raw_limits) do
      {:ok, limits} ->
        {:ok,
         %{
           limits: limits,
           leases: %{},
           by_route: %{},
           by_monitor: %{}
         }}

      {:error, :malformed_config} ->
        {:error, :malformed_config}
    end
  end

  @doc """
  Normalize nested `provider => runtime => non_neg_integer` limits.

  Accepts atom or string keys; never creates atoms. Rejects duplicates,
  malformed identities, oversized maps, and out-of-bound limits.
  """
  @spec normalize_limits(term()) ::
          {:ok, %{optional(route_key()) => non_neg_integer()}} | {:error, :malformed_config}
  def normalize_limits(raw) when is_map(raw) and not is_struct(raw) do
    if map_size(raw) > @max_providers do
      {:error, :malformed_config}
    else
      Enum.reduce_while(raw, {:ok, %{}}, fn {provider_key, runtimes}, {:ok, acc} ->
        case normalize_provider_runtimes(provider_key, runtimes, acc) do
          {:ok, acc2} -> {:cont, {:ok, acc2}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, limits} when map_size(limits) > @max_total_routes ->
          {:error, :malformed_config}

        other ->
          other
      end
    end
  end

  def normalize_limits(_), do: {:error, :malformed_config}

  @doc "Normalize one provider/runtime identity pair to an exact route key."
  @spec normalize_route(term(), term()) :: {:ok, route_key()} | {:error, :malformed_route}
  def normalize_route(provider, runtime) do
    with {:ok, p} <- normalize_segment(provider),
         {:ok, r} <- normalize_segment(runtime) do
      {:ok, {p, r}}
    else
      _ -> {:error, :malformed_route}
    end
  end

  @doc """
  Atomically admit one lease for an exact route.

  `lease_token` is injected by the shell (`make_ref/0`). Owner must be a pid.
  """
  @spec acquire(state(), term(), term(), pid(), lease_token()) ::
          {:ok, state(), [effect()]} | {:error, acquire_error()}
  def acquire(state, provider, runtime, owner, lease_token)
      when is_map(state) and is_pid(owner) and is_reference(lease_token) do
    with {:ok, route} <- normalize_route(provider, runtime),
         :ok <- ensure_token_free(state, lease_token) do
      case Map.fetch(state.limits, route) do
        :error ->
          {:error, :unconfigured_route}

        {:ok, limit} when is_integer(limit) and limit >= 0 ->
          in_use = route_in_use(state, route)

          if in_use >= limit do
            {:error, :at_capacity}
          else
            lease = %{route: route, owner: owner, monitor_ref: nil}
            tokens = Map.get(state.by_route, route, MapSet.new()) |> MapSet.put(lease_token)

            new_state = %{
              state
              | leases: Map.put(state.leases, lease_token, lease),
                by_route: Map.put(state.by_route, route, tokens)
            }

            {:ok, new_state, [{:monitor, owner, lease_token}]}
          end
      end
    end
  end

  def acquire(_state, _provider, _runtime, _owner, _lease_token), do: {:error, :malformed_route}

  @doc "Bind a process monitor ref to an admitted lease (shell after Process.monitor)."
  @spec bind_monitor(state(), lease_token(), mon_ref()) ::
          {:ok, state()} | {:error, :unknown_lease}
  def bind_monitor(state, lease_token, mon_ref)
      when is_reference(lease_token) and is_reference(mon_ref) do
    case Map.fetch(state.leases, lease_token) do
      {:ok, lease} ->
        updated = %{lease | monitor_ref: mon_ref}

        {:ok,
         %{
           state
           | leases: Map.put(state.leases, lease_token, updated),
             by_monitor: Map.put(state.by_monitor, mon_ref, lease_token)
         }}

      :error ->
        {:error, :unknown_lease}
    end
  end

  def bind_monitor(_state, _lease_token, _mon_ref), do: {:error, :unknown_lease}

  @doc "Idempotent release of a lease token; returns demonitor effect when bound."
  @spec release(state(), lease_token()) :: {:ok, state(), [effect()]}
  def release(state, lease_token) when is_reference(lease_token) do
    case Map.pop(state.leases, lease_token) do
      {nil, _} ->
        {:ok, state, []}

      {lease, leases} ->
        drop_lease(state, lease_token, lease, leases)
    end
  end

  def release(state, _lease_token), do: {:ok, state, []}

  @doc "Reclaim capacity when a monitored owner dies."
  @spec owner_down(state(), mon_ref()) :: {:ok, state(), [effect()]}
  def owner_down(state, mon_ref) when is_reference(mon_ref) do
    case Map.pop(state.by_monitor, mon_ref) do
      {nil, _} ->
        {:ok, state, []}

      {lease_token, by_monitor} ->
        state = %{state | by_monitor: by_monitor}

        case Map.pop(state.leases, lease_token) do
          {nil, _} ->
            {:ok, state, []}

          {lease, leases} ->
            # Monitor already fired; no demonitor effect required.
            {state2, _effects} = drop_lease_without_demonitor(state, lease_token, lease, leases)
            {:ok, state2, []}
        end
    end
  end

  def owner_down(state, _mon_ref), do: {:ok, state, []}

  @doc """
  Exact bounded snapshot of configured routes only.

  Returns `%{{provider, runtime} => %{concurrency_limit: n, concurrency_in_use: u}}`.
  """
  @spec snapshot(state()) :: %{
          optional(route_key()) => %{
            concurrency_limit: non_neg_integer(),
            concurrency_in_use: non_neg_integer()
          }
        }
  def snapshot(%{limits: limits, by_route: by_route}) when is_map(limits) do
    Map.new(limits, fn {route, limit} ->
      in_use = by_route |> Map.get(route, MapSet.new()) |> MapSet.size()
      {route, %{concurrency_limit: limit, concurrency_in_use: in_use}}
    end)
  end

  def snapshot(_), do: %{}

  @doc "Validate a public snapshot map shape (assembler fail-closed gate)."
  @spec validate_snapshot(term()) :: {:ok, map()} | {:error, :malformed}
  def validate_snapshot(snap) when is_map(snap) and not is_struct(snap) do
    if map_size(snap) > @max_total_routes do
      {:error, :malformed}
    else
      Enum.reduce_while(snap, {:ok, %{}}, fn entry, {:ok, acc} ->
        case normalize_snapshot_entry(entry) do
          {:ok, route, fields} -> {:cont, {:ok, Map.put(acc, route, fields)}}
          :error -> {:halt, {:error, :malformed}}
        end
      end)
    end
  end

  def validate_snapshot(_), do: {:error, :malformed}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp normalize_provider_runtimes(provider_key, runtimes, acc)
       when is_map(runtimes) and not is_struct(runtimes) do
    with {:ok, provider} <- normalize_segment(provider_key),
         true <- map_size(runtimes) <= @max_runtimes_per_provider do
      Enum.reduce_while(runtimes, {:ok, acc}, fn {runtime_key, limit}, {:ok, acc2} ->
        with {:ok, runtime} <- normalize_segment(runtime_key),
             :ok <- validate_limit(limit),
             route = {provider, runtime},
             :ok <- reject_duplicate_route(acc2, route) do
          {:cont, {:ok, Map.put(acc2, route, limit)}}
        else
          _ -> {:halt, {:error, :malformed_config}}
        end
      end)
    else
      _ -> {:error, :malformed_config}
    end
  end

  defp normalize_provider_runtimes(_provider_key, _runtimes, _acc),
    do: {:error, :malformed_config}

  defp normalize_segment(value) when is_atom(value) do
    # Existing atoms only — never String.to_atom.
    normalize_segment(Atom.to_string(value))
  end

  defp normalize_segment(value) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_segment_bytes and
         String.valid?(value) and String.match?(value, @segment_re) do
      {:ok, value}
    else
      :error
    end
  end

  defp normalize_segment(_), do: :error

  defp validate_limit(limit) when is_integer(limit) and limit >= 0 and limit <= @max_limit,
    do: :ok

  defp validate_limit(_), do: :error

  defp reject_duplicate_route(acc, route) do
    if Map.has_key?(acc, route), do: :error, else: :ok
  end

  defp ensure_token_free(state, lease_token) do
    if Map.has_key?(state.leases, lease_token), do: {:error, :malformed_route}, else: :ok
  end

  defp route_in_use(state, route) do
    state.by_route |> Map.get(route, MapSet.new()) |> MapSet.size()
  end

  defp drop_lease(state, lease_token, lease, leases) do
    {state2, effects} = drop_lease_without_demonitor(state, lease_token, lease, leases)

    effects =
      case lease.monitor_ref do
        mon when is_reference(mon) -> [{:demonitor, mon} | effects]
        _ -> effects
      end

    {:ok, state2, effects}
  end

  defp drop_lease_without_demonitor(state, lease_token, lease, leases) do
    route = lease.route
    tokens = Map.get(state.by_route, route, MapSet.new()) |> MapSet.delete(lease_token)

    by_route =
      if MapSet.size(tokens) == 0 do
        Map.delete(state.by_route, route)
      else
        Map.put(state.by_route, route, tokens)
      end

    by_monitor =
      case lease.monitor_ref do
        mon when is_reference(mon) -> Map.delete(state.by_monitor, mon)
        _ -> state.by_monitor
      end

    {%{state | leases: leases, by_route: by_route, by_monitor: by_monitor}, []}
  end

  defp normalize_snapshot_entry({{p, r}, fields}) when is_binary(p) and is_binary(r) and is_map(fields) do
    with {:ok, route} <- normalize_route(p, r),
         {:ok, limit} <- fetch_nonneg(fields, :concurrency_limit, "concurrency_limit"),
         {:ok, in_use} <- fetch_nonneg(fields, :concurrency_in_use, "concurrency_in_use") do
      {:ok, route, %{concurrency_limit: limit, concurrency_in_use: in_use}}
    else
      _ -> :error
    end
  end

  defp normalize_snapshot_entry(_), do: :error

  defp fetch_nonneg(map, atom_key, string_key) do
    value = Map.get(map, atom_key, Map.get(map, string_key))

    if is_integer(value) and value >= 0 and value <= @max_limit do
      {:ok, value}
    else
      :error
    end
  end
end
