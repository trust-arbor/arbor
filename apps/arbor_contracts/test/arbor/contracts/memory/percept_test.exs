defmodule Arbor.Contracts.Memory.PerceptTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Memory.Percept

  describe "new/3" do
    test "creates a percept with required fields" do
      percept = Percept.new(:action_result, :success)

      assert percept.type == :action_result
      assert percept.outcome == :success
      assert String.starts_with?(percept.id, "prc_")
      assert %DateTime{} = percept.created_at
    end

    test "accepts optional fields" do
      percept =
        Percept.new(:action_result, :success,
          intent_id: "int_123",
          data: %{output: "hello"},
          duration_ms: 100
        )

      assert percept.intent_id == "int_123"
      assert percept.data == %{output: "hello"}
      assert percept.duration_ms == 100
    end
  end

  describe "success/3" do
    test "creates a success percept" do
      percept = Percept.success("int_abc", %{result: 42})

      assert percept.type == :action_result
      assert percept.outcome == :success
      assert percept.intent_id == "int_abc"
      assert percept.data == %{result: 42}
    end

    test "works without arguments" do
      percept = Percept.success()

      assert percept.type == :action_result
      assert percept.outcome == :success
      assert percept.intent_id == nil
    end
  end

  describe "failure/3" do
    test "creates a failure percept" do
      percept = Percept.failure("int_xyz", :command_failed)

      assert percept.type == :action_result
      assert percept.outcome == :failure
      assert percept.intent_id == "int_xyz"
      assert percept.error == :command_failed
    end
  end

  describe "blocked/3" do
    test "creates a blocked percept" do
      percept = Percept.blocked("int_123", "Capability denied")

      assert percept.type == :action_result
      assert percept.outcome == :blocked
      assert percept.data.reason == "Capability denied"
    end
  end

  describe "timeout/3" do
    test "creates a timeout percept" do
      percept = Percept.timeout("int_456", 30_000)

      assert percept.type == :timeout
      assert percept.outcome == :failure
      assert percept.duration_ms == 30_000
      assert percept.error == :timeout
    end
  end

  describe "success?/1" do
    test "returns true for success outcome" do
      percept = Percept.success()
      assert Percept.success?(percept)
    end

    test "returns false for failure outcome" do
      percept = Percept.failure()
      refute Percept.success?(percept)
    end

    test "returns false for blocked outcome" do
      percept = Percept.blocked(nil, "denied")
      refute Percept.success?(percept)
    end
  end

  describe "failed?/1" do
    test "returns true for failure outcome" do
      percept = Percept.failure()
      assert Percept.failed?(percept)
    end

    test "returns true for blocked outcome" do
      percept = Percept.blocked(nil, "denied")
      assert Percept.failed?(percept)
    end

    test "returns true for interrupted outcome" do
      percept = Percept.new(:interrupt, :interrupted)
      assert Percept.failed?(percept)
    end

    test "returns false for success outcome" do
      percept = Percept.success()
      refute Percept.failed?(percept)
    end

    test "returns false for partial outcome" do
      percept = Percept.new(:action_result, :partial)
      refute Percept.failed?(percept)
    end
  end

  describe "percept types" do
    test "supports all percept types" do
      for type <- [:action_result, :environment, :interrupt, :error, :timeout] do
        percept = Percept.new(type, :success)
        assert percept.type == type
      end
    end
  end

  describe "outcome types" do
    test "supports all outcomes" do
      for outcome <- [:success, :failure, :partial, :blocked, :interrupted] do
        percept = Percept.new(:action_result, outcome)
        assert percept.outcome == outcome
      end
    end
  end

  describe "Jason encoding" do
    test "encodes percept to JSON" do
      percept = Percept.success("int_test", %{value: 123}, duration_ms: 500)
      json = Jason.encode!(percept)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "action_result"
      assert decoded["outcome"] == "success"
      assert decoded["intent_id"] == "int_test"
      assert decoded["data"] == %{"value" => 123}
      assert decoded["duration_ms"] == 500
    end

    test "encodes atom error" do
      percept = Percept.failure(nil, :timeout)
      json = Jason.encode!(percept)
      decoded = Jason.decode!(json)

      assert decoded["error"] == "timeout"
    end

    test "encodes string error" do
      percept = Percept.failure(nil, "Something went wrong")
      json = Jason.encode!(percept)
      decoded = Jason.decode!(json)

      assert decoded["error"] == "Something went wrong"
    end
  end
end
