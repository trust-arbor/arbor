defmodule Arbor.Security.InvocationAuditOutcomeSecurityRegressionTest do
  @moduledoc """
  Security regression (D5 follow-up, 2026-09-27): the durable outcome of a tool
  invocation read "refused" for every error. A tool frame never admits an
  effect itself (the nested action frame does, and its admission vanished when
  it finished), so a tool call whose action ran, crashed or timed out was
  recorded as if nothing had run.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Tool.CallFailure
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression

  defmodule Sink do
    @moduledoc false
    def persist_security_invocation(event) do
      send(Application.fetch_env!(:arbor_security, :outcome_audit_test_owner), {:audit, event})
      {:ok, event["id"]}
    end
  end

  setup do
    keys = [:invocation_audit_mode, :invocation_audit_sink, :outcome_audit_test_owner]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_security, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_security, :invocation_audit_sink, Sink)
    Application.put_env(:arbor_security, :outcome_audit_test_owner, self())
    :ok
  end

  describe "tool surface" do
    test "security regression: a tool call whose nested action admitted an effect never reads refused" do
      assert {:error, :opaque} =
               audited(:tool, fn ->
                 {:error, :disk_full} = admitted_action({:error, :disk_full})
                 {:error, :opaque}
               end)

      assert outcomes() == %{"action" => "failed", "tool" => "failed"}
    end

    test "security regression: admission outranks a CallFailure that claims refusal" do
      audited(:tool, fn ->
        admitted_action({:error, :disk_full})
        {:error, failure(:refused)}
      end)

      assert outcomes()["tool"] == "failed"
    end

    test "security regression: an unclassified tool error without admission is unknown, not refused" do
      audited(:tool, fn -> {:error, "executor said no"} end)
      assert outcomes() == %{"tool" => "unknown"}
    end

    test "security regression: a classified tool failure is recorded with its own outcome" do
      for outcome <- CallFailure.outcomes() do
        audited(:tool, fn -> {:error, failure(outcome)} end)
        assert outcomes() == %{"tool" => Atom.to_string(outcome)}, inspect(outcome)
      end
    end

    test "a successful tool call is completed and later calls start from a clean frame" do
      audited(:tool, fn -> {:ok, admitted_action({:ok, :done})} end)
      assert outcomes() == %{"action" => "completed", "tool" => "completed"}

      audited(:tool, fn -> {:error, failure(:refused)} end)
      assert outcomes() == %{"tool" => "refused"}
    end
  end

  describe "admitting surfaces keep their own proof" do
    test "an error before admission is still refused" do
      audited(:action, fn -> {:error, :unauthorized} end)
      assert outcomes() == %{"action" => "refused"}
    end

    test "an admitted error is failed; an admitted timeout is unknown" do
      admitted_action({:error, :bad_input})
      assert outcomes() == %{"action" => "failed"}

      admitted_action({:error, {:http_error, :timeout}})
      assert outcomes() == %{"action" => "unknown"}
    end
  end

  defp audited(surface, fun) do
    Security.with_invocation_audit(%{principal_id: "agent_outcome_audit", surface: surface}, fun)
  end

  defp admitted_action(result) do
    audited(:action, fn ->
      :ok = Security.admit_invocation_effect()
      result
    end)
  end

  defp failure(outcome), do: CallFailure.new!(outcome: outcome, message: "m", tool: "t")

  # Terminal outcome per surface for every invocation recorded since the last call.
  defp outcomes(acc \\ %{}) do
    receive do
      {:audit, %{"stage" => "outcome", "surface" => surface, "outcome" => outcome}} ->
        outcomes(Map.put(acc, surface, outcome))

      {:audit, _other_stage} ->
        outcomes(acc)
    after
      0 -> acc
    end
  end
end
