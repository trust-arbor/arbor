defmodule Arbor.Agent.Orchestration.TaskControlLeaseTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskStore}
  alias __MODULE__.{CountingSecurity, HangRunner, MismatchStore}

  defmodule FlakySecurity do
    @moduledoc false
    @table :task_control_lease_flaky_security

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def configure(opts) do
      ensure!()
      :ets.insert(@table, {:config, opts})
      :ets.insert(@table, {:grant_attempts, []})
      :ets.insert(@table, {:successful_grants, []})
      :ets.insert(@table, {:revokes, []})
      :ok
    end

    def grant_attempts do
      ensure!()

      case :ets.lookup(@table, :grant_attempts) do
        [{:grant_attempts, list}] -> list
        _ -> []
      end
    end

    def successful_grants do
      ensure!()

      case :ets.lookup(@table, :successful_grants) do
        [{:successful_grants, list}] -> list
        _ -> []
      end
    end

    # Back-compat alias used by older assertions.
    def grants, do: successful_grants()

    def revokes do
      ensure!()

      case :ets.lookup(@table, :revokes) do
        [{:revokes, list}] -> list
        _ -> []
      end
    end

    def grant(opts) do
      ensure!()
      kind = get_in(opts, [:metadata, :kind]) || get_in(opts, [:metadata, "kind"])
      attempt = %{kind: kind, resource: opts[:resource], opts: opts}

      case :ets.lookup(@table, :grant_attempts) do
        [{:grant_attempts, list}] -> :ets.insert(@table, {:grant_attempts, list ++ [attempt]})
        _ -> :ets.insert(@table, {:grant_attempts, [attempt]})
      end

      config =
        case :ets.lookup(@table, :config) do
          [{:config, c}] -> c
          _ -> %{}
        end

      fail_kind = Map.get(config, :fail_at_kind)
      uncertain_revoke_kinds = Map.get(config, :uncertain_revoke_kinds, [])

      cond do
        fail_kind && to_string(fail_kind) == to_string(kind) ->
          {:error, :injected_grant_failure}

        true ->
          id = "cap_#{kind}_#{System.unique_integer([:positive])}"
          success = %{kind: kind, id: id, resource: opts[:resource]}

          case :ets.lookup(@table, :successful_grants) do
            [{:successful_grants, list}] ->
              :ets.insert(@table, {:successful_grants, list ++ [success]})

            _ ->
              :ets.insert(@table, {:successful_grants, [success]})
          end

          if to_string(kind) in Enum.map(uncertain_revoke_kinds, &to_string/1) do
            :ets.insert(@table, {{:uncertain, id}, true})
          end

          {:ok, %{id: id, resource_uri: opts[:resource], task_id: opts[:task_id]}}
      end
    end

    def revoke(id) do
      ensure!()

      case :ets.lookup(@table, :revokes) do
        [{:revokes, list}] -> :ets.insert(@table, {:revokes, list ++ [id]})
        _ -> :ets.insert(@table, {:revokes, [id]})
      end

      case :ets.lookup(@table, {:uncertain, id}) do
        [{{:uncertain, ^id}, true}] ->
          :module_unavailable

        _ ->
          :ok
      end
    end
  end

  defmodule DupIdSecurity do
    @moduledoc false
    def grant(opts) do
      send(self(), {:dup_grant, opts[:metadata][:kind]})
      {:ok, %{id: "cap_shared_all"}}
    end

    def revoke(id) do
      send(self(), {:dup_revoke, id})
      :ok
    end
  end

  defmodule CaptureStore do
    @moduledoc false
    @table :task_control_lease_capture_store

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:dispatches, []})
      :ets.insert(@table, {:force, nil})
      :ets.insert(@table, {:next_task_id, nil})
      :ets.insert(@table, {:marker_fail, false})
      :ets.insert(@table, {:reservations, %{}})
      :ets.insert(@table, {:grants_gate, nil})
      :ok
    end

    def dispatches do
      ensure!()

      case :ets.lookup(@table, :dispatches) do
        [{:dispatches, list}] -> list
        _ -> []
      end
    end

    def configure(force) do
      ensure!()
      :ets.insert(@table, {:force, force})
      :ok
    end

    def set_next_task_id(task_id) when is_binary(task_id) do
      ensure!()
      :ets.insert(@table, {:next_task_id, task_id})
      :ok
    end

    def set_marker_fail(flag) when is_boolean(flag) do
      ensure!()
      :ets.insert(@table, {:marker_fail, flag})
      :ok
    end

    def reserve(_target_agent_id, _opts \\ []) do
      ensure!()

      task_id =
        case :ets.lookup(@table, :next_task_id) do
          [{:next_task_id, id}] when is_binary(id) ->
            :ets.insert(@table, {:next_task_id, nil})
            id

          _ ->
            "task_cap_#{System.unique_integer([:positive])}"
        end

      token = TaskControlLease.generate_reservation_token()

      reservations =
        case :ets.lookup(@table, :reservations) do
          [{:reservations, map}] -> map
          _ -> %{}
        end

      :ets.insert(
        @table,
        {:reservations, Map.put(reservations, task_id, %{token: token, marker?: false})}
      )

      {:ok, %{task_id: task_id, reservation_token: token}}
    end

    def commit_recovery_marker(task_id, token, _opts \\ []) do
      ensure!()

      case :ets.lookup(@table, :marker_fail) do
        [{:marker_fail, true}] ->
          {:error, :injected_marker_failure}

        _ ->
          case fetch_reservation(task_id, token) do
            {:ok, res} ->
              reservations =
                case :ets.lookup(@table, :reservations) do
                  [{:reservations, map}] -> map
                  _ -> %{}
                end

              :ets.insert(
                @table,
                {:reservations, Map.put(reservations, task_id, %{res | marker?: true})}
              )

              :ok

            {:error, _} = error ->
              error
          end
      end
    end

    def activate(agent_id, task, task_id, token, opts) do
      case fetch_reservation(task_id, token) do
        {:ok, _} ->
          drop_reservation(task_id)
          dispatch(agent_id, task, Keyword.put(opts, :task_id, task_id))

        {:error, _} = error ->
          error
      end
    end

    def release(task_id, token, _opts \\ []) do
      case fetch_reservation(task_id, token) do
        {:ok, _} ->
          drop_reservation(task_id)
          :ok

        {:error, _} = error ->
          error
      end
    end

    def request_reconcile(_task_id, _opts \\ []), do: :ok

    def dispatch(agent_id, task, opts) do
      ensure!()
      entry = %{agent_id: agent_id, task: task, opts: opts}

      case :ets.lookup(@table, :dispatches) do
        [{:dispatches, list}] -> :ets.insert(@table, {:dispatches, list ++ [entry]})
        _ -> :ets.insert(@table, {:dispatches, [entry]})
      end

      force =
        case :ets.lookup(@table, :force) do
          [{:force, f}] -> f
          _ -> nil
        end

      case force do
        nil ->
          task_id =
            Keyword.get(opts, :task_id) || "task_cap_#{System.unique_integer([:positive])}"

          case Keyword.get(opts, :task_control_lease) do
            %{"task_id" => lease_task_id} = lease when is_binary(lease_task_id) ->
              case TaskControlLease.normalize_for_task(lease, task_id) do
                {:ok, _} -> {:ok, task_id}
                {:error, reason} -> {:error, reason}
              end

            nil ->
              {:ok, task_id}

            _ ->
              {:error, :invalid_task_control_lease}
          end

        :mismatch ->
          {:ok, "task_other_id"}

        :lease_task_mismatch ->
          {:error, :task_control_lease_task_id_mismatch}

        reason ->
          {:error, reason}
      end
    end

    defp fetch_reservation(task_id, token) do
      ensure!()

      case :ets.lookup(@table, :reservations) do
        [{:reservations, map}] ->
          case Map.get(map, task_id) do
            %{token: ^token} = res -> {:ok, res}
            _ -> {:error, :invalid_reservation_token}
          end

        _ ->
          {:error, :invalid_reservation_token}
      end
    end

    defp drop_reservation(task_id) do
      case :ets.lookup(@table, :reservations) do
        [{:reservations, map}] ->
          :ets.insert(@table, {:reservations, Map.delete(map, task_id)})

        _ ->
          :ok
      end
    end
  end

  setup do
    FlakySecurity.ensure!()
    FlakySecurity.configure(%{})
    CaptureStore.ensure!()
    CaptureStore.reset()
    CaptureStore.configure(nil)
    :ok
  end

  test "pure module rejects hostile task ids before URI construction" do
    for bad <- ["**", "a/b", "../x", "a*b", "a b", "a\nb", <<0xFF, 0xFE>>, ""] do
      assert {:error, :invalid_task_id} = TaskControlLease.uri(:task_read, bad)

      assert {:error, :invalid_task_id} =
               TaskControlLease.grant_spec(:task_read, "p", bad, DateTime.utc_now())
    end
  end

  test "new/2 requires exactly six kinds and closed scalar shape" do
    task_id = "task_closed_1"

    ids =
      Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}"} end)

    assert {:ok, lease} = TaskControlLease.new(task_id, ids)
    assert lease["schema_version"] == 1
    assert lease["task_id"] == task_id
    assert map_size(lease["capabilities"]) == 6

    incomplete = Map.delete(ids, :task_cancel)
    assert {:error, _} = TaskControlLease.new(task_id, incomplete)
  end

  test "new/normalize reject duplicate atom+string kind aliases" do
    task_id = "task_alias_1"

    mixed = %{
      "task_read" => "cap_task_read_dup",
      task_read: "cap_task_read",
      approval_read: "cap_approval_read",
      task_steer: "cap_task_steer",
      task_cancel: "cap_task_cancel",
      task_adopt: "cap_task_adopt",
      approval_answer: "cap_approval_answer"
    }

    assert {:error, :duplicate_kind_key_alias} = TaskControlLease.new(task_id, mixed)

    # Same value under both aliases is still rejected.
    same = put_in(mixed["task_read"], "cap_task_read")
    assert {:error, :duplicate_kind_key_alias} = TaskControlLease.new(task_id, same)
  end

  test "new/normalize require six distinct bounded valid capability ids" do
    task_id = "task_ids_1"
    shared = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_shared"} end)
    assert {:error, :duplicate_capability_ids} = TaskControlLease.new(task_id, shared)

    empty = Map.new(TaskControlLease.kinds(), fn k -> {k, ""} end)
    assert {:error, {:invalid_capability_id, _}} = TaskControlLease.new(task_id, empty)

    control = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}\n"} end)
    assert {:error, {:invalid_capability_id, _}} = TaskControlLease.new(task_id, control)

    huge = Map.new(TaskControlLease.kinds(), fn k -> {k, String.duplicate("x", 300)} end)
    assert {:error, {:invalid_capability_id, _}} = TaskControlLease.new(task_id, huge)
  end

  test "grant order is least-risk-first with approval_answer last" do
    assert TaskControlLease.grant_order() == [
             :task_read,
             :approval_read,
             :task_steer,
             :task_cancel,
             :task_adopt,
             :approval_answer
           ]

    now = ~U[2026-08-08 12:00:00Z]

    for kind <- TaskControlLease.grant_order() do
      assert {:ok, spec} = TaskControlLease.grant_spec(kind, "principal", "task_spec_1", now)
      assert spec[:task_id] == "task_spec_1"
      assert spec[:delegation_depth] == 0
      assert spec[:constraints] == %{}
      assert {:ok, spec[:resource]} == TaskControlLease.uri(kind, "task_spec_1")
    end
  end

  test "lifecycle kind sets match phase policy" do
    assert :task_read not in TaskControlLease.lifecycle_kinds(:terminal_revoke_set_keep_adopt)
    assert :task_adopt not in TaskControlLease.lifecycle_kinds(:terminal_revoke_set_keep_adopt)
    assert :task_adopt in TaskControlLease.lifecycle_kinds(:terminal_revoke_set)
    assert TaskControlLease.lifecycle_kinds(:after_adoption) == [:task_adopt]
    assert length(TaskControlLease.lifecycle_kinds(:all)) == 6
  end

  test "public dispatch always rejects caller-selected task_id" do
    assert {:error, :caller_selected_task_id_rejected} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               task_id: "task_rejected_1",
               authorize?: false,
               task_store: CaptureStore
             )
  end

  test "grant failure at every position reverse-revokes all prior in reverse order" do
    for fail_kind <- TaskControlLease.grant_order() do
      FlakySecurity.configure(%{fail_at_kind: fail_kind})
      CaptureStore.reset()
      CaptureStore.set_next_task_id("task_fail_#{fail_kind}")

      assert {:error, {:task_control_lease_grant_failed, ^fail_kind, :injected_grant_failure}} =
               Orchestration.dispatch("agent_1", "work",
                 caller_id: "caller_1",
                 authorize?: false,
                 security_module: FlakySecurity,
                 task_store: CaptureStore
               )

      fail_index = Enum.find_index(TaskControlLease.grant_order(), &(&1 == fail_kind))
      attempts = FlakySecurity.grant_attempts()
      successes = FlakySecurity.successful_grants()
      revokes = FlakySecurity.revokes()

      # Attempts include the failed position; successes are only prior mints.
      assert length(attempts) == fail_index + 1
      assert length(successes) == fail_index

      assert Enum.map(successes, & &1.kind) ==
               TaskControlLease.grant_order() |> Enum.take(fail_index) |> Enum.map(&to_string/1)

      # Exact reverse revoke order by opaque id.
      success_ids = Enum.map(successes, & &1.id)
      assert revokes == Enum.reverse(success_ids)
      assert CaptureStore.dispatches() == []
    end
  end

  test "uncertain compensation returns outcome_unknown without capability ids and still revokes all" do
    # Fail at third kind; mark first two revokes uncertain after mint.
    fail_kind = :task_steer

    FlakySecurity.configure(%{
      fail_at_kind: fail_kind,
      uncertain_revoke_kinds: [:task_read, :approval_read]
    })

    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_uncertain_1")

    assert {:error, {:task_control_lease_grant_outcome_unknown, details}} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: FlakySecurity,
               task_store: CaptureStore
             )

    assert details.uncertainty == true
    assert details.failed_kind == fail_kind
    assert details.revoke_failure_count == 2
    assert details.revoke_uncertain_count == 2
    assert :task_read in details.revoke_failure_kinds
    assert :approval_read in details.revoke_failure_kinds

    # No opaque capability ids in public details.
    refute inspect(details) =~ "cap_"

    successes = FlakySecurity.successful_grants()
    assert length(successes) == 2
    assert FlakySecurity.revokes() == Enum.reverse(Enum.map(successes, & &1.id))
    assert CaptureStore.dispatches() == []
  end

  test "lease shape failure after six grants compensates all six" do
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_shape_fail_1")

    assert {:error, {:task_control_lease_grant_failed, :lease_shape, :duplicate_capability_ids}} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: DupIdSecurity,
               task_store: CaptureStore
             )

    for _ <- 1..6, do: assert_received({:dup_grant, _})
    for _ <- 1..6, do: assert_received({:dup_revoke, "cap_shared_all"})
    assert CaptureStore.dispatches() == []
  end

  test "successful grant passes scalar lease only and never leaks cap ids in store opts" do
    FlakySecurity.configure(%{})
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_ok_lease_1")

    assert {:ok, task_id} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: FlakySecurity,
               task_store: CaptureStore,
               audit_module: __MODULE__.NoopAudit
             )

    assert task_id == "task_ok_lease_1"
    assert length(FlakySecurity.successful_grants()) == 6
    assert length(FlakySecurity.grant_attempts()) == 6

    [dispatch] = CaptureStore.dispatches()
    opts = dispatch.opts
    assert is_map(Keyword.get(opts, :task_control_lease))
    refute Keyword.has_key?(opts, :approval_answer_cap_id)
    refute Keyword.has_key?(opts, :steer_cap_id)
    refute Keyword.has_key?(opts, :adoption_cap_id)
    refute Keyword.has_key?(opts, :task_control_security_module)
    refute Keyword.has_key?(opts, :task_control_revoke)
  end

  test "TaskStore error after grant reverse-revokes complete lease" do
    FlakySecurity.configure(%{})
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_store_err_1")
    CaptureStore.configure(:injected_store_error)

    assert {:error, :injected_store_error} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: FlakySecurity,
               task_store: CaptureStore,
               audit_module: __MODULE__.NoopAudit
             )

    successes = FlakySecurity.successful_grants()
    assert length(successes) == 6
    assert FlakySecurity.revokes() == Enum.reverse(Enum.map(successes, & &1.id))
  end

  test "task-id mismatch reverse-revokes complete lease" do
    FlakySecurity.configure(%{})
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_mismatch_1")
    CaptureStore.configure(:mismatch)

    assert {:error, {:task_id_mismatch, "task_other_id"}} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: FlakySecurity,
               task_store: CaptureStore,
               audit_module: __MODULE__.NoopAudit
             )

    successes = FlakySecurity.successful_grants()
    assert length(successes) == 6
    assert FlakySecurity.revokes() == Enum.reverse(Enum.map(successes, & &1.id))
  end

  test "TaskStore rejects a lease whose embedded task_id does not match dispatch" do
    FlakySecurity.configure(%{})
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_admit_a")
    CaptureStore.configure(:lease_task_mismatch)

    assert {:error, :task_control_lease_task_id_mismatch} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: FlakySecurity,
               task_store: CaptureStore,
               audit_module: __MODULE__.NoopAudit
             )

    # Facade compensates all six minted members when TaskStore rejects admission.
    successes = FlakySecurity.successful_grants()
    assert length(successes) == 6
    assert FlakySecurity.revokes() == Enum.reverse(Enum.map(successes, & &1.id))
  end

  test "real TaskStore admits only exact-task leases and rejects mismatches" do
    supervisor_name = unique_atom(:lease_sup)
    store_name = unique_atom(:lease_store)
    supervisor = start_supervised!({Task.Supervisor, name: supervisor_name}, id: supervisor_name)

    store =
      start_supervised!(
        {TaskStore, name: store_name, task_supervisor: supervisor, runner: HangRunner},
        id: store_name
      )

    good_id = "task_admit_good_1"
    bad_id = "task_admit_bad_1"

    good_lease =
      Enum.reduce(TaskControlLease.kinds(), %{}, fn kind, acc ->
        Map.put(acc, kind, "cap_#{kind}_good")
      end)
      |> then(fn ids ->
        {:ok, lease} = TaskControlLease.new(good_id, ids)
        lease
      end)

    assert {:ok, ^good_id} =
             TaskStore.dispatch("agent_1", "work",
               name: store,
               task_id: good_id,
               task_control_lease: good_lease
             )

    mismatched = put_in(good_lease["task_id"], bad_id)

    assert {:error, :task_control_lease_task_id_mismatch} =
             TaskStore.dispatch("agent_1", "work",
               name: store,
               task_id: good_id <> "x",
               task_control_lease: mismatched
             )

    assert {:error, :invalid_task_control_lease} =
             TaskStore.dispatch("agent_1", "work",
               name: store,
               task_id: "task_invalid_lease_1",
               task_control_lease: %{"schema_version" => 1}
             )
  end

  defmodule HangRunner do
    @moduledoc false
    def run(_a, _t, _o) do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  test "lease construction rejects duplicate capability ids" do
    task_id = "task_dup_ids_1"
    ids = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_shared"} end)
    assert {:error, :duplicate_capability_ids} = TaskControlLease.new(task_id, ids)
  end

  test "closed map rejects unknown keys including non-atom/non-binary keys" do
    task_id = "task_unknown_keys_1"
    base = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}_uk"} end)

    assert {:error, :invalid_lease_kinds} =
             TaskControlLease.new(task_id, Map.put(base, :extra_kind, "cap_extra"))

    assert {:error, :invalid_lease_kinds} =
             TaskControlLease.new(task_id, Map.put(base, "not_a_kind", "cap_extra"))

    # Non-atom/non-binary keys must not be silently ignored.
    assert {:error, :invalid_lease_kinds} =
             TaskControlLease.new(task_id, Map.put(base, 42, "cap_int_key"))

    assert {:error, :invalid_lease_kinds} =
             TaskControlLease.new(task_id, Map.put(base, self(), "cap_pid_key"))
  end

  defmodule MissingIdSecurity do
    @moduledoc false
    def grant(_opts), do: {:ok, %{resource_uri: "x"}}
    def revoke(_id), do: :ok
  end

  test "successful grant without capability id is mint-outcome uncertainty" do
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_missing_id_1")

    assert {:error, {:task_control_lease_grant_outcome_unknown, details}} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: MissingIdSecurity,
               task_store: CaptureStore
             )

    assert details.uncertainty == true
    assert details.failed_kind == :task_read
    assert details.grant_reason == :missing_capability_id
    refute inspect(details) =~ "cap_"
    assert CaptureStore.dispatches() == []
  end

  defmodule RaisingSecurity do
    @moduledoc false
    def grant(_opts) do
      send(self(), :raising_grant_minted)
      raise "injected grant exception after mint"
    end

    def revoke(_id), do: :ok
  end

  test "grant exception after mint is outcome unknown never ordinary grant_failed" do
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_raise_1")

    assert {:error, {:task_control_lease_grant_outcome_unknown, details}} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: RaisingSecurity,
               task_store: CaptureStore
             )

    assert details.uncertainty == true
    assert details.grant_reason == :exception
    refute inspect(details) =~ "cap_"
    assert CaptureStore.dispatches() == []
  end

  test "durable marker write failure prevents grants" do
    FlakySecurity.configure(%{})
    CaptureStore.reset()
    CaptureStore.set_next_task_id("task_marker_fail_1")
    CaptureStore.set_marker_fail(true)

    assert {:error, :injected_marker_failure} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: FlakySecurity,
               task_store: CaptureStore
             )

    assert FlakySecurity.successful_grants() == []
    assert CaptureStore.dispatches() == []
  end

  test "no-lease terminal preserves TaskStore state" do
    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:nolease_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:nolease_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: Arbor.Agent.Orchestration.TaskControlRecoveryMemory,
         runner: __MODULE__.QuickRunner}
      )

    task_id = "task_nolease_term_1"

    assert {:ok, ^task_id} =
             TaskStore.dispatch("agent_1", "work", name: store, task_id: task_id)

    assert wait_until(fn ->
             match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store))
           end)

    assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)
    assert Process.alive?(store)

    assert {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
    assert snap.pending_tasks == 0
  end

  test "retirement partial revoke retains only failed ids" do
    fail_id = "cap_fail_1"

    revoke_fun = fn id ->
      if id == fail_id, do: {:error, :injected_fail}, else: :ok
    end

    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:partial_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:partial_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: HangRunner,
         task_control_revoke: revoke_fun,
         lease_retire_max_attempts: 1}
      )

    task_id = "task_partial_1"
    ok_id = "cap_ok_1"
    attempt_ref = make_ref()

    :sys.replace_state(store, fn state ->
      bucket = %{
        task_id: task_id,
        members: %{
          ok_id => %{kind: :task_steer, id: ok_id},
          fail_id => %{kind: :task_cancel, id: fail_id}
        },
        exhausted: false,
        generation: 0,
        attempt_index: 0,
        retrigger_count: 0
      }

      attempt = running_attempt(attempt_ref, task_id, [ok_id, fail_id])

      state
      |> Map.put(:lease_pending_retirement, %{task_id => bucket})
      |> Map.put(:lease_retire_attempts, %{attempt_ref => attempt})
      |> Map.put(:task_control_revoke, revoke_fun)
      |> Map.put(:lease_retire_max_attempts, 1)
    end)

    send(
      store,
      {:lease_retire_complete, attempt_ref, [{ok_id, :ok}, {fail_id, {:error, :injected_fail}}]}
    )

    assert wait_until(fn ->
             {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
             pending = Map.get(snap.pending, task_id)
             is_map(pending) and pending.remaining_count == 1 and pending.exhausted == true
           end)

    {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
    pending = Map.fetch!(snap.pending, task_id)
    assert pending.remaining_count == 1
    assert pending.exhausted == true
    refute inspect(snap) =~ "cap_"
  end

  test "retirement exhaustion plus ID-free retrigger is deterministic" do
    table = :"lease_retire_always_fail_#{System.unique_integer([:positive])}"
    _ = :ets.new(table, [:named_table, :public, :set])
    :ets.insert(table, {:mode, :fail})

    revoke_fun = fn _id ->
      case :ets.lookup(table, :mode) do
        [{:mode, :fail}] -> {:error, :injected_always_fail}
        _ -> :ok
      end
    end

    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:exhaust_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:exhaust_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: __MODULE__.QuickRunner,
         task_control_revoke: revoke_fun,
         lease_retire_base_delay_ms: 5,
         lease_retire_max_delay_ms: 10,
         lease_retire_max_attempts: 1,
         lease_retire_admit_timeout_ms: 500,
         lease_retire_worker_timeout_ms: 500}
      )

    task_id = "task_exhaust_1"
    # Single-kind terminal retire via full lease terminal non-adoptable (5 members).
    # Force exhaustion by always failing revoke with max_attempts: 1.
    ids = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}_#{task_id}"} end)
    {:ok, lease} = TaskControlLease.new(task_id, ids)

    assert {:ok, ^task_id} =
             TaskStore.dispatch("agent_1", "work",
               name: store,
               task_id: task_id,
               task_control_lease: lease
             )

    assert wait_until(fn ->
             match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store))
           end)

    assert wait_until(fn ->
             {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
             pending = Map.get(snap.pending, task_id)
             is_map(pending) and pending.exhausted == true and pending.remaining_count > 0
           end)

    {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
    pending = Map.fetch!(snap.pending, task_id)
    assert pending.exhausted == true
    assert pending.remaining_count > 0
    refute inspect(snap) =~ "cap_"

    :ets.insert(table, {:mode, :ok})

    assert {:ok, %{retried_tasks: 1, remaining_exhausted: 0}} =
             TaskStore.retrigger_exhausted_lease_retirements(name: store)

    assert wait_until(fn ->
             {:ok, s} = TaskStore.lease_retirement_snapshot(name: store)
             is_nil(Map.get(s.pending, task_id))
           end)
  end

  test "retirement hard worker timeout retains members and ignores late complete" do
    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:wtimeout_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:wtimeout_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: HangRunner,
         lease_retire_max_attempts: 1}
      )

    task_id = "task_wtimeout_1"
    cap_id = "cap_wtimeout_1"
    attempt_ref = make_ref()
    {worker_pid, worker_mon} = spawn_monitor(fn -> Process.sleep(60_000) end)

    :sys.replace_state(store, fn state ->
      bucket = %{
        task_id: task_id,
        members: %{cap_id => %{kind: :task_steer, id: cap_id}},
        exhausted: false,
        generation: 0,
        attempt_index: 0,
        retrigger_count: 0
      }

      attempt =
        running_attempt(attempt_ref, task_id, [cap_id])
        |> Map.put(:worker_pid, worker_pid)
        |> Map.put(:worker_mon, worker_mon)

      state
      |> Map.put(:lease_pending_retirement, %{task_id => bucket})
      |> Map.put(:lease_retire_attempts, %{attempt_ref => attempt})
      |> Map.put(:lease_retire_max_attempts, 1)
    end)

    send(store, {:lease_retire_worker_timeout, attempt_ref})
    assert_receive {:DOWN, ^worker_mon, :process, ^worker_pid, _}, 500

    # Late complete for superseded ref must not delete authority.
    send(store, {:lease_retire_complete, attempt_ref, [{cap_id, :ok}]})
    Process.sleep(30)

    {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
    pending = Map.fetch!(snap.pending, task_id)
    assert pending.remaining_count == 1
    assert pending.exhausted == true
  end

  test "retirement completion CAS: malformed, conflict, omit, idempotent, stale, completion-then-DOWN" do
    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:cas_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:cas_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: HangRunner,
         lease_retire_max_attempts: 8}
      )

    task_id = "task_cas_1"
    a = "cap_a"
    b = "cap_b"
    c = "cap_c"

    # Malformed batch retains all.
    ref1 = make_ref()

    :sys.replace_state(store, fn state ->
      put_retirement_running(state, task_id, ref1, [a, b], generation: 0)
    end)

    send(store, {:lease_retire_complete, ref1, :not_a_list})
    Process.sleep(20)
    assert Map.fetch!(snapshot_pending(store, task_id), :remaining_count) == 2

    # Conflicting duplicates retain that id; pure success deletes; omit retains.
    ref2 = make_ref()

    :sys.replace_state(store, fn state ->
      put_retirement_running(state, task_id, ref2, [a, b, c], generation: 0, attempt_index: 1)
    end)

    send(
      store,
      {:lease_retire_complete, ref2,
       [
         {a, :ok},
         {a, {:error, :nope}},
         {b, :ok},
         {b, :ok}
         # c omitted
       ]}
    )

    assert wait_until(fn ->
             snap = snapshot_pending(store, task_id)
             # a conflict retained, b deleted, c omitted retained => 2
             is_map(snap) and snap.remaining_count == 2
           end)

    # Idempotent success classes clear via worker path normalization is unit-tested
    # here through completion rows already normalized to :ok for not_found/already_revoked
    # by simulating worker-normalized outcomes.
    ref3 = make_ref()

    :sys.replace_state(store, fn state ->
      put_retirement_running(state, task_id, ref3, [a, c], generation: 0, attempt_index: 2)
    end)

    send(store, {:lease_retire_complete, ref3, [{a, :ok}, {c, :ok}]})

    assert wait_until(fn ->
             is_nil(snapshot_pending(store, task_id))
           end)

    # Stale/forged complete ignored.
    send(store, {:lease_retire_complete, make_ref(), [{a, :ok}]})
    Process.sleep(20)
    assert Process.alive?(store)

    # Completion-then-DOWN: apply complete, then worker DOWN must not re-add.
    ref4 = make_ref()
    {wpid, wmon} = spawn_monitor(fn -> Process.sleep(60_000) end)

    :sys.replace_state(store, fn state ->
      bucket = %{
        task_id: task_id,
        members: %{a => %{kind: :task_steer, id: a}},
        exhausted: false,
        generation: 1,
        attempt_index: 0,
        retrigger_count: 0
      }

      attempt =
        running_attempt(ref4, task_id, [a], generation: 1)
        |> Map.put(:worker_pid, wpid)
        |> Map.put(:worker_mon, wmon)

      state
      |> Map.put(:lease_pending_retirement, %{task_id => bucket})
      |> Map.put(:lease_retire_attempts, %{ref4 => attempt})
    end)

    send(store, {:lease_retire_complete, ref4, [{a, :ok}]})

    assert wait_until(fn -> is_nil(snapshot_pending(store, task_id)) end)

    # Late DOWN after completion must not resurrect pending members.
    send(store, {:DOWN, wmon, :process, wpid, :normal})
    Process.sleep(20)
    assert is_nil(snapshot_pending(store, task_id))
    if Process.alive?(wpid), do: Process.exit(wpid, :kill)
  end

  test "unavailable cleanup supervisor admission retains members without blocking status" do
    missing_sup = unique_atom(:missing_cleanup_sup)
    ok_sup = unique_atom(:ok_sup)
    _ = start_supervised!({Task.Supervisor, name: ok_sup})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:unavail_store),
         task_supervisor: ok_sup,
         cleanup_supervisor: missing_sup,
         runner: __MODULE__.QuickRunner,
         task_control_revoke: fn _ -> :ok end,
         lease_retire_admit_timeout_ms: 50,
         lease_retire_base_delay_ms: 10,
         lease_retire_max_delay_ms: 20,
         lease_retire_max_attempts: 1}
      )

    task_id = "task_unavail_1"
    ids = Map.new(TaskControlLease.kinds(), fn k -> {k, "cap_#{k}_#{task_id}"} end)
    {:ok, lease} = TaskControlLease.new(task_id, ids)

    assert {:ok, ^task_id} =
             TaskStore.dispatch("agent_1", "work",
               name: store,
               task_id: task_id,
               task_control_lease: lease
             )

    # Terminal status available even when cleanup supervisor is missing.
    assert wait_until(fn ->
             match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store))
           end)

    assert {:ok, %{state: :done}} = TaskStore.status(task_id, name: store)

    assert wait_until(fn ->
             {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
             pending = Map.get(snap.pending, task_id)
             is_map(pending) and pending.exhausted == true and pending.remaining_count > 0
           end)
  end

  test "idempotent revoke outcomes succeed in live worker path" do
    revoke_fun = fn id ->
      cond do
        String.ends_with?(id, "_nf") -> {:error, :not_found}
        String.ends_with?(id, "_ar") -> {:error, :already_revoked}
        true -> :ok
      end
    end

    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:idem_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:idem_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: __MODULE__.QuickRunner,
         task_control_revoke: revoke_fun,
         lease_retire_admit_timeout_ms: 500,
         lease_retire_worker_timeout_ms: 500}
      )

    task_id = "task_idem_1"

    ids = %{
      task_read: "cap_read_#{task_id}",
      approval_read: "cap_ar_#{task_id}_ar",
      task_steer: "cap_st_#{task_id}_nf",
      task_cancel: "cap_ca_#{task_id}",
      task_adopt: "cap_ad_#{task_id}",
      approval_answer: "cap_aa_#{task_id}"
    }

    {:ok, lease} = TaskControlLease.new(task_id, ids)

    assert {:ok, ^task_id} =
             TaskStore.dispatch("agent_1", "work",
               name: store,
               task_id: task_id,
               task_control_lease: lease
             )

    assert wait_until(fn ->
             match?({:ok, %{state: :done}}, TaskStore.status(task_id, name: store))
           end)

    # Terminal non-adoptable retires 5 members including not_found/already_revoked.
    assert wait_until(fn ->
             {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
             is_nil(Map.get(snap.pending, task_id))
           end)
  end

  test "no-op and forged retirement messages preserve state" do
    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:forge_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:forge_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: HangRunner}
      )

    task_id = "task_forge_1"

    assert {:ok, ^task_id} =
             TaskStore.dispatch("agent_1", "work", name: store, task_id: task_id)

    # Forged completion must be ignored.
    send(store, {:lease_retire_complete, make_ref(), [{"cap_x", :ok}]})
    send(store, {:lease_retire_admitted, make_ref(), self()})
    send(store, {:lease_retire_admit_timeout, make_ref()})

    Process.sleep(50)
    assert Process.alive?(store)
    assert {:ok, %{task_id: ^task_id, state: :running}} = TaskStore.status(task_id, name: store)
  end

  test "security regression: unadmitted retire worker self-expires without revoke I/O" do
    # Exact race: worker child is started (as after start_child succeeds), but
    # TaskStore never accepts admission / never sends begin — same outcome as
    # admit-timeout launcher death with a superseded attempt. Worker must not
    # enter revoke (which could hang unmonitored) and must self-expire.
    table = :"lease_retire_begin_gate_#{System.unique_integer([:positive])}"
    _ = :ets.new(table, [:named_table, :public, :set])
    :ets.insert(table, {:revoke_entered, 0})
    test_pid = self()

    revoke_fun = fn id ->
      :ets.update_counter(table, :revoke_entered, {2, 1}, {:revoke_entered, 0})
      send(test_pid, {:unexpected_revoke, id})
      # Would hang if entered — proves unmonitored hung-revoke risk if begin
      # gating were missing.
      Process.sleep(60_000)
      :ok
    end

    attempt_ref = make_ref()
    store_pid = self()
    begin_wait_ms = 80

    worker_pid =
      spawn(fn ->
        TaskStore.run_lease_retire_worker(
          store_pid,
          attempt_ref,
          ["cap_unmonitored_hung"],
          nil,
          revoke_fun,
          begin_wait_ms
        )
      end)

    mon = Process.monitor(worker_pid)

    # Never send {:lease_retire_begin, attempt_ref}.
    assert_receive {:DOWN, ^mon, :process, ^worker_pid, _reason}, begin_wait_ms + 500

    [{:revoke_entered, entered}] = :ets.lookup(table, :revoke_entered)
    assert entered == 0
    refute_received {:unexpected_revoke, _}
    refute_received {:lease_retire_complete, ^attempt_ref, _}
  end

  test "security regression: stale admitted does not begin a waiting orphan worker" do
    # After admit-timeout supersede, a late {:lease_retire_admitted, ref, pid}
    # must not send begin. Waiting worker self-expires with zero revoke I/O.
    table = :"lease_retire_stale_begin_#{System.unique_integer([:positive])}"
    _ = :ets.new(table, [:named_table, :public, :set])
    :ets.insert(table, {:revoke_entered, 0})

    revoke_fun = fn _id ->
      :ets.update_counter(table, :revoke_entered, {2, 1}, {:revoke_entered, 0})
      Process.sleep(60_000)
      :ok
    end

    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:stale_begin_sup)})

    store =
      start_supervised!(
        {TaskStore,
         name: unique_atom(:stale_begin_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         runner: HangRunner}
      )

    orphan_ref = make_ref()
    begin_wait_ms = 100

    orphan =
      spawn(fn ->
        TaskStore.run_lease_retire_worker(
          store,
          orphan_ref,
          ["cap_stale_orphan"],
          nil,
          revoke_fun,
          begin_wait_ms
        )
      end)

    mon = Process.monitor(orphan)

    # Stale/forged admitted: no matching attempt_ref in store outbox.
    send(store, {:lease_retire_admitted, orphan_ref, orphan})

    assert_receive {:DOWN, ^mon, :process, ^orphan, _reason}, begin_wait_ms + 500
    [{:revoke_entered, entered}] = :ets.lookup(table, :revoke_entered)
    assert entered == 0
    assert Process.alive?(store)
  end

  test "security regression: start_child then admit-timeout race never begins revoke" do
    # Deterministic protocol race (no timing flake):
    # 1) start_child already succeeded → worker is waiting for begin
    # 2) store admit-timeout supersedes attempt and kills launcher
    # 3) late {:lease_retire_admitted, ...} must NOT send begin
    # 4) worker self-expires; revoke never entered; members retained for retry
    table = :"lease_retire_admit_race_#{System.unique_integer([:positive])}"
    _ = :ets.new(table, [:named_table, :public, :set])
    :ets.insert(table, {:revoke_entered, 0})

    revoke_fun = fn _id ->
      :ets.update_counter(table, :revoke_entered, {2, 1}, {:revoke_entered, 0})
      Process.sleep(60_000)
      :ok
    end

    supervisor = start_supervised!({Task.Supervisor, name: unique_atom(:admit_race_sup)})

    store =
      start_supervised!({
        TaskStore,
        # max_attempts 1 + attempt_index 0 ⇒ timeout exhausts without a real
        # retry launch that could race the revoke counter assertion.
        name: unique_atom(:admit_race_store),
        task_supervisor: supervisor,
        cleanup_supervisor: supervisor,
        runner: HangRunner,
        task_control_revoke: revoke_fun,
        lease_retire_admit_timeout_ms: 5_000,
        lease_retire_base_delay_ms: 20,
        lease_retire_max_delay_ms: 40,
        lease_retire_max_attempts: 1
      })

    task_id = "task_admit_race_1"
    cap_id = "cap_race_member_1"
    attempt_ref = make_ref()
    begin_wait_ms = 120

    # Fake launcher blocked in start_child/admission path.
    {launcher_pid, launcher_mon} =
      spawn_monitor(fn ->
        Process.sleep(60_000)
      end)

    worker_pid =
      spawn(fn ->
        TaskStore.run_lease_retire_worker(
          store,
          attempt_ref,
          [cap_id],
          nil,
          revoke_fun,
          begin_wait_ms
        )
      end)

    worker_mon = Process.monitor(worker_pid)

    :sys.replace_state(store, fn state ->
      bucket = %{
        task_id: task_id,
        members: %{cap_id => %{kind: :approval_answer, id: cap_id}},
        exhausted: false,
        generation: 0,
        attempt_index: 0,
        retrigger_count: 0
      }

      attempt = %{
        attempt_ref: attempt_ref,
        task_id: task_id,
        generation: 0,
        attempt_index: 0,
        phase: :terminal_revoke_set,
        member_ids: [cap_id],
        status: :admitting,
        completion_applied?: false,
        launcher_pid: launcher_pid,
        # Store-owned mon so timeout demonitor is valid; test uses separate mon.
        launcher_mon: nil,
        worker_pid: nil,
        worker_mon: nil,
        admit_timer: nil,
        worker_timer: nil,
        retry_timer: nil,
        admit_deadline_mono: System.monotonic_time(:millisecond),
        worker_deadline_mono: nil,
        security_module: Arbor.Security,
        revoke_fun: revoke_fun,
        last_error_class: nil
      }

      state
      |> Map.put(:lease_pending_retirement, Map.put(%{}, task_id, bucket))
      |> Map.put(:lease_retire_attempts, Map.put(%{}, attempt_ref, attempt))
      |> Map.put(:task_control_revoke, revoke_fun)
      |> Map.put(:lease_retire_max_attempts, 1)
    end)

    # Step 2: admit timeout (launcher death path) before acceptance.
    send(store, {:lease_retire_admit_timeout, attempt_ref})

    # Launcher must be killed by the timeout handler.
    assert_receive {:DOWN, ^launcher_mon, :process, ^launcher_pid, _}, 500

    # Step 3: late admitted as if start_child had already returned worker_pid.
    send(store, {:lease_retire_admitted, attempt_ref, worker_pid})

    # Step 4: worker never receives begin → self-expires; no revoke I/O.
    assert_receive {:DOWN, ^worker_mon, :process, ^worker_pid, _}, begin_wait_ms + 500
    [{:revoke_entered, entered}] = :ets.lookup(table, :revoke_entered)
    assert entered == 0

    # Authority retained (exhausted but not forgotten) after admit failure.
    assert {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
    pending = Map.fetch!(snap.pending, task_id)
    assert pending.remaining_count == 1
    assert pending.exhausted == true
    assert Process.alive?(store)
  end

  test "status projection mismatch rejects before authorize or mutation" do
    CountingSecurity.create!()
    CountingSecurity.reset!()
    MismatchStore.reset_mutations!()

    opts = [
      caller_id: "caller",
      task_store: MismatchStore,
      security_module: CountingSecurity
    ]

    assert {:error, :task_id_mismatch} = Orchestration.task_status("task_requested", opts)
    assert {:error, :task_id_mismatch} = Orchestration.task_result("task_requested", opts)

    assert {:error, :task_id_mismatch} =
             Orchestration.steer_task("task_requested", "nope", opts)

    assert {:error, :task_id_mismatch} = Orchestration.cancel_task("task_requested", opts)

    assert {:error, :task_id_mismatch} =
             Orchestration.adopt_task_change("task_requested", "main", opts)

    # authorize_calls/0 must not reset the counter (was a vacuous assertion).
    assert CountingSecurity.authorize_calls() == 0
    assert MismatchStore.mutations() == []
  end

  defmodule MismatchStore do
    @moduledoc false
    @table :lease_mismatch_store_mutations

    def reset_mutations! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ets.insert(@table, {:mutations, []})
      :ok
    end

    def mutations do
      case :ets.lookup(@table, :mutations) do
        [{:mutations, list}] -> list
        _ -> []
      end
    end

    defp record(op) do
      case :ets.lookup(@table, :mutations) do
        [{:mutations, list}] -> :ets.insert(@table, {:mutations, list ++ [op]})
        _ -> :ets.insert(@table, {:mutations, [op]})
      end
    end

    def status(_task_id, _opts),
      do: {:ok, %{task_id: "other_task", agent_id: "a", state: :running}}

    def result(_task_id, _opts) do
      record(:result)
      {:ok, %{}}
    end

    def cancel(_task_id, _opts) do
      record(:cancel)
      {:ok, %{task_id: "other_task", state: :cancelled}}
    end

    def steer(_task_id, _msg, _opts) do
      record(:steer)
      {:ok, %{"control_id" => "c1"}}
    end

    def adopt(_task_id, _dest, _opts) do
      record(:adopt)
      {:ok, %{}}
    end
  end

  defmodule CountingSecurity do
    @moduledoc false
    @table :lease_mismatch_security_count

    def create! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset! do
      create!()
      :ets.insert(@table, {:authorize_calls, 0})
      :ok
    end

    # Read-only: must never reset the counter.
    def authorize_calls do
      case :ets.lookup(@table, :authorize_calls) do
        [{:authorize_calls, n}] -> n
        _ -> 0
      end
    end

    def authorize(_actor, _resource, _action, _opts) do
      case :ets.lookup(@table, :authorize_calls) do
        [{:authorize_calls, n}] -> :ets.insert(@table, {:authorize_calls, n + 1})
        _ -> :ets.insert(@table, {:authorize_calls, 1})
      end

      {:ok, :authorized}
    end
  end

  defmodule QuickRunner do
    @moduledoc false
    def run(_a, _t, _o), do: {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}
  end

  defp running_attempt(attempt_ref, task_id, member_ids, opts \\ []) do
    %{
      attempt_ref: attempt_ref,
      task_id: task_id,
      generation: Keyword.get(opts, :generation, 0),
      attempt_index: Keyword.get(opts, :attempt_index, 0),
      phase: :terminal_revoke_set,
      member_ids: member_ids,
      status: :running,
      completion_applied?: false,
      launcher_pid: nil,
      launcher_mon: nil,
      worker_pid: nil,
      worker_mon: nil,
      admit_timer: nil,
      worker_timer: nil,
      retry_timer: nil,
      admit_deadline_mono: 0,
      worker_deadline_mono: nil,
      security_module: Arbor.Security,
      revoke_fun: nil,
      last_error_class: nil
    }
  end

  defp put_retirement_running(state, task_id, attempt_ref, ids, opts) do
    generation = Keyword.get(opts, :generation, 0)
    attempt_index = Keyword.get(opts, :attempt_index, 0)

    members =
      Map.new(ids, fn id ->
        {id, %{kind: :task_steer, id: id}}
      end)

    bucket = %{
      task_id: task_id,
      members: members,
      exhausted: false,
      generation: generation,
      attempt_index: attempt_index,
      retrigger_count: 0
    }

    attempt =
      running_attempt(attempt_ref, task_id, ids,
        generation: generation,
        attempt_index: attempt_index
      )

    state
    |> Map.put(:lease_pending_retirement, %{task_id => bucket})
    |> Map.put(:lease_retire_attempts, %{attempt_ref => attempt})
  end

  defp snapshot_pending(store, task_id) do
    {:ok, snap} = TaskStore.lease_retirement_snapshot(name: store)
    Map.get(snap.pending, task_id)
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false

  defp unique_atom(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defmodule NoopAudit do
    @moduledoc false
    def record_orchestration_task_dispatched(_caller, _task, _agent, _data), do: :ok
  end
end
