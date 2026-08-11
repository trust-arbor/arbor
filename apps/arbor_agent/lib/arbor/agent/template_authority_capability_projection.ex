defmodule Arbor.Agent.TemplateAuthorityCapabilityProjection do
  @moduledoc """
  Pure projection of declared capability specs to **effective runtime** form.

  Mirrors ordinary (non-exact) `Lifecycle` grant expansion without side effects:

  - resolve `/self` against a concrete agent id
  - `arbor://orchestrator/execute` → `arbor://orchestrator/execute/**`
  - `arbor://fs/read` and `arbor://fs/read/repo` → bare action gate plus
    repo-root-scoped `/**` URI (likewise `fs/list`)
  - normalize known constraints identically (`rate_limit`, `requires_approval`);
    unknown keys are dropped like Lifecycle

  Repo root is an injected pure absolute path — never derived from
  `File.cwd!/0` or other filesystem reads — so the apply path can reuse the
  same primitive with a fixed root.

  Phase 4B uses ordinary non-exact semantics only. Exact-template Session turn
  expansion is intentionally out of scope here.

  Admission is bounded and fail-closed: single-pass list walk (no `length/1`
  on untrusted spines), atom/string key conflicts, and `resource` /
  `resource_uri` alias conflicts are rejected before expansion.
  """

  alias Arbor.Agent.TemplateAuthorityPolicy

  @max_capabilities 256
  @max_resource_bytes 1_024
  @max_agent_id_bytes 256
  @allowed_opt_keys [:repo_root]

  @type effective_spec :: %{required(String.t()) => term()}

  @doc """
  Project a list of declared capability maps to effective runtime specs.

  Options (closed, duplicate-free keyword list):

    * `:repo_root` — canonical absolute repo root used for fs expansion
      (required when any capability expands through the repo shorthand)
  """
  @spec project(term(), String.t(), keyword()) ::
          {:ok, [effective_spec()]} | {:error, term()}
  def project(capabilities, agent_id, opts \\ [])

  def project(capabilities, agent_id, opts)
      when is_list(capabilities) and is_binary(agent_id) and is_list(opts) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, repo_root} <- admit_opts(opts),
         {:ok, specs} <- project_list(capabilities, agent_id, repo_root, 0, []) do
      finalize_specs(specs)
    end
  end

  def project(_capabilities, _agent_id, _opts), do: error(:invalid_projection_input)

  @doc """
  Project then admit through `TemplateAuthorityPolicy.normalize_capabilities/1`.

  Produces the closed string-keyed form used by reconciliation and digests.
  URI admission is delegated to CapabilityUri via TemplateAuthorityPolicy.
  """
  @spec project_normalized(term(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def project_normalized(capabilities, agent_id, opts \\ []) do
    with {:ok, specs} <- project(capabilities, agent_id, opts) do
      case TemplateAuthorityPolicy.normalize_capabilities(specs) do
        {:ok, normalized} ->
          {:ok, normalized}

        {:error, {:template_authority_policy, reason}} ->
          error(reason)

        {:error, reason} ->
          error(reason)
      end
    end
  end

  @doc """
  Pure structural admission of a canonical absolute repo root.

  No filesystem reads and no cwd. Windows drive paths are out of scope for
  this Arbor runtime surface. Shared by Preview preparation and OperationCore
  frozen-authority validation so path normalizers cannot drift.
  """
  @spec admit_canonical_repo_root(term()) ::
          {:ok, String.t()} | {:error, {:template_authority_projection, term()}}
  def admit_canonical_repo_root(root), do: normalize_repo_root(root)

  # ---------------------------------------------------------------------------
  # Bounded single-pass list admission + projection
  # ---------------------------------------------------------------------------

  # Walk the declared list once: count, reject improper tails / oversize, and
  # project each entry. Never call length/1 on untrusted spines.
  defp project_list([], _agent_id, _repo_root, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp project_list([cap | rest], agent_id, repo_root, count, acc)
       when count < @max_capabilities do
    case project_one(cap, agent_id, repo_root) do
      {:ok, specs} when is_list(specs) ->
        project_list(rest, agent_id, repo_root, count + 1, prepend_reverse(specs, acc))

      {:error, _} = failure ->
        failure
    end
  end

  defp project_list([_cap | _rest], _agent_id, _repo_root, _count, _acc),
    do: error(:capabilities_too_many)

  defp project_list(_improper, _agent_id, _repo_root, _count, _acc),
    do: error(:capabilities_missing_or_invalid)

  defp prepend_reverse([], acc), do: acc
  defp prepend_reverse([h | t], acc), do: prepend_reverse(t, [h | acc])

  # ---------------------------------------------------------------------------
  # One declared capability → zero or more effective specs
  # ---------------------------------------------------------------------------

  defp project_one(cap, agent_id, repo_root) when is_map(cap) and not is_struct(cap) do
    with {:ok, resource} <- admit_declared_resource(cap),
         resolved <- resolve_self_uri(resource, agent_id),
         {:ok, resources} <- expand_runtime_uris(resolved, repo_root),
         {:ok, raw_constraints} <- value_constraints(cap),
         {:ok, constraints} <- normalize_constraints(raw_constraints) do
      specs =
        Enum.map(resources, fn res ->
          %{"resource" => res, "constraints" => constraints}
        end)

      {:ok, specs}
    end
  end

  defp project_one(_cap, _agent_id, _repo_root), do: error(:capability_invalid)

  # resource / resource_uri are aliases. Atom and string forms of each key are
  # admitted uniquely; conflicting pairs fail closed (order never chooses).
  defp admit_declared_resource(cap) when is_map(cap) do
    with {:ok, resource} <- fetch_unique_field(cap, "resource", :resource),
         {:ok, resource_uri} <- fetch_unique_field(cap, "resource_uri", :resource_uri) do
      case {resource, resource_uri} do
        {:absent, :absent} ->
          error(:capability_resource_missing_or_invalid)

        {{:present, value}, :absent} ->
          require_resource(value)

        {:absent, {:present, value}} ->
          require_resource(value)

        {{:present, left}, {:present, right}} ->
          if left === right do
            require_resource(left)
          else
            error(:capability_resource_alias_conflict)
          end
      end
    end
  end

  defp fetch_unique_field(map, string_key, atom_key)
       when is_map(map) and is_binary(string_key) and is_atom(atom_key) do
    string_present? = Map.has_key?(map, string_key)
    atom_present? = Map.has_key?(map, atom_key)

    cond do
      string_present? and atom_present? ->
        string_val = Map.fetch!(map, string_key)
        atom_val = Map.fetch!(map, atom_key)

        if string_val === atom_val do
          {:ok, {:present, string_val}}
        else
          error(:capability_resource_key_conflict)
        end

      string_present? ->
        {:ok, {:present, Map.fetch!(map, string_key)}}

      atom_present? ->
        {:ok, {:present, Map.fetch!(map, atom_key)}}

      true ->
        {:ok, :absent}
    end
  end

  defp require_resource(resource) when is_atom(resource),
    do: require_resource(Atom.to_string(resource))

  defp require_resource(resource) when is_binary(resource) do
    if resource != "" and byte_size(resource) <= @max_resource_bytes and String.valid?(resource) and
         not String.contains?(resource, <<0>>) do
      {:ok, resource}
    else
      error(:capability_resource_missing_or_invalid)
    end
  end

  defp require_resource(_resource), do: error(:capability_resource_missing_or_invalid)

  # Expand self-scoped capability URIs to the agent's id. Mirrors Lifecycle /
  # trust resolve_uri so template-declared `/self/` caps project to the same
  # concrete resource ordinary grants use.
  defp resolve_self_uri(uri, agent_id) when is_binary(uri) and is_binary(agent_id) do
    uri
    |> String.replace("/self/", "/#{agent_id}/")
    |> String.replace(~r"/self$", "/#{agent_id}")
  end

  # Ordinary non-exact semantics only (Phase 4B). Exact Session turn expansion
  # is Lifecycle's exact-template path and is not mirrored here.
  defp expand_runtime_uris("arbor://orchestrator/execute", _repo_root),
    do: {:ok, ["arbor://orchestrator/execute/**"]}

  defp expand_runtime_uris(uri, repo_root)
       when uri in ["arbor://fs/read", "arbor://fs/read/repo"],
       do: repo_scoped_fs_uris(:read, repo_root)

  defp expand_runtime_uris(uri, repo_root)
       when uri in ["arbor://fs/list", "arbor://fs/list/repo"],
       do: repo_scoped_fs_uris(:list, repo_root)

  defp expand_runtime_uris(uri, _repo_root) when is_binary(uri), do: {:ok, [uri]}

  defp repo_scoped_fs_uris(operation, repo_root) when operation in [:read, :list] do
    case normalize_repo_root(repo_root) do
      {:ok, root} ->
        op = Atom.to_string(operation)
        trimmed = String.trim_leading(root, "/")
        {:ok, ["arbor://fs/#{op}", "arbor://fs/#{op}/#{trimmed}/**"]}

      {:error, _} = failure ->
        failure
    end
  end

  # Pure absolute-path validation — no filesystem reads, no cwd fallback.
  defp normalize_repo_root(root) when is_binary(root) do
    root = root |> String.trim() |> String.trim_trailing("/")

    cond do
      root == "" or byte_size(root) > @max_resource_bytes ->
        error(:repo_root_missing_or_invalid)

      not String.valid?(root) or String.contains?(root, <<0>>) ->
        error(:repo_root_missing_or_invalid)

      not absolute_path?(root) ->
        error(:repo_root_missing_or_invalid)

      has_dot_segment?(root) ->
        error(:repo_root_missing_or_invalid)

      true ->
        {:ok, root}
    end
  end

  defp normalize_repo_root(_root), do: error(:repo_root_missing_or_invalid)

  defp absolute_path?(path) when is_binary(path) do
    # Pure structural check for absolute Unix/macOS paths. Windows drive paths
    # are out of scope for this Arbor runtime surface.
    String.starts_with?(path, "/") and not String.starts_with?(path, "//")
  end

  defp has_dot_segment?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  # Lifecycle drops unknown constraint keys before grant. Keep that expansion
  # semantics here; value admission and URI bounds run once through Policy in
  # finalize_specs/1 so projection does not reimplement the authority schema.
  # Atom/string pairs for the same logical key must agree — never let map
  # iteration order choose a winner.
  defp value_constraints(cap) when is_map(cap) do
    string_present? = Map.has_key?(cap, "constraints")
    atom_present? = Map.has_key?(cap, :constraints)

    cond do
      string_present? and atom_present? ->
        string_val = Map.fetch!(cap, "constraints")
        atom_val = Map.fetch!(cap, :constraints)

        if string_val === atom_val do
          {:ok, string_val}
        else
          error(:capability_constraints_invalid)
        end

      string_present? ->
        {:ok, Map.fetch!(cap, "constraints")}

      atom_present? ->
        {:ok, Map.fetch!(cap, :constraints)}

      true ->
        {:ok, nil}
    end
  end

  defp normalize_constraints(nil), do: {:ok, %{}}

  defp normalize_constraints(constraints)
       when is_map(constraints) and not is_struct(constraints) do
    with {:ok, rate_limit} <-
           merge_constraint_pair(constraints, "rate_limit", :rate_limit),
         {:ok, requires_approval} <-
           merge_constraint_pair(constraints, "requires_approval", :requires_approval) do
      cleaned =
        %{}
        |> put_present("rate_limit", rate_limit)
        |> put_present("requires_approval", requires_approval)
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Map.new()

      {:ok, cleaned}
    end
  end

  defp normalize_constraints(_constraints), do: error(:capability_constraints_invalid)

  defp merge_constraint_pair(constraints, string_key, atom_key)
       when is_map(constraints) and is_binary(string_key) and is_atom(atom_key) do
    string_present? = Map.has_key?(constraints, string_key)
    atom_present? = Map.has_key?(constraints, atom_key)

    cond do
      string_present? and atom_present? ->
        string_val = Map.fetch!(constraints, string_key)
        atom_val = Map.fetch!(constraints, atom_key)

        if string_val === atom_val do
          {:ok, {:present, string_val}}
        else
          error(:capability_constraints_invalid)
        end

      string_present? ->
        {:ok, {:present, Map.fetch!(constraints, string_key)}}

      atom_present? ->
        {:ok, {:present, Map.fetch!(constraints, atom_key)}}

      true ->
        {:ok, :absent}
    end
  end

  defp put_present(map, _key, :absent), do: map
  defp put_present(map, key, {:present, value}), do: Map.put(map, key, value)

  defp finalize_specs(specs) do
    # Expand may produce duplicate resources (e.g. overlapping declarations).
    # Policy is the single normalizer: identical duplicates collapse; conflicts
    # and invalid constraint values fail closed.
    case TemplateAuthorityPolicy.normalize_capabilities(specs) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, {:template_authority_policy, reason}} ->
        error(reason)

      {:error, reason} ->
        error(reason)
    end
  end

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    if agent_id != "" and byte_size(agent_id) <= @max_agent_id_bytes and String.valid?(agent_id) and
         not String.contains?(agent_id, <<0>>) do
      :ok
    else
      error(:agent_id_invalid)
    end
  end

  # Only :repo_root is admitted. Bound the untrusted opts spine to at most one
  # proper {atom, value} entry — never Keyword.keyword?/1, keys/1, or full-spine
  # Enum walks that raise or scan unbounded improper lists.
  defp admit_opts(opts) when is_list(opts), do: admit_opts_list(opts, 0, :absent)
  defp admit_opts(_opts), do: error(:invalid_projection_options)

  defp admit_opts_list([], _count, :absent), do: {:ok, nil}
  defp admit_opts_list([], _count, {:present, root}), do: admit_repo_root_opt(root)

  defp admit_opts_list([{key, value} | rest], count, :absent)
       when count < 1 and is_atom(key) do
    if key in @allowed_opt_keys do
      admit_opts_list(rest, count + 1, {:present, value})
    else
      error(:invalid_projection_options)
    end
  end

  # Oversized (more than one entry), duplicate keys, non-atom keys, non-pairs.
  defp admit_opts_list([_entry | _rest], _count, _acc),
    do: error(:invalid_projection_options)

  # Improper list tail.
  defp admit_opts_list(_improper, _count, _acc), do: error(:invalid_projection_options)

  defp admit_repo_root_opt(root) do
    # Keep raw binary for later expansion; structural path validation runs when
    # a repo-scoped URI actually needs it.
    if is_binary(root) and byte_size(root) <= @max_resource_bytes and String.valid?(root) and
         not String.contains?(root, <<0>>) do
      {:ok, root}
    else
      error(:repo_root_missing_or_invalid)
    end
  end

  defp error(reason), do: {:error, {:template_authority_projection, reason}}
end
