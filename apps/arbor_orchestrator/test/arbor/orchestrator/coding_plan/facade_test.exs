defmodule Arbor.Orchestrator.CodingPlan.FacadeTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.Compilation

  defmodule FakeCompiler do
    alias Arbor.Contracts.Coding.Plan
    alias Arbor.Orchestrator.CodingPlan.Compilation

    def compile(%Plan{} = plan, opts) do
      send(self(), {:coding_plan_compile_called, plan, opts})

      Process.get({__MODULE__, :reply}) ||
        {:ok,
         %Compilation{
           plan_map: Plan.to_map(plan),
           dot_source: "digraph CodingPlan { start [shape=Mdiamond] }\n",
           graph_hash: String.duplicate("a", 64),
           compiler_version: "test-compiler-1",
           template_version: "test-template-1",
           plan_fingerprint: String.duplicate("b", 64),
           action_catalog_digest: String.duplicate("c", 64),
           initial_values: %{"task" => plan.task},
           manifest: %{"required_actions" => []}
         }}
    end
  end

  defmodule CompilerWithoutCompile do
  end

  setup do
    original_path = Application.fetch_env(:arbor_orchestrator, :coding_pipeline_path)
    original_compiler = Application.fetch_env(:arbor_orchestrator, :coding_plan_compiler)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "coding_plan_facade_test_#{System.unique_integer([:positive])}"
      )

    template_path = Path.join(tmp_dir, "coding-change-v1.dot")
    File.mkdir_p!(tmp_dir)
    File.write!(template_path, "digraph CodingPlan { start [shape=Mdiamond] }\n")

    Application.put_env(:arbor_orchestrator, :coding_pipeline_path, template_path)
    Application.put_env(:arbor_orchestrator, :coding_plan_compiler, FakeCompiler)
    Process.delete({FakeCompiler, :reply})

    on_exit(fn ->
      restore_env(:coding_pipeline_path, original_path)
      restore_env(:coding_plan_compiler, original_compiler)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, template_path: template_path, tmp_dir: tmp_dir}
  end

  test "normalizes map input and passes only the trusted template path", %{
    template_path: template_path
  } do
    attrs = %{
      "task" => "Add a focused facade",
      "repo_root" => "/tmp/repo",
      "worker" => %{"provider" => "grok"}
    }

    assert {:ok, result} = Arbor.Orchestrator.compile_coding_plan(attrs)

    assert_receive {:coding_plan_compile_called, %Plan{} = plan, [template_path: ^template_path]}

    assert plan.base_ref == "HEAD"
    assert plan.validation_profile == "default"
    assert plan.review_profile == "binding"

    assert plan.worker == %{
             "model" => nil,
             "permission_mode" => "default",
             "provider" => "grok"
           }

    assert result["plan_map"] == Plan.to_map(plan)
  end

  test "accepts keyword input supported by Plan.new/1" do
    attrs = [task: "Compile keywords", repo_root: "/tmp/repo", worker: [provider: "grok"]]

    assert {:ok, _result} = Arbor.Orchestrator.compile_coding_plan(attrs)
    assert_receive {:coding_plan_compile_called, %Plan{task: "Compile keywords"}, _opts}
  end

  test "passes an existing Plan through unchanged", %{template_path: template_path} do
    assert {:ok, plan} =
             Plan.new(%{
               task: "Use an existing plan",
               repo_root: "/tmp/repo",
               worker: %{provider: "grok", permission_mode: "deny"}
             })

    assert {:ok, _result} = Arbor.Orchestrator.compile_coding_plan(plan)
    assert_receive {:coding_plan_compile_called, ^plan, [template_path: ^template_path]}
  end

  test "returns string-keyed JSON data without authority fields" do
    assert {:ok, result} = Arbor.Orchestrator.compile_coding_plan(valid_attrs())
    assert {:ok, _json} = Jason.encode(result)
    assert string_keyed?(result)

    authority_fields =
      ~w(action_catalog capabilities capability graph identity principal signer template_path)

    assert MapSet.disjoint?(all_keys(result), MapSet.new(authority_fields))
  end

  test "fails closed when the configured template is unavailable", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing.dot")
    Application.put_env(:arbor_orchestrator, :coding_pipeline_path, missing)

    assert {:error, {:coding_plan_template_unavailable, ^missing, :enoent}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute_receive {:coding_plan_compile_called, _plan, _opts}
  end

  test "fails closed when the configured template path is malformed" do
    for malformed <- [nil, :not_a_path, "  ", "bad" <> <<0>> <> "path"] do
      Application.put_env(:arbor_orchestrator, :coding_pipeline_path, malformed)

      assert {:error, {:coding_plan_template_unavailable, :invalid_path}} =
               Arbor.Orchestrator.compile_coding_plan(valid_attrs())

      refute_receive {:coding_plan_compile_called, _plan, _opts}
    end
  end

  test "fails closed when the configured compiler is invalid" do
    Application.put_env(
      :arbor_orchestrator,
      :coding_plan_compiler,
      CompilerWithoutCompile
    )

    assert {:error, {:coding_plan_compiler_unavailable, CompilerWithoutCompile}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute_receive {:coding_plan_compile_called, _plan, _opts}
  end

  test "fails closed on a malformed compiler reply" do
    Process.put({FakeCompiler, :reply}, {:ok, %{"not" => "a compilation"}})

    assert {:error, {:coding_plan_compiler_malformed_reply, {:ok, %{"not" => "a compilation"}}}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())
  end

  test "forwards plan and compiler tagged errors unchanged" do
    assert {:error, {:missing_field, "task"}} =
             Arbor.Orchestrator.compile_coding_plan(%{
               repo_root: "/tmp/repo",
               worker: %{provider: "grok"}
             })

    Process.put({FakeCompiler, :reply}, {:error, {:profile_not_executable, "docs_only"}})

    assert {:error, {:profile_not_executable, "docs_only"}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())
  end

  test "rejects caller-supplied graph and compiler controls before compilation" do
    for {field, value} <- [
          {"graph", "digraph Untrusted {}"},
          {"template_path", "/tmp/untrusted.dot"},
          {"action_catalog", %{}},
          {"compiler", "Untrusted.Compiler"}
        ] do
      assert {:error, {:unknown_fields, [^field]}} =
               valid_attrs()
               |> Map.put(field, value)
               |> Arbor.Orchestrator.compile_coding_plan()
    end

    refute_receive {:coding_plan_compile_called, _plan, _opts}
  end

  defp valid_attrs do
    %{
      "task" => "Compile a reviewed plan",
      "repo_root" => "/tmp/repo",
      "worker" => %{"provider" => "grok"}
    }
  end

  defp string_keyed?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and string_keyed?(nested) end)
  end

  defp string_keyed?(value) when is_list(value), do: Enum.all?(value, &string_keyed?/1)
  defp string_keyed?(_value), do: true

  defp all_keys(value) when is_map(value) do
    Enum.reduce(value, MapSet.new(), fn {key, nested}, keys ->
      keys
      |> MapSet.put(key)
      |> MapSet.union(all_keys(nested))
    end)
  end

  defp all_keys(value) when is_list(value) do
    Enum.reduce(value, MapSet.new(), &MapSet.union(&2, all_keys(&1)))
  end

  defp all_keys(_value), do: MapSet.new()

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:arbor_orchestrator, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:arbor_orchestrator, key)
end
