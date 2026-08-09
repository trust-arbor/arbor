defmodule Arbor.Agent.DispatchReadinessFacadeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.DispatchReadinessFacade
  alias Arbor.Agent.Orchestration.DispatchReadinessCore

  defp valid_report do
    {:ok, report} =
      DispatchReadinessCore.compose(%{
        observed_at: "2026-08-09T00:00:00Z",
        agent_id: "agent_target1",
        caller_id: "human_caller1",
        security: DispatchReadinessCore.plane("ready", nil, nil, %{}),
        coordinator: DispatchReadinessCore.plane("ready", nil, nil, %{}),
        exact_template: DispatchReadinessCore.plane("ready", nil, nil, %{}),
        task_control: DispatchReadinessCore.plane("ready", nil, nil, %{}),
        executor: DispatchReadinessCore.plane("ready", nil, nil, %{})
      })

    report
  end

  test "rejects invalid ids, tasks, and options" do
    fun = fn _, _, _ -> {:ok, valid_report()} end

    assert {:error, :invalid_caller_id} =
             DispatchReadinessFacade.project("bad", "agent_ok1", %{}, [], fun)

    assert {:error, :invalid_agent_id} =
             DispatchReadinessFacade.project("human_ok1", "nope", %{}, [], fun)

    assert {:error, :invalid_task} =
             DispatchReadinessFacade.project("human_ok1", "agent_ok1", "not-a-map", [], fun)

    assert {:error, :invalid_opts} =
             DispatchReadinessFacade.project(
               "human_ok1",
               "agent_ok1",
               %{},
               [unknown: true],
               fun
             )
  end

  test "unauthorized is closed; session token is forwarded only in orch opts" do
    parent = self()

    fun = fn agent_id, task, opts ->
      send(parent, {:orch, agent_id, task, opts})
      {:error, {:unauthorized, :agent_dispatch_required}}
    end

    assert {:error, :unauthorized} =
             DispatchReadinessFacade.project(
               "human_ok1",
               "agent_ok1",
               %{"kind" => "coding_change"},
               [session_token: "tok_secret_value"],
               fun
             )

    assert_received {:orch, "agent_ok1", %{"kind" => "coding_change"}, opts}
    assert opts[:caller_id] == "human_ok1"
    assert opts[:session_token] == "tok_secret_value"
  end

  test "fixed collaborator path returns bounded report" do
    report = valid_report()
    fun = fn _, _, _ -> {:ok, report} end

    assert {:ok, ^report} =
             DispatchReadinessFacade.project(
               "human_ok1",
               "agent_ok1",
               %{"kind" => "coding_change"},
               [],
               fun
             )
  end

  test "malformed orch return fails closed" do
    fun = fn _, _, _ -> {:ok, %{atom: :bad}} end

    assert {:error, :readiness_failed} =
             DispatchReadinessFacade.project(
               "human_ok1",
               "agent_ok1",
               %{},
               [],
               fun
             )
  end
end
