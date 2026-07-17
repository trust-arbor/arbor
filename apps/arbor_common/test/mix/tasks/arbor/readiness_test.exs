defmodule Mix.Tasks.Arbor.ReadinessTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Mix.Tasks.Arbor.Readiness

  describe "expected_umbrella_apps/1" do
    test "derives a sorted atom list from apps_paths keys" do
      paths = %{
        arbor_web: "apps/arbor_web",
        arbor_common: "apps/arbor_common",
        arbor_gateway: "apps/arbor_gateway"
      }

      assert Readiness.expected_umbrella_apps(paths) == [
               :arbor_common,
               :arbor_gateway,
               :arbor_web
             ]
    end

    test "returns empty list for nil (non-umbrella project)" do
      assert Readiness.expected_umbrella_apps(nil) == []
    end

    test "returns empty list for empty map" do
      assert Readiness.expected_umbrella_apps(%{}) == []
    end

    test "does not hard-code arbor apps — arbitrary keys are preserved" do
      paths = %{zeta_app: "apps/zeta", alpha_app: "apps/alpha"}
      assert Readiness.expected_umbrella_apps(paths) == [:alpha_app, :zeta_app]
    end
  end

  describe "started_application_names/1" do
    test "extracts atoms from which_applications tuples" do
      which = [
        {:kernel, ~c"ERTS  CXC 138 10", ~c"10.0"},
        {:arbor_common, ~c"Arbor Common", ~c"0.1.0"},
        {:stdlib, ~c"ERTS  CXC 138 10", ~c"5.0"}
      ]

      names = Readiness.started_application_names(which)
      assert MapSet.member?(names, :arbor_common)
      assert MapSet.member?(names, :kernel)
      refute MapSet.member?(names, :arbor_gateway)
    end

    test "returns empty set for non-list observations" do
      assert Readiness.started_application_names(:not_a_list) == MapSet.new()
      assert Readiness.started_application_names(nil) == MapSet.new()
    end
  end

  describe "classify_observation/2" do
    @expected [:arbor_common, :arbor_gateway, :arbor_web]

    test "complete observation is ready" do
      which = [
        {:arbor_common, ~c"", ~c"0.1.0"},
        {:arbor_gateway, ~c"", ~c"0.1.0"},
        {:arbor_web, ~c"", ~c"0.1.0"},
        {:kernel, ~c"", ~c"10.0"}
      ]

      assert Readiness.classify_observation(@expected, {:ok, which}) == :ready
    end

    test "partial observation lists missing and present apps" do
      which = [
        {:arbor_common, ~c"", ~c"0.1.0"},
        {:kernel, ~c"", ~c"10.0"}
      ]

      assert Readiness.classify_observation(@expected, {:ok, which}) ==
               {:partial, [:arbor_gateway, :arbor_web], [:arbor_common]}
    end

    test "empty expected set with successful observation is ready" do
      which = [{:kernel, ~c"", ~c"10.0"}]
      assert Readiness.classify_observation([], {:ok, which}) == :ready
    end

    test "failed RPC observation is unavailable" do
      assert Readiness.classify_observation(@expected, {:error, {:badrpc, :nodedown}}) ==
               {:observation_unavailable, {:badrpc, :nodedown}}
    end

    test "timed-out RPC observation is unavailable" do
      assert Readiness.classify_observation(@expected, {:error, {:badrpc, :timeout}}) ==
               {:observation_unavailable, {:badrpc, :timeout}}
    end

    test "invalid which_applications payload is unavailable" do
      assert Readiness.classify_observation(@expected, {:ok, :not_a_list}) ==
               {:observation_unavailable, :invalid_which_applications}
    end
  end

  describe "remaining_ms/2 and rpc_timeout_ms/2" do
    test "remaining_ms never goes negative" do
      assert Readiness.remaining_ms(100, 50) == 50
      assert Readiness.remaining_ms(100, 100) == 0
      assert Readiness.remaining_ms(100, 150) == 0
    end

    test "rpc_timeout_ms clamps to remaining budget and max ceiling" do
      assert Readiness.rpc_timeout_ms(30_000, 5_000) == 5_000
      assert Readiness.rpc_timeout_ms(1_200, 5_000) == 1_200
      assert Readiness.rpc_timeout_ms(0, 5_000) == 0
    end
  end

  describe "poll_decision/3" do
    test "ready result is done regardless of remaining time" do
      assert Readiness.poll_decision(10_000, 0, :ready) == :done_ready
      assert Readiness.poll_decision(10_000, 9_999, :ready) == :done_ready
    end

    test "exhausted deadline returns done_timeout with last result" do
      partial = {:partial, [:arbor_web], [:arbor_common]}

      assert Readiness.poll_decision(1_000, 1_000, partial) == {:done_timeout, partial}
      assert Readiness.poll_decision(1_000, 1_500, partial) == {:done_timeout, partial}

      assert Readiness.poll_decision(1_000, 1_000, :no_observation) ==
               {:done_timeout, :no_observation}

      unavailable = {:observation_unavailable, {:badrpc, :timeout}}

      assert Readiness.poll_decision(500, 600, unavailable) ==
               {:done_timeout, unavailable}
    end

    test "positive remaining continues with remaining budget" do
      partial = {:partial, [:arbor_gateway], [:arbor_common]}
      assert Readiness.poll_decision(5_000, 3_000, partial) == {:continue, 2_000}
      assert Readiness.poll_decision(5_000, 4_999, :no_observation) == {:continue, 1}
    end

    test "slow RPC cannot exceed absolute deadline after classification" do
      # Simulate: deadline 10_000, wall clock advanced past deadline by a slow RPC
      # that started with remaining budget. Decision after return must timeout.
      deadline = 10_000
      now_after_slow_rpc = 12_500
      last = {:partial, [:arbor_dashboard], [:arbor_common]}

      assert Readiness.poll_decision(deadline, now_after_slow_rpc, last) ==
               {:done_timeout, last}
    end
  end

  describe "sleep_ms/2" do
    test "never sleeps past remaining budget" do
      assert Readiness.sleep_ms(500, 500) == 500
      assert Readiness.sleep_ms(120, 500) == 120
      assert Readiness.sleep_ms(0, 500) == 0
    end
  end

  describe "timeout_diagnostic/3" do
    @expected [:arbor_common, :arbor_gateway]

    test "distinguishes unreachable node" do
      msg = Readiness.timeout_diagnostic(:node_unreachable, @expected, 15_000)
      assert msg =~ "did not become reachable"
      assert msg =~ "15 seconds"
      refute msg =~ "Missing:"
    end

    test "distinguishes partially started apps" do
      msg =
        Readiness.timeout_diagnostic(
          {:partial, [:arbor_gateway], [:arbor_common]},
          @expected,
          600_000
        )

      assert msg =~ "applications did not all start"
      assert msg =~ "600 seconds"
      assert msg =~ "Missing:"
      assert msg =~ "arbor_gateway"
    end

    test "distinguishes unavailable RPC observation" do
      msg =
        Readiness.timeout_diagnostic(
          {:observation_unavailable, {:badrpc, :timeout}},
          @expected,
          600_000
        )

      assert msg =~ "could not be observed"
      assert msg =~ "RPC observation unavailable"
      assert msg =~ ":timeout"
    end
  end

  describe "status_label/1" do
    test "ready is fully running" do
      assert Readiness.status_label(:ready) == "running (applications ready)"
    end

    test "partial is not labeled fully running/ready" do
      label = Readiness.status_label({:partial, [:arbor_gateway], [:arbor_common]})
      assert label =~ "reachable"
      assert label =~ "starting"
      assert label =~ "arbor_gateway"
      refute label =~ "applications ready"
      refute label == "running"
    end

    test "observation unavailable is not labeled fully running" do
      label = Readiness.status_label({:observation_unavailable, {:badrpc, :timeout}})
      assert label =~ "reachable"
      assert label =~ "unavailable"
      refute label =~ "applications ready"
    end
  end

  describe "status_missing_label/1" do
    test "ready reports none missing" do
      assert Readiness.status_missing_label(:ready) == "none"
    end

    test "partial reports the missing app names" do
      assert Readiness.status_missing_label(
               {:partial, [:arbor_gateway, :arbor_web], [:arbor_common]}
             ) == "arbor_gateway, arbor_web"
    end

    test "partial with empty missing list reports none" do
      assert Readiness.status_missing_label({:partial, [], [:arbor_common]}) == "none"
    end

    test "observation unavailable reports unknown, not none" do
      # Regression: status used to format an empty missing list as "none", which
      # falsely implied every expected app was present when RPC observation failed.
      assert Readiness.status_missing_label({:observation_unavailable, {:badrpc, :timeout}}) ==
               "unknown"

      assert Readiness.status_missing_label(
               {:observation_unavailable, :invalid_which_applications}
             ) == "unknown"

      refute Readiness.status_missing_label({:observation_unavailable, {:badrpc, :nodedown}}) ==
               "none"
    end
  end
end
