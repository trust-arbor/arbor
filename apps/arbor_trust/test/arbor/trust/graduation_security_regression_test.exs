Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Trust.GraduationSecurityRegressionTest do
  @moduledoc """
  Public graduation gate tests. The configured source represents already
  owner-qualified A1b evidence; acceptance uses real current OIDC human identity,
  HMAC session proof and signed capabilities. The durable backend exercises
  real Store write-through and recovery without an external database.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Security
  alias Arbor.Security.SessionToken
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Fixture
  alias Arbor.Trust
  alias Arbor.Trust.{ConfirmationTracker, PolicyHost, Store}

  @prefix "arbor://memory/read"

  defmodule Source do
    @behaviour Arbor.Trust.Contracts.ApprovalEvidenceProvider
    def answered_approval(source, id),
      do:
        Agent.get(__MODULE__, fn rows ->
          case Map.fetch(rows, {source, id}) do
            {:ok, row} -> {:ok, row}
            :error -> {:error, :approval_evidence_unavailable}
          end
        end)
  end

  defmodule Backend do
    def put(key, record, _opts) do
      pause =
        Agent.get_and_update(__MODULE__, &{Map.get(&1, :pause_once), Map.delete(&1, :pause_once)})

      if is_pid(pause) do
        send(pause, {:persist_waiting, self()})

        receive do
          :finish_persist -> :ok
        after
          15_000 -> raise "test persistence was not released"
        end
      end

      Agent.get_and_update(__MODULE__, fn state ->
        if state.fail,
          do: {{:error, :simulated_persist_failure}, state},
          else: {:ok, put_in(state.rows[key], record)}
      end)
    end

    def get(key, _opts),
      do:
        Agent.get(__MODULE__, fn state ->
          case Map.fetch(state.rows, key) do
            {:ok, row} -> {:ok, row}
            :error -> {:error, :not_found}
          end
        end)

    def list(_opts), do: Agent.get(__MODULE__, &{:ok, Map.keys(&1.rows)})
  end

  setup do
    ctx = Fixture.setup!()
    if Process.whereis(PolicyHost) == nil, do: start_supervised!(PolicyHost)
    start_supervised!({Agent, fn -> %{} end}, id: Source) |> Process.register(Source)

    start_supervised!({Agent, fn -> %{rows: %{}, fail: false} end}, id: Backend)
    |> Process.register(Backend)

    start_supervised!({Store, persistence: :durable, durable_backend: Backend})
    start_supervised!(ConfirmationTracker)
    old_source = Application.fetch_env(:arbor_trust, :approval_evidence_provider)
    old_thresholds = Application.fetch_env(:arbor_trust, :graduation_thresholds)
    Application.put_env(:arbor_trust, :approval_evidence_provider, Source)
    Application.delete_env(:arbor_trust, :graduation_thresholds)

    on_exit(fn ->
      restore(:approval_evidence_provider, old_source)
      restore(:graduation_thresholds, old_thresholds)
    end)

    {:ok, profile} = Profile.new(ctx.agent_id)
    assert :ok = Store.store_profile(%{profile | rules: %{@prefix => :ask}})
    Fixture.grant!(ctx.human_id, "arbor://trust/read/#{ctx.agent_id}")
    cap = Fixture.grant!(ctx.human_id, "arbor://trust/auto_promote/#{ctx.agent_id}")
    Map.put(ctx, :promotion_cap, cap)
  end

  test "security regression: legacy acceptance and unverified counters cannot promote", ctx do
    assert {:error, :human_acceptance_required} = Trust.accept_graduation(ctx.agent_id, @prefix)
    for _ <- 1..6, do: assert(:ok = Trust.record_approval(ctx.agent_id, @prefix))
    refute Trust.graduated?(ctx.agent_id, @prefix)
    assert {:ok, status} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert status.human_streak == 0
    refute status.pending
    assert status.suggestion_id == nil
    assert_mode(ctx, :ask)
  end

  test "status and exact duplicate are read-only; current explicit acceptance persists once",
       ctx do
    {id, expected} = observe!(ctx, @prefix, :approve)
    assert {:ok, first} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert first.pending
    assert first.threshold == 0
    assert first.human_streak == 1
    assert_mode(ctx, :ask)
    assert {:ok, [^first]} = Trust.list_graduations(ctx.agent_id, read_opts(ctx))
    assert {:ok, :duplicate} = Trust.record_approval_answer(:interaction, id, expected)
    assert {:ok, ^first} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert :ok = Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, first))
    assert_mode(ctx, :auto)
    assert {:error, _} = Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, first))
    stop_supervised!(Store)
    start_supervised!({Store, persistence: :durable, durable_backend: Backend})
    assert_mode(ctx, :auto)
  end

  test "new evidence and reset invalidate old suggestion identifiers", ctx do
    observe!(ctx, @prefix, :approve)
    {:ok, old} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    observe!(ctx, @prefix, :approve)
    {:ok, fresh} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert fresh.revision > old.revision
    refute fresh.suggestion_id == old.suggestion_id

    assert {:error, :stale_graduation_suggestion} =
             Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, old))

    assert :ok = ConfirmationTracker.reset(ctx.agent_id)
    observe!(ctx, @prefix, :approve)

    assert {:error, :stale_graduation_suggestion} =
             Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, fresh))

    assert_mode(ctx, :ask)
  end

  test "forged, wrong-human, expired or revoked authority leaves suggestion pending", ctx do
    observe!(ctx, @prefix, :approve)
    {:ok, pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    other = Fixture.human!()
    {:ok, wrong} = SessionToken.generate(other)
    {:ok, expired} = SessionToken.generate(ctx.human_id, ttl: -1)

    for token <- ["forged", wrong, expired, nil] do
      opts = Keyword.put(decision_opts(ctx, pending), :session_token, token)

      assert {:error, :graduation_authority_required} =
               Trust.accept_graduation(ctx.agent_id, @prefix, opts)
    end

    assert {:error, :stale_graduation_suggestion} =
             Trust.accept_graduation(
               ctx.agent_id,
               @prefix,
               Keyword.put(decision_opts(ctx, pending), :suggestion_id, "forged")
             )

    assert :ok = Security.revoke(ctx.promotion_cap.id)

    assert {:error, :graduation_authority_required} =
             Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))

    assert {:ok, ^pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert_mode(ctx, :ask)
  end

  test "read and decisions require their own exact target scope", ctx do
    observe!(ctx, @prefix, :approve)

    assert {:error, :graduation_authority_required} =
             Trust.list_graduations(ctx.agent_id <> "_other", read_opts(ctx))

    assert {:error, :graduation_authority_required} =
             Trust.list_graduations(ctx.agent_id,
               caller_id: ctx.human_id,
               session_token: "forged"
             )

    assert {:error, :invalid_graduation_options} =
             Trust.list_graduations(ctx.agent_id, read_opts(ctx) ++ [verify_identity: false])
  end

  test "failed durable write does not consume the current suggestion; retry succeeds", ctx do
    observe!(ctx, @prefix, :approve)
    {:ok, pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    Agent.update(Backend, &%{&1 | fail: true})

    assert {:error, {:trust_profile_persist_failed, :simulated_persist_failure}} =
             Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))

    assert {:ok, ^pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert_mode(ctx, :ask)
    Agent.update(Backend, &%{&1 | fail: false})
    assert :ok = Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))
    assert_mode(ctx, :auto)
  end

  test "decline locks this prefix and cannot be replayed into acceptance", ctx do
    observe!(ctx, @prefix, :approve)
    {:ok, pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert :ok = Trust.decline_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))
    observe!(ctx, @prefix, :approve)
    {:ok, locked} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert locked.locked
    assert locked.reason == :locked
    refute locked.pending

    assert {:error, :locked} =
             Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))

    assert_mode(ctx, :ask)
  end

  @tag fast: false
  @tag :slow
  test "a timed out write remains uncertain and later acknowledgement is reflected by current profile",
       ctx do
    observe!(ctx, @prefix, :approve)
    {:ok, pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    observer = self()
    Agent.update(Backend, &Map.put(&1, :pause_once, observer))

    task =
      Task.async(fn ->
        Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))
      end)

    assert_receive {:persist_waiting, store}, 1_000

    try do
      assert {:error, :graduation_store_outcome_unknown} = Task.await(task, 8_000)
      assert {:ok, ^pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
      assert_mode(ctx, :ask)
      send(store, :finish_persist)
      # Serialized Store call is a completion barrier for the released write.
      Store.get_cache_stats()
      assert {:ok, current} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
      refute current.pending
      assert current.current_mode == :auto
      assert current.reason == :already_automatic

      assert {:error, :already_automatic} =
               Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))

      assert_mode(ctx, :auto)
    after
      send(store, :finish_persist)
    end
  end

  test "serialized Store boundary rechecks authority after an acceptance has queued", ctx do
    observe!(ctx, @prefix, :approve)
    {:ok, pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    store = Process.whereis(Store)
    # Scheduling only: no state or authority is injected. The asserted action
    # and revocation both use their public facades.
    :ok = :sys.suspend(store)

    try do
      task =
        Task.async(fn ->
          Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))
        end)

      await_store_update(store, 200)
      assert :ok = Security.revoke(ctx.promotion_cap.id)
      :ok = :sys.resume(store)
      assert {:error, :graduation_authority_required} = Task.await(task)
      assert {:ok, ^pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
      assert_mode(ctx, :ask)
    after
      :sys.resume(store)
    end
  end

  test "system ceilings, never-graduate profiles and current profile changes override evidence",
       ctx do
    for prefix <- ["arbor://code/write", "arbor://shell"] do
      assert {:ok, _} = Trust.set_rule(ctx.agent_id, prefix <> "/scope", :ask)
      for _ <- 1..6, do: observe!(ctx, prefix, :approve)
      {:ok, status} = Trust.graduation_status(ctx.agent_id, prefix, read_opts(ctx))
      refute status.pending
      assert status.reason in [:never_graduate, :ceiling_restricted]
    end

    observe!(ctx, @prefix, :approve)
    {:ok, pending} = Trust.graduation_status(ctx.agent_id, @prefix, read_opts(ctx))
    assert {:ok, _} = Store.freeze_profile(ctx.agent_id, :test)

    assert {:error, :profile_frozen} =
             Trust.accept_graduation(ctx.agent_id, @prefix, decision_opts(ctx, pending))

    assert_mode(ctx, :ask)
  end

  defp observe!(ctx, prefix, decision) do
    id = "answer_#{System.unique_integer([:positive])}"

    expected = %{
      agent_id: ctx.agent_id,
      principal_id: ctx.agent_id,
      resource_uri: prefix <> "/exact",
      decision: decision
    }

    row =
      Map.merge(expected, %{source: :interaction, request_id: id, verified_human_id: ctx.human_id})

    Agent.update(Source, &Map.put(&1, {:interaction, id}, row))
    assert {:ok, :recorded} = Trust.record_approval_answer(:interaction, id, expected)
    {id, expected}
  end

  defp read_opts(ctx), do: [caller_id: ctx.human_id, session_token: ctx.token]
  defp decision_opts(ctx, status), do: read_opts(ctx) ++ [suggestion_id: status.suggestion_id]

  defp assert_mode(ctx, mode) do
    assert {:ok, profile} = Store.get_profile(ctx.agent_id)
    assert profile.rules[@prefix] == mode
  end

  defp await_store_update(_store, 0), do: flunk("acceptance did not reach the Store queue")

  defp await_store_update(store, remaining) do
    {:messages, messages} = Process.info(store, :messages)

    if Enum.any?(messages, fn
         {:"$gen_call", _, {:update_profile, _, _}} -> true
         _ -> false
       end) do
      :ok
    else
      receive do
      after
        5 -> await_store_update(store, remaining - 1)
      end
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:arbor_trust, key, value)
  defp restore(key, :error), do: Application.delete_env(:arbor_trust, key)
end
