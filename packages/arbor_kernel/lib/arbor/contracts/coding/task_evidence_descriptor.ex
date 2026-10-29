defmodule Arbor.Contracts.Coding.TaskEvidenceDescriptor do
  @moduledoc """
  Closed JSON data contract for a durable terminal coding-task artifact.

  The descriptor contains only artifact location, digest, size, schema, and
  task identity. It is evidence only and carries no authority, callback,
  replay instruction, or authorization material.
  """

  use TypedStruct

  @schema_version 1
  @max_artifact_bytes 1_048_576
  @max_path_bytes 4_096
  @max_task_id_bytes 512
  @lowercase_sha256 ~r/\A[0-9a-f]{64}\z/
  @fields [:path, :sha256, :byte_size, :schema_version, :task_id]
  @max_fields 5

  typedstruct enforce: true do
    @typedoc "A bounded, authority-free terminal coding-task artifact descriptor."

    field(:path, String.t())
    field(:sha256, String.t())
    field(:byte_size, non_neg_integer())
    field(:schema_version, pos_integer())
    field(:task_id, String.t())
  end

  @doc "Return the accepted descriptor schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Construct a descriptor from a closed atom/string-keyed JSON object."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         :ok <- require_all_fields(attrs),
         {:ok, path} <- canonical_path(attrs.path),
         {:ok, sha256} <- lowercase_digest(attrs.sha256),
         {:ok, byte_size} <- bounded_integer(attrs.byte_size, :byte_size, @max_artifact_bytes),
         :ok <- validate_schema_version(attrs.schema_version),
         {:ok, task_id} <- bounded_task_id(attrs.task_id) do
      {:ok,
       %__MODULE__{
         path: path,
         sha256: sha256,
         byte_size: byte_size,
         schema_version: @schema_version,
         task_id: task_id
       }}
    end
  rescue
    _ -> {:error, {:invalid_descriptor, :malformed}}
  catch
    _, _ -> {:error, {:invalid_descriptor, :malformed}}
  end

  @doc "Return the canonical closed string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = descriptor) do
    %{
      "path" => descriptor.path,
      "sha256" => descriptor.sha256,
      "byte_size" => descriptor.byte_size,
      "schema_version" => descriptor.schema_version,
      "task_id" => descriptor.task_id
    }
  end

  @doc "Normalize a descriptor object directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, descriptor} <- new(attrs), do: {:ok, to_map(descriptor)}
  end

  @doc "Return true only for a complete valid descriptor object or struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = descriptor), do: match?({:ok, _}, new(to_map(descriptor)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp normalize_object(attrs) when is_map(attrs) do
    if map_size(attrs) <= @max_fields,
      do: normalize_entries(attrs),
      else: {:error, {:invalid_descriptor, :object_too_large}}
  end

  defp normalize_object(attrs) when is_list(attrs) do
    entries = Enum.take(attrs, @max_fields + 1)

    cond do
      length(entries) > @max_fields ->
        {:error, {:invalid_descriptor, :object_too_large}}

      Enum.all?(entries, &match?({_, _}, &1)) ->
        normalize_entries(entries)

      true ->
        {:error, {:invalid_descriptor, :object_required}}
    end
  end

  defp normalize_object(_attrs), do: {:error, {:invalid_descriptor, :object_required}}

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case normalize_key(key) do
        {:ok, canonical} ->
          if Map.has_key?(normalized, canonical) do
            {:halt, {:error, {:duplicate_field, Atom.to_string(canonical)}}}
          else
            {:cont, {:ok, Map.put(normalized, canonical, value)}}
          end

        :error ->
          {:halt, {:error, {:unknown_field, printable_key(key)}}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key) do
    if key in @fields, do: {:ok, key}, else: :error
  end

  defp normalize_key(key) when is_binary(key) do
    Enum.find_value(@fields, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp normalize_key(_key), do: :error

  defp require_all_fields(attrs) do
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp canonical_path(path) when is_binary(path) do
    valid =
      String.valid?(path) and String.trim(path) != "" and byte_size(path) <= @max_path_bytes and
        String.starts_with?(path, "/") and not String.contains?(path, <<0>>) and
        not String.match?(path, ~r/[\x00-\x1F\x7F]/) and Path.expand(path) == path

    if valid, do: {:ok, path}, else: {:error, {:invalid_field, "path"}}
  rescue
    _ -> {:error, {:invalid_field, "path"}}
  end

  defp canonical_path(_path), do: {:error, {:invalid_field, "path"}}

  defp lowercase_digest(digest) when is_binary(digest) do
    if String.valid?(digest) and Regex.match?(@lowercase_sha256, digest),
      do: {:ok, digest},
      else: {:error, {:invalid_field, "sha256"}}
  end

  defp lowercase_digest(_digest), do: {:error, {:invalid_field, "sha256"}}

  defp bounded_integer(value, _field, maximum)
       when is_integer(value) and value >= 0 and value <= maximum,
       do: {:ok, value}

  defp bounded_integer(_value, field, _maximum),
    do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp validate_schema_version(@schema_version), do: :ok

  defp validate_schema_version(_version),
    do: {:error, {:invalid_field, "schema_version"}}

  defp bounded_task_id(task_id) when is_binary(task_id) do
    valid =
      String.valid?(task_id) and String.trim(task_id) != "" and
        byte_size(task_id) <= @max_task_id_bytes and not String.contains?(task_id, <<0>>) and
        not String.match?(task_id, ~r/[\x00-\x1F\x7F]/)

    if valid, do: {:ok, task_id}, else: {:error, {:invalid_field, "task_id"}}
  end

  defp bounded_task_id(_task_id), do: {:error, {:invalid_field, "task_id"}}

  defp printable_key(key) when is_binary(key), do: key
  defp printable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp printable_key(_key), do: "<non-string-key>"
end
