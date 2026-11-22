defmodule Arbor.KernelRuntime.FeatureReport do
  @moduledoc """
  Read-only reports about declarations in applications already loaded here.

  Discovery never starts applications or loads a declaration to inspect it. A
  configured declaration must belong to its application's module list and already
  be loaded. Owner snapshots are supplied by the caller; this module obtains no
  private reference, admission result, network observation or backend attestation.

  Full child specifications remain local to this call. Public projections discard
  all start values and private options. Only fixed, source-declared public child
  identities and provided-field names are exposed. Unknown identities are redacted.
  Caller-provided child-ID observations can reveal a mismatch, but are not proof
  of runtime provenance or equality of private start arguments.
  """

  @mandatory [id: 0, requires: 0, children: 1, action_modules: 0, uri_prefixes: 0, health: 0]
  @fields [:id, :start, :restart, :shutdown, :type, :modules, :significant]
  @source_keys [
    :action_modules,
    :uri_prefixes,
    :physical_owner,
    :physical_catalog_owner,
    :catalog_owner,
    :owner,
    :app,
    :module,
    :catalog,
    :registering_actor,
    :registration_actor,
    :uri_registration_actor,
    :registration_status,
    :uri_registration_status,
    :kind,
    :scope,
    :role,
    :reference_role,
    :application,
    :catalog_producer,
    :action_catalog_scope,
    :uri_role,
    :action_catalog,
    :uri_provider,
    :direct_global_action_catalog,
    :direct_global_uri_provider,
    :observation,
    :routes,
    :coverage,
    :ranch_constructor
  ]

  @doc """
  Reads loaded-app metadata and already-loaded declaration callbacks.

  `snapshots` is keyed by application. Optional `observations` entries contain
  only owner-provided `child_ids`; they are compared as multisets, without assuming
  that supervisor observations preserve definition order. No observation is fetched
  here. Missing observations are unobserved; supplied malformed observations are
  explicitly invalid. Missing snapshots or conditional facts remain unresolved.
  """
  @spec inspect_loaded(map(), map()) :: map()
  def inspect_loaded(snapshots \\ %{}, observations \\ %{})

  def inspect_loaded(snapshots, observations) when is_map(snapshots) and is_map(observations) do
    features =
      Application.loaded_applications()
      |> Enum.flat_map(fn {app, _, _} ->
        case Application.fetch_env(app, :arbor_feature) do
          :error -> []
          {:ok, declaration} -> [inspect_declaration(app, declaration, snapshots, observations)]
        end
      end)
      |> Enum.sort_by(& &1.app)

    duplicate_ids =
      features
      |> Enum.map(& &1.id)
      |> Enum.reject(&(&1 == :unresolved))
      |> Enum.frequencies()
      |> Enum.flat_map(fn {id, count} -> if count > 1, do: [id], else: [] end)
      |> Enum.sort()

    %{
      scope: :loaded_release_declarations,
      features: features,
      duplicate_declared_ids: duplicate_ids,
      runtime_or_startup_admission_credit: false
    }
  end

  def inspect_loaded(_, _), do: raise(ArgumentError, "invalid feature report input")

  defp inspect_declaration(app, declaration, snapshots, observations) do
    metadata = Application.get_env(app, :arbor_feature_metadata, %{})
    metadata = if is_map(metadata), do: metadata, else: %{}

    base = %{
      app: app,
      id: declared_id(metadata),
      declared_requires: declared_requires(metadata),
      dependency_role: public_dependency_role(metadata[:dependency_role]),
      contribution_scope: public_scope(metadata[:contribution_scope]),
      sources: public_sources(metadata[:sources]),
      callback_data: :unresolved
    }

    cond do
      not valid_module?(declaration) ->
        Map.put(base, :state, :invalid_declaration)

      declaration not in (Application.spec(app, :modules) || []) ->
        Map.put(base, :state, :declaration_ownership_mismatch)

      :code.is_loaded(declaration) == false ->
        Map.put(base, :state, :declared_module_unloaded)

      not valid_metadata?(metadata) ->
        Map.put(base, :state, :invalid_declaration_metadata)

      not contract_implementation?(declaration) ->
        Map.put(base, :state, :contract_incomplete)

      true ->
        read_declaration(base, app, declaration, metadata, snapshots, observations)
    end
  end

  defp read_declaration(base, app, declaration, metadata, snapshots, observations) do
    mismatches =
      []
      |> mismatch(call(declaration, :id, []), base.id, :id_mismatch)
      |> mismatch(call(declaration, :requires, []), base.declared_requires, :requires_mismatch)

    children = read_children(app, declaration, metadata, snapshots, observations)

    mismatches =
      if children[:identity_match] == false,
        do: [:child_identity_mismatch | mismatches],
        else: mismatches

    mismatches =
      if children[:duplicate_declared_ids],
        do: [:duplicate_declared_child_ids | mismatches],
        else: mismatches

    Map.merge(base, %{
      state: :declaration_read,
      callback_data: :read_without_startup_admission,
      mismatches: Enum.reverse(mismatches),
      children: children,
      health: declared_health(call(declaration, :health, [])),
      contributions: %{
        action_modules: contribution(declaration, :action_modules, :modules),
        uri_prefixes: contribution(declaration, :uri_prefixes, :strings),
        graphs: contribution(declaration, :graphs, :graphs),
        routes: contribution(declaration, :routes, :terms),
        commands: contribution(declaration, :commands, :modules)
      }
    })
  end

  defp read_children(app, declaration, metadata, snapshots, observations) do
    with {:ok, snapshot} <- Map.fetch(snapshots, app),
         true <- is_map(snapshot),
         :ok <- complete_snapshot(metadata, snapshot),
         {:ok, specs} <- call(declaration, :children, [snapshot]),
         true <- valid_specs?(specs) do
      ids = Enum.map(specs, &Map.fetch!(&1, :id))
      public_ids = public_identity_whitelist(metadata[:public_child_ids])

      %{
        state: :declaration_read,
        specifications: Enum.map(specs, &project_spec(&1, public_ids)),
        duplicate_declared_ids: map_size(Enum.frequencies(ids)) != length(ids),
        identity_match: identity_match(Map.fetch(observations, app), ids),
        private_arguments_compared: false
      }
    else
      _ -> %{state: :snapshot_unresolved, private_arguments_compared: false}
    end
  end

  defp complete_snapshot(metadata, snapshot) do
    conditions = Map.get(metadata, :snapshot_conditional_required_keys, %{})

    with {:ok, required} <- Map.fetch(metadata, :snapshot_required_keys),
         true <- atom_keys?(required),
         true <- valid_conditions?(conditions),
         {:ok, required} <- conditional_keys(conditions, snapshot, required),
         true <- Enum.all?(required, &Map.has_key?(snapshot, &1)) do
      :ok
    else
      _ -> :unresolved
    end
  end

  defp conditional_keys(conditions, snapshot, required) do
    Enum.reduce_while(conditions, {:ok, required}, fn {key, branches}, {:ok, keys} ->
      cond do
        not is_atom(key) or not is_map(branches) ->
          {:halt, :unresolved}

        not Map.has_key?(snapshot, key) ->
          {:halt, :unresolved}

        not condition_scalar?(Map.fetch!(snapshot, key)) ->
          {:halt, :unresolved}

        true ->
          case Map.fetch(branches, Map.fetch!(snapshot, key)) do
            {:ok, more} ->
              if atom_keys?(more), do: {:cont, {:ok, keys ++ more}}, else: {:halt, :unresolved}

            :error ->
              {:halt, :unresolved}
          end
      end
    end)
  end

  defp valid_conditions?(conditions) when is_map(conditions) do
    Enum.all?(conditions, fn {key, branches} ->
      atom_keys?([key]) and is_map(branches) and
        Enum.all?(branches, fn {value, keys} -> condition_scalar?(value) and atom_keys?(keys) end)
    end)
  end

  defp valid_conditions?(_), do: false
  defp condition_scalar?(value), do: is_atom(value) or is_binary(value) or is_number(value)

  defp valid_specs?(specs) when is_list(specs) do
    Enum.all?(specs, fn
      %{id: _, start: {module, function, args}} = spec ->
        valid_module?(module) and is_atom(function) and is_list(args) and
          Enum.all?(Map.keys(spec), &(&1 in @fields)) and valid_optional_fields?(spec)

      _ ->
        false
    end)
  end

  defp valid_specs?(_), do: false

  defp valid_optional_fields?(spec) do
    Enum.all?(spec, fn
      {:id, _} ->
        true

      {:start, _} ->
        true

      {:restart, value} ->
        value in [:permanent, :transient, :temporary]

      {:shutdown, value} ->
        value in [:infinity, :brutal_kill] or (is_integer(value) and value >= 0)

      {:type, value} ->
        value in [:worker, :supervisor]

      {:modules, :dynamic} ->
        true

      {:modules, values} when is_list(values) ->
        Enum.all?(values, &valid_module?/1)

      {:significant, value} ->
        is_boolean(value)

      _ ->
        false
    end)
  end

  defp project_spec(spec, public_ids) do
    id = Map.fetch!(spec, :id)

    %{
      id: if(id in public_ids and public_identity?(id), do: id, else: :redacted),
      provided_fields: Enum.filter(@fields, &Map.has_key?(spec, &1))
    }
  end

  defp identity_match({:ok, %{child_ids: ids}}, expected) when is_list(ids) do
    Enum.frequencies(ids) == Enum.frequencies(expected)
  end

  defp identity_match(:error, _), do: :unobserved
  defp identity_match(_, _), do: :invalid_observation

  defp contribution(declaration, callback, kind) do
    if function_exported?(declaration, callback, 0) do
      case call(declaration, callback, []) do
        {:ok, values} when is_list(values) ->
          if contribution_values?(values, kind) do
            %{state: :declared, count: length(values)}
          else
            %{state: :invalid_declaration_data}
          end

        _ ->
          %{state: :callback_unresolved}
      end
    else
      %{state: :undeclared}
    end
  end

  defp contribution_values?(values, :modules), do: Enum.all?(values, &valid_module?/1)
  defp contribution_values?(values, :strings), do: Enum.all?(values, &is_binary/1)

  defp contribution_values?(values, :graphs) do
    Enum.all?(values, fn
      {name, path} when is_binary(name) -> graph_path?(path)
      _ -> false
    end)
  end

  defp contribution_values?(_, :terms), do: true

  defp graph_path?(path) when is_binary(path), do: true

  defp graph_path?(path) when is_list(path) do
    is_binary(:unicode.characters_to_binary(path))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp graph_path?(_), do: false

  defp declared_health({:ok, %{status: status}})
       when status in [:unobserved, :healthy, :unhealthy, :degraded] do
    %{state: :declared, status: status, measured_here: false}
  end

  defp declared_health(_), do: %{state: :unresolved, measured_here: false}

  defp contract_implementation?(declaration) do
    attributes = apply(declaration, :module_info, [:attributes])
    behaviours = attributes |> Keyword.get_values(:behaviour) |> List.flatten()

    Arbor.Contracts.Feature in behaviours and
      Enum.all?(@mandatory, fn {function, arity} ->
        function_exported?(declaration, function, arity)
      end)
  end

  defp call(declaration, function, arguments) do
    {:ok, apply(declaration, function, arguments)}
  rescue
    _ -> {:error, :callback_refused}
  catch
    _, _ -> {:error, :callback_refused}
  end

  defp mismatch(values, expected, reason) do
    case values do
      {:ok, ^expected} -> []
      _ -> [reason]
    end
  end

  defp mismatch(reasons, values, expected, reason),
    do: mismatch(values, expected, reason) ++ reasons

  defp declared_id(%{id: id}) when is_atom(id) and id not in [nil, true, false], do: id
  defp declared_id(_), do: :unresolved

  defp declared_requires(%{requires: ids}) do
    if atom_keys?(ids), do: ids, else: :unresolved
  end

  defp declared_requires(_), do: :unresolved

  defp valid_metadata?(metadata) do
    declared_id(metadata) != :unresolved and declared_requires(metadata) != :unresolved and
      Map.has_key?(metadata, :snapshot_required_keys) and
      atom_keys?(metadata[:snapshot_required_keys]) and
      valid_conditions?(Map.get(metadata, :snapshot_conditional_required_keys, %{}))
  end

  defp public_scope(:direct_application_entrypoint), do: :direct_application_entrypoint
  defp public_scope(_), do: :unresolved

  defp public_dependency_role(role) when role in [:fixed_host, :fixed_host_prerequisite], do: role
  defp public_dependency_role(_), do: :unresolved

  defp public_identity_whitelist(ids) when is_list(ids), do: Enum.filter(ids, &public_identity?/1)
  defp public_identity_whitelist(_), do: []

  defp public_identity?(id) when is_atom(id) and id not in [nil, true, false], do: true

  defp public_identity?(id) when is_tuple(id),
    do: id |> Tuple.to_list() |> Enum.all?(&public_identity?/1)

  defp public_identity?(_), do: false

  defp public_sources(sources) when is_map(sources) do
    sources
    |> Enum.filter(fn {key, _} -> key in @source_keys end)
    |> Enum.reduce(%{}, fn
      {key, value}, result when is_atom(value) -> Map.put(result, key, value)
      {key, value}, result when is_map(value) -> Map.put(result, key, public_sources(value))
      _, result -> result
    end)
  end

  defp public_sources(_), do: %{}

  defp atom_keys?(keys) when is_list(keys),
    do: Enum.all?(keys, &(is_atom(&1) and &1 not in [nil, true, false]))

  defp atom_keys?(_), do: false
  defp valid_module?(module), do: is_atom(module) and module not in [nil, true, false]
end
