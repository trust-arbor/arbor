defmodule Arbor.Voice.Test.SessionFakes do
  @moduledoc """
  Hermetic collaborator fakes for `Arbor.Voice.Session` lifecycle tests
  (VP-04D2B). State is process-independent (ETS + Agent) so the Session
  GenServer can call them from another process. No Application env mutation.
  """

  # ---------------------------------------------------------------------------
  # Signals
  # ---------------------------------------------------------------------------

  defmodule FakeSignals do
    @moduledoc false
    @table :arbor_voice_fake_signals

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _tid -> :ok
      end

      :ok
    end

    def start(opts \\ []) do
      ensure_table!()
      mode = Keyword.get(opts, :mode, :ok)
      {:ok, agent} = Agent.start_link(fn -> %{mode: mode, emissions: []} end)
      :ets.insert(@table, {:agent, agent})
      {:ok, agent}
    end

    def emissions(agent), do: Agent.get(agent, &Enum.reverse(&1.emissions))

    def set_mode(agent, mode), do: Agent.update(agent, &%{&1 | mode: mode})

    def emit(category, type, data \\ %{}, opts \\ []) do
      agent = lookup_agent!()

      mode =
        Agent.get_and_update(agent, fn state ->
          # Record the full public emit/4 shape including the closed opts list.
          entry = {category, type, data, opts}
          {state.mode, %{state | emissions: [entry | state.emissions]}}
        end)

      case mode do
        :ok -> :ok
        :error -> {:error, :bus_down}
        :raise -> raise "signals boom"
        :throw -> throw(:signals_throw)
        :exit -> exit(:signals_exit)
      end
    end

    defp lookup_agent! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] -> agent
        [] -> raise "FakeSignals not started"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Engagement store (Comms seam — forwarded only :engagement_store)
  # ---------------------------------------------------------------------------

  defmodule FakeEngagementStore do
    @moduledoc false
    @table :arbor_voice_fake_engagement_store

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _tid -> :ok
      end

      :ok
    end

    def start(opts \\ []) do
      ensure_table!()

      result =
        Keyword.get(opts, :result, {:ok, %{id: "eng_lifecycle", agent_id: "agent_x"}})

      {:ok, agent} = Agent.start_link(fn -> %{result: result, calls: []} end)
      :ets.insert(@table, {:agent, agent})
      {:ok, agent}
    end

    def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

    def set_result(agent, result), do: Agent.update(agent, &%{&1 | result: result})

    def resolve_or_create(agent_id, user_id, opts) do
      agent = lookup_agent!()

      Agent.get_and_update(agent, fn state ->
        call = {agent_id, user_id, opts}
        {state.result, %{state | calls: [call | state.calls]}}
      end)
    end

    defp lookup_agent! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] -> agent
        [] -> raise "FakeEngagementStore not started"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Comms facade module used when tests inject comms: FakeCommsSession
  # ---------------------------------------------------------------------------

  defmodule FakeCommsSession do
    @moduledoc false
    # resolve_user_engagement/3 only — Session does not call record_engagement_turn.

    def resolve_user_engagement(agent_id, user_id, opts) do
      store = Keyword.get(opts, :engagement_store, FakeEngagementStore)
      store.resolve_or_create(agent_id, user_id, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Ledger
  # ---------------------------------------------------------------------------

  defmodule FakeLedger do
    @moduledoc false
    alias Arbor.Voice.BudgetLedger.Reservation

    @table :arbor_voice_fake_ledger

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _tid -> :ok
      end

      :ok
    end

    def start(opts \\ []) do
      ensure_table!()

      {:ok, agent} =
        Agent.start_link(fn ->
          %{
            reserve_mode: Keyword.get(opts, :reserve_mode, :ok),
            consume_mode: Keyword.get(opts, :consume_mode, :ok),
            release_mode: Keyword.get(opts, :release_mode, :ok),
            # Fail the next N consume/release calls, then succeed (retry proof).
            consume_fail_remaining: Keyword.get(opts, :consume_fail_remaining, 0),
            release_fail_remaining: Keyword.get(opts, :release_fail_remaining, 0),
            calls: [],
            reserved_ms_total: 0
          }
        end)

      :ets.insert(@table, {:agent, agent})
      {:ok, agent}
    end

    def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))
    def reserved_ms_total(agent), do: Agent.get(agent, & &1.reserved_ms_total)

    def set_reserve_mode(agent, mode),
      do: Agent.update(agent, &%{&1 | reserve_mode: mode})

    def set_consume_mode(agent, mode),
      do: Agent.update(agent, &%{&1 | consume_mode: mode})

    def set_release_mode(agent, mode),
      do: Agent.update(agent, &%{&1 | release_mode: mode})

    def set_consume_fail_remaining(agent, n) when is_integer(n) and n >= 0,
      do: Agent.update(agent, &%{&1 | consume_fail_remaining: n})

    def set_release_fail_remaining(agent, n) when is_integer(n) and n >= 0,
      do: Agent.update(agent, &%{&1 | release_fail_remaining: n})

    def reserve(user_id, utc_day, requested_ms, daily_limit_ms, opts) do
      agent = lookup_agent!()

      outcome =
        Agent.get_and_update(agent, fn state ->
          call = {:reserve, user_id, utc_day, requested_ms, daily_limit_ms, opts}

          case state.reserve_mode do
            :ok ->
              reservation = %Reservation{
                id: "vres_" <> Integer.to_string(System.unique_integer([:positive]), 16),
                key: String.duplicate("a", 64) <> ":" <> utc_day,
                utc_day: utc_day,
                requested_ms: requested_ms,
                reserved_at_ms: 1_000,
                expires_at_ms: 1_000 + requested_ms + 60_000
              }

              {{:return, {:ok, reservation}},
               %{
                 state
                 | calls: [call | state.calls],
                   reserved_ms_total: state.reserved_ms_total + requested_ms
               }}

            :budget_exhausted ->
              {{:return, {:error, :budget_exhausted}}, %{state | calls: [call | state.calls]}}

            :error ->
              {{:return, {:error, :backend_error}}, %{state | calls: [call | state.calls]}}

            :raise ->
              {{:raise, "ledger reserve boom"}, %{state | calls: [call | state.calls]}}
          end
        end)

      deliver(outcome)
    end

    def consume(reservation, elapsed_ms, opts) do
      agent = lookup_agent!()

      outcome =
        Agent.get_and_update(agent, fn state ->
          call = {:consume, reservation.id, elapsed_ms, opts}
          state = %{state | calls: [call | state.calls]}

          cond do
            state.consume_fail_remaining > 0 ->
              {{:return, {:error, :backend_error}},
               %{state | consume_fail_remaining: state.consume_fail_remaining - 1}}

            state.consume_mode == :ok ->
              {{:return, :ok}, state}

            state.consume_mode == :error ->
              {{:return, {:error, :backend_error}}, state}

            state.consume_mode == :raise ->
              {{:raise, "ledger consume boom"}, state}

            true ->
              {{:return, {:error, :backend_error}}, state}
          end
        end)

      deliver(outcome)
    end

    def release(reservation, opts) do
      agent = lookup_agent!()

      outcome =
        Agent.get_and_update(agent, fn state ->
          call = {:release, reservation.id, opts}
          state = %{state | calls: [call | state.calls]}

          cond do
            state.release_fail_remaining > 0 ->
              {{:return, {:error, :backend_error}},
               %{state | release_fail_remaining: state.release_fail_remaining - 1}}

            state.release_mode == :ok ->
              {{:return, :ok}, state}

            state.release_mode == :error ->
              {{:return, {:error, :backend_error}}, state}

            state.release_mode == :raise ->
              {{:raise, "ledger release boom"}, state}

            true ->
              {{:return, {:error, :backend_error}}, state}
          end
        end)

      deliver(outcome)
    end

    defp deliver({:return, result}), do: result
    defp deliver({:raise, message}), do: raise(message)

    defp lookup_agent! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] -> agent
        [] -> raise "FakeLedger not started"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ResourceOwner tracking facade (delegates to real ResourceOwner)
  # ---------------------------------------------------------------------------

  defmodule TrackingResourceOwner do
    @moduledoc false
    @table :arbor_voice_tracking_resource_owner

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _tid -> :ok
      end

      :ok
    end

    def start_tracker(opts \\ []) do
      ensure_table!()

      {:ok, agent} =
        Agent.start_link(fn ->
          %{
            start_mode: Keyword.get(opts, :start_mode, :ok),
            register_mode: Keyword.get(opts, :register_mode, :ok),
            configure_mode: Keyword.get(opts, :configure_mode, :ok),
            meta_mode: Keyword.get(opts, :meta_mode, :ok),
            starts: 0,
            closes: 0,
            registers: 0,
            removes: 0,
            configures: 0,
            metas: 0,
            direct_releases: 0
          }
        end)

      :ets.insert(@table, {:agent, agent})
      {:ok, agent}
    end

    def stats(agent) do
      Agent.get(
        agent,
        &Map.take(&1, [
          :starts,
          :closes,
          :registers,
          :removes,
          :configures,
          :metas,
          :start_mode,
          :register_mode,
          :configure_mode,
          :meta_mode
        ])
      )
    end

    def set_start_mode(agent, mode), do: Agent.update(agent, &%{&1 | start_mode: mode})
    def set_register_mode(agent, mode), do: Agent.update(agent, &%{&1 | register_mode: mode})
    def set_configure_mode(agent, mode), do: Agent.update(agent, &%{&1 | configure_mode: mode})
    def set_meta_mode(agent, mode), do: Agent.update(agent, &%{&1 | meta_mode: mode})

    # Tracker state is read/updated via Agent, but every real ResourceOwner
    # call MUST run in the original Session caller process — ResourceOwner's
    # owner-bound check rejects foreign callers (Agent pid ≠ Session pid).

    def start(owner_pid, backend_module, backend_opts \\ [], opts \\ [])

    def start(owner_pid, backend_module, backend_opts, opts)
        when is_pid(owner_pid) and is_atom(backend_module) do
      agent = lookup_agent!()
      mode = Agent.get(agent, fn s -> s.start_mode end)
      _ = Agent.update(agent, fn s -> %{s | starts: s.starts + 1} end)

      case mode do
        :ok ->
          # Call in this process (Session), not inside the Agent callback.
          Arbor.Voice.ResourceOwner.start(owner_pid, backend_module, backend_opts, opts)

        :fail ->
          {:error, :open_failed}
      end
    end

    def configure(owner, config) do
      agent = lookup_agent!()
      mode = Agent.get(agent, fn s -> s.configure_mode end)
      _ = Agent.update(agent, fn s -> %{s | configures: s.configures + 1} end)

      case mode do
        :ok -> Arbor.Voice.ResourceOwner.configure(owner, config)
        :fail -> {:error, :configure_failed}
      end
    end

    def meta(owner) do
      agent = lookup_agent!()
      mode = Agent.get(agent, fn s -> s.meta_mode end)
      _ = Agent.update(agent, fn s -> %{s | metas: s.metas + 1} end)

      case mode do
        :ok -> Arbor.Voice.ResourceOwner.meta(owner)
        :fail -> {:error, :meta_failed}
        :invalid -> {:ok, %{backend: :x, mode: :bogus}}
      end
    end

    def register_cleanup(owner, key, fun) do
      agent = lookup_agent!()
      mode = Agent.get(agent, fn s -> s.register_mode end)
      _ = Agent.update(agent, fn s -> %{s | registers: s.registers + 1} end)

      case mode do
        :ok -> Arbor.Voice.ResourceOwner.register_cleanup(owner, key, fun)
        :fail -> {:error, :register_failed}
      end
    end

    def remove_cleanup(owner, key) do
      agent = lookup_agent!()
      _ = Agent.update(agent, fn s -> %{s | removes: s.removes + 1} end)
      Arbor.Voice.ResourceOwner.remove_cleanup(owner, key)
    end

    def close(owner) do
      agent = lookup_agent!()
      _ = Agent.update(agent, fn s -> %{s | closes: s.closes + 1} end)
      Arbor.Voice.ResourceOwner.close(owner)
    end

    defp lookup_agent! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] -> agent
        [] -> raise "TrackingResourceOwner not started"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Controllable backend
  # ---------------------------------------------------------------------------

  defmodule ControllableBackend do
    @moduledoc false
    @behaviour Arbor.Voice.RealtimeBackend
    @table :arbor_voice_session_controllable_backend

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          _ = :ets.new(@table, [:named_table, :public, :set])

        _tid ->
          :ok
      end

      :ok
    end

    def set_mode(mode) when is_atom(mode) do
      ensure_table!()
      :ets.insert(@table, {:mode, mode})
      :ok
    end

    def close_count do
      ensure_table!()

      case :ets.lookup(@table, :close_count) do
        [{:close_count, n}] -> n
        [] -> 0
      end
    end

    def reset_close_count do
      ensure_table!()
      :ets.insert(@table, {:close_count, 0})
      :ok
    end

    defp mode do
      ensure_table!()

      case :ets.lookup(@table, :mode) do
        [{:mode, m}] -> m
        [] -> :ok
      end
    end

    @impl true
    def open(_opts) do
      ensure_table!()
      reset_close_count()
      {:ok, %{id: make_ref(), closed: false}}
    end

    @impl true
    def configure(session, _config) do
      case mode() do
        :configure_fail -> {:error, :configure_failed}
        _ -> {:ok, session}
      end
    end

    @impl true
    def send_text(session, _text), do: {:ok, session}
    @impl true
    def send_audio(session, _chunk), do: {:ok, session}
    @impl true
    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    @impl true
    def recv(session, _timeout), do: {:ok, session, {:turn_done, %{text: ""}}}

    @impl true
    def close(_session) do
      ensure_table!()

      count =
        case :ets.lookup(@table, :close_count) do
          [{:close_count, n}] -> n + 1
          [] -> 1
        end

      :ets.insert(@table, {:close_count, count})
      :ok
    end

    @impl true
    def meta(_session) do
      case mode() do
        :meta_fail ->
          %{backend: :controllable, mode: :invalid}

        _ ->
          %{backend: :controllable, mode: :local, input_rate: nil, output_rate: nil}
      end
    end
  end
end
