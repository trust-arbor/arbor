defmodule Arbor.Persistence.Schemas.EvalRunTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence.Schemas.EvalRun

  @valid_attrs %{
    id: "test-run-001",
    domain: "coding",
    model: "kimi-k2.5:cloud",
    provider: "ollama",
    dataset: "priv/eval_datasets/elixir_coding.jsonl"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      cs = EvalRun.changeset(%EvalRun{}, @valid_attrs)
      assert cs.valid?
    end

    test "valid with all fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          graders: ["compile_check", "functional_test"],
          sample_count: 10,
          duration_ms: 45_000,
          metrics: %{"accuracy" => 0.8},
          config: %{timeout: 60_000},
          status: "completed",
          error: nil,
          metadata: %{source: "mix arbor.eval"}
        })

      cs = EvalRun.changeset(%EvalRun{}, attrs)
      assert cs.valid?
    end

    test "invalid without required fields" do
      cs = EvalRun.changeset(%EvalRun{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert :id in errors
      assert :domain in errors
      assert :model in errors
      assert :provider in errors
      assert :dataset in errors
    end

    test "invalid with bad domain" do
      cs = EvalRun.changeset(%EvalRun{}, Map.put(@valid_attrs, :domain, "invalid"))
      refute cs.valid?
      assert {:domain, _} = List.keyfind(cs.errors, :domain, 0)
    end

    test "valid domains" do
      # security_verify regression: AggregateVerdict writes this domain via
      # VerdictLog; it was missing from @valid_domains, so every security verdict
      # persist failed changeset validation and degraded silently (2026-06-10
      # architecture review finding).
      for domain <-
            ~w(coding chat heartbeat embedding advisory_consultation llm_judge security_verify council_decision memory_ablation effective_window) do
        cs = EvalRun.changeset(%EvalRun{}, Map.put(@valid_attrs, :domain, domain))
        assert cs.valid?, "Expected domain '#{domain}' to be valid"
      end
    end

    test "invalid with bad status" do
      cs = EvalRun.changeset(%EvalRun{}, Map.put(@valid_attrs, :status, "unknown"))
      refute cs.valid?
      assert {:status, _} = List.keyfind(cs.errors, :status, 0)
    end

    test "valid statuses" do
      for status <- ~w(running completed failed) do
        cs = EvalRun.changeset(%EvalRun{}, Map.put(@valid_attrs, :status, status))
        assert cs.valid?, "Expected status '#{status}' to be valid"
      end
    end

    test "defaults" do
      cs = EvalRun.changeset(%EvalRun{}, @valid_attrs)
      changes = Ecto.Changeset.apply_changes(cs)
      assert changes.graders == []
      assert changes.sample_count == 0
      assert changes.duration_ms == 0
      assert changes.metrics == %{}
      assert changes.config == %{}
      assert changes.status == "running"
      assert changes.metadata == %{}
    end

    test "valid with run-identity fields (eval-system-architecture 2026-06-10)" do
      attrs =
        Map.merge(@valid_attrs, %{
          git_sha: "abc123def456",
          git_dirty: false,
          quant: "q4_k_xl",
          endpoint: "http://localhost:1234/v1",
          dataset_hash: "sha256:deadbeef",
          config_fingerprint: "sha256:cafebabe",
          layer: "task",
          task_id: "preprocessor.needs_tools"
        })

      cs = EvalRun.changeset(%EvalRun{}, attrs)
      assert cs.valid?

      changes = Ecto.Changeset.apply_changes(cs)
      assert changes.git_sha == "abc123def456"
      assert changes.git_dirty == false
      assert changes.quant == "q4_k_xl"
      assert changes.layer == "task"
      assert changes.task_id == "preprocessor.needs_tools"
    end

    test "run-identity fields are optional (legacy callers stay valid)" do
      cs = EvalRun.changeset(%EvalRun{}, @valid_attrs)
      assert cs.valid?
    end

    test "valid layers" do
      for layer <- ~w(task system) do
        cs = EvalRun.changeset(%EvalRun{}, Map.put(@valid_attrs, :layer, layer))
        assert cs.valid?, "Expected layer '#{layer}' to be valid"
      end
    end

    test "invalid with bad layer" do
      cs = EvalRun.changeset(%EvalRun{}, Map.put(@valid_attrs, :layer, "cloud"))
      refute cs.valid?
      assert {:layer, _} = List.keyfind(cs.errors, :layer, 0)
    end
  end

  defp errors_on(changeset) do
    changeset.errors |> Keyword.keys()
  end
end
