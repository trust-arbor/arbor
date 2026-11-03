defmodule Arbor.Scheduler.OwnedRoutineFixtureJournalIsolationFirstSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Repo
  alias Arbor.Scheduler
  alias Arbor.Scheduler.Test.OwnedRoutineFixture, as: F

  @moduletag :integration
  @moduletag :isolated_repo
  @moduletag :security_regression

  setup_all do
    assert apply(Repo, :__adapter__, []) == Ecto.Adapters.SQLite3
    F.start_sql!()
  end

  setup context do
    F.start!(context)
  end

  test "a fresh SQL owner executes the reused first attempt and double drain is idempotent", f do
    assert Repo.aggregate(Oban.Job, :count) == 0
    intent = F.intent!(f)
    proof = F.proof!(f.owner, :enqueue, intent)
    assert {:ok, job} = Scheduler.enqueue_routine(intent, proof)
    assert job.id == 1

    assert :ok = Supervisor.terminate_child(f.repo_supervisor, Repo)
    assert {:ok, _} = Supervisor.restart_child(f.repo_supervisor, Repo)

    assert %{success: 1, failure: 0} = F.drain()
    row = Repo.get!(Oban.Job, job.id)
    assert row.state == "completed"
    assert row.attempt == 1
    output = File.read!(F.report(f, "morning-digest"))
    assert output =~ "first bounded source"
    assert output =~ "second bounded source"
    refute output =~ "previous digest"
    assert %{success: 0, failure: 0} = F.drain()
    assert File.read!(F.report(f, "morning-digest")) == output
  end
end

defmodule Arbor.Scheduler.OwnedRoutineFixtureJournalIsolationSecondSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Repo
  alias Arbor.Scheduler
  alias Arbor.Scheduler.Test.OwnedRoutineFixture, as: F

  @moduletag :integration
  @moduletag :isolated_repo
  @moduletag :security_regression

  setup_all do
    assert apply(Repo, :__adapter__, []) == Ecto.Adapters.SQLite3
    F.start_sql!()
  end

  setup context do
    F.start!(context)
  end

  test "a fresh SQL owner executes the reused first attempt and double drain is idempotent", f do
    assert Repo.aggregate(Oban.Job, :count) == 0
    intent = F.intent!(f)
    proof = F.proof!(f.owner, :enqueue, intent)
    assert {:ok, job} = Scheduler.enqueue_routine(intent, proof)
    assert job.id == 1

    assert :ok = Supervisor.terminate_child(f.repo_supervisor, Repo)
    assert {:ok, _} = Supervisor.restart_child(f.repo_supervisor, Repo)

    assert %{success: 1, failure: 0} = F.drain()
    row = Repo.get!(Oban.Job, job.id)
    assert row.state == "completed"
    assert row.attempt == 1
    output = File.read!(F.report(f, "morning-digest"))
    assert output =~ "first bounded source"
    assert output =~ "second bounded source"
    refute output =~ "previous digest"
    assert %{success: 0, failure: 0} = F.drain()
    assert File.read!(F.report(f, "morning-digest")) == output
  end
end
