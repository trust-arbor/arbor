defmodule Arbor.Contracts.Coding.WorkPacket do
  @moduledoc """
  Versioned, closed JSON data contract for an incremental coding work packet.

  A work packet records intent and review requirements only. It carries no
  capabilities, paths outside the repository, executable terms, or other
  authority. Authority is derived independently by the executor.
  """

  use TypedStruct

  @schema_version 1
  @checkpoint_policies ~w(direct design_required)
  @fields [
    :version,
    :success_criteria,
    :non_goals,
    :constraints,
    :architecture_refs,
    :required_evidence,
    :checkpoint_policy
  ]
  @field_names Enum.map(@fields, &Atom.to_string/1)
  # Future nested objects must add their path and fixed field order here.
  @canonical_object_fields %{[] => @field_names}
  @required_fields [:success_criteria]

  @max_fields length(@fields)
  @max_list_items 32
  @max_text_bytes 4_096
  @max_architecture_ref_bytes 4_096
  @max_packet_bytes 256_000
  @digest_prefix "sha256:"

  @schema %{
    version: @schema_version,
    fields: @field_names,
    required_fields: Enum.map(@required_fields, &Atom.to_string/1),
    bounds: %{
      max_fields: @max_fields,
      max_list_items: @max_list_items,
      max_text_bytes: @max_text_bytes,
      max_architecture_ref_bytes: @max_architecture_ref_bytes,
      max_packet_bytes: @max_packet_bytes
    },
    enums: %{checkpoint_policy: @checkpoint_policies}
  }

  @enums %{"checkpoint_policy" => @checkpoint_policies}

  typedstruct enforce: true do
    @typedoc "A bounded, authority-free coding work packet."

    field(:version, pos_integer(), default: @schema_version)
    field(:success_criteria, [String.t()])
    field(:non_goals, [String.t()], default: [])
    field(:constraints, [String.t()], default: [])
    field(:architecture_refs, [String.t()], default: [])
    field(:required_evidence, [String.t()], default: [])
    field(:checkpoint_policy, String.t(), default: "direct")
  end

  @doc "Return the accepted packet schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Return the closed packet schema metadata."
  @spec schema() :: map()
  def schema, do: @schema

  @doc "Return the closed enum metadata."
  @spec enums() :: map()
  def enums, do: @enums

  @doc "Return the accepted checkpoint policies."
  @spec checkpoint_policies() :: [String.t()]
  def checkpoint_policies, do: @checkpoint_policies

  @doc "Return the maximum number of fields in the packet object."
  @spec max_fields() :: pos_integer()
  def max_fields, do: @max_fields

  @doc "Return the maximum number of entries in any packet list."
  @spec max_list_items() :: pos_integer()
  def max_list_items, do: @max_list_items

  @doc "Return the maximum UTF-8 byte size of ordinary packet text."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "Return the maximum UTF-8 byte size of an architecture reference."
  @spec max_architecture_ref_bytes() :: pos_integer()
  def max_architecture_ref_bytes, do: @max_architecture_ref_bytes

  @doc "Return the maximum encoded packet size in bytes."
  @spec max_packet_bytes() :: pos_integer()
  def max_packet_bytes, do: @max_packet_bytes

  @doc "Construct and validate a closed work packet object."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         {:ok, version} <- normalize_version(Map.get(attrs, :version, @schema_version)),
         {:ok, success_criteria} <- required_text_list(attrs, :success_criteria),
         {:ok, non_goals} <- optional_text_list(attrs, :non_goals),
         {:ok, constraints} <- optional_text_list(attrs, :constraints),
         {:ok, architecture_refs} <- optional_architecture_refs(attrs),
         {:ok, required_evidence} <- optional_text_list(attrs, :required_evidence),
         {:ok, checkpoint_policy} <-
           normalize_enum(
             Map.get(attrs, :checkpoint_policy, "direct"),
             @checkpoint_policies,
             "checkpoint_policy"
           ) do
      packet = %__MODULE__{
        version: version,
        success_criteria: success_criteria,
        non_goals: non_goals,
        constraints: constraints,
        architecture_refs: architecture_refs,
        required_evidence: required_evidence,
        checkpoint_policy: checkpoint_policy
      }

      if packet_size_ok?(packet), do: {:ok, packet}, else: too_large()
    end
  rescue
    _ -> {:error, {:invalid_work_packet, :malformed}}
  catch
    _, _ -> {:error, {:invalid_work_packet, :malformed}}
  end

  @doc "Return the canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = packet) do
    %{
      "version" => packet.version,
      "success_criteria" => packet.success_criteria,
      "non_goals" => packet.non_goals,
      "constraints" => packet.constraints,
      "architecture_refs" => packet.architecture_refs,
      "required_evidence" => packet.required_evidence,
      "checkpoint_policy" => packet.checkpoint_policy
    }
  end

  def to_map(_packet), do: {:error, {:invalid_work_packet, :struct_required}}

  @doc "Normalize a packet object directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, packet} <- new(attrs), do: {:ok, to_map(packet)}
  end

  @doc "Return true only for a valid packet object or packet struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = packet), do: match?({:ok, _}, new(to_map(packet)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @doc "Encode the exact canonical normalized packet as UTF-8 JSON bytes."
  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def canonical_bytes(%__MODULE__{} = packet) do
    with {:ok, normalized} <- new(to_map(packet)), do: encode_packet(normalized)
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, packet} <- new(attrs), do: encode_packet(packet)
  end

  def canonical_bytes(_attrs), do: {:error, {:invalid_work_packet, :object_required}}

  @doc "Hash canonical packet bytes as `sha256:` followed by 64 lowercase hex characters."
  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def digest(packet_or_attrs) do
    with {:ok, bytes} <- canonical_bytes(packet_or_attrs) do
      {:ok, @digest_prefix <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  rescue
    _ -> {:error, {:invalid_work_packet, :malformed}}
  catch
    _, _ -> {:error, {:invalid_work_packet, :malformed}}
  end

  @doc "Compatibility alias for `digest/1`; returns the same prefixed SHA-256 digest."
  @spec sha256(t() | map() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def sha256(packet_or_attrs), do: digest(packet_or_attrs)

  defp normalize_version(@schema_version), do: {:ok, @schema_version}
  defp normalize_version(_version), do: {:error, {:invalid_field, "version", :unsupported}}

  defp required_text_list(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> normalize_text_list(value, Atom.to_string(field), true)
      :error -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp optional_text_list(attrs, field) do
    normalize_text_list(Map.get(attrs, field, []), Atom.to_string(field), false)
  end

  defp optional_architecture_refs(attrs) do
    normalize_architecture_refs(Map.get(attrs, :architecture_refs, []))
  end

  defp normalize_text_list(value, field, required?) when is_list(value) do
    with {:ok, values} <- collect_text_list(value, field, 0, []) do
      if required? and values == [],
        do: {:error, {:invalid_field, field, :must_be_non_empty}},
        else: {:ok, values}
    end
  end

  defp normalize_text_list(_value, field, _required?),
    do: {:error, {:invalid_field, field, :expected_list}}

  defp collect_text_list([], _field, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_text_list([_head | _tail], field, index, _acc) when index >= @max_list_items,
    do: {:error, {:invalid_field, field, :list_too_large}}

  defp collect_text_list([head | tail], field, index, acc) do
    with {:ok, text} <- normalize_text(head, "#{field}[#{index}]", @max_text_bytes),
         {:ok, values} <- collect_text_list(tail, field, index + 1, [text | acc]) do
      {:ok, values}
    end
  end

  defp collect_text_list(_improper_tail, field, _index, _acc),
    do: {:error, {:invalid_field, field, :improper_list}}

  defp normalize_architecture_refs(value) when is_list(value) do
    collect_architecture_refs(value, 0, [])
  end

  defp normalize_architecture_refs(_value),
    do: {:error, {:invalid_field, "architecture_refs", :expected_list}}

  defp collect_architecture_refs([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_architecture_refs([_head | _tail], index, _acc) when index >= @max_list_items,
    do: {:error, {:invalid_field, "architecture_refs", :list_too_large}}

  defp collect_architecture_refs([head | tail], index, acc) do
    with {:ok, path} <- normalize_architecture_ref(head, index),
         {:ok, paths} <- collect_architecture_refs(tail, index + 1, [path | acc]) do
      {:ok, paths}
    end
  end

  defp collect_architecture_refs(_improper_tail, _index, _acc),
    do: {:error, {:invalid_field, "architecture_refs", :improper_list}}

  defp normalize_architecture_ref(value, index) when is_binary(value) do
    field = "architecture_refs[#{index}]"

    with {:ok, path} <- normalize_text(value, field, @max_architecture_ref_bytes),
         :ok <- validate_repository_path(path, field) do
      {:ok, path}
    end
  end

  defp normalize_architecture_ref(_value, index),
    do: {:error, {:invalid_field, "architecture_refs[#{index}]", :expected_string}}

  defp validate_repository_path(path, field) do
    segments = String.split(path, "/", trim: false)

    cond do
      String.starts_with?(path, "/") ->
        {:error, {:invalid_field, field, :absolute_path}}

      String.contains?(path, "\\") ->
        {:error, {:invalid_field, field, :non_posix_path}}

      Regex.match?(~r/\A[A-Za-z]:/, path) ->
        {:error, {:invalid_field, field, :absolute_path}}

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        {:error, {:invalid_field, field, :non_canonical_path}}

      true ->
        :ok
    end
  end

  defp normalize_text(value, field, maximum) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_field, field, :invalid_utf8}}

      byte_size(value) == 0 or String.trim(value) == "" ->
        {:error, {:invalid_field, field, :blank}}

      byte_size(value) > maximum ->
        {:error, {:invalid_field, field, :text_too_large}}

      String.match?(value, ~r/[\x00-\x1F\x7F]/) ->
        {:error, {:invalid_field, field, :control_character}}

      true ->
        {:ok, value}
    end
  end

  defp normalize_text(_value, field, _maximum),
    do: {:error, {:invalid_field, field, :expected_string}}

  defp normalize_enum(value, allowed, field) do
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if is_binary(normalized) and normalized in allowed,
      do: {:ok, normalized},
      else: {:error, {:invalid_field, field, :unsupported}}
  end

  defp normalize_object(attrs) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {:invalid_object, :struct_not_allowed}}
      map_size(attrs) > @max_fields -> {:error, {:invalid_object, :object_too_large}}
      true -> normalize_entries(Map.to_list(attrs))
    end
  end

  defp normalize_object(attrs) when is_list(attrs) do
    with {:ok, entries} <- collect_object_entries(attrs, 0, []) do
      normalize_entries(entries)
    end
  end

  defp normalize_object(_attrs), do: {:error, {:invalid_object, :object_required}}

  defp collect_object_entries([], _count, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_object_entries([_head | _tail], count, _acc) when count >= @max_fields,
    do: {:error, {:invalid_object, :object_too_large}}

  defp collect_object_entries([{key, value} | tail], count, acc),
    do: collect_object_entries(tail, count + 1, [{key, value} | acc])

  defp collect_object_entries([_invalid | _tail], _count, _acc),
    do: {:error, {:invalid_object, :object_required}}

  defp collect_object_entries(_improper_tail, _count, _acc),
    do: {:error, {:invalid_object, :improper_list}}

  defp normalize_entries(entries) do
    named_entries = Enum.map(entries, &name_entry/1)

    invalid_keys =
      named_entries
      |> Enum.filter(&match?({:invalid, _}, &1))

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

    unknown_fields =
      named_entries
      |> Enum.flat_map(fn
        {:ok, name, _value} -> if name in @field_names, do: [], else: [name]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      invalid_keys != [] ->
        {:error, {:invalid_object, :invalid_key}}

      duplicate_fields != [] ->
        {:error, {:duplicate_fields, duplicate_fields}}

      unknown_fields != [] ->
        {:error, {:unknown_fields, unknown_fields}}

      true ->
        fields_by_name = Map.new(@fields, &{Atom.to_string(&1), &1})

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

  defp packet_size_ok?(packet) do
    case encode_packet(packet) do
      {:ok, _bytes} -> true
      {:error, _reason} -> false
    end
  end

  defp too_large, do: {:error, {:invalid_work_packet, :packet_too_large}}

  defp encode_packet(packet) do
    case Jason.encode(canonical_packet(packet)) do
      {:ok, bytes} when byte_size(bytes) <= @max_packet_bytes -> {:ok, bytes}
      {:ok, _bytes} -> too_large()
      {:error, _reason} -> {:error, {:invalid_work_packet, :not_json}}
    end
  rescue
    _ -> {:error, {:invalid_work_packet, :not_json}}
  catch
    _, _ -> {:error, {:invalid_work_packet, :not_json}}
  end

  defp canonical_packet(packet) do
    packet
    |> to_map()
    |> canonical_json_object([])
  end

  defp canonical_json_object(values, path) do
    @canonical_object_fields
    |> Map.fetch!(path)
    |> Enum.map(fn field ->
      {field, canonical_json_value(Map.fetch!(values, field), path ++ [field])}
    end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json_value(map, path) when is_map(map) and not is_struct(map),
    do: canonical_json_object(map, path)

  defp canonical_json_value(list, path) when is_list(list),
    do: Enum.map(list, &canonical_json_value(&1, path))

  defp canonical_json_value(value, _path), do: value
end
