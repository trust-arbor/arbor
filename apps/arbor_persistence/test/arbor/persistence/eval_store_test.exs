defmodule Arbor.Persistence.EvalStoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence

  describe "eval_database_available?/0" do
    test "returns boolean" do
      assert is_boolean(Persistence.eval_database_available?())
    end
  end

  describe "generate_eval_run_id/2" do
    test "creates slug from model and domain" do
      id = Persistence.generate_eval_run_id("kimi-k2.5:cloud", "coding")
      assert String.contains?(id, "kimi-k2-5-cloud")
      assert String.contains?(id, "coding")
    end

    test "includes date" do
      id = Persistence.generate_eval_run_id("model", "domain")
      date = Date.utc_today() |> Date.to_iso8601()
      assert String.contains?(id, date)
    end

    test "includes random suffix" do
      id1 = Persistence.generate_eval_run_id("model", "domain")
      id2 = Persistence.generate_eval_run_id("model", "domain")
      assert id1 != id2
    end

    test "lowercases the slug" do
      id = Persistence.generate_eval_run_id("Claude-Sonnet-4.5", "chat")
      assert id == String.downcase(id)
    end

    test "replaces special chars in model name" do
      id = Persistence.generate_eval_run_id("openai/gpt-4o:latest", "coding")
      refute String.contains?(id, "/")
      refute String.contains?(id, ":")
    end
  end

  describe "create_eval_run/2 (file backend)" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "eval_create_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)
      File.chmod!(tmp_dir, 0o700)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{dir: tmp_dir}
    end

    test "returns {:ok, _} via file backend", %{dir: dir} do
      attrs = %{
        id: "test-#{System.os_time(:millisecond)}",
        model: "test-model",
        domain: "coding",
        provider: "test",
        dataset: "test.jsonl",
        graders: [],
        status: "running",
        config: %{}
      }

      assert {:ok, _} = Persistence.create_eval_run(attrs, backend: :file, dir: dir)
      assert {:ok, loaded} = Persistence.load_eval_run_file(attrs.id, dir: dir)
      assert loaded["id"] == attrs.id
    end
  end

  describe "complete_eval_run/5 and fail_eval_run/3" do
    test "complete returns ok-ish when no DB run exists" do
      result = Persistence.complete_eval_run("nonexistent", %{}, 0, 0, backend: :file)
      assert result in [:ok, {:error, :not_found}]
    end

    test "fail returns ok-ish when no DB run exists" do
      result = Persistence.fail_eval_run("nonexistent", "test error", backend: :file)
      assert result in [:ok, {:error, :not_found}]
    end
  end

  describe "list_eval_runs/2 and get_eval_run/2 (file backend)" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "eval_list_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)
      File.chmod!(tmp_dir, 0o700)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      :ok =
        Persistence.save_eval_run_file(
          "list-run-1",
          %{model: "m1", provider: "p1", timestamp: "2026-01-02T00:00:00Z"},
          dir: tmp_dir
        )

      %{dir: tmp_dir}
    end

    test "lists via file backend", %{dir: dir} do
      assert {:ok, runs} = Persistence.list_eval_runs([], backend: :file, dir: dir)
      assert is_list(runs)
      assert Enum.any?(runs, &(&1["id"] == "list-run-1"))
    end

    test "gets via file backend", %{dir: dir} do
      assert {:ok, run} = Persistence.get_eval_run("list-run-1", backend: :file, dir: dir)
      assert run["id"] == "list-run-1"
    end
  end
end
