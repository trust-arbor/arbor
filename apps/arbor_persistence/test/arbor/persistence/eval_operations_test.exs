defmodule Arbor.Persistence.EvalOperationsTest do
  @moduledoc """
  Tests for eval operation changeset logic in the Arbor.Persistence facade.

  These tests verify the changeset construction and validation for
  insert_eval_run, update_eval_run, insert_eval_result, and
  insert_eval_results_batch without requiring a database connection.
  """

  use ExUnit.Case, async: true

  alias Arbor.Persistence.Schemas.{EvalResult, EvalRun}

  describe "EvalRun changeset for insert_eval_run" do
    @valid_run_attrs %{
      id: "run-insert-001",
      domain: "coding",
      model: "gpt-4",
      provider: "openai",
      dataset: "priv/eval_datasets/elixir_coding.jsonl"
    }

    @tag :fast
    test "produces valid changeset with minimal required fields" do
      changeset = EvalRun.changeset(%EvalRun{}, @valid_run_attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :id) == "run-insert-001"
      assert Ecto.Changeset.get_change(changeset, :domain) == "coding"
      assert Ecto.Changeset.get_change(changeset, :model) == "gpt-4"
      assert Ecto.Changeset.get_change(changeset, :provider) == "openai"
    end

    @tag :fast
    test "rejects missing id" do
      attrs = Map.delete(@valid_run_attrs, :id)
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      refute changeset.valid?
      assert {:id, {"can't be blank", _}} = List.keyfind(changeset.errors, :id, 0)
    end

    @tag :fast
    test "rejects missing domain" do
      attrs = Map.delete(@valid_run_attrs, :domain)
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      refute changeset.valid?
      assert {:domain, {"can't be blank", _}} = List.keyfind(changeset.errors, :domain, 0)
    end

    @tag :fast
    test "rejects missing model" do
      attrs = Map.delete(@valid_run_attrs, :model)
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      refute changeset.valid?
      assert {:model, {"can't be blank", _}} = List.keyfind(changeset.errors, :model, 0)
    end

    @tag :fast
    test "rejects missing provider" do
      attrs = Map.delete(@valid_run_attrs, :provider)
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      refute changeset.valid?
      assert {:provider, {"can't be blank", _}} = List.keyfind(changeset.errors, :provider, 0)
    end

    @tag :fast
    test "rejects missing dataset" do
      attrs = Map.delete(@valid_run_attrs, :dataset)
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      refute changeset.valid?
      assert {:dataset, {"can't be blank", _}} = List.keyfind(changeset.errors, :dataset, 0)
    end

    @tag :fast
    test "rejects invalid domain value" do
      for bad_domain <- ["unknown", "sql_injection", "", "CODING", "Code"] do
        attrs = Map.put(@valid_run_attrs, :domain, bad_domain)
        changeset = EvalRun.changeset(%EvalRun{}, attrs)
        refute changeset.valid?, "Expected domain '#{bad_domain}' to be rejected"
      end
    end

    @tag :fast
    test "accepts all valid domain values" do
      for domain <- ~w(coding chat heartbeat embedding advisory_consultation llm_judge memory_ablation effective_window) do
        attrs = Map.put(@valid_run_attrs, :domain, domain)
        changeset = EvalRun.changeset(%EvalRun{}, attrs)
        assert changeset.valid?, "Expected domain '#{domain}' to be accepted"
      end
    end

    @tag :fast
    test "rejects invalid status value" do
      for bad_status <- ["pending", "cancelled", "done", "RUNNING", "success"] do
        attrs = Map.put(@valid_run_attrs, :status, bad_status)
        changeset = EvalRun.changeset(%EvalRun{}, attrs)
        refute changeset.valid?, "Expected status '#{bad_status}' to be rejected"
      end
    end

    @tag :fast
    test "accepts all valid status values" do
      for status <- ~w(running completed failed) do
        attrs = Map.put(@valid_run_attrs, :status, status)
        changeset = EvalRun.changeset(%EvalRun{}, attrs)
        assert changeset.valid?, "Expected status '#{status}' to be accepted"
      end
    end

    @tag :fast
    test "accepts metrics as a map" do
      attrs = Map.put(@valid_run_attrs, :metrics, %{"accuracy" => 0.95, "latency_p99" => 1200})
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.metrics["accuracy"] == 0.95
    end

    @tag :fast
    test "accepts config as a map" do
      attrs = Map.put(@valid_run_attrs, :config, %{temperature: 0.7, max_tokens: 2048})
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.config[:temperature] == 0.7
    end

    @tag :fast
    test "accepts graders as a list of strings" do
      attrs = Map.put(@valid_run_attrs, :graders, ["compile_check", "functional_test", "llm_judge"])
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert length(applied.graders) == 3
    end

    @tag :fast
    test "accepts error field for failed runs" do
      attrs = Map.merge(@valid_run_attrs, %{status: "failed", error: "Timeout after 60s"})
      changeset = EvalRun.changeset(%EvalRun{}, attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.error == "Timeout after 60s"
      assert applied.status == "failed"
    end

    @tag :fast
    test "defaults are applied correctly on apply_changes" do
      changeset = EvalRun.changeset(%EvalRun{}, @valid_run_attrs)
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.graders == []
      assert applied.sample_count == 0
      assert applied.duration_ms == 0
      assert applied.metrics == %{}
      assert applied.config == %{}
      assert applied.status == "running"
      assert applied.error == nil
      assert applied.metadata == %{}
    end
  end

  describe "EvalRun changeset for update_eval_run (updating existing struct)" do
    @tag :fast
    test "updates status on an existing run struct" do
      existing = %EvalRun{
        id: "run-update-001",
        domain: "coding",
        model: "gpt-4",
        provider: "openai",
        dataset: "test.jsonl",
        status: "running",
        graders: [],
        sample_count: 0,
        duration_ms: 0,
        metrics: %{},
        config: %{},
        metadata: %{}
      }

      changeset = EvalRun.changeset(existing, %{status: "completed"})
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.status == "completed"
      # Other fields should remain unchanged
      assert applied.domain == "coding"
      assert applied.model == "gpt-4"
    end

    @tag :fast
    test "updates metrics and duration on an existing run" do
      existing = %EvalRun{
        id: "run-update-002",
        domain: "chat",
        model: "claude-3",
        provider: "anthropic",
        dataset: "test.jsonl",
        status: "running",
        graders: ["compile_check"],
        sample_count: 0,
        duration_ms: 0,
        metrics: %{},
        config: %{},
        metadata: %{}
      }

      update_attrs = %{
        status: "completed",
        sample_count: 50,
        duration_ms: 120_000,
        metrics: %{"accuracy" => 0.92, "pass_rate" => 0.88}
      }

      changeset = EvalRun.changeset(existing, update_attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.status == "completed"
      assert applied.sample_count == 50
      assert applied.duration_ms == 120_000
      assert applied.metrics["accuracy"] == 0.92
    end

    @tag :fast
    test "rejects updating to invalid status" do
      existing = %EvalRun{
        id: "run-update-003",
        domain: "coding",
        model: "gpt-4",
        provider: "openai",
        dataset: "test.jsonl",
        status: "running",
        graders: [],
        sample_count: 0,
        duration_ms: 0,
        metrics: %{},
        config: %{},
        metadata: %{}
      }

      changeset = EvalRun.changeset(existing, %{status: "invalid_status"})
      refute changeset.valid?
      assert {:status, _} = List.keyfind(changeset.errors, :status, 0)
    end

    @tag :fast
    test "rejects updating to invalid domain" do
      existing = %EvalRun{
        id: "run-update-004",
        domain: "coding",
        model: "gpt-4",
        provider: "openai",
        dataset: "test.jsonl",
        status: "running",
        graders: [],
        sample_count: 0,
        duration_ms: 0,
        metrics: %{},
        config: %{},
        metadata: %{}
      }

      changeset = EvalRun.changeset(existing, %{domain: "nonexistent_domain"})
      refute changeset.valid?
      assert {:domain, _} = List.keyfind(changeset.errors, :domain, 0)
    end

    @tag :fast
    test "updates error field when run fails" do
      existing = %EvalRun{
        id: "run-update-005",
        domain: "coding",
        model: "gpt-4",
        provider: "openai",
        dataset: "test.jsonl",
        status: "running",
        graders: [],
        sample_count: 5,
        duration_ms: 30_000,
        metrics: %{},
        config: %{},
        metadata: %{}
      }

      changeset = EvalRun.changeset(existing, %{status: "failed", error: "Model returned 500"})
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.status == "failed"
      assert applied.error == "Model returned 500"
    end

    @tag :fast
    test "no-op changeset when no changes provided" do
      existing = %EvalRun{
        id: "run-update-006",
        domain: "coding",
        model: "gpt-4",
        provider: "openai",
        dataset: "test.jsonl",
        status: "running",
        graders: [],
        sample_count: 0,
        duration_ms: 0,
        metrics: %{},
        config: %{},
        metadata: %{}
      }

      changeset = EvalRun.changeset(existing, %{})
      assert changeset.valid?
      assert changeset.changes == %{}
    end
  end

  describe "EvalResult changeset for insert_eval_result" do
    @valid_result_attrs %{
      id: "result-insert-001",
      run_id: "run-001",
      sample_id: "sample_genserver"
    }

    @tag :fast
    test "produces valid changeset with required fields" do
      changeset = EvalResult.changeset(%EvalResult{}, @valid_result_attrs)
      assert changeset.valid?
    end

    @tag :fast
    test "rejects missing id" do
      attrs = Map.delete(@valid_result_attrs, :id)
      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      refute changeset.valid?
      assert {:id, _} = List.keyfind(changeset.errors, :id, 0)
    end

    @tag :fast
    test "rejects missing run_id" do
      attrs = Map.delete(@valid_result_attrs, :run_id)
      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      refute changeset.valid?
      assert {:run_id, _} = List.keyfind(changeset.errors, :run_id, 0)
    end

    @tag :fast
    test "rejects missing sample_id" do
      attrs = Map.delete(@valid_result_attrs, :sample_id)
      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      refute changeset.valid?
      assert {:sample_id, _} = List.keyfind(changeset.errors, :sample_id, 0)
    end

    @tag :fast
    test "accepts full result with all optional fields" do
      attrs =
        Map.merge(@valid_result_attrs, %{
          input: "Write a GenServer that manages a counter",
          expected: "defmodule Counter do\n  use GenServer\nend",
          actual: "defmodule Counter do\n  use GenServer\n\n  def start_link(initial) do...",
          passed: true,
          scores: %{
            "compile_check" => %{"score" => 1.0, "passed" => true},
            "functional_test" => %{"score" => 0.8, "passed" => true}
          },
          duration_ms: 5400,
          ttft_ms: 320,
          tokens_generated: 512,
          metadata: %{attempt: 1, temperature: 0.7}
        })

      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.passed == true
      assert applied.duration_ms == 5400
      assert applied.ttft_ms == 320
      assert applied.tokens_generated == 512
      assert map_size(applied.scores) == 2
    end

    @tag :fast
    test "defaults passed to false" do
      changeset = EvalResult.changeset(%EvalResult{}, @valid_result_attrs)
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.passed == false
    end

    @tag :fast
    test "defaults scores to empty map" do
      changeset = EvalResult.changeset(%EvalResult{}, @valid_result_attrs)
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.scores == %{}
    end

    @tag :fast
    test "defaults duration_ms to 0" do
      changeset = EvalResult.changeset(%EvalResult{}, @valid_result_attrs)
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.duration_ms == 0
    end

    @tag :fast
    test "defaults ttft_ms and tokens_generated to nil" do
      changeset = EvalResult.changeset(%EvalResult{}, @valid_result_attrs)
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.ttft_ms == nil
      assert applied.tokens_generated == nil
    end

    @tag :fast
    test "accepts nil for optional timing fields" do
      attrs = Map.merge(@valid_result_attrs, %{ttft_ms: nil, tokens_generated: nil})
      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      assert changeset.valid?
    end

    @tag :fast
    test "accepts zero values for timing fields" do
      attrs = Map.merge(@valid_result_attrs, %{duration_ms: 0, ttft_ms: 0, tokens_generated: 0})
      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      assert changeset.valid?
      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.duration_ms == 0
      assert applied.ttft_ms == 0
      assert applied.tokens_generated == 0
    end

    @tag :fast
    test "handles empty string input/expected/actual" do
      attrs = Map.merge(@valid_result_attrs, %{input: "", expected: "", actual: ""})
      changeset = EvalResult.changeset(%EvalResult{}, attrs)
      assert changeset.valid?
    end
  end
end
