defmodule Arbor.Contracts.Coding.CandidateMaterialization do
  @moduledoc """
  Closed, bounded JSON contract for a passive candidate materialization descriptor.

  The descriptor names a source commit, an expected tree, and a nonempty
  strictly path-sorted list of blob entries. It is data only: no filesystem,
  Git object I/O, workspace, lease, recovery intent, or execution authority.
  Callers must re-admit bytes through `new/1` before trusting paths or OIDs.
  """

  use TypedStruct

  @fields [:source_commit_oid, :expected_tree_oid, :entries]
  @entry_fields [:path, :blob_oid, :mode]
  @entry_key_order ["path", "blob_oid", "mode"]

  @max_entries 2048
  @max_path_bytes 1024
  @max_path_depth 48
  @max_component_bytes 255
  @max_encoded_bytes 1_048_576
  @max_recovery_nodes 65_536
  @max_record_bytes 4_194_304
  @max_inventory_bytes 8_388_608
  @max_structural_depth 8
  @max_diagnosable_fields 64
  @allowed_modes [100_644, 100_755]
  @digest_prefix "sha256:"
  @recovery_stage 0
  @recovery_quarantine false
  @recovery_phase "pending"

  typedstruct enforce: true do
    @typedoc "Canonical passive candidate-materialization descriptor."

    field(:source_commit_oid, String.t())
    field(:expected_tree_oid, String.t())
    field(:entries, [map()])
  end

  @doc "Return the maximum number of descriptor entries."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "Return the maximum UTF-8 byte size of an entry path."
  @spec max_path_bytes() :: pos_integer()
  def max_path_bytes, do: @max_path_bytes

  @doc "Return the maximum number of `/`-separated path segments."
  @spec max_path_depth() :: pos_integer()
  def max_path_depth, do: @max_path_depth

  @doc "Return the maximum UTF-8 byte size of one path segment."
  @spec max_component_bytes() :: pos_integer()
  def max_component_bytes, do: @max_component_bytes

  @doc "Return the maximum canonical descriptor size in bytes."
  @spec max_encoded_bytes() :: pos_integer()
  def max_encoded_bytes, do: @max_encoded_bytes

  @doc "Return the maximum JSON node count of a recovery value."
  @spec max_recovery_nodes() :: pos_integer()
  def max_recovery_nodes, do: @max_recovery_nodes

  @doc "Return the maximum encoded size of one recovery record in bytes."
  @spec max_record_bytes() :: pos_integer()
  def max_record_bytes, do: @max_record_bytes

  @doc "Return the maximum encoded recovery inventory size in bytes."
  @spec max_inventory_bytes() :: pos_integer()
  def max_inventory_bytes, do: @max_inventory_bytes

  @doc "Return the maximum nested map/list container depth of a recovery value."
  @spec max_structural_depth() :: pos_integer()
  def max_structural_depth, do: @max_structural_depth

  @doc "Return the admitted Git file modes."
  @spec allowed_modes() :: [pos_integer()]
  def allowed_modes, do: @allowed_modes

  @doc "Construct and validate a closed candidate-materialization descriptor."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @fields, nil),
         :ok <- require_fields(attrs, @fields, nil),
         {:ok, source_commit_oid, width} <-
           admit_oid(attrs.source_commit_oid, "source_commit_oid"),
         {:ok, expected_tree_oid} <-
           admit_oid_width(attrs.expected_tree_oid, "expected_tree_oid", width),
         {:ok, entries} <- admit_entries(attrs.entries, width) do
      descriptor = %__MODULE__{
        source_commit_oid: source_commit_oid,
        expected_tree_oid: expected_tree_oid,
        entries: entries
      }

      with {:ok, _bytes} <- canonical_bytes(descriptor),
           {:ok, shape} <- recovery_shape(descriptor),
           {:ok, _shape} <- admit_recovery_value(shape) do
        {:ok, descriptor}
      end
    end
  rescue
    _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  catch
    _, _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  end

  @doc "Return the canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = descriptor) do
    %{
      "source_commit_oid" => descriptor.source_commit_oid,
      "expected_tree_oid" => descriptor.expected_tree_oid,
      "entries" => descriptor.entries
    }
  end

  @doc "Normalize a descriptor object directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, descriptor} <- new(attrs), do: {:ok, to_map(descriptor)}
  end

  @doc "Return true only for a valid descriptor object or descriptor struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = descriptor), do: match?({:ok, _}, new(to_map(descriptor)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @doc "Encode an admitted descriptor as deterministic JSON bytes."
  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def canonical_bytes(%__MODULE__{} = descriptor) do
    encode_descriptor(descriptor)
  rescue
    _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  catch
    _, _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, descriptor} <- new(attrs), do: canonical_bytes(descriptor)
  end

  def canonical_bytes(_attrs), do: {:error, {:invalid_candidate_materialization, :malformed}}

  @doc "Hash canonical descriptor bytes as `sha256:` followed by 64 lowercase hex characters."
  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def digest(descriptor_or_attrs) do
    with {:ok, bytes} <- canonical_bytes(descriptor_or_attrs) do
      {:ok, @digest_prefix <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  rescue
    _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  catch
    _, _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  end

  @doc "Derive the shallow JSON recovery shape from an admitted descriptor."
  @spec recovery_shape(t()) :: {:ok, map()} | {:error, term()}
  def recovery_shape(%__MODULE__{} = descriptor) do
    {:ok, build_recovery_shape(descriptor)}
  end

  def recovery_shape(_descriptor), do: {:error, {:invalid_candidate_materialization, :malformed}}

  @doc "Admit a derived or synthetic recovery JSON value against frozen structural bounds."
  @spec admit_recovery_value(term()) :: {:ok, term()} | {:error, term()}
  def admit_recovery_value(value) do
    with {:ok, depth, nodes} <- measure_json(value),
         :ok <- admit_depth(depth),
         :ok <- admit_nodes(nodes),
         :ok <- admit_records(value),
         :ok <- admit_inventory(value) do
      {:ok, value}
    end
  rescue
    _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  catch
    _, _ -> {:error, {:invalid_candidate_materialization, :malformed}}
  end

  defp encode_descriptor(descriptor) do
    entries =
      Enum.map(descriptor.entries, fn entry ->
        Jason.OrderedObject.new(Enum.map(@entry_key_order, &{&1, Map.fetch!(entry, &1)}))
      end)

    ordered =
      Jason.OrderedObject.new([
        {"source_commit_oid", descriptor.source_commit_oid},
        {"expected_tree_oid", descriptor.expected_tree_oid},
        {"entries", entries}
      ])

    case Jason.encode(ordered) do
      {:ok, bytes} when byte_size(bytes) <= @max_encoded_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, {:invalid_candidate_materialization, :too_large}}
      {:error, _reason} -> {:error, {:invalid_candidate_materialization, :malformed}}
    end
  end

  defp admit_entries(entries, width) when is_list(entries) do
    collect_entries(entries, width, 0, [], MapSet.new(), nil)
  end

  defp admit_entries(_entries, _width), do: {:error, {:invalid_field, "entries", :expected_list}}

  defp collect_entries([], _width, _index, [], _seen, _prev),
    do: {:error, {:invalid_field, "entries", :must_be_non_empty}}

  defp collect_entries([], _width, _index, acc, _seen, _prev), do: {:ok, Enum.reverse(acc)}

  defp collect_entries([_head | _tail], _width, index, _acc, _seen, _prev)
       when index >= @max_entries,
       do: {:error, {:invalid_field, "entries", :list_too_large}}

  defp collect_entries([head | tail], width, index, acc, seen, prev) do
    prefix = "entries[#{index}]"

    with {:ok, attrs} <- normalize_object(head, @entry_fields, prefix),
         :ok <- require_fields(attrs, @entry_fields, prefix),
         {:ok, path} <- admit_path(attrs.path, prefix <> ".path"),
         :ok <- reject_duplicate_path(path, index, seen),
         :ok <- reject_unsorted_path(path, index, prev),
         {:ok, blob_oid} <- admit_oid_width(attrs.blob_oid, prefix <> ".blob_oid", width),
         {:ok, mode} <- admit_mode(attrs.mode, prefix <> ".mode") do
      entry = %{"path" => path, "blob_oid" => blob_oid, "mode" => mode}

      collect_entries(
        tail,
        width,
        index + 1,
        [entry | acc],
        MapSet.put(seen, path),
        path
      )
    end
  end

  defp collect_entries(_improper, _width, _index, _acc, _seen, _prev),
    do: {:error, {:invalid_field, "entries", :improper_list}}

  defp reject_duplicate_path(path, index, seen) do
    if MapSet.member?(seen, path),
      do: {:error, {:invalid_field, "entries[#{index}].path", :duplicate_path}},
      else: :ok
  end

  defp reject_unsorted_path(_path, _index, nil), do: :ok

  defp reject_unsorted_path(path, index, prev) do
    if path > prev,
      do: :ok,
      else: {:error, {:invalid_field, "entries[#{index}].path", :unsorted}}
  end

  defp admit_oid(value, field) when is_binary(value) do
    width = byte_size(value)

    if (width == 40 or width == 64) and oid_hex?(value) do
      {:ok, value, width}
    else
      {:error, {:invalid_field, field, :invalid_oid}}
    end
  end

  defp admit_oid(_value, field), do: {:error, {:invalid_field, field, :invalid_oid}}

  defp admit_oid_width(value, field, width) do
    case admit_oid(value, field) do
      {:ok, oid, ^width} -> {:ok, oid}
      {:ok, _oid, _other} -> {:error, {:invalid_field, field, :inconsistent_oid_width}}
      error -> error
    end
  end

  defp oid_hex?(<<>>), do: true
  defp oid_hex?(<<char, rest::binary>>) when char in ?0..?9 or char in ?a..?f, do: oid_hex?(rest)
  defp oid_hex?(_value), do: false

  defp admit_mode(mode, _field) when mode in @allowed_modes, do: {:ok, mode}
  defp admit_mode(_mode, field), do: {:error, {:invalid_field, field, :unsupported}}

  defp admit_path(path, field) when is_binary(path) do
    cond do
      # O(1) byte-size ceiling before UTF-8 scanning so attacker-sized
      # binaries fail as :path_too_long without an encoding walk.
      byte_size(path) > @max_path_bytes ->
        {:error, {:invalid_field, field, :path_too_long}}

      not String.valid?(path) ->
        {:error, {:invalid_field, field, :invalid_utf8}}

      path == "" ->
        {:error, {:invalid_field, field, :empty_path}}

      :binary.match(path, <<0>>) != :nomatch ->
        {:error, {:invalid_field, field, :nul_byte}}

      :binary.match(path, <<"\n">>) != :nomatch or :binary.match(path, <<"\r">>) != :nomatch ->
        {:error, {:invalid_field, field, :crlf}}

      :binary.match(path, <<"\\">>) != :nomatch ->
        {:error, {:invalid_field, field, :backslash}}

      absolute_path?(path) ->
        {:error, {:invalid_field, field, :absolute_path}}

      String.starts_with?(path, "./") ->
        {:error, {:invalid_field, field, :leading_dot_slash}}

      true ->
        admit_path_segments(path, field)
    end
  end

  defp admit_path(_path, field), do: {:error, {:invalid_field, field, :expected_string}}

  defp admit_path_segments(path, field) do
    segments = :binary.split(path, <<"/">>, [:global])

    cond do
      segments == [] ->
        {:error, {:invalid_field, field, :empty_path}}

      match?([_ | _], segments) and List.last(segments) == <<>> ->
        {:error, {:invalid_field, field, :trailing_slash}}

      Enum.any?(segments, &(&1 == <<>>)) ->
        {:error, {:invalid_field, field, :repeated_slash}}

      length(segments) > @max_path_depth ->
        {:error, {:invalid_field, field, :path_depth}}

      Enum.any?(segments, &(byte_size(&1) > @max_component_bytes)) ->
        {:error, {:invalid_field, field, :component_too_long}}

      Enum.any?(segments, &(&1 == <<".">>)) ->
        {:error, {:invalid_field, field, :dot_segment}}

      Enum.any?(segments, &(&1 == <<"..">>)) ->
        {:error, {:invalid_field, field, :dotdot_segment}}

      Enum.any?(segments, &(&1 == <<".git">>)) ->
        {:error, {:invalid_field, field, :git_segment}}

      true ->
        {:ok, path}
    end
  end

  defp absolute_path?(path) do
    Path.type(path) == :absolute or
      (byte_size(path) > 0 and :binary.part(path, {0, 1}) == <<"/">>) or
      Regex.match?(~r/^[A-Za-z]:/, path)
  end

  defp build_recovery_shape(descriptor) do
    ancestors =
      descriptor.entries
      |> Enum.reduce(MapSet.new(), fn entry, acc ->
        Enum.reduce(strict_ancestors(entry["path"]), acc, &MapSet.put(&2, &1))
      end)
      |> MapSet.to_list()
      |> Enum.sort()

    records =
      descriptor.entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        %{
          "path" => entry["path"],
          "blob_oid" => entry["blob_oid"],
          "mode" => entry["mode"],
          "stage" => @recovery_stage,
          "quarantine" => @recovery_quarantine,
          "index" => index,
          "phase" => @recovery_phase
        }
      end)

    %{"ancestors" => ancestors, "records" => records}
  end

  defp strict_ancestors(path) do
    case :binary.split(path, <<"/">>, [:global]) do
      [] ->
        []

      [_file] ->
        []

      segments ->
        segments
        |> Enum.drop(-1)
        |> Enum.reduce({[], []}, fn segment, {ancestors, parts} ->
          next = parts ++ [segment]
          {[Enum.join(next, "/") | ancestors], next}
        end)
        |> elem(0)
        |> Enum.reverse()
    end
  end

  defp admit_depth(depth) when depth > @max_structural_depth,
    do: {:error, {:invalid_candidate_materialization, :structural_depth_exceeded}}

  defp admit_depth(_depth), do: :ok

  defp admit_nodes(nodes) when nodes > @max_recovery_nodes,
    do: {:error, {:invalid_candidate_materialization, :recovery_nodes_exceeded}}

  defp admit_nodes(_nodes), do: :ok

  defp admit_records(value) do
    value
    |> record_values()
    |> Enum.reduce_while(:ok, fn record, :ok ->
      case encoded_size(record) do
        {:ok, size} when size <= @max_record_bytes ->
          {:cont, :ok}

        {:ok, _size} ->
          {:halt, {:error, {:invalid_candidate_materialization, :record_too_large}}}

        {:error, _reason} ->
          {:halt, {:error, {:invalid_candidate_materialization, :malformed}}}
      end
    end)
  end

  defp admit_inventory(value) do
    case encoded_size(value) do
      {:ok, size} when size <= @max_inventory_bytes -> :ok
      {:ok, _size} -> {:error, {:invalid_candidate_materialization, :inventory_too_large}}
      {:error, _reason} -> {:error, {:invalid_candidate_materialization, :malformed}}
    end
  end

  defp record_values(value) when is_map(value) and not is_struct(value) do
    case Map.get(value, "records") do
      records when is_list(records) -> records
      _ -> [value]
    end
  end

  defp record_values(value) when is_list(value), do: value
  defp record_values(_value), do: []

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp measure_json(value) when is_boolean(value) or is_nil(value) or is_integer(value),
    do: {:ok, 0, 1}

  defp measure_json(value) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _bytes} -> {:ok, 0, 1}
      {:error, _reason} -> {:error, {:invalid_candidate_materialization, :malformed}}
    end
  end

  defp measure_json(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, 0, 1},
      else: {:error, {:invalid_candidate_materialization, :malformed}}
  end

  defp measure_json(value) when is_list(value) do
    if proper_list?(value),
      do: measure_container(value),
      else: {:error, {:invalid_candidate_materialization, :malformed}}
  end

  defp measure_json(value) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      measure_container(Map.values(value))
    else
      {:error, {:invalid_candidate_materialization, :malformed}}
    end
  end

  defp measure_json(_value), do: {:error, {:invalid_candidate_materialization, :malformed}}

  defp measure_container([]), do: {:ok, 1, 1}

  defp measure_container(children) do
    Enum.reduce_while(children, {:ok, 0, 1}, fn child, {:ok, max_depth, nodes} ->
      case measure_json(child) do
        {:ok, depth, child_nodes} ->
          {:cont, {:ok, max(max_depth, depth), nodes + child_nodes}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, max_depth, nodes} -> {:ok, 1 + max_depth, nodes}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_object(attrs, allowed, prefix) when is_map(attrs) do
    cond do
      is_struct(attrs) ->
        object_error(prefix, :struct_not_allowed)

      map_size(attrs) > @max_diagnosable_fields ->
        object_error(prefix, :object_too_large)

      true ->
        normalize_entries(Map.to_list(attrs), allowed, prefix)
    end
  end

  defp normalize_object(attrs, allowed, prefix) when is_list(attrs) do
    with {:ok, entries} <- collect_object_entries(attrs, 0, [], prefix) do
      normalize_entries(entries, allowed, prefix)
    end
  end

  defp normalize_object(_attrs, _allowed, prefix), do: object_error(prefix, :object_required)

  defp collect_object_entries([], _count, acc, _prefix), do: {:ok, Enum.reverse(acc)}

  defp collect_object_entries([_head | _tail], count, _acc, prefix)
       when count >= @max_diagnosable_fields,
       do: object_error(prefix, :object_too_large)

  defp collect_object_entries([{key, value} | tail], count, acc, prefix),
    do: collect_object_entries(tail, count + 1, [{key, value} | acc], prefix)

  defp collect_object_entries([_invalid | _tail], _count, _acc, prefix),
    do: object_error(prefix, :object_required)

  defp collect_object_entries(_improper, _count, _acc, prefix),
    do: object_error(prefix, :improper_list)

  defp normalize_entries(entries, allowed, prefix) do
    allowed_names = field_names(allowed)
    named_entries = Enum.map(entries, &name_entry/1)

    invalid_keys = Enum.filter(named_entries, &match?({:invalid, _}, &1))

    duplicate_fields =
      named_entries
      |> Enum.flat_map(fn
        {:ok, name, _value} -> [name]
        _ -> []
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(&qualify(prefix, &1))

    unknown_fields =
      named_entries
      |> Enum.flat_map(fn
        {:ok, name, _value} -> if name in allowed_names, do: [], else: [name]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&qualify(prefix, &1))

    cond do
      invalid_keys != [] ->
        object_error(prefix, :invalid_key)

      duplicate_fields != [] ->
        {:error, {:duplicate_fields, duplicate_fields}}

      unknown_fields != [] ->
        {:error, {:unknown_fields, unknown_fields}}

      true ->
        fields_by_name = Map.new(allowed, &{Atom.to_string(&1), &1})

        {:ok,
         Map.new(named_entries, fn {:ok, name, value} ->
           {Map.fetch!(fields_by_name, name), value}
         end)}
    end
  end

  defp name_entry({key, value}) do
    case key_name(key) do
      {:ok, name} -> {:ok, name, value}
      :error -> {:invalid, value}
    end
  end

  defp key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp key_name(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp key_name(_key), do: :error

  defp require_fields(attrs, fields, prefix) do
    case Enum.find(fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, qualify(prefix, Atom.to_string(field))}}
    end
  end

  defp field_names(fields), do: Enum.map(fields, &Atom.to_string/1)

  defp qualify(nil, name), do: name
  defp qualify(prefix, name), do: prefix <> "." <> name

  defp object_error(nil, tag), do: {:error, {:invalid_object, tag}}
  defp object_error(prefix, tag), do: {:error, {:invalid_field, prefix, tag}}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false
end
