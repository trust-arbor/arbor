defmodule Arbor.Agent.Eval.SecurityReview.CorpusTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.Corpus

  # A stubbed git reader: maps {ref, path} -> bare content string. ref is
  # "<commit>^" (buggy) or "<commit>" (fixed). Map.fetch already yields the
  # {:ok, content} the reader contract wants; an unknown key -> {:error, :not_found},
  # modelling a path that doesn't exist at that commit.
  defp git_stub(table) do
    fn ref, path ->
      case Map.fetch(table, {ref, path}) do
        {:ok, content} -> {:ok, content}
        :error -> {:error, :not_found}
      end
    end
  end

  defp item(overrides) do
    Map.merge(
      %{
        id: "demo",
        category: :fail_open_authz,
        fix_commit: "abc123",
        paths: ["lib/a.ex"],
        invariant: "must fail closed",
        cross_file: false,
        verified: true
      },
      overrides
    )
  end

  describe "build/2 assembly (write?: false)" do
    test "assembles buggy+fixed snapshots per path from git" do
      git =
        git_stub(%{
          {"abc123^", "lib/a.ex"} => "BUGGY",
          {"abc123", "lib/a.ex"} => "FIXED"
        })

      assert {:ok, summary} = Corpus.build([item(%{})], git_reader: git, write?: false)

      assert summary.item_count == 1
      assert summary.built == ["demo"]
      assert summary.file_count == 1
      assert summary.skipped == []
    end

    test "a cross-file item resolves every path" do
      git =
        git_stub(%{
          {"c^", "lib/a.ex"} => "A_BUG",
          {"c", "lib/a.ex"} => "A_FIX",
          {"c^", "lib/b.ex"} => "B_BUG",
          {"c", "lib/b.ex"} => "B_FIX"
        })

      items = [
        item(%{id: "x", fix_commit: "c", paths: ["lib/a.ex", "lib/b.ex"], cross_file: true})
      ]

      assert {:ok, summary} = Corpus.build(items, git_reader: git, write?: false)
      assert summary.item_count == 1
      assert summary.file_count == 2
    end

    test "drops (does not silently include) an item whose buggy == fixed (no bug to find)" do
      git =
        git_stub(%{
          {"abc123^", "lib/a.ex"} => "SAME",
          {"abc123", "lib/a.ex"} => "SAME"
        })

      assert {:ok, summary} = Corpus.build([item(%{})], git_reader: git, write?: false)
      assert summary.item_count == 0
      assert [%{id: "demo", reason: {"lib/a.ex", :no_change}}] = summary.skipped
    end

    test "drops an item whose path can't be read at the commit" do
      git = git_stub(%{{"abc123", "lib/a.ex"} => "FIXED"})
      # buggy ref ("abc123^", "lib/a.ex") is absent -> {:error, :not_found}

      assert {:ok, summary} = Corpus.build([item(%{})], git_reader: git, write?: false)
      assert summary.item_count == 0
      assert [%{id: "demo", reason: {"lib/a.ex", :not_found}}] = summary.skipped
    end
  end

  describe "build/2 writing" do
    test "writes buggy/fixed snapshots and a manifest.json" do
      out = Path.join(System.tmp_dir!(), "seccorpus_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)

      git =
        git_stub(%{
          {"abc123^", "lib/a.ex"} => "BUGGY CONTENT",
          {"abc123", "lib/a.ex"} => "FIXED CONTENT"
        })

      assert {:ok, _summary} = Corpus.build([item(%{})], git_reader: git, output_dir: out)

      assert File.read!(Path.join([out, "demo", "buggy", "lib/a.ex"])) == "BUGGY CONTENT"
      assert File.read!(Path.join([out, "demo", "fixed", "lib/a.ex"])) == "FIXED CONTENT"

      manifest = out |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

      assert [%{"id" => "demo", "category" => "fail_open_authz", "files" => ["lib/a.ex"]}] =
               manifest
    end
  end
end
