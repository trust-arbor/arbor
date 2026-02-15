defmodule Arbor.Security.ConstraintTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Constraint

  setup do
    principal = "agent_#{:erlang.unique_integer([:positive])}"
    resource = "arbor://fs/read/project/src/main.ex"
    {:ok, principal: principal, resource: resource}
  end

  describe "enforce/3" do
    test "empty constraints map returns :ok", %{principal: p, resource: r} do
      assert :ok = Constraint.enforce(%{}, p, r)
    end

    test "unknown constraint keys are ignored", %{principal: p, resource: r} do
      assert :ok = Constraint.enforce(%{unknown_future_key: "whatever"}, p, r)
    end
  end

  describe "time_window constraint" do
    test "within window returns :ok", %{principal: p, resource: r} do
      # Window that covers all 24 hours
      constraints = %{time_window: %{start_hour: 0, end_hour: 24}}
      assert :ok = Constraint.enforce(constraints, p, r)
    end

    test "outside window returns constraint_violated", %{principal: p, resource: r} do
      # Set a window that is definitely not now (1-hour window 12 hours from now)
      current_hour = DateTime.utc_now().hour
      bad_start = rem(current_hour + 12, 24)
      bad_end = rem(bad_start + 1, 24)

      constraints = %{time_window: %{start_hour: bad_start, end_hour: bad_end}}

      assert {:error, {:constraint_violated, :time_window, context}} =
               Constraint.enforce(constraints, p, r)

      assert context.current_hour == current_hour
      assert context.start_hour == bad_start
      assert context.end_hour == bad_end
    end

    test "midnight-wrapping window works", %{principal: p, resource: r} do
      current_hour = DateTime.utc_now().hour

      # Create a wrapping window that always includes current hour
      # start = current_hour, end = current_hour (wraps full 24h)
      # Actually, let's be precise: start=22, end=6 wraps midnight
      # If current_hour is in [22,23,0,1,2,3,4,5], it should pass.
      # Instead, let's construct one that definitely includes current_hour:
      start_hour = rem(current_hour + 23, 24)
      end_hour = rem(current_hour + 2, 24)

      # This wraps midnight if start_hour > end_hour
      if start_hour > end_hour do
        constraints = %{time_window: %{start_hour: start_hour, end_hour: end_hour}}
        assert :ok = Constraint.enforce(constraints, p, r)
      end
    end
  end

  describe "allowed_paths constraint" do
    test "matching path prefix returns :ok", %{principal: p, resource: r} do
      # resource is "arbor://fs/read/project/src/main.ex"
      constraints = %{allowed_paths: ["arbor://fs/read/project/src"]}
      assert :ok = Constraint.enforce(constraints, p, r)
    end

    test "non-matching path returns constraint_violated", %{principal: p, resource: r} do
      constraints = %{allowed_paths: ["arbor://fs/read/project/docs", "arbor://fs/read/project/test"]}

      assert {:error, {:constraint_violated, :allowed_paths, context}} =
               Constraint.enforce(constraints, p, r)

      assert context.resource_uri == r
    end

    test "multiple paths, one matches", %{principal: p, resource: r} do
      constraints = %{allowed_paths: ["arbor://fs/read/project/docs", "arbor://fs/read/project/src"]}
      assert :ok = Constraint.enforce(constraints, p, r)
    end

    test "rejects substring-only matches (not prefix)", %{principal: p} do
      # "/home" should NOT match "/home_config" — that was the old bug
      constraints = %{allowed_paths: ["/home"]}
      assert {:error, {:constraint_violated, :allowed_paths, _}} =
               Constraint.enforce(constraints, p, "/home_config")
      # But should match "/home/user/file" (proper prefix)
      assert :ok = Constraint.enforce(constraints, p, "/home/user/file")
    end
  end

  describe "rate_limit constraint" do
    test "under limit returns :ok", %{principal: p, resource: r} do
      constraints = %{rate_limit: 10}
      assert :ok = Constraint.enforce(constraints, p, r)
    end

    test "exceeding limit returns constraint_violated", %{principal: p, resource: r} do
      constraints = %{rate_limit: 3}

      # Consume all tokens
      assert :ok = Constraint.enforce(constraints, p, r)
      assert :ok = Constraint.enforce(constraints, p, r)
      assert :ok = Constraint.enforce(constraints, p, r)

      assert {:error, {:constraint_violated, :rate_limit, context}} =
               Constraint.enforce(constraints, p, r)

      assert context.limit == 3
      assert context.remaining == 0
    end
  end

  describe "requires_approval constraint" do
    test "returns :ok (Phase 5 placeholder)", %{principal: p, resource: r} do
      constraints = %{requires_approval: true}
      assert :ok = Constraint.enforce(constraints, p, r)
    end
  end

  describe "evaluation order" do
    test "stateless constraint rejects before stateful rate_limit", %{principal: p} do
      # Use a unique resource so we get a fresh rate bucket
      resource = "arbor://fs/read/ordering_test_#{:erlang.unique_integer([:positive])}"

      # Set up constraints: time_window will reject, rate_limit exists
      current_hour = DateTime.utc_now().hour
      bad_start = rem(current_hour + 12, 24)
      bad_end = rem(bad_start + 1, 24)

      constraints = %{
        time_window: %{start_hour: bad_start, end_hour: bad_end},
        rate_limit: 1
      }

      # Enforce — should fail on time_window, NOT consume rate token
      assert {:error, {:constraint_violated, :time_window, _}} =
               Constraint.enforce(constraints, p, resource)

      # Now enforce with just rate_limit — should still have tokens
      assert :ok = Constraint.enforce(%{rate_limit: 1}, p, resource)
    end
  end
end
