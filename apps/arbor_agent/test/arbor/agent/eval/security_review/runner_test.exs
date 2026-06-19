defmodule Arbor.Agent.Eval.SecurityReview.RunnerTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.Runner

  # Build a minimal corpus dir on disk: manifest.json + buggy snapshots.
  defp corpus(items) do
    dir = Path.join(System.tmp_dir!(), "secrun_#{System.unique_integer([:positive])}")

    manifest =
      Enum.map(items, fn {id, category, cross_file, files} ->
        Enum.each(files, fn {path, code} ->
          dest = Path.join([dir, id, "buggy", path])
          File.mkdir_p!(Path.dirname(dest))
          File.write!(dest, code)
        end)

        %{
          id: id,
          category: category,
          cross_file: cross_file,
          files: Enum.map(files, &elem(&1, 0))
        }
      end)

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp reviewer(id \\ "stub"),
    do: [%{id: id, provider: :stub, model: "stub-1", tier: :local}]

  # An LLM stub that returns one finding echoing the unit label (the path/"N files"
  # the runner puts in the prompt's parenthetical).
  defp ok_llm(category \\ "fail_open_authz") do
    fn %{user: user} ->
      file =
        case Regex.run(~r/\(([^)]+)\)/, user) do
          [_, label] -> label
          _ -> "?"
        end

      {:ok,
       Jason.encode!([
         %{
           category: category,
           title: "stub finding",
           file: file,
           line: 1,
           severity: "high",
           rationale: "r"
         }
       ])}
    end
  end

  describe "load_corpus/1" do
    test "reads items + buggy file contents from the manifest" do
      dir = corpus([{"i1", "fail_open_authz", false, [{"lib/a.ex", "CODE_A"}]}])
      assert {:ok, [item]} = Runner.load_corpus(dir)
      assert item.id == "i1"
      assert [%{path: "lib/a.ex", code: "CODE_A"}] = item.files
    end
  end

  describe "strategies" do
    test ":a reviews each file separately (one unit per file)" do
      dir = corpus([{"x", "capability_overmatch", true, [{"lib/a.ex", "A"}, {"lib/b.ex", "B"}]}])

      {:ok, summary} =
        Runner.run(dir, reviewers: reviewer(), strategies: [:a], llm: ok_llm(), write?: false)

      assert [cell] = summary.results
      assert cell.units == 2
      assert cell.strategy == :a
    end

    test ":b_lite reviews all files together (one unit)" do
      dir = corpus([{"x", "capability_overmatch", true, [{"lib/a.ex", "A"}, {"lib/b.ex", "B"}]}])

      {:ok, summary} =
        Runner.run(dir,
          reviewers: reviewer(),
          strategies: [:b_lite],
          llm: ok_llm(),
          write?: false
        )

      assert [cell] = summary.results
      assert cell.units == 1
    end
  end

  describe "run/2 cell envelope + findings" do
    test "parses findings and records the cell metadata" do
      dir = corpus([{"i1", "fail_open_authz", false, [{"lib/a.ex", "def authorize, do: :ok"}]}])

      {:ok, summary} =
        Runner.run(dir,
          reviewers: reviewer(),
          strategies: [:a],
          k: 2,
          llm: ok_llm(),
          write?: false
        )

      # 1 reviewer × 1 item × 1 strategy × k=2 = 2 cells
      assert summary.cell_count == 2
      cell = hd(summary.results)
      assert cell.reviewer == "stub"
      assert cell.item_id == "i1"
      assert [%{category: :fail_open_authz, file: "lib/a.ex"}] = cell.findings
      assert cell.errors == []
    end

    test "an LLM error is captured per-unit, not fatal" do
      dir = corpus([{"i1", "fail_open_authz", false, [{"lib/a.ex", "A"}]}])
      failing = fn _call -> {:error, :model_down} end

      {:ok, summary} =
        Runner.run(dir, reviewers: reviewer(), strategies: [:a], llm: failing, write?: false)

      cell = hd(summary.results)
      assert cell.findings == []
      assert [%{reason: reason}] = cell.errors
      assert reason =~ "model_down"
    end

    test "an LLM that RAISES is captured per-unit, not fatal (the live-run crash class)" do
      dir = corpus([{"i1", "fail_open_authz", false, [{"lib/a.ex", "A"}]}])
      raising = fn _call -> raise FunctionClauseError, "no clause" end

      {:ok, summary} =
        Runner.run(dir, reviewers: reviewer(), strategies: [:a], llm: raising, write?: false)

      cell = hd(summary.results)
      assert cell.findings == []
      assert [%{reason: reason}] = cell.errors
      assert reason =~ "exception"
    end
  end

  describe "run/2 writing" do
    test "writes a results JSON when write?: true" do
      dir = corpus([{"i1", "fail_open_authz", false, [{"lib/a.ex", "A"}]}])
      out = Path.join(System.tmp_dir!(), "secout_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)

      {:ok, _} =
        Runner.run(dir,
          reviewers: reviewer(),
          strategies: [:a],
          llm: ok_llm(),
          output_dir: out,
          now: "20260618T000000"
        )

      path = Path.join(out, "security-review-results-20260618T000000.json")
      assert File.exists?(path)
      decoded = path |> File.read!() |> Jason.decode!()
      assert decoded["cell_count"] == 1
    end
  end
end
