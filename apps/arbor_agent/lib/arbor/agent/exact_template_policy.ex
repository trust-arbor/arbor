defmodule Arbor.Agent.ExactTemplatePolicy do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.{SandboxLevel, TrustRule}

  @metadata_key "exact_template_policy"
  @pipeline_architect "pipeline_architect"
  @snapshot_version 1

  @policy_keys [
    "capability_policy",
    "runtime_policy",
    "sandbox_policy",
    "tool_policy",
    "trust_preset_policy"
  ]

  @known_constraint_keys ["rate_limit", "requires_approval"]
  @trust_modes ~w(block ask allow auto)
  @runtimes ~w(arbor acp)

  @session_turn_capability_uris [
    "arbor://orchestrator/execute",
    "arbor://orchestrator/execute/exec",
    "arbor://orchestrator/execute/compute",
    "arbor://orchestrator/execute/transform",
    "arbor://orchestrator/execute/unknown"
  ]

  @type envelope :: map()

  @spec build(String.t(), map(), keyword()) ::
          {:ok, envelope()} | :not_exact | {:error, term()}
  def build(template_name, data, opts \\ [])
      when is_binary(template_name) and is_map(data) and is_list(opts) do
    metadata = value(data, "metadata")

    if is_map(metadata) do
      exact_keys = Enum.filter(@policy_keys, &(value(metadata, &1) in ["exact", :exact]))

      cond do
        exact_keys == [] ->
          :not_exact

        length(exact_keys) != length(@policy_keys) ->
          missing = @policy_keys -- exact_keys
          error({:incomplete_policy_markers, missing})

        true ->
          build_envelope(template_name, data, metadata, opts)
      end
    else
      :not_exact
    end
  end

  @spec exact?(map()) :: boolean()
  def exact?(data) when is_map(data) do
    case value(data, "metadata") do
      metadata when is_map(metadata) ->
        Enum.any?(@policy_keys, &(value(metadata, &1) in ["exact", :exact]))

      _ ->
        false
    end
  end

  def exact?(_data), do: false

  @spec from_metadata(map()) :: {:ok, envelope()} | :not_marked | {:error, term()}
  def from_metadata(metadata) when is_map(metadata) do
    case fetch_value(metadata, @metadata_key) do
      :error ->
        :not_marked

      {:ok, envelope} when is_map(envelope) ->
        validate_envelope(envelope)

      {:ok, _other} ->
        error(:invalid_profile_metadata)
    end
  end

  def from_metadata(_metadata), do: :not_marked

  @spec validate(String.t(), map(), map(), keyword()) :: {:ok, envelope()} | {:error, term()}
  def validate(template_name, profile_metadata, template_data, opts \\ [])
      when is_binary(template_name) and is_map(template_data) and is_list(opts) do
    with {:ok, stored} <- require_profile_envelope(profile_metadata),
         {:ok, current} <- require_exact_template(build(template_name, template_data, opts)),
         :ok <- compare_envelopes(stored, current) do
      {:ok, stored}
    end
  end

  @spec put_metadata(map(), envelope()) :: map()
  def put_metadata(metadata, envelope) when is_map(metadata) and is_map(envelope) do
    Map.put(metadata, @metadata_key, envelope)
  end

  @spec marked?(map()) :: boolean()
  def marked?(metadata) when is_map(metadata) do
    Map.has_key?(metadata, @metadata_key) or Map.has_key?(metadata, :exact_template_policy)
  end

  def marked?(_metadata), do: false

  @spec migration_candidate?(map()) :: boolean()
  def migration_candidate?(%{template: @pipeline_architect, metadata: metadata}) do
    not marked?(metadata || %{})
  end

  def migration_candidate?(_profile), do: false

  @spec managed_profile?(map()) :: boolean()
  def managed_profile?(%{template: @pipeline_architect}), do: true

  def managed_profile?(%{metadata: metadata}), do: marked?(metadata || %{})
  def managed_profile?(_profile), do: false

  @spec snapshot(envelope()) :: map()
  def snapshot(envelope), do: value(envelope, "snapshot")

  @spec digest(envelope()) :: String.t()
  def digest(envelope), do: value(envelope, "digest")

  @spec capabilities(map()) :: [map()]
  def capabilities(snapshot), do: value(snapshot, "capabilities") || []

  @spec template_metadata(map()) :: map()
  def template_metadata(snapshot), do: value(snapshot, "metadata") || %{}

  @spec sandbox_level(map()) :: atom()
  def sandbox_level(snapshot) do
    snapshot
    |> value("sandbox_level")
    |> SandboxLevel.coerce()
  end

  @spec trust_preset(map()) :: map()
  def trust_preset(snapshot), do: value(snapshot, "trust_preset") || %{}

  @spec repo_root(map()) :: String.t() | nil
  def repo_root(snapshot), do: value(snapshot, "repo_root")

  defp build_envelope(template_name, data, metadata, opts) do
    with :ok <- validate_template_name(template_name, data),
         {:ok, runtime} <- normalize_runtime(value(metadata, "runtime")),
         {:ok, tools} <- normalize_tools(value(metadata, "tools")),
         {:ok, normalized_metadata} <- normalize_metadata(metadata, runtime, tools),
         {:ok, repo_root} <- normalize_repo_root(Keyword.get(opts, :repo_root)),
         {:ok, sandbox_level} <- normalize_sandbox_level(value(data, "sandbox_level")),
         {:ok, capabilities} <-
           normalize_capabilities(value(data, "required_capabilities"), repo_root),
         {:ok, trust_preset} <- normalize_trust_preset(value(data, "trust_preset")) do
      snapshot = %{
        "version" => @snapshot_version,
        "template" => template_name,
        "metadata" => normalized_metadata,
        "repo_root" => repo_root,
        "sandbox_level" => sandbox_level,
        "capabilities" => capabilities,
        "trust_preset" => trust_preset
      }

      {:ok,
       %{
         "version" => @snapshot_version,
         "snapshot" => snapshot,
         "digest" => snapshot_digest(snapshot)
       }}
    end
  end

  defp validate_template_name(template_name, data) do
    case value(data, "name") do
      ^template_name -> :ok
      nil -> error(:template_name_missing)
      other -> error({:template_name_mismatch, other, template_name})
    end
  end

  defp normalize_runtime(runtime) when runtime in @runtimes, do: {:ok, runtime}

  defp normalize_runtime(runtime) when runtime in [:arbor, :acp],
    do: {:ok, Atom.to_string(runtime)}

  defp normalize_runtime(_runtime), do: error(:runtime_missing_or_invalid)

  defp normalize_tools(tools) when is_list(tools) do
    if Enum.all?(tools, &(is_binary(&1) and &1 != "")) do
      {:ok, tools}
    else
      error(:tools_invalid)
    end
  end

  defp normalize_tools(_tools), do: error(:tools_missing_or_invalid)

  defp normalize_metadata(metadata, runtime, tools) do
    with {:ok, normalized} <- normalize_json(metadata) do
      normalized =
        normalized
        |> Map.put("capability_policy", "exact")
        |> Map.put("runtime_policy", "exact")
        |> Map.put("runtime", runtime)
        |> Map.put("sandbox_policy", "exact")
        |> Map.put("tool_policy", "exact")
        |> Map.put("tools", tools)
        |> Map.put("trust_preset_policy", "exact")

      {:ok, normalized}
    end
  end

  defp normalize_sandbox_level(level)
       when level in [:strict, :standard, :permissive, :none],
       do: {:ok, Atom.to_string(level)}

  defp normalize_sandbox_level(level)
       when level in ["strict", "standard", "permissive", "none"],
       do: {:ok, level}

  defp normalize_sandbox_level(_level), do: error(:sandbox_level_missing_or_invalid)

  defp normalize_capabilities(capabilities, repo_root) when is_list(capabilities) do
    capabilities
    |> Enum.reduce_while({:ok, []}, fn capability, {:ok, acc} ->
      case normalize_capability(capability, repo_root) do
        {:ok, normalized} -> {:cont, {:ok, normalized ++ acc}}
        {:error, _} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized =
          normalized
          |> Enum.uniq()
          |> Enum.sort_by(&canonical_term/1)

        {:ok, normalized}

      {:error, _} = failure ->
        failure
    end
  end

  defp normalize_capabilities(_capabilities, _repo_root),
    do: error(:capabilities_missing_or_invalid)

  defp normalize_capability(capability, repo_root) when is_map(capability) do
    resource = value(capability, "resource")

    if is_binary(resource) and resource != "" do
      with {:ok, constraints} <- normalize_constraints(value(capability, "constraints")),
           {:ok, resources} <- expand_exact_resource(resource, repo_root) do
        {:ok,
         Enum.map(resources, fn expanded ->
           %{"resource" => expanded, "constraints" => constraints}
         end)}
      end
    else
      error(:capability_resource_missing_or_invalid)
    end
  end

  defp normalize_capability(_capability, _repo_root), do: error(:capability_invalid)

  defp expand_exact_resource("arbor://orchestrator/execute", _repo_root),
    do: {:ok, @session_turn_capability_uris}

  defp expand_exact_resource(resource, repo_root)
       when resource in ["arbor://fs/read", "arbor://fs/read/repo"] do
    expand_repo_resource(:read, repo_root)
  end

  defp expand_exact_resource(resource, repo_root)
       when resource in ["arbor://fs/list", "arbor://fs/list/repo"] do
    expand_repo_resource(:list, repo_root)
  end

  defp expand_exact_resource(resource, _repo_root) do
    if String.contains?(resource, "/self") do
      error({:agent_scoped_resource_cannot_be_snapshotted, resource})
    else
      {:ok, [resource]}
    end
  end

  defp expand_repo_resource(_operation, nil), do: error(:repo_root_required)

  defp expand_repo_resource(operation, repo_root) do
    op = Atom.to_string(operation)
    uri_root = String.trim_leading(repo_root, "/")
    {:ok, ["arbor://fs/#{op}", "arbor://fs/#{op}/#{uri_root}/**"]}
  end

  defp normalize_repo_root(nil), do: {:ok, nil}

  defp normalize_repo_root(repo_root) when is_binary(repo_root) do
    expanded = Path.expand(repo_root)

    case SafePath.resolve_real(expanded) do
      {:ok, real_root} when real_root != "" -> {:ok, String.trim_trailing(real_root, "/")}
      _ -> error(:repo_root_invalid)
    end
  end

  defp normalize_repo_root(_repo_root), do: error(:repo_root_invalid)

  defp normalize_constraints(nil), do: {:ok, %{}}

  defp normalize_constraints(constraints) when is_map(constraints) do
    normalized =
      Map.new(constraints, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

    unknown = Map.keys(normalized) -- @known_constraint_keys

    if unknown == [] do
      {:ok, normalized}
    else
      error({:unsupported_capability_constraints, Enum.sort(unknown)})
    end
  end

  defp normalize_constraints(_constraints), do: error(:capability_constraints_invalid)

  defp normalize_trust_preset(preset) when is_map(preset) do
    with {:ok, baseline} <- normalize_trust_mode(value(preset, "baseline")),
         {:ok, rules} <- normalize_trust_rules(value(preset, "rules")) do
      {:ok, %{"baseline" => baseline, "rules" => rules}}
    end
  end

  defp normalize_trust_preset(_preset), do: error(:trust_preset_missing_or_invalid)

  defp normalize_trust_rules(rules) when is_map(rules) do
    Enum.reduce_while(rules, {:ok, %{}}, fn {uri, mode}, {:ok, acc} ->
      if is_binary(uri) and uri != "" do
        case normalize_trust_mode(mode) do
          {:ok, normalized_mode} ->
            normalized_uri =
              if TrustRule.glob?(uri), do: TrustRule.canonicalize(uri), else: uri

            {:cont, {:ok, Map.put(acc, normalized_uri, normalized_mode)}}

          {:error, _} = failure ->
            {:halt, failure}
        end
      else
        {:halt, error(:trust_rule_uri_invalid)}
      end
    end)
  end

  defp normalize_trust_rules(_rules), do: error(:trust_rules_missing_or_invalid)

  defp normalize_trust_mode(mode) when mode in @trust_modes, do: {:ok, mode}

  defp normalize_trust_mode(mode) when mode in [:block, :ask, :allow, :auto],
    do: {:ok, Atom.to_string(mode)}

  defp normalize_trust_mode(_mode), do: error(:trust_mode_invalid)

  defp normalize_json(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_json(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_json(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_json(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = failure -> failure
    end
  end

  defp normalize_json(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(normalized_key) do
        case normalize_json(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, normalized_key, normalized)}}
          {:error, _} = failure -> {:halt, failure}
        end
      else
        {:halt, error(:metadata_key_invalid)}
      end
    end)
  end

  defp normalize_json(_value), do: error(:metadata_not_json_clean)

  defp validate_envelope(envelope) do
    version = value(envelope, "version")
    snapshot = value(envelope, "snapshot")
    digest = value(envelope, "digest")

    cond do
      version != @snapshot_version ->
        error({:unsupported_snapshot_version, version})

      not is_map(snapshot) ->
        error(:snapshot_missing_or_invalid)

      not (is_binary(digest) and byte_size(digest) == 64) ->
        error(:digest_missing_or_invalid)

      snapshot_digest(snapshot) != digest ->
        error(:profile_snapshot_digest_mismatch)

      true ->
        {:ok,
         %{
           "version" => version,
           "snapshot" => snapshot,
           "digest" => digest
         }}
    end
  end

  defp require_profile_envelope(metadata) do
    case from_metadata(metadata) do
      {:ok, envelope} -> {:ok, envelope}
      :not_marked -> error(:profile_metadata_missing)
      {:error, _} = failure -> failure
    end
  end

  defp require_exact_template({:ok, envelope}), do: {:ok, envelope}
  defp require_exact_template(:not_exact), do: error(:template_exact_metadata_missing)
  defp require_exact_template({:error, _} = failure), do: failure

  defp compare_envelopes(stored, current) do
    cond do
      digest(stored) != digest(current) -> error(:template_digest_mismatch)
      snapshot(stored) != snapshot(current) -> error(:template_snapshot_mismatch)
      true -> :ok
    end
  end

  defp snapshot_digest(snapshot) do
    snapshot
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, _value} = found -> found
      :error -> Map.fetch(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> :error
  end

  defp value(map, key) when is_map(map) do
    case fetch_value(map, key) do
      {:ok, found} -> found
      :error -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp error(reason), do: {:error, {:exact_template_policy, reason}}
end
