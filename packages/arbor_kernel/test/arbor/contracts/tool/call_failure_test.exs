defmodule Arbor.Contracts.Tool.CallFailureTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Tool.CallFailure

  @moduletag :fast

  describe "new/1" do
    test "builds a failure from keyword or map attributes" do
      assert {:ok, %CallFailure{outcome: :unknown, message: "m", tool: "t", idempotency: nil}} =
               CallFailure.new(outcome: :unknown, message: "m", tool: "t")

      assert {:ok, %CallFailure{outcome: :refused, idempotency: :read_only}} =
               CallFailure.new(%{outcome: :refused, message: "m", idempotency: :read_only})
    end

    test "rejects an outcome outside the taxonomy, a non-string message, and bad optional fields" do
      assert {:error, {:invalid_call_failure, :outcome}} =
               CallFailure.new(outcome: :maybe, message: "m")

      assert {:error, {:invalid_call_failure, :message}} =
               CallFailure.new(outcome: :failed, message: :oops)

      assert {:error, {:invalid_call_failure, :tool}} =
               CallFailure.new(outcome: :failed, message: "m", tool: :atom)

      assert {:error, {:invalid_call_failure, :idempotency}} =
               CallFailure.new(outcome: :failed, message: "m", idempotency: :sometimes)

      assert {:error, {:invalid_call_failure, :attrs}} = CallFailure.new("nope")
      assert_raise ArgumentError, fn -> CallFailure.new!(outcome: :maybe, message: "m") end
    end

    test "outcomes/0 is the closed taxonomy" do
      assert CallFailure.outcomes() == [:refused, :not_sent, :failed, :unknown]
    end
  end

  describe "indeterminate_effect?/1" do
    test "an unknown outcome is indeterminate unless the tool is declared safe to repeat" do
      for class <- [nil, :side_effecting, :idempotent_with_key] do
        assert CallFailure.indeterminate_effect?(failure(:unknown, class)), inspect(class)
      end

      for class <- [:read_only, :idempotent] do
        refute CallFailure.indeterminate_effect?(failure(:unknown, class)), inspect(class)
      end
    end

    test "refused, not-sent and failed calls are never indeterminate" do
      for outcome <- [:refused, :not_sent, :failed] do
        refute CallFailure.indeterminate_effect?(failure(outcome, :side_effecting))
      end
    end
  end

  describe "timeout_reason?/1" do
    test "recognizes timeout term shapes, including wrapped ones" do
      for reason <- [
            :timeout,
            :etimedout,
            {:timeout, {GenServer, :call, []}},
            {:http_error, :timeout},
            %{reason: :timeout},
            {:transport, %{reason: :etimedout}}
          ] do
        assert CallFailure.timeout_reason?(reason), inspect(reason)
      end
    end

    test "never matches message text or unrelated reasons" do
      for reason <- [
            "timed out after 30s",
            :bad_input,
            {:unauthorized, "timeout"},
            {:a, {:b, {:c, {:d, {:e, :timeout}}}}}
          ] do
        refute CallFailure.timeout_reason?(reason), inspect(reason)
      end
    end
  end

  describe "describe/1" do
    test "states that refused and unsent calls were not carried out" do
      assert CallFailure.describe(failure(:refused, nil)) =~ "was not carried out"
      assert CallFailure.describe(failure(:not_sent, nil)) =~ "was not carried out"
    end

    test "tells the caller an indeterminate call may have taken effect and will not be retried" do
      text = CallFailure.describe(failure(:unknown, :side_effecting))
      assert text =~ "may have taken effect"
      assert text =~ "will not be retried automatically"
    end

    test "a repeat-safe unknown call and a failed call add no effect warning" do
      refute CallFailure.describe(failure(:unknown, :read_only)) =~ "may have taken effect"
      assert CallFailure.describe(failure(:failed, nil)) == "boom"
    end
  end

  defp failure(outcome, idempotency) do
    CallFailure.new!(outcome: outcome, message: "boom", idempotency: idempotency)
  end
end
