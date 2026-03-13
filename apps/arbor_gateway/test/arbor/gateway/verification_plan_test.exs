defmodule Arbor.Gateway.VerificationPlanTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Gateway.VerificationPlan

  @sample_intent %{
    goal: "Deploy app to staging",
    success_criteria: [
      "HTTP 200 at https://staging.example.com/health",
      "config/staging.exs exists"
    ],
    constraints: [
      "Don't modify config/prod.exs"
    ],
    resources: ["config/staging.exs"],
    risk_level: :medium
  }

  describe "from_intent/1" do
    test "generates checks from success criteria" do
      plan = VerificationPlan.from_intent(@sample_intent)

      assert is_list(plan.checks)
      assert length(plan.checks) >= 2

      types = Enum.map(plan.checks, & &1.type)
      assert :http in types
    end

    test "generates file_unchanged checks from constraints" do
      plan = VerificationPlan.from_intent(@sample_intent)

      unchanged = Enum.filter(plan.checks, &(&1.type == :file_unchanged))
      assert length(unchanged) >= 1
      assert hd(unchanged).params.path =~ "config/prod.exs"
    end

    test "captures risk level" do
      plan = VerificationPlan.from_intent(@sample_intent)
      assert plan.risk_level == :medium
    end

    test "derives rollback hint for medium risk" do
      plan = VerificationPlan.from_intent(@sample_intent)
      assert plan.rollback_hint =~ "Review"
    end

    test "derives git rollback hint for high risk with resources" do
      intent = %{@sample_intent | risk_level: :high}
      plan = VerificationPlan.from_intent(intent)
      assert plan.rollback_hint =~ "git checkout"
    end

    test "no rollback hint for low risk" do
      intent = %{@sample_intent | risk_level: :low}
      plan = VerificationPlan.from_intent(intent)
      assert plan.rollback_hint == nil
    end

    test "handles empty intent" do
      plan = VerificationPlan.from_intent(%{})
      assert plan.checks == []
      assert plan.risk_level == :low
    end

    test "http check extracts URL and status code" do
      intent = %{
        success_criteria: ["GET https://example.com/api returns 201"],
        constraints: [],
        resources: []
      }

      plan = VerificationPlan.from_intent(intent)
      http_checks = Enum.filter(plan.checks, &(&1.type == :http))
      assert length(http_checks) == 1

      check = hd(http_checks)
      assert check.params.url == "https://example.com/api"
      assert check.params.expected_status == 201
    end

    test "command criterion generates command check" do
      intent = %{
        success_criteria: ["run mix ecto.migrations shows all up"],
        constraints: [],
        resources: []
      }

      plan = VerificationPlan.from_intent(intent)
      cmd_checks = Enum.filter(plan.checks, &(&1.type == :command))
      assert length(cmd_checks) == 1
    end

    test "unrecognized criteria become custom checks" do
      intent = %{
        success_criteria: ["The system feels responsive"],
        constraints: [],
        resources: []
      }

      plan = VerificationPlan.from_intent(intent)
      custom = Enum.filter(plan.checks, &(&1.type == :custom))
      assert length(custom) == 1
      assert hd(custom).description == "The system feels responsive"
    end
  end

  describe "execute/1" do
    test "runs file_exists checks" do
      # Use a file we know exists
      plan = %{
        checks: [
          %{
            type: :file_exists,
            description: "mix.exs exists",
            params: %{path: "mix.exs"},
            source: :resource
          }
        ],
        rollback_hint: nil,
        risk_level: :low
      }

      results = VerificationPlan.execute(plan)
      assert length(results) == 1
      assert hd(results).passed == true
    end

    test "file_exists fails for missing file" do
      plan = %{
        checks: [
          %{
            type: :file_exists,
            description: "missing",
            params: %{path: "nonexistent_file_xyz.ex"},
            source: :resource
          }
        ],
        rollback_hint: nil,
        risk_level: :low
      }

      results = VerificationPlan.execute(plan)
      assert hd(results).passed == false
      assert hd(results).detail =~ "not found"
    end

    test "file_unchanged passes when hash matches" do
      path = "mix.exs"
      hash = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

      plan = %{
        checks: [
          %{
            type: :file_unchanged,
            description: "mix.exs unchanged",
            params: %{path: path, snapshot_hash: hash},
            source: :constraint
          }
        ],
        rollback_hint: nil,
        risk_level: :low
      }

      results = VerificationPlan.execute(plan)
      assert hd(results).passed == true
    end

    test "http checks are deferred" do
      plan = %{
        checks: [
          %{
            type: :http,
            description: "check health",
            params: %{url: "https://example.com", expected_status: 200},
            source: :success_criteria
          }
        ],
        rollback_hint: nil,
        risk_level: :low
      }

      results = VerificationPlan.execute(plan)
      assert hd(results).passed == true
      assert hd(results).detail =~ "deferred"
    end

    test "custom checks are deferred" do
      plan = %{
        checks: [
          %{type: :custom, description: "feels good", params: %{}, source: :success_criteria}
        ],
        rollback_hint: nil,
        risk_level: :low
      }

      results = VerificationPlan.execute(plan)
      assert hd(results).passed == true
      assert hd(results).detail =~ "manual"
    end
  end

  describe "all_passed?/1 and failures/1" do
    test "all_passed? true when all pass" do
      results = [
        %{check: %{}, passed: true, detail: nil},
        %{check: %{}, passed: true, detail: nil}
      ]

      assert VerificationPlan.all_passed?(results)
      assert VerificationPlan.failures(results) == []
    end

    test "all_passed? false when any fail" do
      results = [
        %{check: %{description: "a"}, passed: true, detail: nil},
        %{check: %{description: "b"}, passed: false, detail: "nope"}
      ]

      refute VerificationPlan.all_passed?(results)
      assert length(VerificationPlan.failures(results)) == 1
    end
  end

  describe "summarize/1" do
    test "produces readable summary" do
      results = [
        %{check: %{description: "file exists"}, passed: true, detail: nil},
        %{check: %{description: "config unchanged"}, passed: false, detail: "hash changed"}
      ]

      summary = VerificationPlan.summarize(results)
      assert summary =~ "1/2 passed"
      assert summary =~ "1 failed"
      assert summary =~ "[PASS] file exists"
      assert summary =~ "[FAIL] config unchanged"
      assert summary =~ "hash changed"
    end
  end

  describe "full pipeline" do
    test "from_intent → execute → summarize" do
      intent = %{
        goal: "Check project structure",
        success_criteria: ["mix.exs exists"],
        constraints: [],
        resources: ["mix.exs"],
        risk_level: :low
      }

      plan = VerificationPlan.from_intent(intent)
      results = VerificationPlan.execute(plan)
      summary = VerificationPlan.summarize(results)

      assert VerificationPlan.all_passed?(results)
      assert summary =~ "passed"
    end
  end
end
