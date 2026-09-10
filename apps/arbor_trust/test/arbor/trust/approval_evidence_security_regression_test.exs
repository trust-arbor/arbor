defmodule Arbor.Trust.ApprovalEvidenceSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust
  alias Arbor.Trust.ConfirmationTracker

  @moduletag :fast
  @prefix "arbor://code/write"

  defmodule Source do
    @behaviour Arbor.Trust.Contracts.ApprovalEvidenceProvider

    def answered_approval(source, id) do
      Agent.get(__MODULE__, fn rows ->
        case Map.fetch(rows, {source, id}) do
          {:ok, row} -> {:ok, row}
          :error -> {:error, :approval_evidence_unavailable}
        end
      end)
    end
  end

  setup do
    pid = start_supervised!({Agent, fn -> %{} end}, id: Source)
    # Give the source test process a fixed name; its rows are a controlled
    # authority fixture. Consumer integration tests use real Comms/Consensus.
    Process.register(pid, Source)
    start_supervised!(ConfirmationTracker)
    previous = Application.fetch_env(:arbor_trust, :approval_evidence_provider)
    Application.put_env(:arbor_trust, :approval_evidence_provider, Source)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_trust, :approval_evidence_provider, value)
        :error -> Application.delete_env(:arbor_trust, :approval_evidence_provider)
      end
    end)

    %{agent_id: "agent_confirmation_#{System.unique_integer([:positive])}"}
  end

  test "security regression: unknown answers increment once without human graduation", ctx do
    for index <- 1..5 do
      {id, expected} = committed!(ctx.agent_id, "approval_#{index}", :approve)
      assert {:ok, :recorded} = Trust.record_approval_answer(:interaction, id, expected)
      assert {:ok, :duplicate} = Trust.record_approval_answer(:interaction, id, expected)
    end

    status = Trust.confirmation_status(ctx.agent_id, @prefix)
    assert status.approvals == 5
    assert status.streak == 5
    assert status.unknown_approvals == 5
    assert status.verified_human_approvals == 0
    assert status.human_streak == 0
    refute Trust.graduated?(ctx.agent_id, @prefix)
  end

  test "security regression: caller scope and human flags cannot manufacture evidence", ctx do
    {id, expected} = committed!(ctx.agent_id, "scope", :approve)

    for {key, forged} <- [
          agent_id: "agent_other",
          principal_id: "agent_other",
          resource_uri: "arbor://code/write/elsewhere",
          decision: :deny
        ] do
      assert {:error, :approval_evidence_mismatch} =
               Trust.record_approval_answer(:interaction, id, Map.put(expected, key, forged))
    end

    for key <- [:human, :verified_human, :responder, :actor, :session_token] do
      assert {:error, :invalid_approval_evidence} =
               Trust.record_approval_answer(:interaction, id, Map.put(expected, key, true))
    end

    assert Trust.confirmation_status(ctx.agent_id, @prefix).approvals == 0
  end

  test "security regression: source mutation cannot reuse an already counted request", ctx do
    {id, expected} = committed!(ctx.agent_id, "immutable", :approve)
    assert {:ok, :recorded} = Trust.record_approval_answer(:interaction, id, expected)
    {_id, changed} = committed!(ctx.agent_id, id, :deny)

    assert {:error, :approval_evidence_mismatch} =
             Trust.record_approval_answer(:interaction, id, changed)

    status = Trust.confirmation_status(ctx.agent_id, @prefix)
    assert status.approvals == 1
    assert status.rejections == 0
  end

  test "rejection and rework reset the streak; duplicate replay after reset stays inert", ctx do
    {approved_id, approved} = committed!(ctx.agent_id, "approved", :approve)
    assert {:ok, :recorded} = Trust.record_approval_answer(:interaction, approved_id, approved)

    for decision <- [:deny, :rework] do
      {id, expected} = committed!(ctx.agent_id, Atom.to_string(decision), decision)
      assert {:ok, :recorded} = Trust.record_approval_answer(:interaction, id, expected)
      assert Trust.confirmation_status(ctx.agent_id, @prefix).streak == 0
    end

    assert Trust.confirmation_status(ctx.agent_id, @prefix).unknown_rejections == 2
    assert :ok = ConfirmationTracker.reset(ctx.agent_id)
    assert {:ok, :duplicate} = Trust.record_approval_answer(:interaction, approved_id, approved)
    assert Trust.confirmation_status(ctx.agent_id, @prefix).approvals == 0
  end

  test "missing or unavailable source refuses caller-authored approvals", ctx do
    expected = scope(ctx.agent_id, :approve)

    assert {:error, :approval_evidence_unavailable} =
             Trust.record_approval_answer(:interaction, "pending", expected)

    Application.put_env(:arbor_trust, :approval_evidence_provider, nil)

    assert {:error, :approval_evidence_unavailable} =
             Trust.record_approval_answer(:interaction, "pending", expected)

    assert Trust.confirmation_status(ctx.agent_id, @prefix).approvals == 0
  end

  defp committed!(agent_id, id, decision) do
    expected = scope(agent_id, decision)
    row = Map.merge(expected, %{source: :interaction, request_id: id})
    Agent.update(Source, &Map.put(&1, {:interaction, id}, row))
    {id, expected}
  end

  defp scope(agent_id, decision) do
    %{
      agent_id: agent_id,
      principal_id: agent_id,
      resource_uri: @prefix <> "/exact/file.ex",
      decision: decision
    }
  end
end
