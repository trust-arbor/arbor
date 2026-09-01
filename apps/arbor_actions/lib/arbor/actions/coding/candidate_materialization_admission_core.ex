defmodule Arbor.Actions.Coding.CandidateMaterializationAdmissionCore do
  @moduledoc """
  Pure admission decisions for immutable CandidateMaterialization.

  Lineage and acquired base bind to an inspected active lease. The kernel
  descriptor stays `{source_commit_oid, expected_tree_oid, entries}`.
  """

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Contracts.Coding.CandidateMaterialization

  @max_task_id_bytes 256
  @max_workspace_id_bytes 128
  @max_principal_id_bytes 256
  @allowed_changed_modes MapSet.new(["100644", "100755"])
  @input_fields [:workspace_id, :task_id, :principal_id, :candidate_materialization, :server]
  @max_diagnosable_fields 64

  @doc false
  @spec admit_input(term()) :: {:ok, map()} | {:error, term()}
  def admit_input(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @input_fields),
         :ok <-
           require_fields(attrs, [
             :workspace_id,
             :task_id,
             :principal_id,
             :candidate_materialization
           ]),
         {:ok, workspace_id} <- admit_opaque_id(attrs.workspace_id, @max_workspace_id_bytes),
         {:ok, task_id} <- admit_opaque_id(attrs.task_id, @max_task_id_bytes),
         {:ok, principal_id} <- admit_opaque_id(attrs.principal_id, @max_principal_id_bytes),
         {:ok, descriptor} <- CandidateMaterialization.new(attrs.candidate_materialization),
         {:ok, server} <- admit_optional_server(Map.get(attrs, :server)) do
      {:ok,
       %{
         workspace_id: workspace_id,
         task_id: task_id,
         principal_id: principal_id,
         descriptor: descriptor,
         server: server
       }}
    end
  rescue
    _ -> {:error, :malformed_admission_input}
  catch
    _, _ -> {:error, :malformed_admission_input}
  end

  @doc false
  @spec authorize_identity(term(), term()) :: {:ok, map()} | {:error, term()}
  def authorize_identity(lookup, lease) when is_map(lookup) and is_map(lease) do
    with {:ok, task_id} <- require_binary_field(lookup, :task_id),
         {:ok, principal_id} <- require_binary_field(lookup, :principal_id),
         {:ok, workspace_id} <- require_binary_field(lookup, :workspace_id),
         {:ok, lease_task} <- require_binary_field(lease, :task_id),
         {:ok, lease_principal} <- require_binary_field(lease, :principal_id),
         {:ok, lease_workspace} <- require_binary_field(lease, :workspace_id),
         {:ok, base_commit} <- require_binary_field(lease, :base_commit),
         {:ok, repo_path} <- require_binary_field(lease, :repo_path) do
      cond do
        not active_lease?(lease) ->
          {:error, :inactive_workspace_lease}

        task_id !== lease_task or principal_id !== lease_principal or
            workspace_id !== lease_workspace ->
          {:error, :workspace_unauthorized}

        true ->
          {:ok,
           %{
             task_id: task_id,
             principal_id: principal_id,
             workspace_id: workspace_id,
             base_commit: base_commit,
             repo_path: repo_path
           }}
      end
    else
      {:error, :missing_identity_field} -> {:error, :invalid_task_principal}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_identity(_lookup, _lease), do: {:error, :invalid_task_principal}

  @doc false
  @spec prove_trees_and_delta(term()) :: {:ok, map()} | {:error, term()}
  def prove_trees_and_delta(facts) when is_map(facts) do
    descriptor = Map.get(facts, :descriptor) || Map.get(facts, "descriptor")

    with %CandidateMaterialization{} <- descriptor,
         :ok <- require_source_commit(facts),
         :ok <- require_descendant(facts),
         :ok <- require_source_tree(facts, descriptor),
         {:ok, format} <- require_object_format(facts, descriptor),
         {:ok, base_manifest} <- canonical_manifest(facts, :base_manifest),
         {:ok, candidate_manifest} <- canonical_manifest(facts, :candidate_manifest),
         {:ok, changed} <- BlobManifest.diff_blob_manifests(base_manifest, candidate_manifest),
         :ok <- reject_deletions_and_non_regular(changed, candidate_manifest),
         :ok <- require_exact_changed_paths(descriptor, changed),
         :ok <- require_exact_mode_oid(descriptor, candidate_manifest) do
      {:ok,
       %{
         descriptor: descriptor,
         object_format: format,
         candidate_manifest: candidate_manifest,
         base_manifest: base_manifest,
         changed_paths: changed
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :malformed_admission_facts}
    end
  end

  def prove_trees_and_delta(_facts), do: {:error, :malformed_admission_facts}

  @doc false
  @spec decide_effects(term(), term()) :: {:ok, :commit, list()} | {:error, term()}
  def decide_effects(proof, lookup) when is_map(proof) and is_map(lookup) do
    descriptor = Map.get(proof, :descriptor)
    format = Map.get(proof, :object_format)
    manifest = Map.get(proof, :candidate_manifest)
    task_id = Map.get(lookup, :task_id)
    workspace_id = Map.get(lookup, :workspace_id)

    with %CandidateMaterialization{} <- descriptor,
         true <- format in [:sha1, :sha256],
         true <- is_list(manifest),
         true <- is_binary(task_id) and task_id != "",
         true <- is_binary(workspace_id) and workspace_id != "" do
      {:ok, :commit,
       [
         {:materialize_object_snapshot,
          %{
            source_commit_oid: descriptor.source_commit_oid,
            expected_tree_oid: descriptor.expected_tree_oid,
            object_format: format,
            candidate_manifest: manifest
          }},
         {:pin_evidence_ref,
          %{
            task_id: task_id,
            workspace_id: workspace_id,
            source_commit_oid: descriptor.source_commit_oid
          }}
       ]}
    else
      _other -> {:error, :malformed_admission_facts}
    end
  end

  def decide_effects(_proof, _lookup), do: {:error, :malformed_admission_facts}

  defp require_source_commit(facts) do
    type = Map.get(facts, :source_object_type) || Map.get(facts, "source_object_type")

    if type == "commit", do: :ok, else: {:error, :source_commit_missing}
  end

  defp require_descendant(facts) do
    case Map.get(facts, :source_is_descendant) || Map.get(facts, "source_is_descendant") do
      true -> :ok
      false -> {:error, :source_not_descendant}
      _other -> {:error, :source_not_descendant}
    end
  end

  defp require_source_tree(facts, descriptor) do
    observed =
      Map.get(facts, :observed_source_tree_oid) || Map.get(facts, "observed_source_tree_oid")

    if observed === descriptor.expected_tree_oid,
      do: :ok,
      else: {:error, :admitted_tree_mismatch}
  end

  defp require_object_format(facts, descriptor) do
    base_tree =
      Map.get(facts, :observed_base_tree_oid) || Map.get(facts, "observed_base_tree_oid")

    source_tree =
      Map.get(facts, :observed_source_tree_oid) || Map.get(facts, "observed_source_tree_oid")

    base_commit = Map.get(facts, :base_commit) || Map.get(facts, "base_commit")

    with true <- is_binary(base_tree) and base_tree != "",
         {:ok, base_manifest} <- canonical_manifest(facts, :base_manifest),
         {:ok, candidate_manifest} <- canonical_manifest(facts, :candidate_manifest),
         {:ok, base_format} <- BlobManifest.infer_object_format(base_tree, base_manifest),
         {:ok, source_format} <- BlobManifest.infer_object_format(source_tree, candidate_manifest),
         true <- base_format == source_format,
         {:ok, descriptor_format} <- format_for_oid(descriptor.source_commit_oid),
         true <- descriptor_format == source_format,
         {:ok, expected_format} <- format_for_oid(descriptor.expected_tree_oid),
         true <- expected_format == source_format,
         {:ok, base_commit_format} <- format_for_oid(base_commit),
         true <- base_commit_format == source_format do
      {:ok, source_format}
    else
      false ->
        if is_binary(base_tree) and base_tree != "",
          do: {:error, :mixed_object_format},
          else: {:error, :base_tree_oid_unavailable}

      {:error, :mixed_object_format} ->
        {:error, :mixed_object_format}

      {:error, :invalid_blob_manifest} ->
        {:error, :invalid_blob_manifest}

      {:error, reason} ->
        {:error, reason}

      _other ->
        if is_binary(base_tree) and base_tree != "",
          do: {:error, :mixed_object_format},
          else: {:error, :base_tree_oid_unavailable}
    end
  end

  defp canonical_manifest(facts, key) do
    value = Map.get(facts, key) || Map.get(facts, Atom.to_string(key))
    BlobManifest.canonical_entries(value)
  end

  defp reject_deletions_and_non_regular(changed, candidate_manifest) do
    candidate_map = Map.new(candidate_manifest, &{&1.path, &1})

    Enum.reduce_while(changed, :ok, fn path, :ok ->
      case Map.get(candidate_map, path) do
        nil ->
          {:halt, {:error, :descriptor_deletion}}

        %{mode: mode} ->
          if MapSet.member?(@allowed_changed_modes, mode) do
            {:cont, :ok}
          else
            {:halt, {:error, :non_regular_changed_entry}}
          end
      end
    end)
  end

  defp require_exact_changed_paths(descriptor, changed) do
    descriptor_paths = Enum.map(descriptor.entries, & &1["path"])

    cond do
      Enum.any?(descriptor_paths, &(&1 not in changed)) ->
        {:error, :extra_descriptor_path}

      Enum.any?(changed, &(&1 not in descriptor_paths)) ->
        {:error, :missing_descriptor_path}

      descriptor_paths != changed ->
        {:error, :missing_descriptor_path}

      true ->
        :ok
    end
  end

  defp require_exact_mode_oid(descriptor, candidate_manifest) do
    candidate_map = Map.new(candidate_manifest, &{&1.path, &1})

    Enum.reduce_while(descriptor.entries, :ok, fn entry, :ok ->
      path = entry["path"]

      case Map.get(candidate_map, path) do
        nil ->
          {:halt, {:error, :descriptor_deletion}}

        cand ->
          with {:ok, mode} <- mode_int(cand.mode),
               true <- mode == entry["mode"],
               true <- cand.oid == entry["blob_oid"] do
            {:cont, :ok}
          else
            _other -> {:halt, {:error, :descriptor_mode_oid_mismatch}}
          end
      end
    end)
  end

  defp mode_int("100644"), do: {:ok, 100_644}
  defp mode_int("100755"), do: {:ok, 100_755}
  defp mode_int(_mode), do: :error

  defp format_for_oid(oid) when is_binary(oid) do
    case byte_size(oid) do
      40 -> {:ok, :sha1}
      64 -> {:ok, :sha256}
      _other -> {:error, :mixed_object_format}
    end
  end

  defp format_for_oid(_oid), do: {:error, :mixed_object_format}

  defp active_lease?(lease) do
    Map.get(lease, :active, Map.get(lease, "active")) == true
  end

  defp require_binary_field(map, key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, :missing_identity_field}
  end

  defp admit_opaque_id(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    cond do
      String.trim(value) == "" ->
        {:error, :invalid_task_principal}

      not String.valid?(value) ->
        {:error, :invalid_task_principal}

      String.contains?(value, <<0>>) ->
        {:error, :invalid_task_principal}

      byte_size(value) > max_bytes ->
        {:error, :invalid_task_principal}

      true ->
        {:ok, value}
    end
  end

  defp admit_opaque_id(_value, _max_bytes), do: {:error, :invalid_task_principal}

  defp admit_optional_server(nil), do: {:ok, nil}
  defp admit_optional_server(server) when is_atom(server), do: {:ok, server}
  defp admit_optional_server(_server), do: {:error, :malformed_admission_input}

  defp normalize_object(attrs, allowed) when is_map(attrs) and not is_struct(attrs) do
    if map_size(attrs) > @max_diagnosable_fields do
      {:error, {:invalid_object, :object_too_large}}
    else
      normalize_entries(Map.to_list(attrs), allowed)
    end
  end

  defp normalize_object(_attrs, _allowed), do: {:error, {:invalid_object, :object_required}}

  defp normalize_entries(entries, allowed) do
    allowed_names = Enum.map(allowed, &Atom.to_string/1)

    named =
      Enum.map(entries, fn
        {key, value} when is_atom(key) -> {:ok, Atom.to_string(key), value}
        {key, value} when is_binary(key) -> {:ok, key, value}
        _other -> {:invalid, nil}
      end)

    if Enum.any?(named, &match?({:invalid, _}, &1)) do
      {:error, {:invalid_object, :invalid_key}}
    else
      names = Enum.map(named, fn {:ok, name, _value} -> name end)

      duplicates =
        names
        |> Enum.frequencies()
        |> Enum.filter(fn {_name, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      unknown =
        names
        |> Enum.uniq()
        |> Enum.reject(&(&1 in allowed_names))
        |> Enum.sort()

      cond do
        duplicates != [] ->
          {:error, {:duplicate_fields, duplicates}}

        unknown != [] ->
          {:error, {:unknown_fields, unknown}}

        true ->
          fields_by_name = Map.new(allowed, &{Atom.to_string(&1), &1})

          {:ok,
           Map.new(named, fn {:ok, name, value} ->
             {Map.fetch!(fields_by_name, name), value}
           end)}
      end
    end
  end

  defp require_fields(attrs, fields) do
    case Enum.find(fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end
end
