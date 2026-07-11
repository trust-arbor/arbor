defmodule Arbor.Orchestrator.CodingPlan.Compilation do
  @moduledoc false

  use TypedStruct

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.ExecutionManifest
  alias Arbor.Orchestrator.Dot.Parser

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @max_version_bytes 128

  @type json_scalar :: nil | boolean() | number() | String.t()
  @type json_value :: json_scalar() | [json_value()] | %{String.t() => json_value()}
  @type json_object :: %{String.t() => json_value()}

  typedstruct enforce: true do
    field(:plan_map, json_object())
    field(:dot_source, String.t())
    field(:graph_hash, String.t())
    field(:compiler_version, String.t())
    field(:template_version, String.t())
    field(:plan_fingerprint, String.t())
    field(:action_catalog_digest, String.t())
    field(:execution_manifest, json_object())
    field(:execution_manifest_digest, String.t())
    field(:initial_values, json_object())
    field(:manifest, json_object())
  end

  @type validation_error ::
          {:invalid_compilation_field, String.t()}
          | {:compilation_field_mismatch, String.t()}
          | {:forbidden_compilation_key, String.t(), atom()}

  @doc "Validate that trusted compiler output is fully bound to its input plan."
  @spec validate(t(), Plan.t()) :: {:ok, t()} | {:error, validation_error()}
  def validate(%__MODULE__{} = compilation, %Plan{} = plan) do
    plan_map = Plan.to_map(plan)

    with :ok <- require_equal(compilation.plan_map, plan_map, "plan_map"),
         :ok <- validate_dot_source(compilation.dot_source),
         :ok <- validate_nonblank(compilation.compiler_version, "compiler_version"),
         :ok <- validate_nonblank(compilation.template_version, "template_version"),
         :ok <- validate_digest(compilation.graph_hash, "graph_hash"),
         :ok <- validate_digest(compilation.plan_fingerprint, "plan_fingerprint"),
         :ok <- validate_digest(compilation.action_catalog_digest, "action_catalog_digest"),
         :ok <-
           validate_digest(compilation.execution_manifest_digest, "execution_manifest_digest"),
         :ok <- validate_graph_hash(compilation),
         :ok <- validate_plan_fingerprint(compilation, plan_map),
         :ok <- validate_json_object(compilation.execution_manifest, "execution_manifest"),
         :ok <-
           ExecutionManifest.validate(
             compilation.execution_manifest,
             compilation.execution_manifest_digest,
             compilation.graph_hash
           ),
         :ok <- validate_json_object(compilation.initial_values, "initial_values"),
         :ok <- validate_json_object(compilation.manifest, "manifest"),
         :ok <- reject_forbidden_keys(compilation.initial_values, "initial_values", :control),
         :ok <- reject_manifest_envelope_forbidden_keys(compilation.manifest),
         :ok <- validate_initial_values(compilation, plan),
         :ok <- validate_manifest(compilation, plan) do
      {:ok, compilation}
    end
  end

  def validate(_compilation, _plan),
    do: {:error, {:invalid_compilation_field, "compilation"}}

  @doc "Return the compilation result as a string-keyed, JSON-clean map."
  @spec to_map(t()) :: json_object()
  def to_map(%__MODULE__{} = compilation) do
    %{
      "plan_map" => compilation.plan_map,
      "dot_source" => compilation.dot_source,
      "graph_hash" => compilation.graph_hash,
      "compiler_version" => compilation.compiler_version,
      "template_version" => compilation.template_version,
      "plan_fingerprint" => compilation.plan_fingerprint,
      "action_catalog_digest" => compilation.action_catalog_digest,
      "execution_manifest" => compilation.execution_manifest,
      "execution_manifest_digest" => compilation.execution_manifest_digest,
      "initial_values" => compilation.initial_values,
      "manifest" => compilation.manifest
    }
  end

  defp validate_dot_source(source) when is_binary(source) do
    if String.valid?(source) and String.trim(source) != "" do
      try do
        case Parser.parse(source) do
          {:ok, _graph} -> :ok
          _other -> invalid("dot_source")
        end
      rescue
        _exception -> invalid("dot_source")
      catch
        _kind, _reason -> invalid("dot_source")
      end
    else
      invalid("dot_source")
    end
  end

  defp validate_dot_source(_source), do: invalid("dot_source")

  defp validate_nonblank(value, field) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_version_bytes and
         String.trim(value) != "" and not String.contains?(value, <<0>>) do
      :ok
    else
      invalid(field)
    end
  end

  defp validate_nonblank(_value, field), do: invalid(field)

  defp validate_digest(value, field) when is_binary(value) do
    if Regex.match?(@sha256_pattern, value), do: :ok, else: invalid(field)
  end

  defp validate_digest(_value, field), do: invalid(field)

  defp validate_graph_hash(compilation) do
    require_equal(compilation.graph_hash, sha256(compilation.dot_source), "graph_hash")
  end

  defp validate_plan_fingerprint(compilation, plan_map) do
    case canonical_json(plan_map) do
      {:ok, encoded} ->
        require_equal(compilation.plan_fingerprint, sha256(encoded), "plan_fingerprint")

      {:error, _reason} ->
        invalid("plan_fingerprint")
    end
  end

  defp validate_json_object(value, field) when is_map(value) and not is_struct(value) do
    if json_clean?(value) and match?({:ok, _encoded}, Jason.encode(value)) do
      :ok
    else
      invalid(field)
    end
  end

  defp validate_json_object(_value, field), do: invalid(field)

  defp validate_initial_values(compilation, plan) do
    expected =
      %{
        "task" => plan.task,
        "repo_path" => plan.repo_root,
        "base_ref" => plan.base_ref,
        "acp_agent" => plan.worker["provider"],
        "open_pr" => bool_string(plan.output["draft_pr"]),
        "submit_review" => bool_string(plan.review_profile != "none"),
        "timeout" => plan.budgets["wall_clock_ms"],
        "inactivity_timeout_ms" => plan.budgets["inactivity_timeout_ms"],
        "coding_plan_compiler_version" => compilation.compiler_version,
        "coding_plan_template_version" => compilation.template_version,
        "coding_plan_version" => plan.version,
        "coding_plan_fingerprint" => compilation.plan_fingerprint,
        "coding_plan_task_class" => plan.task_class,
        "coding_plan_validation_profile" => plan.validation_profile,
        "coding_plan_review_profile" => plan.review_profile,
        "coding_plan_action_catalog_digest" => compilation.action_catalog_digest
      }
      |> maybe_put("branch_name", plan.workspace_policy["branch_name"])
      |> maybe_put("worktree_base_dir", plan.workspace_policy["worktree_base_dir"])
      |> maybe_put("model", plan.worker["model"])
      |> maybe_put_test_paths(plan)

    require_equal(compilation.initial_values, expected, "initial_values")
  end

  defp validate_manifest(compilation, plan) do
    bindings = [
      {"graph_hash", compilation.graph_hash},
      {"compiler_version", compilation.compiler_version},
      {"template_version", compilation.template_version},
      {"plan_fingerprint", compilation.plan_fingerprint},
      {"action_catalog_digest", compilation.action_catalog_digest},
      {"execution_manifest", compilation.execution_manifest},
      {"execution_manifest_digest", compilation.execution_manifest_digest},
      {"plan_version", plan.version},
      {"task_class", plan.task_class},
      {"validation_profile", plan.validation_profile},
      {"review_profile", plan.review_profile},
      {"overlays", plan.overlays}
    ]

    Enum.reduce_while(bindings, :ok, fn {field, expected}, :ok ->
      case Map.fetch(compilation.manifest, field) do
        {:ok, ^expected} -> {:cont, :ok}
        _other -> {:halt, mismatch("manifest.#{field}")}
      end
    end)
  end

  defp reject_manifest_envelope_forbidden_keys(manifest) do
    manifest
    |> Map.delete("execution_manifest")
    |> reject_forbidden_keys("manifest", :authority)
  end

  defp reject_forbidden_keys(value, field, scope) do
    case forbidden_categories(value, scope) |> Enum.uniq() |> Enum.sort() do
      [] -> :ok
      [category | _rest] -> {:error, {:forbidden_compilation_key, field, category}}
    end
  end

  defp forbidden_categories(value, scope) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      key_categories(key, scope) ++ forbidden_categories(nested, scope)
    end)
  end

  defp forbidden_categories(value, scope) when is_list(value) do
    Enum.flat_map(value, &forbidden_categories(&1, scope))
  end

  defp forbidden_categories(_value, _scope), do: []

  defp key_categories(key, scope) do
    normalized =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    compact = String.replace(normalized, "_", "")

    category =
      cond do
        signing_authority_key?(compact) ->
          :signing_authority

        String.contains?(compact, "identity") ->
          :identity_authority

        compact in ["auth", "authcontext"] or String.contains?(compact, "authorization") ->
          :authorization

        compact == "capabilityuris" ->
          nil

        String.contains?(compact, "capabilit") or compact in ["grant", "grants"] ->
          :capabilities

        String.contains?(compact, "session") ->
          :session_authority

        String.contains?(compact, "principal") ->
          :principal_override

        compact in ["agent", "agentid", "caller", "callerid", "owner", "ownerid"] ->
          :agent_override

        compact in ["taskid", "taskoverride", "taskownerid", "taskprincipalid"] ->
          :task_override

        scope == :control and
            compact in [
              "graph",
              "graphhash",
              "graphpath",
              "dot",
              "dotsource",
              "dotsourcepath",
              "pipeline",
              "pipelinepath",
              "templatepath"
            ] ->
          :graph_control

        scope == :control and compact in ["path", "sourcepath"] ->
          :path_control

        scope == :control and compact in ["compiler", "compilermodule"] ->
          :compiler_control

        scope == :control and compact in ["executor", "executormodule"] ->
          :executor_control

        true ->
          nil
      end

    if category, do: [category], else: []
  end

  defp signing_authority_key?(key) do
    Enum.any?(~w(privatekey secretkey signingkey signer), &String.contains?(key, &1))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_test_paths(values, %Plan{validation_profile: "security_regression"} = plan),
    do: Map.put(values, "test_paths", plan.requested_paths)

  defp maybe_put_test_paths(values, _plan), do: values

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  defp require_equal(value, value, _field), do: :ok
  defp require_equal(_actual, _expected, field), do: mismatch(field)

  defp invalid(field), do: {:error, {:invalid_compilation_field, field}}
  defp mismatch(field), do: {:error, {:compilation_field_mismatch, field}}

  defp canonical_json(term) do
    term
    |> canonicalize()
    |> Jason.encode()
  rescue
    _exception -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
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

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_clean?(nested)
    end)
  end

  defp json_clean?(_value), do: false
end
