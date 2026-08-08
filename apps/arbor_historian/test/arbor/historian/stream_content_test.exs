defmodule Arbor.Historian.StreamContentTest do
  use ExUnit.Case, async: false

  alias Arbor.Historian
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4C"

  defmodule InjectBackend do
    @moduledoc false

    # Named agent so BoundedWorker child processes can resolve inject state.
    @agent_name __MODULE__.State

    def start_state!(initial) do
      case Process.whereis(@agent_name) do
        nil ->
          case Agent.start_link(fn -> initial end, name: @agent_name) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, pid}} ->
              reset_state(pid, initial)
          end

        pid when is_pid(pid) ->
          reset_state(pid, initial)
      end
    end

    # Race-safe teardown: the linked Agent may exit between whereis and stop
    # (or before release_holds) during on_exit. Tolerate only already-dead
    # :noproc / :normal races — never swallow arbitrary exits or exceptions.
    def stop_state do
      case Process.whereis(@agent_name) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          try do
            Process.unlink(pid)
            Agent.stop(pid, :normal, 5_000)
            :ok
          catch
            :exit, reason ->
              if already_dead_agent_race?(reason), do: :ok, else: exit(reason)
          end
      end
    end

    def get_state, do: Agent.get(@agent_name, & &1)

    def update_state(fun), do: Agent.update(@agent_name, fun)

    def set_waiter(pid) when is_pid(pid) do
      Agent.update(@agent_name, fn state -> Map.put(state, :waiter, pid) end)
    end

    def release_holds do
      case Process.whereis(@agent_name) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          try do
            holders =
              Agent.get(pid, fn state ->
                state.holders || []
              end)

            Enum.each(holders, fn holder ->
              if is_pid(holder) and Process.alive?(holder) do
                send(holder, :release_hold)
              end
            end)

            Agent.update(pid, fn state -> %{state | holders: []} end)
            :ok
          catch
            :exit, reason ->
              if already_dead_agent_race?(reason), do: :ok, else: exit(reason)
          end
      end
    end

    defp already_dead_agent_race?(:noproc), do: true
    defp already_dead_agent_race?(:normal), do: true
    defp already_dead_agent_race?({:noproc, _}), do: true
    defp already_dead_agent_race?({:normal, _}), do: true
    defp already_dead_agent_race?(_reason), do: false

    defp reset_state(pid, initial) do
      try do
        Agent.update(pid, fn _ -> initial end)
        :ok
      catch
        :exit, {:noproc, _} ->
          case Agent.start_link(fn -> initial end, name: @agent_name) do
            {:ok, _} -> :ok
            {:error, {:already_started, alive}} -> Agent.update(alive, fn _ -> initial end)
          end
      end
    end

    def purge_stream(stream_id, opts) do
      name = Keyword.fetch!(opts, :name)
      record_call(name, :purge, stream_id)

      case take_script(name, :purge) do
        :ok ->
          do_purge(name, stream_id)

        :indeterminate ->
          {:error, {:purge_indeterminate, stream_id}}

        :malformed ->
          {:ok, :deleted}

        :raise ->
          raise "injected purge failure"

        :exit ->
          exit(:injected_purge_exit)

        :unavailable ->
          {:error, :backend_unavailable}

        :not_supported ->
          {:error, :purge_not_supported}

        :hold ->
          hold_until_release(name, :purge, stream_id)
          {:error, {:purge_indeterminate, stream_id}}
      end
    end

    def stream_absent(stream_id, opts) do
      name = Keyword.fetch!(opts, :name)
      record_call(name, :absent, stream_id)

      case take_script(name, :absent) do
        :true ->
          {:ok, true}

        :false ->
          {:ok, false}

        :ok ->
          do_absent(name, stream_id)

        :indeterminate ->
          {:error, {:absence_indeterminate, stream_id}}

        :malformed ->
          {:ok, :deleted}

        :raise ->
          raise "injected absence failure"

        :exit ->
          exit(:injected_absence_exit)

        :unavailable ->
          {:error, :backend_unavailable}

        :not_supported ->
          {:error, :absence_not_supported}

        :hold ->
          hold_until_release(name, :absent, stream_id)
          {:error, {:absence_indeterminate, stream_id}}
      end
    end

    defp hold_until_release(name, op, stream_id) do
      holder = self()

      waiter =
        Agent.get_and_update(@agent_name, fn state ->
          holders = [holder | state.holders || []]
          {state.waiter, %{state | holders: holders}}
        end)

      if is_pid(waiter), do: send(waiter, {:stage_entered, name, op, stream_id})

      # Deterministic barrier: wait for explicit release. If BoundedWorker kills
      # this process on deadline, Persistence normalizes to indeterminate.
      receive do
        :release_hold -> :ok
      end
    end

    defp do_purge(name, stream_id) do
      Agent.update(@agent_name, fn state ->
        streams = Map.update!(state.streams, name, &MapSet.delete(&1, stream_id))
        %{state | streams: streams}
      end)

      :ok
    end

    defp do_absent(name, stream_id) do
      present? =
        Agent.get(@agent_name, fn state ->
          MapSet.member?(Map.fetch!(state.streams, name), stream_id)
        end)

      {:ok, not present?}
    end

    defp take_script(name, op) do
      Agent.get_and_update(@agent_name, fn state ->
        queue = get_in(state.scripts, [name, op]) || []

        case queue do
          [next | rest] ->
            {next, put_in(state.scripts[name][op], rest)}

          [] ->
            # Default: mutate/read the in-memory stream set.
            {:ok, state}
        end
      end)
    end

    defp record_call(name, op, stream_id) do
      Agent.update(@agent_name, fn state ->
        calls = [{name, op, stream_id} | state.calls]
        %{state | calls: calls}
      end)
    end
  end

  defmodule UnsupportedBackend do
    @moduledoc false
  end

  setup do
    durable_name = :"c4c_durable_#{System.unique_integer([:positive])}"
    hot_name = :"c4c_hot_#{System.unique_integer([:positive])}"

    :ok =
      InjectBackend.start_state!(%{
        streams: %{durable_name => MapSet.new(), hot_name => MapSet.new()},
        scripts: %{
          durable_name => %{purge: [], absent: []},
          hot_name => %{purge: [], absent: []}
        },
        calls: [],
        waiter: self(),
        holders: []
      })

    previous_durable = Application.get_env(:arbor_historian, :durable_event_log_target)
    previous_hot = Application.get_env(:arbor_historian, :hot_event_log_target)

    put_targets(durable_name, hot_name)

    on_exit(fn ->
      InjectBackend.release_holds()
      restore_env(:durable_event_log_target, previous_durable)
      restore_env(:hot_event_log_target, previous_hot)
      InjectBackend.stop_state()
    end)

    {:ok, durable_name: durable_name, hot_name: hot_name}
  end

  test "facade implements optional contract callbacks and short names" do
    assert function_exported?(Historian, :delete_stream_content, 2)
    assert function_exported?(Historian, :stream_content_absent?, 2)
    assert function_exported?(Historian, :delete_complete_history_stream_content, 2)
    assert function_exported?(Historian, :check_complete_history_stream_content_absent, 2)

    behaviours = Historian.module_info(:attributes)[:behaviour] || []
    assert Arbor.Contracts.API.Historian in List.flatten(behaviours)
  end

  test "short facade and verbose callbacks share behavior", %{
    durable_name: durable_name,
    hot_name: hot_name
  } do
    seed(durable_name, hot_name, "target")

    assert {:ok, false} = Historian.stream_content_absent?("target")
    assert {:ok, false} = Historian.check_complete_history_stream_content_absent("target", [])

    assert :ok = Historian.delete_stream_content("target")
    assert :ok = Historian.delete_complete_history_stream_content("target", [])

    assert {:ok, true} = Historian.stream_content_absent?("target")
    assert :ok = Historian.delete_stream_content("target")
  end

  test "admit failures use packet atoms" do
    assert {:error, :invalid_stream_id} = Historian.delete_stream_content("")
    assert {:error, :invalid_precondition} = Historian.delete_stream_content("s", timeout_ms: 0)
    assert {:error, :invalid_stream_id} = Historian.stream_content_absent?("")
    assert {:error, :invalid_precondition} = Historian.stream_content_absent?("s", repo: true)
  end

  test "pre-effect durable unavailable and delete not supported", %{
    durable_name: durable_name,
    hot_name: hot_name
  } do
    seed(durable_name, hot_name, "t")
    script(durable_name, :purge, [:unavailable])
    assert {:error, :durable_unavailable} = Historian.delete_stream_content("t")

    script(durable_name, :purge, [:not_supported])
    assert {:error, :delete_not_supported} = Historian.delete_stream_content("t")
  end

  test "read-only absence never purges and dual-proves", %{
    durable_name: durable_name,
    hot_name: hot_name
  } do
    seed(durable_name, hot_name, "target")

    assert {:ok, false} = Historian.stream_content_absent?("target")
    calls = InjectBackend.get_state().calls
    assert Enum.all?(calls, fn {_name, op, _} -> op == :absent end)
    assert length(calls) >= 2

    # Clear and prove true without purge.
    InjectBackend.update_state(fn state ->
      streams =
        state.streams
        |> Map.put(durable_name, MapSet.new())
        |> Map.put(hot_name, MapSet.new())

      %{state | streams: streams, calls: []}
    end)

    assert {:ok, true} = Historian.stream_content_absent?("target")
    calls = InjectBackend.get_state().calls
    refute Enum.any?(calls, fn {_n, op, _} -> op == :purge end)
  end

  test "absence uncertainty is indeterminate and preserves content", %{
    durable_name: durable_name,
    hot_name: hot_name
  } do
    seed(durable_name, hot_name, "target")
    script(durable_name, :absent, [:indeterminate])

    assert {:error, {:absence_indeterminate, "target"}} =
             Historian.stream_content_absent?("target")

    assert present?(durable_name, "target")
    assert present?(hot_name, "target")
  end

  # Complete four-stage deterministic failure matrix (Rev 2).
  for {stage, source_name, op, inject, progress} <- [
        {:durable_delete, :durable_name, :purge, :indeterminate, :none_proven_absent},
        {:durable_delete, :durable_name, :purge, :malformed, :none_proven_absent},
        {:durable_delete, :durable_name, :purge, :raise, :none_proven_absent},
        {:durable_delete, :durable_name, :purge, :exit, :none_proven_absent},
        {:durable_verify, :durable_name, :absent, :indeterminate, :none_proven_absent},
        {:durable_verify, :durable_name, :absent, :malformed, :none_proven_absent},
        {:durable_verify, :durable_name, :absent, :raise, :none_proven_absent},
        {:durable_verify, :durable_name, :absent, :exit, :none_proven_absent},
        {:durable_verify, :durable_name, :absent, :false, :none_proven_absent},
        {:hot_delete, :hot_name, :purge, :indeterminate, :durable_proven_absent},
        {:hot_delete, :hot_name, :purge, :malformed, :durable_proven_absent},
        {:hot_delete, :hot_name, :purge, :raise, :durable_proven_absent},
        {:hot_delete, :hot_name, :purge, :exit, :durable_proven_absent},
        {:hot_verify, :hot_name, :absent, :indeterminate, :durable_proven_absent},
        {:hot_verify, :hot_name, :absent, :malformed, :durable_proven_absent},
        {:hot_verify, :hot_name, :absent, :raise, :durable_proven_absent},
        {:hot_verify, :hot_name, :absent, :exit, :durable_proven_absent},
        {:hot_verify, :hot_name, :absent, :false, :durable_proven_absent}
      ] do
    test "inject #{stage}/#{inject} reports incomplete then retry converges", context do
      stage = unquote(stage)
      source_name = unquote(source_name)
      op = unquote(op)
      inject = unquote(inject)
      progress = unquote(progress)

      durable_name = context.durable_name
      hot_name = context.hot_name
      name = Map.fetch!(context, source_name)

      seed(durable_name, hot_name, "target")
      script_reach_stage(stage, durable_name, hot_name, name, op, inject)

      assert {:error, {:delete_incomplete, "target", ^stage, ^progress}} =
               Historian.delete_stream_content("target", timeout_ms: 5_000)

      # Healthy retry: empty scripts fall through to store-backed success.
      assert :ok = Historian.delete_stream_content("target", timeout_ms: 5_000)
      assert {:ok, true} = Historian.stream_content_absent?("target")
    end
  end

  for {stage, source_name, op, progress} <- [
        {:durable_delete, :durable_name, :purge, :none_proven_absent},
        {:durable_verify, :durable_name, :absent, :none_proven_absent},
        {:hot_delete, :hot_name, :purge, :durable_proven_absent},
        {:hot_verify, :hot_name, :absent, :durable_proven_absent}
      ] do
    test "timeout hold at #{stage} reports incomplete then retry converges", context do
      stage = unquote(stage)
      source_name = unquote(source_name)
      op = unquote(op)
      progress = unquote(progress)

      durable_name = context.durable_name
      hot_name = context.hot_name
      name = Map.fetch!(context, source_name)

      seed(durable_name, hot_name, "target")
      InjectBackend.set_waiter(self())
      script_reach_stage(stage, durable_name, hot_name, name, op, :hold)

      task =
        Task.async(fn ->
          Historian.delete_stream_content("target", timeout_ms: 30)
        end)

      assert_receive {:stage_entered, ^name, ^op, "target"}, 1_000

      assert {:error, {:delete_incomplete, "target", ^stage, ^progress}} =
               Task.await(task, 5_000)

      # Later stages must not run after the held stage times out.
      later_forbidden? =
        case stage do
          :durable_delete ->
            fn
              {^hot_name, _, _} -> true
              {^durable_name, :absent, _} -> true
              _ -> false
            end

          :durable_verify ->
            fn
              {^hot_name, _, _} -> true
              _ -> false
            end

          :hot_delete ->
            fn
              {^hot_name, :absent, _} -> true
              _ -> false
            end

          :hot_verify ->
            fn _ -> false end
        end

      calls = InjectBackend.get_state().calls
      refute Enum.any?(calls, later_forbidden?)

      InjectBackend.release_holds()
      # Clear remaining hold scripts so retry uses store-backed success.
      script(name, op, [])
      assert :ok = Historian.delete_stream_content("target", timeout_ms: 5_000)
      assert {:ok, true} = Historian.stream_content_absent?("target")
    end
  end

  test "exact dual ETS stores delete only the target and preserve survivors" do
    durable = :"c4c_real_durable_#{System.unique_integer([:positive])}"
    hot = :"c4c_real_hot_#{System.unique_integer([:positive])}"

    start_supervised!({ETS, name: durable, max_age_ms: :infinity, trim_interval_ms: :disabled})
    start_supervised!({ETS, name: hot, max_age_ms: :infinity, trim_interval_ms: :disabled})

    previous_durable = Application.get_env(:arbor_historian, :durable_event_log_target)
    previous_hot = Application.get_env(:arbor_historian, :hot_event_log_target)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: durable,
      backend: ETS,
      opts: []
    })

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: hot,
      backend: ETS,
      opts: []
    })

    on_exit(fn ->
      restore_env(:durable_event_log_target, previous_durable)
      restore_env(:hot_event_log_target, previous_hot)
    end)

    target = "agent:alice"
    prefix_related = "agent:alice2"
    unrelated = "session:other"

    for store <- [durable, hot], stream <- [target, prefix_related, unrelated] do
      event = Event.new(stream, "test.created", %{"stream" => stream})
      assert {:ok, [_]} = Persistence.append(store, ETS, stream, event)
    end

    assert {:ok, [prefix_d]} = Persistence.read_stream(durable, ETS, prefix_related)
    assert {:ok, [unrelated_d]} = Persistence.read_stream(durable, ETS, unrelated)
    assert {:ok, [prefix_h]} = Persistence.read_stream(hot, ETS, prefix_related)
    assert {:ok, [unrelated_h]} = Persistence.read_stream(hot, ETS, unrelated)

    assert {:ok, false} = Historian.stream_content_absent?(target)
    assert :ok = Historian.delete_stream_content(target, timeout_ms: 5_000)
    assert {:ok, true} = Historian.stream_content_absent?(target)
    assert :ok = Historian.delete_stream_content(target, timeout_ms: 5_000)

    assert {:ok, []} = Persistence.read_stream(durable, ETS, target)
    assert {:ok, []} = Persistence.read_stream(hot, ETS, target)

    assert {:ok, [prefix_d_after]} = Persistence.read_stream(durable, ETS, prefix_related)
    assert {:ok, [unrelated_d_after]} = Persistence.read_stream(durable, ETS, unrelated)
    assert {:ok, [prefix_h_after]} = Persistence.read_stream(hot, ETS, prefix_related)
    assert {:ok, [unrelated_h_after]} = Persistence.read_stream(hot, ETS, unrelated)

    assert prefix_d_after.id == prefix_d.id
    assert prefix_d_after.global_position == prefix_d.global_position
    assert unrelated_d_after.id == unrelated_d.id
    assert unrelated_d_after.global_position == unrelated_d.global_position
    assert prefix_h_after.id == prefix_h.id
    assert prefix_h_after.global_position == prefix_h.global_position
    assert unrelated_h_after.id == unrelated_h.id
    assert unrelated_h_after.global_position == unrelated_h.global_position

    next = Event.new(prefix_related, "test.updated", %{"n" => 2})

    assert {:ok, [persisted]} =
             Persistence.append(durable, ETS, prefix_related, next, expected_version: 1)

    assert persisted.event_number == 2
    assert persisted.global_position > prefix_d.global_position
  end

  test "hot unavailable after durable proof reports incomplete with progress", %{
    durable_name: durable_name,
    hot_name: hot_name
  } do
    seed(durable_name, hot_name, "target")
    script(durable_name, :purge, [:ok])
    script(durable_name, :absent, [:true])
    script(hot_name, :purge, [:unavailable])

    assert {:error, {:delete_incomplete, "target", :hot_delete, :durable_proven_absent}} =
             Historian.delete_stream_content("target")

    assert :ok = Historian.delete_stream_content("target")
    assert {:ok, true} = Historian.stream_content_absent?("target")
  end

  test "hot not_supported after durable proof reports incomplete with progress", %{
    durable_name: durable_name,
    hot_name: hot_name
  } do
    seed(durable_name, hot_name, "target")
    script(durable_name, :purge, [:ok])
    script(durable_name, :absent, [:true])
    script(hot_name, :purge, [:not_supported])

    assert {:error, {:delete_incomplete, "target", :hot_delete, :durable_proven_absent}} =
             Historian.delete_stream_content("target")

    assert :ok = Historian.delete_stream_content("target")
  end

  test "config rejects timeout keys in static target opts" do
    previous = Application.get_env(:arbor_historian, :durable_event_log_target)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: :x,
      backend: ETS,
      opts: [purge_timeout_ms: 5_000]
    })

    assert {:error, :durable_unavailable} = Historian.delete_stream_content("s")
    restore_env(:durable_event_log_target, previous)
  end

  test "unsupported backend maps to delete_not_supported / absence_not_supported" do
    previous_durable = Application.get_env(:arbor_historian, :durable_event_log_target)
    previous_hot = Application.get_env(:arbor_historian, :hot_event_log_target)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: :unsupported,
      backend: UnsupportedBackend,
      opts: []
    })

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: :unsupported_hot,
      backend: UnsupportedBackend,
      opts: []
    })

    assert {:error, :delete_not_supported} = Historian.delete_stream_content("s")
    assert {:error, :absence_not_supported} = Historian.stream_content_absent?("s")

    restore_env(:durable_event_log_target, previous_durable)
    restore_env(:hot_event_log_target, previous_hot)
  end

  defp put_targets(durable_name, hot_name) do
    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: durable_name,
      backend: InjectBackend,
      opts: []
    })

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: hot_name,
      backend: InjectBackend,
      opts: []
    })
  end

  defp seed(durable_name, hot_name, stream_id) do
    InjectBackend.update_state(fn state ->
      streams =
        state.streams
        |> Map.update!(durable_name, &MapSet.put(&1, stream_id))
        |> Map.update!(hot_name, &MapSet.put(&1, stream_id))

      scripts = %{
        durable_name => %{purge: [], absent: []},
        hot_name => %{purge: [], absent: []}
      }

      %{state | streams: streams, scripts: scripts, calls: [], holders: []}
    end)
  end

  defp script(name, op, queue) do
    InjectBackend.update_state(fn state ->
      put_in(state.scripts[name][op], queue)
    end)
  end

  defp script_reach_stage(stage, durable_name, hot_name, name, op, inject) do
    case stage do
      :durable_delete ->
        script(name, op, [inject])

      :durable_verify ->
        script(durable_name, :purge, [:ok])
        script(name, op, [inject])

      :hot_delete ->
        script(durable_name, :purge, [:ok])
        script(durable_name, :absent, [:true])
        script(name, op, [inject])

      :hot_verify ->
        script(durable_name, :purge, [:ok])
        script(durable_name, :absent, [:true])
        script(hot_name, :purge, [:ok])
        script(name, op, [inject])
    end
  end

  defp present?(name, stream_id) do
    state = InjectBackend.get_state()
    MapSet.member?(Map.fetch!(state.streams, name), stream_id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_historian, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_historian, key, value)
end
