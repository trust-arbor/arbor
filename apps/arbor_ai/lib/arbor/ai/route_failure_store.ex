defmodule Arbor.AI.RouteFailureStore do
  @moduledoc """
  Exact-route, AI-owned current non-quota failure evidence for OAuth routes.

  Stores only closed class/code pairs with explicit expiry. Never holds tokens,
  account IDs, paths, or provider response bodies. Quota/rate-limit cooldowns
  stay in `Arbor.AI.QuotaTracker` — this store must not be used as a quota sink.

  ## Competing-failure severity (deterministic; single active class per route)

  One entry is retained per exact route. Arrival order must not clobber a more
  severe class. Severity ranks (higher wins):

      :auth         = 50
      :tier_denied  = 40
      :outage       = 30
      :protocol     = 20
      :transport    = 10

  Put merge (deterministic; wall-clock `now` at put; **arrival-order independent**):

  * New entry must still be active (`expires_at > now`); already-expired puts reject.
  * Absent or expired existing → accept active new.
  * Active existing + active new → **severity rank first** (higher wins regardless of
    `observed_at` order). Equal rank/class → prefer newer `observed_at`; if equal,
    prefer later `expires_at`, then lexicographically greater `code`, then
    `retryable == true`; fully identical fields keep existing (content-identical).

  Snapshot validates every stored entry (route key, `entry.route` equality, closed
  class/code, DateTime fields, boolean) **before** any `DateTime.compare/2`.
  Malformed state returns `{:error, :malformed}` without crashing the GenServer.

  Periodic cleanup is **expiry-only for validated entries**. Malformed slots are
  retained unchanged so corrupt required evidence cannot silently become an
  empty/clean route. Explicit recovery is a validated put replace, `clear_sync/1`,
  or supervised restart — never silent cleanup erasure.

  Supervised by `Arbor.AI.Application`. Callers must not lazy-start this process.
  """

  use GenServer

  @routes ~w(openai_oauth xai_oauth)
  @classes [:auth, :tier_denied, :transport, :protocol, :outage]
  @codes ~w(
    unauthorized forbidden xai_oauth_tier_denied server_error request_timeout
    deadline_exceeded connection_failed unexpected_status response_bytes_exceeded
    invalid_response_headers invalid_stream
  )
  @severity_rank %{
    auth: 50,
    tier_denied: 40,
    outage: 30,
    protocol: 20,
    transport: 10
  }
  @max_entries 32
  @max_retry_after_ms 86_400_000
  @default_ttl_ms %{
    auth: 300_000,
    tier_denied: 3_600_000,
    transport: 60_000,
    protocol: 300_000,
    outage: 120_000
  }

  defstruct routes: %{}

  @type public_entry :: %{
          route: String.t(),
          class: atom(),
          code: String.t(),
          observed_at: DateTime.t(),
          expires_at: DateTime.t(),
          retryable: boolean()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously record one exact-route failure. Replies only after in-memory state updates.

  Does not start the GenServer — it must already be supervised.
  """
  @spec put_sync(keyword() | map()) :: :ok | {:error, :rejected | :unavailable}
  def put_sync(attrs) when is_list(attrs) or is_map(attrs) do
    # Reject non-keyword/improper lists at the public boundary before GenServer.
    case safe_attrs_map(attrs) do
      {:ok, normalized_attrs} ->
        case Process.whereis(__MODULE__) do
          pid when is_pid(pid) ->
            if Process.alive?(pid) do
              try do
                case GenServer.call(pid, {:put, normalized_attrs}, 1_000) do
                  :ok -> :ok
                  {:error, :rejected} -> {:error, :rejected}
                end
              catch
                :exit, _ -> {:error, :unavailable}
              end
            else
              {:error, :unavailable}
            end

          _ ->
            {:error, :unavailable}
        end

      :error ->
        {:error, :rejected}
    end
  rescue
    _ -> {:error, :rejected}
  catch
    _, _ -> {:error, :rejected}
  end

  def put_sync(_attrs), do: {:error, :rejected}

  @doc "Synchronously clear one exact route (tests / recovery). No-op when store is down."
  @spec clear_sync(atom() | String.t()) :: :ok
  def clear_sync(route) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        case admit_route(route) do
          {:ok, route} ->
            try do
              GenServer.call(pid, {:clear, route}, 1_000)
            catch
              :exit, _ -> :ok
            end

          :error ->
            :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Bounded snapshot of non-expired failures keyed by exact route string.
  """
  @spec snapshot_status(keyword()) ::
          {:ok, %{String.t() => public_entry()}} | {:error, :unavailable | :malformed}
  def snapshot_status(opts \\ [])

  def snapshot_status(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if match?(%DateTime{}, now) do
      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            try do
              GenServer.call(pid, {:snapshot, now}, 500)
            catch
              :exit, _ -> {:error, :unavailable}
            end
          else
            {:error, :unavailable}
          end

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :malformed}
    end
  end

  def snapshot_status(_opts), do: {:error, :malformed}

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %__MODULE__{routes: %{}}}
  end

  @impl true
  def handle_call({:put, attrs}, _from, state) do
    now = DateTime.utc_now()

    case normalize_put(attrs) do
      {:ok, entry} ->
        # Already-expired evidence must not enter or replace active state.
        if active_entry?(entry, now) do
          case fetch_existing(state.routes, entry.route, now) do
            :absent ->
              accept_new_route(state, entry)

            {:active, existing} ->
              merge_put(state, existing, entry)

            :malformed_existing ->
              # Heal by replacing corrupt slot with validated active entry.
              accept_replace(state, entry)
          end
        else
          {:reply, {:error, :rejected}, state}
        end

      :error ->
        {:reply, {:error, :rejected}, state}
    end
  end

  def handle_call({:clear, route}, _from, state) do
    {:reply, :ok, %{state | routes: Map.delete(state.routes, route)}}
  end

  def handle_call({:snapshot, now}, _from, state) do
    case build_snapshot(state.routes, now) do
      {:ok, active} -> {:reply, {:ok, active}, state}
      {:error, :malformed} -> {:reply, {:error, :malformed}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    routes =
      state.routes
      |> Enum.reduce(%{}, fn {route, entry}, acc ->
        case validate_stored_entry(route, entry) do
          {:ok, valid} ->
            # Expiry-only for validated entries: drop expired, keep active.
            if active_entry?(valid, now), do: Map.put(acc, route, valid), else: acc

          :error ->
            # Retain corrupt slots fail-closed until explicit recovery. Cleanup
            # must not erase required evidence into an apparently clean route.
            Map.put(acc, route, entry)
        end
      end)

    schedule_cleanup()
    {:noreply, %{state | routes: routes}}
  end

  defp fetch_existing(routes, route, now) do
    case Map.fetch(routes, route) do
      :error ->
        :absent

      {:ok, existing} ->
        case validate_stored_entry(route, existing) do
          {:ok, valid} ->
            if active_entry?(valid, now), do: {:active, valid}, else: :absent

          :error ->
            :malformed_existing
        end
    end
  end

  defp accept_new_route(state, entry) do
    if map_size(state.routes) >= @max_entries do
      {:reply, {:error, :rejected}, state}
    else
      {:reply, :ok, %{state | routes: Map.put(state.routes, entry.route, entry)}}
    end
  end

  defp accept_replace(state, entry) do
    {:reply, :ok, %{state | routes: Map.put(state.routes, entry.route, entry)}}
  end

  # Severity-first merge: result must not depend on put arrival order among active entries.
  defp merge_put(state, existing, entry) do
    existing_rank = Map.fetch!(@severity_rank, existing.class)
    new_rank = Map.fetch!(@severity_rank, entry.class)

    cond do
      new_rank > existing_rank ->
        accept_replace(state, entry)

      new_rank < existing_rank ->
        {:reply, :ok, state}

      # Equal rank (unique ranks ⇒ same class): pick preferred by timestamps / fields.
      true ->
        case preferred_equal_rank_entry(existing, entry) do
          ^entry -> accept_replace(state, entry)
          _keep_existing -> {:reply, :ok, state}
        end
    end
  end

  defp preferred_equal_rank_entry(existing, entry) do
    case DateTime.compare(entry.observed_at, existing.observed_at) do
      :gt ->
        entry

      :lt ->
        existing

      :eq ->
        case DateTime.compare(entry.expires_at, existing.expires_at) do
          :gt ->
            entry

          :lt ->
            existing

          :eq ->
            cond do
              entry.code > existing.code -> entry
              entry.code < existing.code -> existing
              entry.retryable == true and existing.retryable == false -> entry
              entry.retryable == false and existing.retryable == true -> existing
              true -> existing
            end
        end
    end
  end

  defp active_entry?(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) == :gt
  end

  defp active_entry?(_, _), do: false

  # Validate every field before any DateTime.compare — never crash on corrupt state.
  defp build_snapshot(routes, %DateTime{} = now) when is_map(routes) do
    Enum.reduce_while(routes, {:ok, %{}}, fn {route_key, entry}, {:ok, acc} ->
      case validate_stored_entry(route_key, entry) do
        {:ok, valid} ->
          if active_entry?(valid, now) do
            {:cont, {:ok, Map.put(acc, valid.route, public_entry_map(valid))}}
          else
            {:cont, {:ok, acc}}
          end

        :error ->
          {:halt, {:error, :malformed}}
      end
    end)
  end

  defp build_snapshot(_, _), do: {:error, :malformed}

  defp validate_stored_entry(route_key, entry) when is_map(entry) do
    with true <- is_binary(route_key) and route_key in @routes,
         route when is_binary(route) and route in @routes <- Map.get(entry, :route),
         true <- route == route_key,
         class when is_atom(class) and class in @classes <- Map.get(entry, :class),
         code when is_binary(code) and code in @codes <- Map.get(entry, :code),
         %DateTime{} = observed_at <- Map.get(entry, :observed_at),
         %DateTime{} = expires_at <- Map.get(entry, :expires_at),
         retryable when is_boolean(retryable) <- Map.get(entry, :retryable),
         true <- DateTime.compare(expires_at, observed_at) == :gt do
      {:ok,
       %{
         route: route,
         class: class,
         code: code,
         observed_at: observed_at,
         expires_at: expires_at,
         retryable: retryable
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp validate_stored_entry(_, _), do: :error

  defp public_entry_map(entry) do
    %{
      route: entry.route,
      class: entry.class,
      code: entry.code,
      observed_at: entry.observed_at,
      expires_at: entry.expires_at,
      retryable: entry.retryable
    }
  end

  defp normalize_put(attrs) do
    with {:ok, map} <- safe_attrs_map(attrs) do
      normalize_put_map(map)
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp normalize_put_map(attrs) when is_map(attrs) do
    with {:ok, route} <- admit_route(Map.get(attrs, :route) || Map.get(attrs, "route")),
         {:ok, class} <- admit_class(Map.get(attrs, :class) || Map.get(attrs, "class")),
         {:ok, code} <- admit_code(Map.get(attrs, :code) || Map.get(attrs, "code")),
         {:ok, retryable} <- admit_boolean(retryable_raw(attrs), false),
         {:ok, observed_at} <-
           admit_datetime(
             Map.get(attrs, :observed_at) || Map.get(attrs, "observed_at"),
             DateTime.utc_now()
           ),
         {:ok, explicit_expires} <-
           admit_optional_datetime(Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at")),
         {:ok, expires_at} <-
           compute_expires_at(observed_at, class, retry_after_raw(attrs), explicit_expires) do
      {:ok,
       %{
         route: route,
         class: class,
         code: code,
         observed_at: observed_at,
         expires_at: expires_at,
         retryable: retryable
       }}
    else
      _ -> :error
    end
  end

  # Never call Map.new/1 on arbitrary lists — improper/non-keyword lists raise.
  # Maps and keyword lists share the same entry bound so oversized maps never
  # enter the GenServer mailbox.
  @max_put_attrs 64

  defp safe_attrs_map(attrs) when is_map(attrs) do
    if map_size(attrs) <= @max_put_attrs do
      {:ok, attrs}
    else
      :error
    end
  end

  defp safe_attrs_map(attrs) when is_list(attrs) do
    if proper_keyword_list?(attrs) do
      {:ok, Map.new(attrs)}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp safe_attrs_map(_), do: :error

  defp proper_keyword_list?(list), do: proper_keyword_list?(list, 0)

  defp proper_keyword_list?([], _n), do: true

  defp proper_keyword_list?([{key, _value} | rest], n)
       when is_atom(key) and n < @max_put_attrs do
    proper_keyword_list?(rest, n + 1)
  end

  defp proper_keyword_list?(_, _), do: false

  # Preserve false: never use || across boolean fields.
  defp retryable_raw(attrs) do
    cond do
      Map.has_key?(attrs, :retryable) -> Map.get(attrs, :retryable)
      Map.has_key?(attrs, "retryable") -> Map.get(attrs, "retryable")
      true -> nil
    end
  end

  # Prefer atom key; do not use || so falsey integers are not an issue (ints are truthy).
  defp retry_after_raw(attrs) do
    cond do
      Map.has_key?(attrs, :retry_after_ms) -> Map.get(attrs, :retry_after_ms)
      Map.has_key?(attrs, "retry_after_ms") -> Map.get(attrs, "retry_after_ms")
      true -> nil
    end
  end

  defp compute_expires_at(observed_at, class, retry_after_ms, explicit_expires) do
    max_expires = DateTime.add(observed_at, @max_retry_after_ms, :millisecond)

    cond do
      match?(%DateTime{}, explicit_expires) and
          DateTime.compare(explicit_expires, observed_at) == :gt ->
        {:ok, clamp_expires(explicit_expires, max_expires)}

      # Explicit negative retry_after is rejected (do not fall through to default TTL).
      is_integer(retry_after_ms) and retry_after_ms < 0 ->
        :error

      is_integer(retry_after_ms) and retry_after_ms >= 0 and retry_after_ms <= @max_retry_after_ms ->
        {:ok, DateTime.add(observed_at, retry_after_ms, :millisecond)}

      is_integer(retry_after_ms) and retry_after_ms > @max_retry_after_ms ->
        {:ok, max_expires}

      is_nil(retry_after_ms) and is_nil(explicit_expires) ->
        ttl = Map.fetch!(@default_ttl_ms, class)
        {:ok, DateTime.add(observed_at, ttl, :millisecond)}

      is_nil(retry_after_ms) ->
        # explicit_expires present but not a future DateTime — reject rather than invent TTL.
        :error

      true ->
        # Non-integer non-nil retry_after_ms
        :error
    end
  end

  defp clamp_expires(%DateTime{} = expires, %DateTime{} = max_expires) do
    if DateTime.compare(expires, max_expires) == :gt, do: max_expires, else: expires
  end

  defp admit_route(route) when route in @routes, do: {:ok, route}
  defp admit_route(:openai_oauth), do: {:ok, "openai_oauth"}
  defp admit_route(:xai_oauth), do: {:ok, "xai_oauth"}
  defp admit_route(_), do: :error

  # Binary-or-atom closed class admission: exact table membership only.
  # Never String.to_atom/1 on free text; never substring/alias inference.
  defp admit_class(class) when class in @classes, do: {:ok, class}

  defp admit_class(class) when is_binary(class) do
    Enum.find_value(@classes, :error, fn atom ->
      if Atom.to_string(atom) == class, do: {:ok, atom}
    end)
  end

  defp admit_class(_), do: :error

  # Binary-or-atom closed code admission: exact table membership only.
  defp admit_code(code) when is_atom(code) and not is_nil(code) do
    string = Atom.to_string(code)
    if string in @codes, do: {:ok, string}, else: :error
  end

  defp admit_code(code) when is_binary(code) and code in @codes, do: {:ok, code}
  defp admit_code(_), do: :error

  defp admit_boolean(true, _default), do: {:ok, true}
  defp admit_boolean(false, _default), do: {:ok, false}
  defp admit_boolean(nil, default), do: {:ok, default}
  defp admit_boolean(_, _default), do: :error

  defp admit_datetime(%DateTime{} = dt, _default), do: {:ok, dt}

  defp admit_datetime(iso, _default) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp admit_datetime(nil, %DateTime{} = default), do: {:ok, default}
  defp admit_datetime(_, _), do: :error

  defp admit_optional_datetime(nil), do: {:ok, nil}
  defp admit_optional_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp admit_optional_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp admit_optional_datetime(_), do: :error

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(1))
  end
end
