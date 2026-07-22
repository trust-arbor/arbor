defmodule Arbor.Orchestrator.CodingPlan.ValidationProgramTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.{Profiles, ValidationProgram}

  @moduletag :fast

  @executable_ids ~w[cross_app default security_regression]
  @unsupported_ids ~w[contract_change database_migration docs_only frontend_visual]

  describe "build/2" do
    test "builds exact deterministic JSON-clean descriptors for every executable profile" do
      cases = [
        {"default", 900_000,
         %{
           "version" => 1,
           "profile_id" => "default",
           "action" => "mix_compile",
           "result_adapter" => "mix_compile_v1",
           "context_keys" => ["path", "workspace_id"],
           "static_parameters" => %{
             "timeout" => 600_000,
             "warnings_as_errors" => true
           }
         }},
        {"cross_app", 900_000,
         %{
           "version" => 1,
           "profile_id" => "cross_app",
           "action" => "coding_cross_app_validate",
           "result_adapter" => "cross_app_v1",
           "context_keys" => ["workspace_id"],
           "static_parameters" => %{
             "test_stage_timeout" => 900_000,
             "timeout" => 900_000
           }
         }},
        {"security_regression", 120_000,
         %{
           "version" => 1,
           "profile_id" => "security_regression",
           "action" => "coding_security_regression_validate",
           "result_adapter" => "security_regression_v1",
           "context_keys" => ["review_attestation_id"],
           "static_parameters" => %{"timeout" => 120_000}
         }}
      ]

      assert ValidationProgram.version() == 1

      for {profile_id, wall_clock_ms, expected} <- cases do
        strategy = strategy!(profile_id)
        budgets = %{"wall_clock_ms" => wall_clock_ms}

        assert {:ok, ^expected} = ValidationProgram.build(strategy, budgets)
        assert {:ok, ^expected} = ValidationProgram.build(strategy, budgets)
        assert :ok = ValidationProgram.validate(expected)
        assert {:ok, _json} = Jason.encode(expected)
      end
    end

    test "derives per-operation and aggregate timeouts from the reviewed wall-clock budget" do
      cases = [
        {"default", 120_000, %{"timeout" => 120_000, "warnings_as_errors" => true}},
        {"default", 900_000, %{"timeout" => 600_000, "warnings_as_errors" => true}},
        {"security_regression", 900_000, %{"timeout" => 600_000}},
        {"cross_app", 120_000, %{"timeout" => 120_000, "test_stage_timeout" => 120_000}},
        {"cross_app", 1_500_000, %{"timeout" => 1_200_000, "test_stage_timeout" => 1_500_000}},
        {"cross_app", 4_300_000, %{"timeout" => 1_200_000, "test_stage_timeout" => 4_200_000}}
      ]

      for {profile_id, wall_clock_ms, expected_parameters} <- cases do
        assert {:ok, program} =
                 ValidationProgram.build(strategy!(profile_id), %{
                   "wall_clock_ms" => wall_clock_ms
                 })

        assert program["static_parameters"] == expected_parameters
      end
    end

    test "fails closed for unsupported, malformed, and drifted strategy data" do
      for profile_id <- @unsupported_ids do
        assert {:ok, profile} = Profiles.fetch(profile_id)

        assert {:error, {:unsupported_validation_strategy, _enforcement}} =
                 ValidationProgram.build(profile["validation_strategy"], %{
                   "wall_clock_ms" => 900_000
                 })
      end

      default = strategy!("default")

      malformed = [
        %{},
        Map.delete(default, "action"),
        Map.delete(default, "context_keys"),
        Map.put(default, "context_keys", ["workspace_id", "path"]),
        Map.put(default, "result_adapter", "cross_app_v1"),
        Map.put(default, "result_adapter", "unreviewed_adapter"),
        Map.put(default, "static_parameters", %{}),
        Map.put(default, "timeout_budget_source", "unreviewed.budget"),
        Map.put(default, "extra_authority", true)
      ]

      for strategy <- malformed do
        assert {:error, :invalid_validation_strategy} =
                 ValidationProgram.build(strategy, %{"wall_clock_ms" => 900_000})
      end

      assert {:error, {:unsupported_validation_strategy, "unreviewed_validate"}} =
               ValidationProgram.build(
                 Map.put(default, "action", "unreviewed_validate"),
                 %{"wall_clock_ms" => 900_000}
               )
    end

    test "rejects malformed reviewed budget inputs" do
      strategy = strategy!("default")

      for budgets <- [
            nil,
            %{},
            %{"wall_clock_ms" => nil},
            %{"wall_clock_ms" => 0},
            %{
              "wall_clock_ms" => 1.5
            }
          ] do
        assert {:error, :invalid_validation_budget} =
                 ValidationProgram.build(strategy, budgets)
      end
    end
  end

  describe "project_onto/2" do
    test "projects exact context and static attrs while removing template parameter drift" do
      base_attrs = %{
        "type" => "exec",
        "target" => "action",
        "action" => "mix_compile",
        "context_keys" => "stale",
        "output_prefix" => "stale",
        "max_retries" => "0",
        "param.warnings_as_errors" => false,
        "param.unreviewed" => true,
        "arg.legacy" => "stale"
      }

      expected_controlled = %{
        "default" => %{
          "action" => "mix_compile",
          "context_keys" => "path,workspace_id",
          "output_prefix" => "validation",
          "param.timeout" => 600_000,
          "param.warnings_as_errors" => true
        },
        "cross_app" => %{
          "action" => "coding_cross_app_validate",
          "context_keys" => "workspace_id",
          "output_prefix" => "validation",
          "param.test_stage_timeout" => 900_000,
          "param.timeout" => 900_000
        },
        "security_regression" => %{
          "action" => "coding_security_regression_validate",
          "context_keys" => "review_attestation_id",
          "output_prefix" => "validation",
          "param.timeout" => 600_000
        }
      }

      for profile_id <- @executable_ids do
        assert {:ok, program} =
                 ValidationProgram.build(strategy!(profile_id), %{"wall_clock_ms" => 900_000})

        assert {:ok, attrs} = ValidationProgram.project_onto(program, base_attrs)

        assert Map.take(attrs, Map.keys(expected_controlled[profile_id])) ==
                 expected_controlled[profile_id]

        assert attrs["type"] == "exec"
        assert attrs["target"] == "action"
        assert attrs["max_retries"] == "0"
        refute Map.has_key?(attrs, "param.unreviewed")
        refute Map.has_key?(attrs, "arg.legacy")
      end
    end

    test "rejects drifted descriptors instead of projecting them" do
      assert {:ok, program} =
               ValidationProgram.build(strategy!("default"), %{"wall_clock_ms" => 900_000})

      invalid_programs = [
        Map.put(program, "version", 2),
        Map.put(program, "profile_id", "cross_app"),
        Map.put(program, "result_adapter", "cross_app_v1"),
        Map.put(program, "context_keys", ["workspace_id"]),
        put_in(program, ["static_parameters", "timeout"], 600_001),
        Map.put(program, "extra", true)
      ]

      for invalid <- invalid_programs do
        assert {:error, :invalid_validation_program} = ValidationProgram.validate(invalid)

        assert {:error, :invalid_validation_program} =
                 ValidationProgram.project_onto(invalid, %{})
      end
    end
  end

  defp strategy!(profile_id) do
    {:ok, profile} = Profiles.fetch_executable(profile_id)
    profile["validation_strategy"]
  end
end
