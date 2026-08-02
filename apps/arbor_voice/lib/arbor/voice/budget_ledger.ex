defmodule Arbor.Voice.BudgetLedger do
  @moduledoc """
  Durable daily voice budget ledger (VP-04B — prerequisite for VOICE-24).

  Prevents concurrent or restarted voice sessions from exceeding one user's
  UTC-day allowance. Reaches persistence only through the public
  `Arbor.Persistence` facade, using structured
  `Arbor.Contracts.Persistence.Record` compare-and-swap fenced on generation
  and revision. Every operation — not only `readiness/1` — first attests that
  the configured backend exposes linearizable CAS and reports code-attested
  `:node_restart` durability; none of them read or write before that
  attestation succeeds.

  State validation and the reserve/consume/release/remaining decisions live
  in the pure `Arbor.Voice.BudgetLedgerCore` (CRC pattern). This module is the
  imperative shell: it generates reservation ids, reads the clock, resolves
  configuration, computes settlement fingerprints, and performs the bounded
  read/decide/CAS loop.

  VOICE-24 stays `(planned)` in `docs/arbor/specs/VOICE-1.0.md` — this packet
  supplies accounting only. VP-04 wires a hard session timer, backend
  closure, spoken notice, and audit signal before that statement is proven.
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence
  alias Arbor.Voice.BudgetLedger.Reservation
  alias Arbor.Voice.BudgetLedgerCore, as: Core
  alias Arbor.Voice.Config

  @readiness_opts [:backend, :backend_opts]
  @simple_opts [:backend, :backend_opts, :now_unix_ms]
  @reserve_opts [:backend, :backend_opts, :now_unix_ms, :reservation_id]
  @hash_hex_length 64
  @max_user_id_bytes 4096
  # tight caller-input cap (1 day); Core allows a wider internal arithmetic bound
  @max_caller_duration_ms 86_400_000

  @doc """
  Attests that the configured (or `opts`-overridden) backend exposes
  linearizable CAS and reports code-attested `:node_restart` durability.
  Every other operation in this module runs the same attestation first — this
  function just reports its own result.
  """
  @spec readiness(keyword()) ::
          {:ok, %{durability: :node_restart}} | {:error, atom() | {:backend_error, term()}}
  def readiness(opts \\ []) do
    with :ok <- validate_opts(opts, @readiness_opts),
         {:ok, _config} <- resolve_config(opts) do
      {:ok, %{durability: :node_restart}}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reserve `requested_ms` of `user_id`'s `utc_day` allowance. Admits only when
  the sum of consumed usage, live reservations, and this request does not
  exceed `daily_limit_ms`. Returns an opaque `Reservation` on success.
  """
  @spec reserve(String.t(), String.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, Reservation.t()} | {:error, atom() | {:backend_error, term()}}
  def reserve(user_id, utc_day, requested_ms, daily_limit_ms, opts \\ []) do
    with :ok <- validate_opts(opts, @reserve_opts),
         :ok <- validate_user_id(user_id),
         :ok <- validate_utc_day(utc_day),
         :ok <- validate_positive_duration(requested_ms),
         :ok <- validate_positive_duration(daily_limit_ms),
         :ok <- validate_now_ms(Keyword.get(opts, :now_unix_ms)),
         :ok <- validate_reservation_id_opt(Keyword.get(opts, :reservation_id)),
         {:ok, config} <- resolve_config(opts),
         {:ok, grace_ms} <- Config.budget_reservation_grace_ms(),
         {:ok, max_retries} <- Config.budget_cas_max_retries() do
      key = storage_key(user_id, utc_day)

      now_ms =
        if is_nil(Keyword.get(opts, :now_unix_ms)),
          do: System.system_time(:millisecond),
          else: Keyword.get(opts, :now_unix_ms)

      reservation_id =
        if is_nil(Keyword.get(opts, :reservation_id)),
          do: generate_reservation_id(),
          else: Keyword.get(opts, :reservation_id)

      decide_fun = fn existing ->
        reserve_decide(
          existing,
          key,
          utc_day,
          daily_limit_ms,
          reservation_id,
          requested_ms,
          now_ms,
          grace_ms
        )
      end

      cas_loop(key, config, decide_fun, max_retries)
    end
  end

  @doc """
  Atomically convert `reservation` into `elapsed_ms` of consumed usage,
  releasing any unused remainder. Idempotent for a replay with the same
  elapsed value. Fails closed on a fingerprint mismatch (the reservation's
  claims do not match durable provenance), a larger conflicting replay, an
  elapsed value above the reservation, or an unknown/expired reservation.
  """
  @spec consume(term(), non_neg_integer(), keyword()) ::
          :ok | {:error, atom() | {:backend_error, term()}}
  def consume(reservation, elapsed_ms, opts \\ [])

  def consume(%Reservation{} = reservation, elapsed_ms, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @simple_opts),
         :ok <- validate_reservation_shape(reservation),
         :ok <- validate_non_negative_duration(elapsed_ms),
         :ok <- validate_now_ms(Keyword.get(opts, :now_unix_ms)),
         {:ok, config} <- resolve_config(opts),
         {:ok, max_retries} <- Config.budget_cas_max_retries() do
      now_ms =
        if is_nil(Keyword.get(opts, :now_unix_ms)),
          do: System.system_time(:millisecond),
          else: Keyword.get(opts, :now_unix_ms)

      fingerprint = reservation_fingerprint(reservation)

      decide_fun = fn existing ->
        consume_decide(existing, reservation, elapsed_ms, fingerprint, now_ms)
      end

      case cas_loop(reservation.key, config, decide_fun, max_retries) do
        {:ok, :ok} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  def consume(_reservation, _elapsed_ms, _opts), do: {:error, :invalid_reservation}

  @doc """
  Atomically release an unconsumed `reservation`. Idempotent when that exact
  reservation was already released. Fails closed on a fingerprint mismatch,
  an already-consumed settlement, or an unknown/expired reservation.
  """
  @spec release(term(), keyword()) :: :ok | {:error, atom() | {:backend_error, term()}}
  def release(reservation, opts \\ [])

  def release(%Reservation{} = reservation, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @simple_opts),
         :ok <- validate_reservation_shape(reservation),
         :ok <- validate_now_ms(Keyword.get(opts, :now_unix_ms)),
         {:ok, config} <- resolve_config(opts),
         {:ok, max_retries} <- Config.budget_cas_max_retries() do
      now_ms =
        if is_nil(Keyword.get(opts, :now_unix_ms)),
          do: System.system_time(:millisecond),
          else: Keyword.get(opts, :now_unix_ms)

      fingerprint = reservation_fingerprint(reservation)

      decide_fun = fn existing -> release_decide(existing, reservation, fingerprint, now_ms) end

      case cas_loop(reservation.key, config, decide_fun, max_retries) do
        {:ok, :ok} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  def release(_reservation, _opts), do: {:error, :invalid_reservation}

  @doc "Report `user_id`'s remaining `utc_day` allowance after consumed usage and live reservations."
  @spec remaining(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, atom() | {:backend_error, term()}}
  def remaining(user_id, utc_day, daily_limit_ms, opts \\ []) do
    with :ok <- validate_opts(opts, @simple_opts),
         :ok <- validate_user_id(user_id),
         :ok <- validate_utc_day(utc_day),
         :ok <- validate_positive_duration(daily_limit_ms),
         :ok <- validate_now_ms(Keyword.get(opts, :now_unix_ms)),
         {:ok, config} <- resolve_config(opts) do
      key = storage_key(user_id, utc_day)

      now_ms =
        if is_nil(Keyword.get(opts, :now_unix_ms)),
          do: System.system_time(:millisecond),
          else: Keyword.get(opts, :now_unix_ms)

      case Persistence.get(config.namespace, config.backend, key, config.backend_opts) do
        {:ok, %Record{} = existing} ->
          read_remaining(existing.data, utc_day, now_ms, daily_limit_ms)

        {:error, :not_found} ->
          read_remaining(nil, utc_day, now_ms, daily_limit_ms)

        {:error, reason} ->
          {:error, {:backend_error, reason}}
      end
    end
  end

  defp read_remaining(data, utc_day, now_ms, daily_limit_ms) do
    case Core.new(data, utc_day, now_ms, {:check, daily_limit_ms}) do
      {:ok, state} -> {:ok, Core.remaining(state)}
      {:error, _reason} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Reserve decision — two pure core calls so the fingerprint (shell, impure)
  # can be computed from the core-decided fields before the single CAS write.
  # ---------------------------------------------------------------------------

  defp reserve_decide(
         existing,
         key,
         utc_day,
         daily_limit_ms,
         reservation_id,
         requested_ms,
         now_ms,
         grace_ms
       ) do
    data = existing && existing.data

    case Core.new(data, utc_day, now_ms, {:check, daily_limit_ms}) do
      {:error, _reason} = error ->
        error

      {:ok, state} ->
        case Core.reserve(state, reservation_id, requested_ms, now_ms, grace_ms) do
          {:error, _reason} = error ->
            error

          {:ok, :admitted, fields} ->
            fp =
              fingerprint(
                fields.id,
                key,
                utc_day,
                fields.requested_ms,
                fields.reserved_at_ms,
                fields.expires_at_ms
              )

            {:ok, new_state} = Core.commit_reservation(state, fields, fp)

            reservation = %Reservation{
              id: fields.id,
              key: key,
              utc_day: utc_day,
              requested_ms: fields.requested_ms,
              reserved_at_ms: fields.reserved_at_ms,
              expires_at_ms: fields.expires_at_ms
            }

            {:write, new_state, reservation}
        end
    end
  end

  defp consume_decide(existing, reservation, elapsed_ms, fingerprint, now_ms) do
    data = existing && existing.data

    case Core.new(data, reservation.utc_day, now_ms, :skip) do
      {:error, _reason} = error ->
        error

      {:ok, state} ->
        case Core.consume(state, reservation.id, elapsed_ms, fingerprint, now_ms) do
          {:error, _reason} = error -> error
          {:ok, ^state} -> {:noop, :ok}
          {:ok, new_state} -> {:write, new_state, :ok}
        end
    end
  end

  defp release_decide(existing, reservation, fingerprint, now_ms) do
    data = existing && existing.data

    case Core.new(data, reservation.utc_day, now_ms, :skip) do
      {:error, _reason} = error ->
        error

      {:ok, state} ->
        case Core.release(state, reservation.id, fingerprint, now_ms) do
          {:error, _reason} = error -> error
          {:ok, ^state} -> {:noop, :ok}
          {:ok, new_state} -> {:write, new_state, :ok}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Bounded read/decide/CAS loop — the only place Persistence writes happen.
  # `decide_fun` returns {:error, reason} | {:noop, extra} | {:write, state, extra}.
  # ---------------------------------------------------------------------------

  defp cas_loop(key, config, decide_fun, retries_left) do
    case Persistence.get(config.namespace, config.backend, key, config.backend_opts) do
      {:ok, %Record{} = existing} ->
        dispatch(
          decide_fun.(existing),
          key,
          config,
          existing,
          {:value, existing},
          decide_fun,
          retries_left
        )

      {:error, :not_found} ->
        dispatch(decide_fun.(nil), key, config, nil, :not_found, decide_fun, retries_left)

      {:error, reason} ->
        {:error, {:backend_error, reason}}
    end
  end

  defp dispatch(
         {:error, _reason} = error,
         _key,
         _config,
         _existing,
         _cas_expected,
         _decide_fun,
         _retries_left
       ),
       do: error

  defp dispatch(
         {:noop, extra},
         _key,
         _config,
         _existing,
         _cas_expected,
         _decide_fun,
         _retries_left
       ),
       do: {:ok, extra}

  defp dispatch(
         {:write, new_state, extra},
         key,
         config,
         existing,
         cas_expected,
         decide_fun,
         retries_left
       ) do
    record = build_record(key, existing, new_state)

    case Persistence.compare_and_swap(
           config.namespace,
           config.backend,
           key,
           cas_expected,
           record,
           config.backend_opts
         ) do
      {:ok, _stored} ->
        {:ok, extra}

      {:error, :conflict} when retries_left > 0 ->
        cas_loop(key, config, decide_fun, retries_left - 1)

      {:error, :conflict} ->
        {:error, :contention}

      {:error, :unsupported} ->
        {:error, :unsupported}

      {:error, reason} ->
        {:error, {:backend_error, reason}}
    end
  end

  defp build_record(key, nil, new_state), do: Record.new(key, Core.to_data(new_state))

  defp build_record(_key, %Record{} = existing, new_state),
    do: Record.update(existing, Core.to_data(new_state))

  # ---------------------------------------------------------------------------
  # Config resolution — attests CAS + :node_restart durability before every
  # operation reads or writes. opts override Config only for :backend and
  # :backend_opts (the injectable test seam); the namespace is fixed.
  # ---------------------------------------------------------------------------

  defp resolve_config(opts) do
    with {:ok, backend} <- resolve_backend(opts),
         {:ok, backend_opts} <- resolve_backend_opts(opts),
         {:ok, namespace} <- Config.budget_namespace(),
         :ok <- attest(backend, namespace, backend_opts) do
      {:ok, %{backend: backend, namespace: namespace, backend_opts: backend_opts}}
    end
  end

  defp resolve_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      :error -> Config.budget_backend()
      {:ok, backend} -> Config.validate_budget_backend(backend)
    end
  end

  defp resolve_backend_opts(opts) do
    case Keyword.fetch(opts, :backend_opts) do
      :error -> Config.budget_backend_opts()
      {:ok, backend_opts} -> Config.validate_budget_backend_opts(backend_opts)
    end
  end

  defp attest(backend, namespace, backend_opts) do
    cond do
      not Persistence.supports_compare_and_swap?(backend) -> {:error, :unsupported}
      not Persistence.supports_durability_class?(backend) -> {:error, :unsupported}
      true -> attest_durability(backend, namespace, backend_opts)
    end
  end

  defp attest_durability(backend, namespace, backend_opts) do
    case safe_call(fn -> Persistence.durability_class(namespace, backend, backend_opts) end) do
      {:ok, :node_restart} -> :ok
      {:ok, _other} -> {:error, :not_node_restart}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # Reservation provenance — recompute, never trust a caller-presented value.
  # ---------------------------------------------------------------------------

  defp reservation_fingerprint(%Reservation{} = r) do
    fingerprint(r.id, r.key, r.utc_day, r.requested_ms, r.reserved_at_ms, r.expires_at_ms)
  end

  defp fingerprint(id, key, utc_day, requested_ms, reserved_at_ms, expires_at_ms) do
    payload =
      Jason.encode!([
        "arbor.voice.budget_ledger.reservation:v1",
        id,
        key,
        utc_day,
        requested_ms,
        reserved_at_ms,
        expires_at_ms
      ])

    Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp validate_reservation_shape(%Reservation{key: key, utc_day: utc_day} = reservation) do
    with true <- is_binary(key),
         true <- is_binary(utc_day),
         suffix = ":" <> utc_day,
         true <- String.ends_with?(key, suffix),
         prefix = binary_part(key, 0, byte_size(key) - byte_size(suffix)),
         true <- valid_hash_prefix?(prefix),
         true <- Core.valid_utc_day?(utc_day),
         true <- Core.valid_id?(reservation.id),
         true <- valid_positive_duration?(reservation.requested_ms),
         true <- Core.valid_timestamp_ms?(reservation.reserved_at_ms),
         true <-
           valid_expiry?(
             reservation.reserved_at_ms,
             reservation.requested_ms,
             reservation.expires_at_ms
           ) do
      :ok
    else
      _ -> {:error, :invalid_reservation}
    end
  end

  defp valid_expiry?(reserved_at_ms, requested_ms, expires_at_ms) do
    Core.valid_timestamp_ms?(expires_at_ms) and
      expires_at_ms >= reserved_at_ms and
      expires_at_ms - reserved_at_ms >= requested_ms
  end

  defp valid_hash_prefix?(v),
    do: is_binary(v) and byte_size(v) == @hash_hex_length and String.match?(v, ~r/^[0-9a-f]+$/)

  # ---------------------------------------------------------------------------
  # Caller input validation
  # ---------------------------------------------------------------------------

  defp validate_user_id(v)
       when is_binary(v) and byte_size(v) > 0 and byte_size(v) <= @max_user_id_bytes do
    if String.valid?(v) and String.trim_leading(v) != "" and String.trim_trailing(v) != "",
      do: :ok,
      else: {:error, :invalid_user_id}
  end

  defp validate_user_id(_), do: {:error, :invalid_user_id}

  defp validate_utc_day(v) do
    if Core.valid_utc_day?(v), do: :ok, else: {:error, :invalid_utc_day}
  end

  defp valid_positive_duration?(v),
    do: is_integer(v) and v > 0 and v <= @max_caller_duration_ms

  defp validate_positive_duration(v) do
    if valid_positive_duration?(v), do: :ok, else: {:error, :invalid_amount}
  end

  defp validate_non_negative_duration(v) do
    if is_integer(v) and v >= 0 and v <= @max_caller_duration_ms,
      do: :ok,
      else: {:error, :invalid_amount}
  end

  defp validate_now_ms(v) when is_nil(v), do: :ok

  defp validate_now_ms(v) do
    if Core.valid_timestamp_ms?(v), do: :ok, else: {:error, :invalid_now}
  end

  defp validate_reservation_id_opt(v) when is_nil(v), do: :ok

  defp validate_reservation_id_opt(v) do
    if Core.valid_id?(v), do: :ok, else: {:error, :invalid_reservation_id}
  end

  # ---------------------------------------------------------------------------
  # Storage key — raw user ids must never appear in a durable key.
  # ---------------------------------------------------------------------------

  defp storage_key(user_id, utc_day) do
    Base.encode16(:crypto.hash(:sha256, user_id), case: :lower) <> ":" <> utc_day
  end

  defp generate_reservation_id do
    hex =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "vres_" <> hex
  end

  defp validate_opts(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) -> {:error, :invalid_options}
        Enum.any?(keys, &(&1 not in allowed)) -> {:error, :invalid_options}
        true -> :ok
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_opts(_opts, _allowed), do: {:error, :invalid_options}
end
