defmodule Arbor.Contracts.Coding.SourceInventory do
  @moduledoc """
  Bounded, owner-attested source path inventory for contained Mix validation.

  Pure envelope: construct, normalize, digest-verify, and encode. No filesystem,
  process, or application access. Callers (Actions host publish; contract guards
  in contained mode) re-admit bytes through `new/1` before trusting paths.
  """

  use TypedStruct

  @schema "arbor.source_inventory.v1"
  @paths_domain_tag "arbor.source_inventory.paths.v1\0"
  @fields [:schema, :tree_oid, :path_count, :paths_sha256, :paths]
  # Explicit wire key order for encode/1 (never rely on map enumeration).
  @encode_key_order ["schema", "tree_oid", "path_count", "paths_sha256", "paths"]
  @max_entries 50_000
  @max_path_bytes 4_096
  @max_component_bytes 255
  @max_path_depth 48
  @max_encoded_bytes 8 * 1024 * 1024
  @tree_oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @hex64_re ~r/\A[0-9a-f]{64}\z/

  typedstruct enforce: true do
    @typedoc "Canonical attested source-inventory envelope."

    field(:schema, String.t())
    field(:tree_oid, String.t())
    field(:path_count, non_neg_integer())
    field(:paths_sha256, String.t())
    field(:paths, [String.t()])
  end

  @doc "Construct and validate a canonical source-inventory envelope."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @fields, :invalid_source_inventory),
         :ok <- require_exact(attrs, @fields),
         {:ok, schema} <- exact_schema(attrs.schema),
         {:ok, tree_oid} <- admit_tree_oid(attrs.tree_oid),
         {:ok, paths} <- normalize_paths(attrs.paths),
         {:ok, path_count} <- admit_path_count(attrs.path_count, paths),
         {:ok, paths_sha256} <- admit_paths_sha256(attrs.paths_sha256, paths),
         inventory = %__MODULE__{
           schema: schema,
           tree_oid: tree_oid,
           path_count: path_count,
           paths_sha256: paths_sha256,
           paths: paths
         },
         :ok <- size_ok(inventory) do
      {:ok, inventory}
    end
  rescue
    _ -> {:error, {:invalid_source_inventory, :malformed}}
  catch
    _, _ -> {:error, {:invalid_source_inventory, :malformed}}
  end

  @doc "Build an admitted inventory from a tree OID and path list (computes digest)."
  @spec build(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def build(tree_oid, paths) when is_binary(tree_oid) and is_list(paths) do
    sorted = Enum.sort(paths)

    new(%{
      "schema" => @schema,
      "tree_oid" => tree_oid,
      "path_count" => length(sorted),
      "paths_sha256" => paths_digest(sorted),
      "paths" => sorted
    })
  end

  def build(_tree_oid, _paths), do: {:error, {:invalid_source_inventory, :malformed}}

  @doc "Return the canonical string-keyed JSON map (unordered map; use encode/1 for bytes)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = inventory) do
    %{
      "schema" => inventory.schema,
      "tree_oid" => inventory.tree_oid,
      "path_count" => inventory.path_count,
      "paths_sha256" => inventory.paths_sha256,
      "paths" => inventory.paths
    }
  end

  @doc """
  Encode an admitted inventory as deterministic JSON bytes.

  Uses `Jason.OrderedObject` with one explicit stable key order
  (`schema`, `tree_oid`, `path_count`, `paths_sha256`, `paths`) so canonical
  bytes never depend on map enumeration order.
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = inventory) do
    map = to_map(inventory)

    ordered =
      Jason.OrderedObject.new(
        Enum.map(@encode_key_order, fn key ->
          {key, Map.fetch!(map, key)}
        end)
      )

    bytes = Jason.encode!(ordered)

    if byte_size(bytes) <= @max_encoded_bytes do
      {:ok, bytes}
    else
      {:error, {:invalid_source_inventory, :too_large}}
    end
  rescue
    _ -> {:error, {:invalid_source_inventory, :encode_failed}}
  end

  def encode(_), do: {:error, {:invalid_source_inventory, :malformed}}

  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Hard ceiling for encoded inventory JSON bytes (and pre-read lstat reject)."
  @spec max_encoded_bytes() :: pos_integer()
  def max_encoded_bytes, do: @max_encoded_bytes

  @spec paths(t()) :: [String.t()]
  def paths(%__MODULE__{paths: paths}), do: paths

  @spec tree_oid(t()) :: String.t()
  def tree_oid(%__MODULE__{tree_oid: tree_oid}), do: tree_oid

  @spec path_count(t()) :: non_neg_integer()
  def path_count(%__MODULE__{path_count: count}), do: count

  @spec paths_sha256(t()) :: String.t()
  def paths_sha256(%__MODULE__{paths_sha256: digest}), do: digest

  @doc "SHA-256 hex over the framed path list (domain tag + length-prefixed paths)."
  @spec paths_digest([String.t()]) :: String.t()
  def paths_digest(paths) when is_list(paths) do
    paths
    |> Enum.reduce(:crypto.hash_init(:sha256) |> :crypto.hash_update(@paths_domain_tag), fn path,
                                                                                            acc ->
      :crypto.hash_update(acc, [<<byte_size(path)::unsigned-big-32>>, path])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # --- private ---

  defp exact_schema(@schema), do: {:ok, @schema}
  defp exact_schema(_), do: {:error, {:invalid_source_inventory, :schema}}

  defp admit_tree_oid(value) when is_binary(value) do
    if Regex.match?(@tree_oid_re, value),
      do: {:ok, value},
      else: {:error, {:invalid_source_inventory, :tree_oid}}
  end

  defp admit_tree_oid(_), do: {:error, {:invalid_source_inventory, :tree_oid}}

  defp admit_path_count(count, paths) when is_integer(count) and count >= 0 do
    cond do
      count > @max_entries ->
        {:error, {:invalid_source_inventory, :oversized}}

      count != length(paths) ->
        {:error, {:invalid_source_inventory, :count_mismatch}}

      true ->
        {:ok, count}
    end
  end

  defp admit_path_count(_, _), do: {:error, {:invalid_source_inventory, :path_count}}

  defp admit_paths_sha256(value, paths) when is_binary(value) do
    expected = paths_digest(paths)

    cond do
      not Regex.match?(@hex64_re, value) ->
        {:error, {:invalid_source_inventory, :paths_sha256}}

      value != expected ->
        {:error, {:invalid_source_inventory, :digest_mismatch}}

      true ->
        {:ok, value}
    end
  end

  defp admit_paths_sha256(_, _), do: {:error, {:invalid_source_inventory, :paths_sha256}}

  defp normalize_paths(paths) when is_list(paths) do
    if length(paths) > @max_entries do
      {:error, {:invalid_source_inventory, :oversized}}
    else
      Enum.reduce_while(paths, {:ok, [], MapSet.new(), nil}, fn path, {:ok, acc, seen, prev} ->
        case validate_path(path) do
          {:ok, path} ->
            cond do
              MapSet.member?(seen, path) ->
                {:halt, {:error, {:invalid_source_inventory, :duplicate_path}}}

              is_binary(prev) and path <= prev ->
                {:halt, {:error, {:invalid_source_inventory, :unsorted}}}

              true ->
                {:cont, {:ok, [path | acc], MapSet.put(seen, path), path}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc, _seen, _prev} -> {:ok, Enum.reverse(acc)}
        {:error, _} = error -> error
      end
    end
  end

  defp normalize_paths(_), do: {:error, {:invalid_source_inventory, :paths}}

  defp validate_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, {:invalid_source_inventory, :empty_path}}

      not String.valid?(path) ->
        {:error, {:invalid_source_inventory, :path_encoding}}

      byte_size(path) > @max_path_bytes ->
        {:error, {:invalid_source_inventory, :path_too_long}}

      :binary.match(path, <<0>>) != :nomatch or :binary.match(path, <<"\n">>) != :nomatch or
          :binary.match(path, <<"\r">>) != :nomatch ->
        {:error, {:invalid_source_inventory, :unsafe_path}}

      absolute_path?(path) ->
        {:error, {:invalid_source_inventory, :absolute_path}}

      true ->
        segments = :binary.split(path, <<"/">>, [:global])

        cond do
          segments == [] ->
            {:error, {:invalid_source_inventory, :empty_path}}

          length(segments) > @max_path_depth ->
            {:error, {:invalid_source_inventory, :path_depth}}

          Enum.any?(segments, fn segment ->
            segment == <<>> or segment == <<".">> or segment == <<"..">> or
                byte_size(segment) > @max_component_bytes
          end) ->
            {:error, {:invalid_source_inventory, :traversal}}

          true ->
            {:ok, path}
        end
    end
  end

  defp validate_path(_), do: {:error, {:invalid_source_inventory, :path}}

  defp absolute_path?(path) when is_binary(path) do
    (byte_size(path) > 0 and :binary.part(path, {0, 1}) == <<"/">>) or
      Path.type(path) == :absolute
  end

  defp size_ok(inventory) do
    case encode(inventory) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_object(attrs, allowed, tag) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {tag, :struct_not_allowed}}
      map_size(attrs) > length(allowed) -> {:error, {tag, :object_too_large}}
      true -> normalize_entries(Map.to_list(attrs), allowed, tag)
    end
  end

  defp normalize_object(attrs, allowed, tag) when is_list(attrs) do
    entries = Enum.take(attrs, length(allowed) + 1)

    cond do
      length(entries) > length(allowed) -> {:error, {tag, :object_too_large}}
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries, allowed, tag)
      true -> {:error, {tag, :object_required}}
    end
  end

  defp normalize_object(_attrs, _allowed, tag), do: {:error, {tag, :object_required}}

  defp normalize_entries(entries, allowed, tag) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case canonical_key(key, allowed) do
        {:ok, canonical} when not is_map_key(normalized, canonical) ->
          {:cont, {:ok, Map.put(normalized, canonical, value)}}

        {:ok, _canonical} ->
          {:halt, {:error, {tag, :duplicate_field}}}

        :error ->
          {:halt, {:error, {tag, :unknown_field}}}
      end
    end)
  end

  defp canonical_key(key, allowed) when is_atom(key) do
    if Enum.member?(allowed, key), do: {:ok, key}, else: :error
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    Enum.find_value(allowed, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp canonical_key(_key, _allowed), do: :error

  defp require_exact(attrs, fields) do
    if Map.keys(attrs) |> Enum.sort() == fields |> Enum.sort(),
      do: :ok,
      else: {:error, {:invalid_source_inventory, :field_set}}
  end
end
