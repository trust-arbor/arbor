defmodule Arbor.Scheduler.OwnedRoutineSecurityRegressionTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Arbor.Persistence.Repo
  alias Arbor.Scheduler
  alias Arbor.Scheduler.Test.OwnedRoutineFixture, as: F
  alias Arbor.Scheduler.Workers.OwnedRoutineRunner
  alias Arbor.Security
  alias Arbor.Trust

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :security_regression

  setup_all do
    F.start_sql!()
  end

  setup context do
    F.start!(context)
  end

  test "real signed enqueue survives cold SQL and aged ingress proof, then real Engine publishes",
       f do
    intent = F.intent!(f)
    old = DateTime.add(DateTime.utc_now(), -120)
    F.env(:arbor_security, :timestamp_max_drift_seconds, 300)
    proof = F.proof!(f.owner, :enqueue, intent, timestamp: old)
    assert {:ok, job} = Scheduler.enqueue_routine(intent, proof)
    Application.put_env(:arbor_security, :timestamp_max_drift_seconds, 60)

    assert :ok = Supervisor.terminate_child(f.repo_supervisor, Repo)
    assert {:ok, _} = Supervisor.restart_child(f.repo_supervisor, Repo)

    assert Repo.get!(Oban.Job, job.id).args["owned_routine"]["proof"]["timestamp"] ==
             DateTime.to_iso8601(old)

    assert %{success: 1, failure: 0} = F.drain()
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    output = File.read!(F.report(f, "morning-digest"))
    assert output =~ "first bounded source"
    assert output =~ "second bounded source"
    refute output =~ "previous digest"
    assert %{success: 0, failure: 0} = F.drain()
    assert File.read!(F.report(f, "morning-digest")) == output

    assert_receive {:routine_effect, _, token, %{operation: :enter, principal: ephemeral}}
    refute ephemeral == f.owner.identity.agent_id
    assert {:error, _} = Security.lookup_public_key(ephemeral)

    assert {:error, _} =
             Scheduler.authorize_routine_effect(token, %{operation: :enter, principal: ephemeral})

    for path <- Path.wildcard(Path.join([f.workdir, "logs", "**", "*"])), File.regular?(path) do
      refute File.read!(path) =~ token.token
    end
  end

  for variant <- [:lock_loser, :positive_ghost] do
    @tag oban_insert_variant: variant
    test "an injected #{variant} Oban result cannot acknowledge an absent SQL job", f do
      intent = F.intent!(f)

      assert {:error, :routine_enqueue_not_committed} =
               Scheduler.enqueue_routine(intent, F.proof!(f.owner, :enqueue, intent))

      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  @tag oban_insert_variant: :persisted_without_result_id
  test "an ambiguous Oban return succeeds only after observing the actual positive SQL row", f do
    intent = F.intent!(f)
    assert {:ok, result} = Scheduler.enqueue_routine(intent, F.proof!(f.owner, :enqueue, intent))
    assert is_integer(result.id) and result.id > 0
    row = Repo.get!(Oban.Job, result.id)
    assert row.args["owned_routine"]["intent"] == intent
    assert row.args["owned_routine"]["proof"]["agent_id"] == f.owner.identity.agent_id
  end

  test "owner derives from signature; own list/cancel and stable request retries are bounded",
       f do
    intent = F.intent!(f)
    assert {:ok, job} = Scheduler.enqueue_routine(intent, F.proof!(f.owner, :enqueue, intent))
    assert job.owner == f.owner.identity.agent_id

    assert {:ok, repeated} =
             Scheduler.enqueue_routine(intent, F.proof!(f.owner, :enqueue, intent))

    assert repeated.id == job.id
    assert Repo.aggregate(Oban.Job, :count) == 1

    filters = %{"limit" => 20}

    assert {:ok, %{items: [listed]}} =
             Scheduler.list_owned_routines(filters, F.proof!(f.owner, :list, filters))

    assert listed.id == job.id
    refute Map.has_key?(listed, :proof)
    refute Map.has_key?(listed, :parents)

    assert {:ok, %{items: []}} =
             Scheduler.list_owned_routines(filters, F.proof!(f.other, :list, filters))

    assert {:error, :routine_cancel_denied} =
             Scheduler.cancel_owned_routine(job.id, F.proof!(f.other, :cancel, job.id))

    assert :ok = Scheduler.cancel_owned_routine(job.id, F.proof!(f.owner, :cancel, job.id))
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert %{success: 0} = F.drain()
    assert File.read!(F.report(f, "morning-digest")) == "previous digest"
  end

  test "exact signed operation refuses replay, unknown owner fields and parameter drift before insertion",
       f do
    intent = F.intent!(f)
    proof = F.proof!(f.owner, :enqueue, intent)
    changed = Map.put(intent, "request_id", "another_immutable_request")
    assert {:error, _} = Scheduler.enqueue_routine(changed, proof)

    assert {:error, _} =
             Scheduler.enqueue_routine(
               Map.put(intent, "owner_id", f.other.identity.agent_id),
               proof
             )

    assert {:error, _} =
             Scheduler.enqueue_routine(
               Map.put(intent, "parents", [hd(intent["parents"]) | :bad]),
               proof
             )

    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:ok, _} = Scheduler.enqueue_routine(intent, proof)
    assert {:error, _} = Scheduler.enqueue_routine(intent, proof)

    conflicting =
      Map.put(
        intent,
        "scheduled_at",
        DateTime.utc_now()
        |> DateTime.add(120)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
      )

    assert {:error, :routine_request_conflict} =
             Scheduler.enqueue_routine(conflicting, F.proof!(f.owner, :enqueue, conflicting))

    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "missing required SQL uniqueness migration refuses before insertion", f do
    intent = F.intent!(f)
    Ecto.Adapters.SQL.query!(Repo, "DROP INDEX oban_owned_routine_request_key_unique", [])

    try do
      assert {:error, :routine_store_migration_required} =
               Scheduler.enqueue_routine(intent, F.proof!(f.owner, :enqueue, intent))

      assert Repo.aggregate(Oban.Job, :count) == 0
    after
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE UNIQUE INDEX oban_owned_routine_request_key_unique ON oban_jobs(json_extract(args, '$.request_key')) WHERE worker = 'Arbor.Scheduler.Workers.OwnedRoutineRunner'",
        []
      )
    end
  end

  test "other owner's selected cap IDs and digest replacement do not become owner authority", f do
    intent = F.intent!(f)
    other_intent = F.intent!(f, f.other)
    forged = Map.put(intent, "parents", other_intent["parents"])
    assert {:error, _} = Scheduler.enqueue_routine(forged, F.proof!(f.owner, :enqueue, forged))

    digest_changed =
      update_in(intent, ["parents", Access.at(0), "capability_digest"], fn _ ->
        String.duplicate("0", 64)
      end)

    assert {:error, _} =
             Scheduler.enqueue_routine(
               digest_changed,
               F.proof!(f.owner, :enqueue, digest_changed)
             )

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "scheduled time is signed and the ordinary queue cannot run it before due", f do
    future =
      DateTime.utc_now()
      |> DateTime.add(3600)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    job = F.enqueue!(f, at: future)
    assert %{success: 0} = F.drain()
    # Hostile persisted-row seam: changing Oban's wake-up fields cannot change
    # the signed earliest execution time or create a source effect token.
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "available", scheduled_at: DateTime.utc_now()]
    )

    assert %{discard: 1, success: 0} = F.drain()
    refute_received {:routine_effect, _, _, _}
    assert File.read!(F.report(f, "morning-digest")) == "previous digest"
  end

  test "current original cap revocation stops execution despite an alternate covering cap", f do
    job = F.enqueue!(f)
    selected = List.last(f.owner.caps)

    assert {:ok, alternative} =
             Security.grant(principal: f.owner.identity.agent_id, resource: "arbor://fs/write/**")

    on_exit(fn -> Security.revoke(alternative.id) end)
    assert alternative.id != selected.id
    assert {:ok, held} = Security.list_capabilities(f.owner.identity.agent_id)
    assert Enum.any?(held, &(&1.id == selected.id))
    assert Enum.any?(held, &(&1.id == alternative.id))
    assert :ok = Security.revoke(selected.id)
    assert %{discard: 1, success: 0} = F.drain()
    assert Repo.get!(Oban.Job, job.id).state == "discarded"
    refute_received {:routine_effect, _, _, _}
    assert File.read!(F.report(f, "morning-digest")) == "previous digest"
  end

  for mutation <- [:suspend, :trust_ask, :tamper_proof, :manifest_change] do
    test "delayed execution refuses #{mutation} without minting a usable effect token", f do
      job = F.enqueue!(f)

      case unquote(mutation) do
        :suspend ->
          assert :ok = Security.suspend_identity(f.owner.identity.agent_id)

        :trust_ask ->
          selected = List.last(f.owner.caps)

          assert {:ok, _} =
                   Trust.set_rule(
                     f.owner.identity.agent_id,
                     String.trim_trailing(selected.resource_uri, "/**"),
                     :ask
                   )

        :tamper_proof ->
          row = Repo.get!(Oban.Job, job.id)

          args =
            put_in(row.args, ["owned_routine", "intent", "request_id"], "tampered_stored_request")

          Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [args: args])

        :manifest_change ->
          File.write!(f.dot, File.read!(f.dot) <> "\n// different reviewed bytes\n")
      end

      assert %{discard: 1, success: 0} = F.drain()
      refute_received {:routine_effect, _, _, _}
      assert File.read!(F.report(f, "morning-digest")) == "previous digest"
    end
  end

  for mutation <- [:revoke, :cancel, :trust_ask, :suspend] do
    test "security regression: #{mutation} after temporary write denies final publication", f do
      job = F.enqueue!(f)
      Application.put_env(:arbor_scheduler, :_owned_routine_pause, :publication)
      {holder, monitor} = F.drain_async()
      assert_receive {:routine_paused, actor, marker, token, effect}, 10_000
      assert effect.operation == :write
      assert effect.path == F.report(f, "morning-digest")
      assert File.read!(effect.path) == "previous digest"
      assert Enum.any?(File.ls!(Path.dirname(effect.path)), &String.ends_with?(&1, ".tmp"))

      status =
        :sys.get_status(Arbor.Scheduler.RunLease.whereis(token.lease))
        |> inspect(limit: :infinity)

      refute status =~ token.token

      case unquote(mutation) do
        :revoke ->
          assert :ok = Security.revoke(List.last(f.owner.caps).id)

        :cancel ->
          assert :ok = Scheduler.cancel_owned_routine(job.id, F.proof!(f.owner, :cancel, job.id))

        :trust_ask ->
          assert {:ok, _} =
                   Trust.set_rule(
                     f.owner.identity.agent_id,
                     String.trim_trailing(List.last(f.owner.caps).resource_uri, "/**"),
                     :ask
                   )

        :suspend ->
          assert :ok = Security.suspend_identity(f.owner.identity.agent_id)
      end

      send(actor, {:continue_routine, marker})
      assert_receive {:routine_drain_result, ^holder, %{success: 0}}, 10_000
      assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 10_000
      assert File.read!(effect.path) == "previous digest"
      assert File.ls!(Path.dirname(effect.path)) == [f.date <> ".md"]
      assert {:error, _} = Scheduler.authorize_routine_effect(token, effect)
    end
  end

  test "missing lease is an authorization refusal while cleanup remains idempotent", f do
    reference = %{lease: "lease_" <> String.duplicate("z", 24), token: String.duplicate("y", 43)}

    assert {:error, :routine_lease_not_current} =
             Scheduler.authorize_routine_effect(
               reference,
               %{principal: f.owner.identity.agent_id, operation: :enter}
             )

    assert :ok = Arbor.Scheduler.RunLease.revoke(reference.lease)
  end

  test "a copied executing Job cannot claim a second holder for the same SQL attempt", f do
    job = F.enqueue!(f)
    Application.put_env(:arbor_scheduler, :_owned_routine_pause, :publication)
    {holder, monitor} = F.drain_async()
    assert_receive {:routine_paused, actor, marker, token, effect}, 10_000
    row = Repo.get!(Oban.Job, job.id)
    assert row.state == "executing"
    assert {:discard, :routine_attempt_already_claimed} = OwnedRoutineRunner.perform(row)

    assert {:error, _} =
             Scheduler.authorize_routine_effect(
               %{token | token: String.duplicate("x", 43)},
               effect
             )

    assert {:error, _} =
             Scheduler.authorize_routine_effect(token, %{
               effect
               | principal: f.owner.identity.agent_id
             })

    send(actor, {:continue_routine, marker})
    assert_receive {:routine_drain_result, ^holder, %{success: 1}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 10_000
    assert File.read!(effect.path) =~ "first bounded source"
  end

  test "holder death makes the captured effect token unusable before any resumed publication",
       f do
    F.enqueue!(f)
    Application.put_env(:arbor_scheduler, :_owned_routine_pause, :publication)
    {holder, monitor} = F.drain_async()
    assert_receive {:routine_paused, actor, marker, token, effect}, 10_000
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 10_000
    assert {:error, _} = Scheduler.authorize_routine_effect(token, effect)
    if Process.alive?(actor), do: send(actor, {:continue_routine, marker})
    assert File.read!(effect.path) == "previous digest"
  end

  for change <- [:owner_death, :lease_expiry] do
    test "#{change} during the actual SQL admission cannot become a new effect", f do
      F.env(:arbor_scheduler, :run_identity_lease_ttl_ms, 15_000)
      F.enqueue!(f)
      Application.put_env(:arbor_scheduler, :_owned_routine_pause, :publication)
      {holder, holder_monitor} = F.drain_async()
      assert_receive {:routine_paused, actor, marker, token, effect}, 10_000
      lease = Arbor.Scheduler.RunLease.whereis(token.lease)
      remaining = :erlang.read_timer(:sys.get_state(lease).expiry_ref)
      assert is_integer(remaining) and remaining > 0
      F.pause_next_job_query!([lease])
      observer = self()

      {checker, checker_monitor} =
        spawn_monitor(fn ->
          result = Scheduler.authorize_routine_effect(token, effect)
          send(observer, {:blocked_admission_result, self(), result})
        end)

      assert_receive {:routine_sql_paused, ^lease, sql_marker}, 10_000

      case unquote(change) do
        :owner_death ->
          Process.exit(holder, :kill)
          assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 10_000

        :lease_expiry ->
          Process.sleep(remaining + 25)
      end

      send(lease, {:continue_routine_sql, sql_marker})
      assert_receive {:blocked_admission_result, ^checker, {:error, _}}, 10_000
      assert_receive {:DOWN, ^checker_monitor, :process, ^checker, :normal}, 10_000
      if Process.alive?(actor), do: send(actor, {:continue_routine, marker})

      if unquote(change) == :lease_expiry do
        assert_receive {:routine_drain_result, ^holder, %{success: 0}}, 10_000
        assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :normal}, 10_000
      end

      assert File.read!(effect.path) == "previous digest"
    end
  end

  for variant <- [:identical, :conflicting] do
    test "SQL uniqueness serializes concurrent #{variant} freshly signed request IDs", f do
      first = F.intent!(f)

      second =
        if unquote(variant) == :identical,
          do: first,
          else:
            Map.put(
              first,
              "scheduled_at",
              DateTime.utc_now()
              |> DateTime.add(120)
              |> DateTime.truncate(:second)
              |> DateTime.to_iso8601()
            )

      observer = self()

      workers =
        for intent <- [first, second] do
          spawn_monitor(fn ->
            receive do
              :begin_enqueue ->
                result = Scheduler.enqueue_routine(intent, F.proof!(f.owner, :enqueue, intent))
                send(observer, {:concurrent_enqueue_result, self(), result})
            end
          end)
        end

      F.pause_next_job_query!(Enum.map(workers, &elem(&1, 0)))
      for {pid, _} <- workers, do: send(pid, :begin_enqueue)

      pauses =
        for _ <- 1..2 do
          assert_receive {:routine_sql_paused, pid, marker}, 10_000
          {pid, marker}
        end

      for {pid, marker} <- pauses, do: send(pid, {:continue_routine_sql, marker})

      results =
        for {pid, ref} <- workers do
          assert_receive {:concurrent_enqueue_result, ^pid, result}, 10_000
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
          result
        end

      if unquote(variant) == :identical do
        assert [{:ok, a}, {:ok, b}] = results
        assert a.id == b.id
      else
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, :routine_request_conflict}, &1)) == 1
      end

      assert Repo.aggregate(Oban.Job, :count) == 1
    end
  end

  test "pagination does not expose or scan through another owner's newer jobs", f do
    first = F.enqueue!(f)
    second = F.enqueue!(f)
    other_intent = F.intent!(f, f.other)

    assert {:ok, foreign} =
             Scheduler.enqueue_routine(other_intent, F.proof!(f.other, :enqueue, other_intent))

    assert foreign.id > second.id
    filters = %{"limit" => 1}

    assert {:ok, %{items: [item], next_before_id: cursor}} =
             Scheduler.list_owned_routines(filters, F.proof!(f.owner, :list, filters))

    assert item.id == second.id
    assert cursor == second.id
    next = %{"limit" => 1, "before_id" => cursor}

    assert {:ok, %{items: [item], next_before_id: next_cursor}} =
             Scheduler.list_owned_routines(next, F.proof!(f.owner, :list, next))

    assert item.id == first.id
    assert next_cursor == first.id
    empty = %{"limit" => 1, "before_id" => first.id}

    assert {:ok, %{items: [], next_before_id: nil}} =
             Scheduler.list_owned_routines(empty, F.proof!(f.owner, :list, empty))
  end

  test "SQL owner outage refuses the next operation instead of trusting the retained signed envelope",
       f do
    F.enqueue!(f)
    Application.put_env(:arbor_scheduler, :_owned_routine_pause, :publication)
    {holder, monitor} = F.drain_async()
    assert_receive {:routine_paused, actor, marker, token, effect}, 10_000
    assert :ok = Supervisor.terminate_child(f.repo_supervisor, Repo)
    assert {:error, _} = Scheduler.authorize_routine_effect(token, effect)
    assert {:ok, _} = Supervisor.restart_child(f.repo_supervisor, Repo)
    # Cancel using the restored authoritative SQL owner so finishing the test
    # cannot make the post-outage continuation eligible again.
    row = Repo.one!(from(j in Oban.Job, where: j.state == "executing"))
    assert :ok = Scheduler.cancel_owned_routine(row.id, F.proof!(f.owner, :cancel, row.id))
    send(actor, {:continue_routine, marker})
    assert_receive {:routine_drain_result, ^holder, %{success: 0}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 10_000
    assert File.read!(effect.path) == "previous digest"
  end
end
