defmodule Arbor.Persistence.Schemas.EvalRunTest do
  use ExUnit.Case, async: true

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
      for domain <- ~w(coding chat heartbeat embedding advisory_consultation llm_judge memory_ablation effective_window) do
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
  end

  defp errors_on(changeset) do
    changeset.errors |> Keyword.keys()
  end
end
