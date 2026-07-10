defmodule Arbor.Orchestrator.CodingPlan.ArtifactStore do
  @moduledoc """
  Archives the immutable inputs and output of coding-plan compilation.

  The caller supplies the per-task artifact root. Artifact names are fixed here
  and never incorporate plan or task text. Each file is written through a
  same-directory, mode-`0600` temporary file and atomically renamed into place.
  """

  @plan_filename "coding-plan.json"
  @pipeline_filename "coding-pipeline.dot"
  @manifest_filename "coding-compile-manifest.json"

  @typedoc "JSON-clean descriptor for an archived coding-plan compilation."
  @type descriptor :: %{required(String.t()) => String.t()}

  @doc """
  Archives a normalized plan, exact generated DOT bytes, and compile manifest.

  The plan and manifest must be plain, string-keyed JSON objects. The manifest
  must contain non-empty `graph_hash` and `compiler_version` strings.
  """
  @spec archive(String.t(), map(), binary(), map()) ::
          {:ok, descriptor()} | {:error, term()}
  def archive(root, plan, dot_source, manifest) do
    with {:ok, root} <- normalize_root(root),
         :ok <- validate_json_object(plan, :invalid_plan),
         :ok <- validate_dot_source(dot_source),
         :ok <- validate_json_object(manifest, :invalid_manifest),
         {:ok, graph_hash} <- fetch_manifest_string(manifest, "graph_hash"),
         {:ok, compiler_version} <- fetch_manifest_string(manifest, "compiler_version"),
         {:ok, plan_json} <- encode_json(plan, :plan),
         {:ok, manifest_json} <- encode_json(manifest, :manifest),
         :ok <- create_root(root),
         paths = artifact_paths(root),
         :ok <- atomic_write(paths.coding_plan, plan_json),
         :ok <- atomic_write(paths.coding_pipeline, dot_source),
         :ok <- atomic_write(paths.compile_manifest, manifest_json) do
      {:ok,
       %{
         "coding_plan_path" => paths.coding_plan,
         "coding_pipeline_path" => paths.coding_pipeline,
         "compile_manifest_path" => paths.compile_manifest,
         "graph_hash" => graph_hash,
         "compiler_version" => compiler_version
       }}
    end
  end

  defp normalize_root(root) when is_binary(root) do
    cond do
      not String.valid?(root) ->
        {:error, {:invalid_root, :invalid_encoding}}

      String.trim(root) == "" ->
        {:error, {:invalid_root, :empty}}

      String.contains?(root, <<0>>) ->
        {:error, {:invalid_root, :null_byte}}

      true ->
        try do
          {:ok, Path.expand(root)}
        rescue
          _ -> {:error, {:invalid_root, :invalid_path}}
        end
    end
  end

  defp normalize_root(_root), do: {:error, {:invalid_root, :expected_string}}

  defp validate_dot_source(dot_source) when is_binary(dot_source) and byte_size(dot_source) > 0,
    do: :ok

  defp validate_dot_source(_dot_source),
    do: {:error, {:invalid_dot_source, :expected_non_empty_binary}}

  defp validate_json_object(value, error_tag) when is_map(value) and not is_struct(value) do
    case validate_json_map(value, []) do
      :ok -> :ok
      {:error, reason} -> {:error, {error_tag, reason}}
    end
  end

  defp validate_json_object(_value, error_tag),
    do: {:error, {error_tag, :expected_string_keyed_map}}

  defp validate_json_map(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      if is_binary(key) do
        case validate_json_value(value, [key | path]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:halt, {:error, {:non_string_key, Enum.reverse(path)}}}
      end
    end)
  end

  defp validate_json_value(value, _path)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_json_value(value, path) when is_list(value),
    do: validate_json_list(value, path, 0)

  defp validate_json_value(value, path) when is_map(value) and not is_struct(value),
    do: validate_json_map(value, path)

  defp validate_json_value(%_struct{}, path),
    do: {:error, {:struct_not_json, Enum.reverse(path)}}

  defp validate_json_value(_value, path),
    do: {:error, {:non_json_value, Enum.reverse(path)}}

  defp validate_json_list([], _path, _index), do: :ok

  defp validate_json_list([head | tail], path, index) do
    with :ok <- validate_json_value(head, [index | path]) do
      validate_json_list(tail, path, index + 1)
    end
  end

  defp validate_json_list(_improper_tail, path, index),
    do: {:error, {:improper_list, Enum.reverse([index | path])}}

  defp fetch_manifest_string(manifest, key) do
    case Map.fetch(manifest, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "" do
          {:ok, value}
        else
          {:error, {:invalid_manifest_field, key}}
        end

      _ ->
        {:error, {:invalid_manifest_field, key}}
    end
  end

  defp encode_json(value, artifact) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:json_encode_failed, artifact, Exception.message(reason)}}
    end
  rescue
    error -> {:error, {:json_encode_failed, artifact, Exception.message(error)}}
  end

  defp create_root(root) do
    case File.mkdir_p(root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_artifact_root_failed, reason}}
    end
  end

  defp artifact_paths(root) do
    %{
      coding_plan: Path.join(root, @plan_filename),
      coding_pipeline: Path.join(root, @pipeline_filename),
      compile_manifest: Path.join(root, @manifest_filename)
    }
  end

  defp atomic_write(path, content) do
    temporary_path = temporary_path(path)

    try do
      with :ok <- write_secure_temp(temporary_path, content),
           :ok <- File.rename(temporary_path, path) do
        :ok
      else
        {:error, reason} ->
          {:error, {:write_artifact_failed, Path.basename(path), reason}}
      end
    after
      File.rm(temporary_path)
    end
  end

  defp write_secure_temp(path, content) do
    # The file is empty until its final restrictive mode is in place.
    case File.open(path, [:write, :binary, :exclusive], fn device ->
           with :ok <- File.chmod(path, 0o600),
                :ok <- IO.binwrite(device, content) do
             :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")
  end
end
