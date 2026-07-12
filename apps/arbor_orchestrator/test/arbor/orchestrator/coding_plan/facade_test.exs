defmodule Arbor.Orchestrator.CodingPlan.FacadeTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.{Compilation, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

  defmodule FakeCompiler do
    alias Arbor.Contracts.Coding.Plan

    def compile(%Plan{} = plan, opts) do
      send(self(), {:coding_plan_compile_called, plan, opts})

      case Process.get({__MODULE__, :reply}) do
        nil ->
          {:ok, Arbor.Orchestrator.CodingPlan.FacadeTest.valid_compilation(plan)}

        {:raise, message} ->
          raise message

        {:exit, reason} ->
          exit(reason)

        {:throw, reason} ->
          throw(reason)

        reply when is_function(reply, 1) ->
          reply.(plan)

        reply ->
          reply
      end
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
             "provider" => "grok",
             "use_pool" => true,
             "resume_provider" => nil,
             "resume_session_id" => nil
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

  test "public provenance verification uses packaged compilation and rejects changed DOT bytes" do
    Application.delete_env(:arbor_orchestrator, :coding_pipeline_path)
    Application.delete_env(:arbor_orchestrator, :coding_plan_compiler)

    assert {:ok, compilation} = Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    assert {:ok, identity} =
             Arbor.Orchestrator.verify_coding_provenance(
               compilation["plan_map"],
               compilation["dot_source"],
               compilation["manifest"]
             )

    assert identity == %{
             "compiler_version" => compilation["compiler_version"],
             "graph_hash" => compilation["graph_hash"]
           }

    assert {:error, {:invalid_coding_provenance, :archived_compilation_mismatch}} =
             Arbor.Orchestrator.verify_coding_provenance(
               compilation["plan_map"],
               compilation["dot_source"] <> "\n// changed after compilation\n",
               compilation["manifest"]
             )
  end

  test "fails closed when the configured template is unavailable", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing.dot")
    Application.put_env(:arbor_orchestrator, :coding_pipeline_path, missing)

    assert {:error, {:coding_plan_template_unavailable, ^missing, :enoent}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute_receive {:coding_plan_compile_called, _plan, _opts}
  end

  test "fails closed when the configured template path is malformed" do
    # Non-binary and blank configuration intentionally falls back to the
    # packaged template in Config. These malformed binaries cross that seam
    # and must still fail before File.stat/1 or the compiler is called.
    for malformed <- [<<255>>, "bad" <> <<0>> <> "path"] do
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
    private_value = "private-signing-material"

    Process.put(
      {FakeCompiler, :reply},
      {:ok, %{"not" => "a compilation", "private" => private_value}}
    )

    assert {:error, {:coding_plan_compiler_malformed_reply, :invalid_success_payload}} =
             error =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute inspect(error) =~ private_value
  end

  test "forwards plan errors and bounds compiler tagged errors" do
    assert {:error, {:missing_field, "task"}} =
             Arbor.Orchestrator.compile_coding_plan(%{
               repo_root: "/tmp/repo",
               worker: %{provider: "grok"}
             })

    private_value = "private-error-context"

    Process.put(
      {FakeCompiler, :reply},
      {:error, {:profile_not_executable, "docs_only", private_value}}
    )

    assert {:error, {:coding_plan_compiler_error, :profile_not_executable}} =
             error =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute inspect(error) =~ private_value
  end

  test "rejects malformed DOT and graph hashes without reflecting source data" do
    private_value = "private-dot-payload"

    put_compilation_mutator(fn compilation ->
      dot_source = "this is not DOT #{private_value}"

      %{
        compilation
        | dot_source: dot_source,
          graph_hash: sha256(dot_source)
      }
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply, {:invalid_compilation_field, "dot_source"}}} =
             error =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute inspect(error) =~ private_value

    put_compilation_mutator(fn compilation ->
      %{compilation | graph_hash: String.duplicate("A", 64)}
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply, {:invalid_compilation_field, "graph_hash"}}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    put_compilation_mutator(fn compilation ->
      %{compilation | graph_hash: String.duplicate("0", 64)}
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply, {:compilation_field_mismatch, "graph_hash"}}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())
  end

  test "rejects a compiler plan map or fingerprint that is not bound to the input plan" do
    private_value = "private-plan-override"

    put_compilation_mutator(fn compilation ->
      %{compilation | plan_map: Map.put(compilation.plan_map, "task", private_value)}
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply, {:compilation_field_mismatch, "plan_map"}}} =
             error =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute inspect(error) =~ private_value

    put_compilation_mutator(fn compilation ->
      %{compilation | plan_fingerprint: String.duplicate("0", 64)}
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply,
             {:compilation_field_mismatch, "plan_fingerprint"}}} =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())
  end

  test "rejects blank versions and malformed lowercase digest fields" do
    cases = [
      {:compiler_version, " ", "compiler_version"},
      {:template_version, "", "template_version"},
      {:plan_fingerprint, String.duplicate("B", 64), "plan_fingerprint"},
      {:action_catalog_digest, String.duplicate("C", 64), "action_catalog_digest"}
    ]

    for {field, replacement, error_field} <- cases do
      put_compilation_mutator(fn compilation ->
        Map.replace!(compilation, field, replacement)
      end)

      assert {:error,
              {:coding_plan_compiler_invalid_reply, {:invalid_compilation_field, ^error_field}}} =
               Arbor.Orchestrator.compile_coding_plan(valid_attrs())
    end
  end

  test "rejects non-JSON initial values including PID-backed authority" do
    private_value = "private-pid-context"

    put_compilation_mutator(fn compilation ->
      initial_values =
        compilation.initial_values
        |> Map.put("metadata", %{private_value => self()})
        |> Map.put("signer", self())

      %{compilation | initial_values: initial_values}
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply, {:invalid_compilation_field, "initial_values"}}} =
             error =
             Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute inspect(error) =~ private_value
  end

  test "rejects recursively non-JSON manifests" do
    private_value = "private-manifest-value"

    put_compilation_mutator(fn compilation ->
      manifest = Map.put(compilation.manifest, "metadata", %{private_value => self()})
      %{compilation | manifest: manifest}
    end)

    assert {:error,
            {:coding_plan_compiler_invalid_reply, {:invalid_compilation_field, "manifest"}}} =
             error = Arbor.Orchestrator.compile_coding_plan(valid_attrs())

    refute inspect(error) =~ private_value
  end

  test "rejects authority and execution-control keys recursively in initial values" do
    cases = [
      {"signer", :signing_authority},
      {"identity_private_key", :signing_authority},
      {"authorization", :authorization},
      {"agent_id", :agent_override},
      {"task_id", :task_override},
      {"principal_id", :principal_override},
      {"graph", :graph_control},
      {"path", :path_control},
      {"compiler", :compiler_control},
      {"executor", :executor_control},
      {"capabilities", :capabilities},
      {"worker_session_id", :session_authority}
    ]

    for {key, category} <- cases do
      private_value = "private-#{key}"

      put_compilation_mutator(fn compilation ->
        nested = %{"safe" => %{key => private_value}}
        %{compilation | initial_values: Map.put(compilation.initial_values, "metadata", nested)}
      end)

      assert {:error,
              {:coding_plan_compiler_invalid_reply,
               {:forbidden_compilation_key, "initial_values", ^category}}} =
               error =
               Arbor.Orchestrator.compile_coding_plan(valid_attrs())

      refute inspect(error) =~ private_value
    end
  end

  test "rejects manifest fields that are not bound to compilation and plan metadata" do
    fields = [
      {"graph_hash", String.duplicate("0", 64)},
      {"compiler_version", "other-compiler"},
      {"template_version", "other-template"},
      {"plan_fingerprint", String.duplicate("0", 64)},
      {"action_catalog_digest", String.duplicate("0", 64)},
      {"plan_version", 2},
      {"task_class", "security_regression"},
      {"validation_profile", "security_regression"},
      {"review_profile", "human_required"},
      {"overlays", ["docs_only"]}
    ]

    for {field, replacement} <- fields do
      put_compilation_mutator(fn compilation ->
        %{compilation | manifest: Map.put(compilation.manifest, field, replacement)}
      end)

      assert {:error,
              {:coding_plan_compiler_invalid_reply,
               {:compilation_field_mismatch, "manifest." <> ^field}}} =
               Arbor.Orchestrator.compile_coding_plan(valid_attrs())
    end
  end

  test "catches compiler raise, exit, and throw without leaking reasons" do
    private_value = "private-compiler-reason"

    for {mode, expected_kind} <- [raise: :raise, exit: :exit, throw: :throw] do
      Process.put({FakeCompiler, :reply}, {mode, {private_value, self()}})

      assert {:error, {:coding_plan_compiler_failed, ^expected_kind}} =
               error =
               Arbor.Orchestrator.compile_coding_plan(valid_attrs())

      refute inspect(error) =~ private_value
    end
  end

  test "planner-facing facade rejects the legacy-only none review profile" do
    attrs = Map.put(valid_attrs(), "review_profile", "none")

    assert {:error, {:coding_plan_review_profile_not_allowed, "none"}} =
             Arbor.Orchestrator.compile_coding_plan(attrs)

    refute_receive {:coding_plan_compile_called, _plan, _opts}
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

  @doc false
  def valid_compilation(%Plan{} = plan) do
    plan_map = Plan.to_map(plan)

    dot_source =
      "digraph CodingPlan { start [shape=Mdiamond]; done [shape=Msquare]; start -> done; }\n"

    graph_hash = sha256(dot_source)
    plan_fingerprint = canonical_sha256(plan_map)
    action_catalog_digest = String.duplicate("c", 64)
    compiler_version = "test-compiler-1"
    template_version = "test-template-1"
    {:ok, parsed_graph} = Parser.parse(dot_source)
    {:ok, compiled_graph} = IRCompiler.compile(parsed_graph)

    {:ok, {execution_manifest, execution_manifest_digest}} =
      ExecutionManifest.build(compiled_graph, %{"actions" => []}, graph_hash)

    initial_values =
      %{
        "task" => plan.task,
        "repo_path" => plan.repo_root,
        "base_ref" => plan.base_ref,
        "acp_agent" => plan.worker["provider"],
        "open_pr" => bool_string(plan.output["draft_pr"]),
        "submit_review" => bool_string(plan.review_profile != "none"),
        "timeout" => plan.budgets["wall_clock_ms"],
        "inactivity_timeout_ms" => plan.budgets["inactivity_timeout_ms"],
        "coding_plan_compiler_version" => compiler_version,
        "coding_plan_template_version" => template_version,
        "coding_plan_version" => plan.version,
        "coding_plan_fingerprint" => plan_fingerprint,
        "coding_plan_task_class" => plan.task_class,
        "coding_plan_validation_profile" => plan.validation_profile,
        "coding_plan_review_profile" => plan.review_profile,
        "coding_plan_action_catalog_digest" => action_catalog_digest
      }
      |> maybe_put("branch_name", plan.workspace_policy["branch_name"])
      |> maybe_put("worktree_base_dir", plan.workspace_policy["worktree_base_dir"])
      |> maybe_put("model", plan.worker["model"])
      |> maybe_put_test_paths(plan)

    manifest = %{
      "compiler_version" => compiler_version,
      "template_version" => template_version,
      "graph_hash" => graph_hash,
      "plan_fingerprint" => plan_fingerprint,
      "plan_version" => plan.version,
      "task_class" => plan.task_class,
      "validation_profile" => plan.validation_profile,
      "review_profile" => plan.review_profile,
      "overlays" => plan.overlays,
      "action_catalog_digest" => action_catalog_digest,
      "execution_manifest" => execution_manifest,
      "execution_manifest_digest" => execution_manifest_digest,
      "action_names" => [],
      "handler_types" => []
    }

    %Compilation{
      plan_map: plan_map,
      dot_source: dot_source,
      graph_hash: graph_hash,
      compiler_version: compiler_version,
      template_version: template_version,
      plan_fingerprint: plan_fingerprint,
      action_catalog_digest: action_catalog_digest,
      execution_manifest: execution_manifest,
      execution_manifest_digest: execution_manifest_digest,
      initial_values: initial_values,
      manifest: manifest
    }
  end

  defp put_compilation_mutator(mutator) do
    Process.put({FakeCompiler, :reply}, fn plan ->
      {:ok, plan |> valid_compilation() |> mutator.()}
    end)
  end

  defp canonical_sha256(term) do
    term
    |> canonicalize()
    |> Jason.encode!()
    |> sha256()
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_test_paths(values, %Plan{validation_profile: "security_regression"} = plan),
    do: Map.put(values, "test_paths", plan.requested_paths)

  defp maybe_put_test_paths(values, _plan), do: values

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

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
