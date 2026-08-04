defmodule Arbor.Voice.Test.SessionFakes do
  @moduledoc """
  Hermetic collaborator fakes for `Arbor.Voice.Session` lifecycle tests
  (VP-04D2B). State is process-independent (ETS + Agent) so the Session
  GenServer can call them from another process. No Application env mutation.

  Agents are started under ExUnit's per-test supervisor with unique child
  ids so normal test-process exit reclaims every fake state process. Do not
  use bare `Agent.start_link/1` here — a linked Agent outlives a normally
  exiting ExUnit process.
  """

  @doc false
  def start_owned_agent(initial_fun) when is_function(initial_fun, 0) do
    # Unique child id per start so table-driven tests may own many Agents
    # within one ExUnit case; all are stopped by ExUnit on test exit.
    id = {__MODULE__, make_ref()}

    ExUnit.Callbacks.start_supervised(%{
      id: id,
      start: {Agent, :start_link, [initial_fun]}
    })
  end

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

      {:ok, agent} =
        Arbor.Voice.Test.SessionFakes.start_owned_agent(fn ->
          %{mode: mode, emissions: []}
        end)

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

      {:ok, agent} =
        Arbor.Voice.Test.SessionFakes.start_owned_agent(fn ->
          %{result: result, calls: []}
        end)

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
    # Public Comms shapes used by Session: resolve_user_engagement/3 and
    # record_engagement_turn/5 (via TranscriptRecorder).

    @table :arbor_voice_fake_comms_session

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _tid -> :ok
      end

      :ok
    end

    def start_recorder(opts \\ []) do
      ensure_table!()

      {:ok, agent} =
        Arbor.Voice.Test.SessionFakes.start_owned_agent(fn ->
          %{
            result: Keyword.get(opts, :result, {:ok, 2}),
            mode: Keyword.get(opts, :mode, :ok),
            waiter: Keyword.get(opts, :waiter),
            calls: []
          }
        end)

      :ets.insert(@table, {:agent, agent})
      {:ok, agent}
    end

    def record_calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

    def set_record_result(agent, result),
      do: Agent.update(agent, &%{&1 | result: result, mode: :ok})

    def set_record_mode(agent, mode), do: Agent.update(agent, &%{&1 | mode: mode})

    def set_record_waiter(agent, waiter) when is_pid(waiter),
      do: Agent.update(agent, &%{&1 | waiter: waiter})

    def resolve_user_engagement(agent_id, user_id, opts) do
      store = Keyword.get(opts, :engagement_store, FakeEngagementStore)
      store.resolve_or_create(agent_id, user_id, opts)
    end

    def record_engagement_turn(agent_id, engagement_id, user_entry, assistant_entry, opts) do
      agent = lookup_recorder!()

      outcome =
        Agent.get_and_update(agent, fn state ->
          call = {agent_id, engagement_id, user_entry, assistant_entry, opts}
          state = %{state | calls: [call | state.calls]}

          case state.mode do
            :ok -> {{:return, state.result}, state}
            :error -> {{:return, {:error, :persistence_down}}, state}
            :raise -> {{:raise, "comms record boom"}, state}
            :throw -> {{:throw, :comms_throw}, state}
            :exit -> {{:exit, :comms_exit}, state}
            :block -> {{:block, state.result, state.waiter}, state}
          end
        end)

      case outcome do
        {:return, result} ->
          result

        {:raise, message} ->
          raise(message)

        {:throw, value} ->
          throw(value)

        {:exit, reason} ->
          exit(reason)

        {:block, result, waiter} ->
          # Session shell blocks here until the test releases durable write.
          if is_pid(waiter), do: send(waiter, {:record_entered, self()})

          receive do
            :release_record -> result
          after
            15_000 ->
              raise "FakeCommsSession record block timed out waiting for :release_record"
          end
      end
    end

    defp lookup_recorder! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] -> agent
        [] -> raise "FakeCommsSession recorder not started"
      end
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
        Arbor.Voice.Test.SessionFakes.start_owned_agent(fn ->
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
        Arbor.Voice.Test.SessionFakes.start_owned_agent(fn ->
          %{
            start_mode: Keyword.get(opts, :start_mode, :ok),
            register_mode: Keyword.get(opts, :register_mode, :ok),
            adopt_mode: Keyword.get(opts, :adopt_mode, :ok),
            activate_mode: Keyword.get(opts, :activate_mode, :ok),
            configure_mode: Keyword.get(opts, :configure_mode, :ok),
            meta_mode: Keyword.get(opts, :meta_mode, :ok),
            close_mode: Keyword.get(opts, :close_mode, :ok),
            starts: 0,
            closes: 0,
            registers: 0,
            adopts: 0,
            removes: 0,
            activates: 0,
            fences: 0,
            configures: 0,
            metas: 0,
            direct_releases: 0,
            accepted_failures: 0,
            cleanup_runs: 0,
            handoff_cleanup_keys: [],
            owner_cleanups: %{},
            last_owner: nil
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
          :adopts,
          :removes,
          :activates,
          :fences,
          :configures,
          :metas,
          :start_mode,
          :register_mode,
          :adopt_mode,
          :activate_mode,
          :configure_mode,
          :meta_mode,
          :close_mode,
          :accepted_failures,
          :cleanup_runs,
          :handoff_cleanup_keys
        ])
      )
    end

    def set_start_mode(agent, mode), do: Agent.update(agent, &%{&1 | start_mode: mode})
    def set_register_mode(agent, mode), do: Agent.update(agent, &%{&1 | register_mode: mode})
    def set_adopt_mode(agent, mode), do: Agent.update(agent, &%{&1 | adopt_mode: mode})
    def set_activate_mode(agent, mode), do: Agent.update(agent, &%{&1 | activate_mode: mode})
    def set_configure_mode(agent, mode), do: Agent.update(agent, &%{&1 | configure_mode: mode})
    def set_meta_mode(agent, mode), do: Agent.update(agent, &%{&1 | meta_mode: mode})
    def set_close_mode(agent, mode), do: Agent.update(agent, &%{&1 | close_mode: mode})
    def owner(agent), do: Agent.get(agent, & &1.last_owner)

    # Tracker state is read/updated via Agent, but every real ResourceOwner
    # call MUST run in the original Session caller process — ResourceOwner's
    # owner-bound check rejects foreign callers (Agent pid ≠ Session pid).

    def start(owner_pid, backend_module, backend_opts, handoff, opts)

    def start(owner_pid, backend_module, backend_opts, handoff, opts)
        when is_pid(owner_pid) and is_atom(backend_module) do
      agent = lookup_agent!()
      mode = Agent.get(agent, fn s -> s.start_mode end)
      initial_cleanups = Map.get(handoff, :initial_cleanups)

      _ =
        Agent.update(agent, fn state ->
          keys = if is_map(initial_cleanups), do: Map.keys(initial_cleanups), else: []
          %{state | starts: state.starts + 1, handoff_cleanup_keys: keys}
        end)

      case mode do
        :ok ->
          {legacy_handoff, cleanups_to_register} =
            legacy_handoff(Map.get(handoff, :authority), initial_cleanups)

          # The branch's concrete ResourceOwner still speaks the prior handoff
          # shape. Translate at this fake boundary only, while retaining the
          # complete new cleanup map for the parallel owner's drain semantics.
          case Arbor.Voice.ResourceOwner.start(
                 owner_pid,
                 backend_module,
                 backend_opts,
                 legacy_handoff,
                 opts
               ) do
            {:ok, owner} = result ->
              cleanups = if is_map(initial_cleanups), do: initial_cleanups, else: %{}

              case register_initial_cleanups(owner, cleanups_to_register) do
                :ok ->
                  _ =
                    Agent.update(agent, fn state ->
                      %{
                        state
                        | last_owner: owner,
                          owner_cleanups: Map.put(state.owner_cleanups, owner, cleanups)
                      }
                    end)

                  result

                {:error, _reason} ->
                  _ = Arbor.Voice.ResourceOwner.close(owner)
                  {:error, {:handoff_accepted, :start_failed}}
              end

            other ->
              other
          end

        :accepted_fail ->
          _ = Agent.update(agent, &%{&1 | accepted_failures: &1.accepted_failures + 1})
          _ = run_cleanup_map(agent, initial_cleanups)
          {:error, {:handoff_accepted, :start_failed}}

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

    def send_text(owner, text), do: Arbor.Voice.ResourceOwner.send_text(owner, text)
    def send_audio(owner, audio), do: Arbor.Voice.ResourceOwner.send_audio(owner, audio)

    def send_tool_result(owner, call_id, output),
      do: Arbor.Voice.ResourceOwner.send_tool_result(owner, call_id, output)

    def recv(owner, timeout), do: Arbor.Voice.ResourceOwner.recv(owner, timeout)

    def register_cleanup(owner, key, fun) do
      agent = lookup_agent!()

      mode =
        Agent.get_and_update(agent, fn state ->
          {mode, register_mode} = next_register_mode(state.register_mode)
          {mode, %{state | register_mode: register_mode, registers: state.registers + 1}}
        end)

      case mode do
        :ok ->
          case Arbor.Voice.ResourceOwner.register_cleanup(owner, key, fun) do
            :ok ->
              Agent.update(agent, fn state ->
                owner_cleanups =
                  Map.update(state.owner_cleanups, owner, %{key => fun}, &Map.put(&1, key, fun))

                %{state | owner_cleanups: owner_cleanups}
              end)

              :ok

            error ->
              error
          end

        :fail ->
          {:error, :register_failed}
      end
    end

    def adopt_provisional_cleanup(owner, key, fun) do
      agent = lookup_agent!()

      mode =
        Agent.get_and_update(agent, fn state ->
          {state.adopt_mode, %{state | adopts: state.adopts + 1}}
        end)

      case mode do
        :ok ->
          Arbor.Voice.ResourceOwner.adopt_provisional_cleanup(owner, key, fun)

        :fail ->
          {:error, :adopt_failed}

        :owner_down ->
          ref = Process.monitor(owner)
          Process.exit(owner, :kill)

          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
          after
            1_000 -> Process.demonitor(ref, [:flush])
          end

          Arbor.Voice.ResourceOwner.adopt_provisional_cleanup(owner, key, fun)
      end
    end

    def remove_cleanup(owner, key) do
      agent = lookup_agent!()

      _ =
        Agent.update(agent, fn state ->
          owner_cleanups = Map.update(state.owner_cleanups, owner, %{}, &Map.delete(&1, key))
          %{state | removes: state.removes + 1, owner_cleanups: owner_cleanups}
        end)

      Arbor.Voice.ResourceOwner.remove_cleanup(owner, key)
    end

    def activate_turn(owner, lease) do
      agent = lookup_agent!()

      mode =
        Agent.get_and_update(agent, fn state ->
          {state.activate_mode, %{state | activates: state.activates + 1}}
        end)

      case mode do
        :ok -> Arbor.Voice.ResourceOwner.activate_turn(owner, lease)
        :fail -> {:error, :turn_activation_denied}
      end
    end

    def fence_and_drain(owner, scope) do
      agent = lookup_agent!()
      _ = Agent.update(agent, fn s -> %{s | fences: s.fences + 1} end)

      with :ok <- Arbor.Voice.ResourceOwner.fence_and_drain(owner, scope),
           :ok <- drain_scope(agent, owner, scope) do
        :ok
      else
        _ -> {:error, :cleanup_pending}
      end
    end

    def close(owner) do
      agent = lookup_agent!()
      mode = Agent.get(agent, fn s -> s.close_mode end)
      _ = Agent.update(agent, fn s -> %{s | closes: s.closes + 1} end)

      case mode do
        :ok ->
          cleanup_result = drain_owner_cleanups(agent, owner)
          close_result = Arbor.Voice.ResourceOwner.close(owner)

          if cleanup_result == :ok and close_result == :ok,
            do: :ok,
            else: {:error, :cleanup_pending}

        :cleanup_pending ->
          {:error, :cleanup_pending}

        :raise ->
          raise "resource_owner close boom"

        :throw ->
          throw(:resource_owner_close_throw)

        :exit ->
          exit(:resource_owner_close_exit)
      end
    end

    defp lookup_agent! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] -> agent
        [] -> raise "TrackingResourceOwner not started"
      end
    end

    defp drain_scope(_agent, _owner, :session), do: :ok

    defp drain_scope(agent, owner, turn_id) when is_binary(turn_id) do
      cleanup_key = {:voice_turn, turn_id}

      case take_cleanup(agent, owner, cleanup_key) do
        nil ->
          :ok

        cleanup ->
          case run_cleanup(agent, cleanup) do
            :ok ->
              _ = Arbor.Voice.ResourceOwner.remove_cleanup(owner, cleanup_key)
              :ok

            {:error, _reason} ->
              put_cleanup(agent, owner, cleanup_key, cleanup)
              {:error, :cleanup_pending}
          end
      end
    end

    defp drain_scope(_agent, _owner, _scope), do: {:error, :cleanup_pending}

    defp register_initial_cleanups(owner, cleanups) do
      Enum.reduce_while(cleanups, :ok, fn {key, cleanup}, :ok ->
        case Arbor.Voice.ResourceOwner.register_cleanup(owner, key, cleanup) do
          :ok -> {:cont, :ok}
          _error -> {:halt, {:error, :cleanup_registration_failed}}
        end
      end)
    end

    defp legacy_handoff(%{kind: :external} = authority, initial_cleanups)
         when is_map(initial_cleanups) do
      route_key = :voice_realtime_route_capability
      route_cleanup = Map.fetch!(initial_cleanups, route_key)

      {
        %{authority: authority, initial_cleanup: {route_key, route_cleanup}},
        Map.delete(initial_cleanups, route_key)
      }
    end

    defp legacy_handoff(authority, initial_cleanups) do
      cleanups = if is_map(initial_cleanups), do: initial_cleanups, else: %{}
      {%{authority: authority, initial_cleanup: nil}, cleanups}
    end

    defp drain_owner_cleanups(agent, owner) do
      cleanups = Agent.get(agent, &Map.get(&1.owner_cleanups, owner, %{}))

      case run_cleanup_map(agent, cleanups) do
        :ok ->
          Agent.update(agent, fn state ->
            %{state | owner_cleanups: Map.delete(state.owner_cleanups, owner)}
          end)

          Enum.each(Map.keys(cleanups), fn key ->
            _ = Arbor.Voice.ResourceOwner.remove_cleanup(owner, key)
          end)

          :ok

        {:error, _reason} ->
          {:error, :cleanup_pending}
      end
    end

    defp run_cleanup_map(agent, cleanups) when is_map(cleanups) do
      Enum.reduce(cleanups, :ok, fn {_key, cleanup}, aggregate ->
        case {aggregate, run_cleanup(agent, cleanup)} do
          {:ok, :ok} -> :ok
          _pending -> {:error, :cleanup_pending}
        end
      end)
    end

    defp run_cleanup_map(_agent, _cleanups), do: {:error, :cleanup_pending}

    defp run_cleanup(agent, cleanup) do
      Agent.update(agent, &%{&1 | cleanup_runs: &1.cleanup_runs + 1})
      Arbor.Voice.EgressAuthority.run_cleanup(cleanup)
    end

    defp take_cleanup(agent, owner, key) do
      Agent.get_and_update(agent, fn state ->
        cleanups = Map.get(state.owner_cleanups, owner, %{})
        cleanup = Map.get(cleanups, key)
        owner_cleanups = Map.put(state.owner_cleanups, owner, Map.delete(cleanups, key))
        {cleanup, %{state | owner_cleanups: owner_cleanups}}
      end)
    end

    defp put_cleanup(agent, owner, key, cleanup) do
      Agent.update(agent, fn state ->
        owner_cleanups =
          Map.update(state.owner_cleanups, owner, %{key => cleanup}, &Map.put(&1, key, cleanup))

        %{state | owner_cleanups: owner_cleanups}
      end)
    end

    defp next_register_mode({:sequence, [mode | rest]}) when mode in [:ok, :fail],
      do: {mode, {:sequence, rest}}

    defp next_register_mode({:sequence, []}), do: {:fail, {:sequence, []}}
    defp next_register_mode(mode) when mode in [:ok, :fail], do: {mode, mode}
  end

  # ---------------------------------------------------------------------------
  # Controllable backend
  # ---------------------------------------------------------------------------

  defmodule ControllableBackend do
    @moduledoc false
    @behaviour Arbor.Voice.RealtimeBackend
    @table :arbor_voice_session_controllable_backend

    @impl true
    def egress_route, do: :none

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

  # ---------------------------------------------------------------------------
  # Controllable turn backend — queue-driven recv for message-driven Session
  # ---------------------------------------------------------------------------

  defmodule ControllableTurnBackend do
    @moduledoc false
    @behaviour Arbor.Voice.RealtimeBackend
    # Agent-owned mutable state so test-process enqueue and ResourceOwner
    # recv cannot race on a non-atomic ETS read-modify-write.
    @table :arbor_voice_session_turn_backend

    @impl true
    def egress_route, do: :none

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _tid -> :ok
      end

      :ok
    end

    def reset do
      ensure_table!()

      {:ok, agent} =
        Arbor.Voice.Test.SessionFakes.start_owned_agent(fn -> initial_state() end)

      :ets.insert(@table, {:agent, agent})
      :ok
    end

    defp initial_state do
      %{
        queue: :queue.new(),
        sent_texts: [],
        tool_results: [],
        tool_result_mode: :ok,
        send_text_mode: :ok,
        close_count: 0,
        recv_timeouts: 0,
        # Ordered backend ops for cancel-before-close proofs.
        op_log: []
      }
    end

    defp agent! do
      ensure_table!()

      case :ets.lookup(@table, :agent) do
        [{:agent, agent}] when is_pid(agent) -> agent
        _ -> raise "ControllableTurnBackend.reset/0 must be called before use"
      end
    end

    def enqueue(items) when is_list(items) do
      Agent.update(agent!(), fn state ->
        queue =
          Enum.reduce(items, state.queue, fn item, q ->
            :queue.in(item, q)
          end)

        %{state | queue: queue}
      end)
    end

    def sent_texts do
      Agent.get(agent!(), fn s -> Enum.reverse(s.sent_texts) end)
    end

    def tool_results do
      Agent.get(agent!(), fn s -> Enum.reverse(s.tool_results) end)
    end

    def op_log do
      Agent.get(agent!(), fn s -> Enum.reverse(Map.get(s, :op_log, [])) end)
    end

    def set_tool_result_mode(mode) when mode in [:ok, :error, :raise] do
      Agent.update(agent!(), fn s -> %{s | tool_result_mode: mode} end)
    end

    def set_send_text_mode(mode) when mode in [:ok, :error] do
      Agent.update(agent!(), fn s -> %{s | send_text_mode: mode} end)
    end

    def close_count, do: Agent.get(agent!(), & &1.close_count)
    def recv_timeouts, do: Agent.get(agent!(), & &1.recv_timeouts)

    @impl true
    def open(_opts) do
      _ = agent!()
      {:ok, %{id: make_ref()}}
    end

    @impl true
    def configure(session, _config), do: {:ok, session}

    @impl true
    def send_text(session, text) do
      mode =
        Agent.get_and_update(agent!(), fn s ->
          {s.send_text_mode, %{s | sent_texts: [text | s.sent_texts]}}
        end)

      case mode do
        :ok -> {:ok, session}
        :error -> {:error, :send_failed}
      end
    end

    @impl true
    def send_audio(session, _chunk), do: {:ok, session}

    @impl true
    def send_tool_result(session, call_id, output) do
      mode =
        Agent.get_and_update(agent!(), fn s ->
          op_log = [{:tool_result, call_id} | Map.get(s, :op_log, [])]

          {s.tool_result_mode,
           %{
             s
             | tool_results: [{call_id, output} | s.tool_results],
               op_log: op_log
           }}
        end)

      case mode do
        :ok -> {:ok, session}
        :error -> {:error, :tool_send_failed}
        :raise -> raise "tool result boom"
      end
    end

    @impl true
    def recv(session, timeout) do
      item =
        Agent.get_and_update(agent!(), fn s ->
          case :queue.out(s.queue) do
            {{:value, value}, rest} ->
              {{:ok, value}, %{s | queue: rest}}

            {:empty, _} ->
              {:empty, s}
          end
        end)

      case item do
        {:ok, :timeout} ->
          Agent.update(agent!(), fn s -> %{s | recv_timeouts: s.recv_timeouts + 1} end)
          {:error, :timeout}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, event} ->
          {:ok, session, event}

        :empty ->
          receive do
          after
            timeout ->
              Agent.update(agent!(), fn s -> %{s | recv_timeouts: s.recv_timeouts + 1} end)
              {:error, :timeout}
          end
      end
    end

    @impl true
    def close(_session) do
      Agent.update(agent!(), fn s ->
        op_log = [:close | Map.get(s, :op_log, [])]
        %{s | close_count: s.close_count + 1, op_log: op_log}
      end)

      :ok
    end

    @impl true
    def meta(_session) do
      %{backend: :controllable_turn, mode: :local, input_rate: nil, output_rate: nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Speakable doubles for closed start_session option validation (VP-04E2)
  # ---------------------------------------------------------------------------

  defmodule ValidSpeakableDouble do
    @moduledoc false
    def render(text, _opts), do: {:speak, text}

    def tts_guard!({tag, text})
        when tag in [:speak, :speak_truncated, :screen_only] and is_binary(text),
        do: text
  end

  defmodule IncompleteSpeakableDouble do
    @moduledoc false
    # Missing tts_guard!/1 — start_session must reject.
    def render(text, _opts), do: {:speak, text}
  end
end
