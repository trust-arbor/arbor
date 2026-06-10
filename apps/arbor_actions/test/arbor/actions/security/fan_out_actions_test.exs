defmodule Arbor.Actions.Security.FanOutActionsTest do
  @moduledoc """
  Unit tests for the verify-pending fan-out actions: `LoadFinding` (makes
  verify-finding self-contained — load content by id) and
  `SelectFindingsToVerify` (the deterministic gate that picks which recorded
  findings still need adversarial verification).
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.{FindingStore, LoadFinding, SelectFindingsToVerify}
  alias Arbor.Contracts.Security.Finding

  setup do
    dir = Path.join(System.tmp_dir!(), "sentinel_fanout_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp record(dir, opts) do
    finding = Finding.new(opts)
    {_outcome, _} = {FindingStore.record(finding, dir), finding}
    finding
  end

  describe "LoadFinding" do
    test "loads a recorded finding's markdown by id", %{dir: dir} do
      f = record(dir, category: :fail_open_authz, title: "loadable finding")

      assert {:ok, %{finding_content: content}} =
               LoadFinding.run(%{finding_id: f.id, output_dir: dir}, %{})

      assert content =~ "loadable finding"
    end

    test "returns empty content for an unknown id (graceful)", %{dir: dir} do
      assert {:ok, %{finding_content: ""}} =
               LoadFinding.run(%{finding_id: "does_not_exist", output_dir: dir}, %{})
    end
  end

  describe "SelectFindingsToVerify gating" do
    test "selects L1 (LLM-discovered) findings, skips high-confidence L0", %{dir: dir} do
      l1 =
        record(dir,
          category: :other,
          title: "L1 finding",
          location: %{file: "apps/x/lib/l1.ex", function: "a", line: 1},
          detector: %{layer: "L1", name: "diff_review"},
          confidence: %{score: 0.5, rationale: "llm"}
        )

      l0 =
        record(dir,
          category: :other,
          title: "L0 high-confidence finding",
          location: %{file: "apps/x/lib/l0.ex", function: "b", line: 2},
          detector: %{layer: "L0", name: "auth_smells"},
          confidence: %{score: 0.9, rationale: "ast"}
        )

      assert {:ok, %{to_verify: ids, count: count}} =
               SelectFindingsToVerify.run(%{output_dir: dir}, %{})

      assert l1.id in ids
      assert count == length(ids)
      refute l0.id in ids
    end

    test "selects a low-confidence L0 finding (below threshold)", %{dir: dir} do
      low =
        record(dir,
          category: :other,
          title: "low-confidence L0",
          location: %{file: "apps/x/lib/low.ex", function: "c", line: 3},
          detector: %{layer: "L0", name: "weak"},
          confidence: %{score: 0.4, rationale: "uncertain"}
        )

      assert {:ok, %{to_verify: ids}} = SelectFindingsToVerify.run(%{output_dir: dir}, %{})
      assert low.id in ids
    end

    test "skips findings a human has triaged out (not open/regressed)", %{dir: dir} do
      f =
        record(dir,
          category: :other,
          title: "triaged L1",
          location: %{file: "apps/x/lib/triaged.ex", function: "d", line: 4},
          detector: %{layer: "L1", name: "diff_review"},
          confidence: %{score: 0.5}
        )

      :ok = FindingStore.set_status(f.id, :false_positive, dir: dir)

      assert {:ok, %{to_verify: ids}} = SelectFindingsToVerify.run(%{output_dir: dir}, %{})
      refute f.id in ids
    end

    test "honors the max cap", %{dir: dir} do
      for i <- 1..5 do
        record(dir,
          category: :other,
          title: "L1 finding #{i}",
          location: %{file: "apps/x/lib/f#{i}.ex", function: "f#{i}", line: i},
          detector: %{layer: "L1", name: "diff_review_#{i}"},
          confidence: %{score: 0.5}
        )
      end

      assert {:ok, %{to_verify: ids}} =
               SelectFindingsToVerify.run(%{output_dir: dir, max: 2}, %{})

      assert length(ids) == 2
    end

    test "empty store yields nothing to verify", %{dir: dir} do
      assert {:ok, %{to_verify: [], count: 0}} =
               SelectFindingsToVerify.run(%{output_dir: dir}, %{})
    end
  end
end
