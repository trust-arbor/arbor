defmodule Arbor.Agent.Orchestration.ApprovalInventoryProjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Orchestration

  @moduletag :fast
  @timestamp ~U[2026-07-22 12:00:00Z]

  defmodule Security do
    def authorize(actor, resource, action, opts) do
      send(self(), {:authorized, actor, resource, action, opts})
      Process.get({__MODULE__, :result}, {:ok, :authorized})
    end
  end

  defmodule Consensus do
    def list_pending, do: Process.get({__MODULE__, :pending}, [])
  end

  defmodule Comms do
    def pending_interactions, do: Process.get({__MODULE__, :pending}, [])
  end

  setup do
    Process.delete({Security, :result})
    Process.delete({Consensus, :pending})
    Process.delete({Comms, :pending})
    :ok
  end

  test "requires approval read authorization" do
    Process.put({Security, :result}, {:error, :missing_capability})

    assert {:error, {:unauthorized, :missing_capability}} =
             inventory(caller_id: "operator", security_module: Security)
  end

  test "projects bounded redacted ownership evidence deterministically" do
    secret = "approval-secret-must-not-cross-the-boundary"

    Process.put(
      {Consensus, :pending},
      [
        consensus("z-approval", "agent-z", "task-z",
          description: secret,
          context: %{secret: secret}
        ),
        consensus("a-approval", "agent-a", "task-a",
          metadata: %{approval_context: %{provenance: %{task_id: "task-a"}}},
          context: %{secret: secret}
        ),
        consensus("a-approval", "agent-a", "task-a"),
        %{
          topic: :authorization_request,
          id: "malformed",
          proposer: "agent-a",
          created_at: self()
        },
        %{topic: :code_modification, id: "ignored"}
      ]
    )

    Process.put(
      {Comms, :pending},
      [
        interaction("b-approval", "agent-b", "task-b", "human-b",
          metadata: %{approval_context: %{provenance: %{task_id: "task-b"}}, secret: secret}
        )
      ]
    )

    opts = [
      caller_id: "operator",
      consensus_module: Consensus,
      interaction_router: Comms,
      security_module: Security,
      max_items: 2
    ]

    assert {:ok, first} = Orchestration.pending_approval_inventory(opts)
    assert {:ok, second} = Orchestration.pending_approval_inventory(opts)
    assert first == second

    assert Enum.map(first["approvals"], & &1["approval_id"]) == ["a-approval", "b-approval"]
    assert Enum.at(first["approvals"], 0)["task_id"] == "task-a"
    assert first["counts"]["observed"] == 6
    assert first["counts"]["matching"] == 3
    assert first["counts"]["returned"] == 2
    assert first["counts"]["truncated"] == 1
    assert first["counts"]["duplicates"] == 1
    assert first["counts"]["malformed"] == 1
    assert first["counts"]["ignored"] == 1
    assert first["counts"]["quarantined"] == 2
    assert first["truncated"] == true

    assert first["storage"] == %{
             "durability" => "volatile",
             "authority" => "approval_backends",
             "read_only" => true
           }

    assert first["backend_counts"]["consensus"]["observed"] == 5
    assert first["backend_counts"]["interaction"]["observed"] == 1
    refute String.contains?(Jason.encode!(first), secret)
    assert {:ok, _} = Jason.encode(first)
  end

  test "filters by exact task id and segment-aware resource prefix" do
    Process.put(
      {Consensus, :pending},
      [
        consensus("approval-one", "agent-a", "task-one", "arbor://fs/read/repo/file.ex"),
        consensus(
          "approval-one-extra",
          "agent-a",
          "task-one-extra",
          "arbor://fs/read/repo/file.ex"
        ),
        consensus("approval-two", "agent-a", "task-two", "arbor://fs/reader/repo/file.ex")
      ]
    )

    assert {:ok, inventory} =
             inventory(
               caller_id: "operator",
               consensus_module: Consensus,
               interaction_router: Comms,
               security_module: Security,
               task_id: "task-one",
               resource_uri: "arbor://fs/read"
             )

    assert Enum.map(inventory["approvals"], & &1["approval_id"]) == ["approval-one"]
    assert inventory["filters"]["task_id"] == "task-one"
  end

  test "backend overrun is explicitly bounded" do
    Process.put(
      {Consensus, :pending},
      Enum.map(1..1_001, &consensus("approval-#{&1}", "agent-a", nil))
    )

    assert {:ok, inventory} =
             inventory(
               caller_id: "operator",
               consensus_module: Consensus,
               interaction_router: Comms,
               security_module: Security
             )

    assert inventory["backend_counts"]["consensus"]["observed"] == 1_000
    assert inventory["backend_counts"]["consensus"]["omitted"] == 1
    assert inventory["counts"]["backend_omitted"] == 1
    assert inventory["truncated"] == true
    assert length(inventory["approvals"]) == 64
  end

  test "legacy pending approval list remains the rich compatibility view" do
    Process.put(
      {Consensus, :pending},
      [consensus("legacy-approval", "agent-a", "task-a", description: "human-readable")]
    )

    assert {:ok, [approval]} =
             Orchestration.list_pending_approvals(
               authorize?: false,
               consensus_module: Consensus,
               interaction_router: Comms
             )

    assert approval.id == "legacy-approval"
    assert approval.description == "human-readable"
    assert approval.metadata[:task_id] == "task-a"
  end

  defp inventory(opts) do
    Orchestration.pending_approval_inventory(opts)
  end

  defp consensus(id, agent_id, task_id),
    do: consensus(id, agent_id, task_id, "arbor://fs/read/repo/file.ex", [])

  defp consensus(id, agent_id, task_id, opts) when is_list(opts),
    do: consensus(id, agent_id, task_id, "arbor://fs/read/repo/file.ex", opts)

  defp consensus(id, agent_id, task_id, resource_uri) when is_binary(resource_uri),
    do: consensus(id, agent_id, task_id, resource_uri, [])

  defp consensus(id, agent_id, task_id, resource_uri, opts) do
    metadata =
      %{principal_id: agent_id, resource_uri: resource_uri}
      |> maybe_put_task_id(task_id)
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    %{
      id: id,
      proposer: agent_id,
      topic: :authorization_request,
      description: Keyword.get(opts, :description, "description"),
      metadata: metadata,
      context: Keyword.get(opts, :context, %{}),
      status: :pending,
      created_at: @timestamp
    }
  end

  defp interaction(id, agent_id, task_id, user_id, opts) do
    metadata =
      %{principal_id: agent_id}
      |> maybe_put_task_id(task_id)
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    %{
      request_id: id,
      kind: :approval,
      agent_id: agent_id,
      user_id: user_id,
      description: Keyword.get(opts, :description, "description"),
      resource_uri: Keyword.get(opts, :resource_uri, "arbor://shell/exec/git"),
      metadata: metadata,
      submitted_at: @timestamp
    }
  end

  defp maybe_put_task_id(metadata, nil), do: metadata
  defp maybe_put_task_id(metadata, task_id), do: Map.put(metadata, :task_id, task_id)
end
