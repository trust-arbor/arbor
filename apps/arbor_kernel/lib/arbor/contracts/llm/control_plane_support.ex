defmodule Arbor.Contracts.LLM.ControlPlaneSupport do
  @moduledoc false

  @max_number 1.0e18
  @max_text_bytes 512
  @max_timestamp_bytes 64

  @spec normalize_object(map() | keyword(), [atom()], atom()) ::
          {:ok, map()} | {:error, tuple()}
  def normalize_object(attrs, fields, tag) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {tag, :struct_not_allowed}}
      map_size(attrs) > length(fields) -> {:error, {tag, :object_too_large}}
      true -> normalize_entries(Map.to_list(attrs), fields, tag)
    end
  end

  def normalize_object(attrs, fields, tag) when is_list(attrs) do
    with {:ok, entries} <- collect_entries(attrs, length(fields), tag),
         {:ok, normalized} <- normalize_entries(entries, fields, tag) do
      {:ok, normalized}
    end
  end

  def normalize_object(_attrs, _fields, tag), do: {:error, {tag, :object_required}}

  @spec normalize_identifier(term(), atom(), pos_integer()) ::
          {:ok, String.t()} | {:error, tuple()}
  def normalize_identifier(value, field, maximum \\ @max_text_bytes) do
    value = if is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value

    case value do
      value when is_binary(value) -> normalize_text(value, field, maximum)
      _ -> {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  @spec normalize_text(term(), atom() | String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, tuple()}
  def normalize_text(value, field, maximum)
      when is_binary(value) do
    field = field_name(field)

    if String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= maximum and
         String.trim(value) != "" and not String.match?(value, ~r/[\x00-\x1F\x7F]/) do
      {:ok, value}
    else
      {:error, {:invalid_field, field}}
    end
  end

  def normalize_text(_value, field, _maximum), do: {:error, {:invalid_field, field_name(field)}}

  def normalize_text(value, field), do: normalize_text(value, field, @max_text_bytes)

  @spec normalize_enum(term(), [String.t()], atom()) ::
          {:ok, String.t()} | {:error, tuple()}
  def normalize_enum(value, allowed, field) do
    value = if is_atom(value), do: Atom.to_string(value), else: value

    if is_binary(value) and value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  @spec optional_enum(map(), atom(), [String.t()]) ::
          {:ok, String.t() | nil} | {:error, tuple()}
  def optional_enum(attrs, field, allowed) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil}
      value -> normalize_enum(value, allowed, field)
    end
  end

  @spec required_timestamp(term(), atom()) ::
          {:ok, String.t(), DateTime.t()} | {:error, tuple()}
  def required_timestamp(value, field), do: normalize_timestamp(value, field)

  @spec optional_timestamp(map(), atom()) ::
          {:ok, String.t() | nil, DateTime.t() | nil} | {:error, tuple()}
  def optional_timestamp(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil, nil}
      value -> normalize_timestamp(value, field)
    end
  end

  @spec validate_expiry(DateTime.t(), DateTime.t() | nil) :: :ok | {:error, tuple()}
  def validate_expiry(_observed, nil), do: :ok

  def validate_expiry(observed, expires_at) do
    if DateTime.compare(expires_at, observed) == :gt,
      do: :ok,
      else: {:error, {:invalid_field, "expires_at"}}
  end

  @spec nonnegative_number(term(), atom()) ::
          {:ok, number()} | {:error, tuple()}
  def nonnegative_number(value, _field)
      when is_integer(value) and value >= 0 and value <= 1_000_000_000_000_000_000,
      do: {:ok, value}

  def nonnegative_number(value, field) when is_float(value) do
    if value >= 0.0 and value <= @max_number,
      do: {:ok, value},
      else: {:error, {:invalid_field, Atom.to_string(field)}}
  end

  def nonnegative_number(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  @spec optional_nonnegative_number(map(), atom()) ::
          {:ok, number() | nil} | {:error, tuple()}
  def optional_nonnegative_number(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil}
      value -> nonnegative_number(value, field)
    end
  end

  @spec optional_nonnegative_integer(map(), atom()) ::
          {:ok, non_neg_integer() | nil} | {:error, tuple()}
  def optional_nonnegative_integer(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 and value <= 1_000_000_000_000 -> {:ok, value}
      _ -> {:error, {:invalid_field, Atom.to_string(field)}}
    end
  end

  @spec put_optional(map(), String.t(), term()) :: map()
  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)

  @spec canonical_bytes(map(), [atom()], atom(), pos_integer()) ::
          {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(values, fields, tag, max_bytes) do
    ordered =
      fields
      |> Enum.flat_map(fn field ->
        key = Atom.to_string(field)
        if Map.has_key?(values, key), do: [{key, Map.fetch!(values, key)}], else: []
      end)
      |> Jason.OrderedObject.new()

    case Jason.encode(ordered) do
      {:ok, bytes} when byte_size(bytes) <= max_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, {tag, :object_too_large}}
      {:error, _reason} -> {:error, {tag, :not_json}}
    end
  rescue
    _ -> {:error, {tag, :not_json}}
  catch
    _, _ -> {:error, {tag, :not_json}}
  end

  def digest(bytes, tag) when is_binary(bytes) do
    {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  rescue
    _ -> {:error, {tag, :not_json}}
  end

  def digest(_bytes, tag), do: {:error, {tag, :not_json}}

  defp normalize_timestamp(value, field) when is_binary(value) do
    field = Atom.to_string(field)

    with true <- String.valid?(value),
         true <- byte_size(value) > 0 and byte_size(value) <= @max_timestamp_bytes,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, utc_datetime} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, DateTime.to_iso8601(utc_datetime), utc_datetime}
    else
      _ -> {:error, {:invalid_field, field}}
    end
  end

  defp normalize_timestamp(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp collect_entries([], _maximum, _tag), do: {:ok, []}

  defp collect_entries(_attrs, maximum, tag) when maximum < 1,
    do: {:error, {tag, :object_too_large}}

  defp collect_entries([{key, value} | tail], maximum, tag),
    do: collect_entries(tail, maximum - 1, tag) |> prepend_entry(key, value)

  defp collect_entries([_invalid | _tail], _maximum, tag), do: {:error, {tag, :object_required}}
  defp collect_entries(_improper_tail, _maximum, tag), do: {:error, {tag, :improper_list}}

  defp prepend_entry({:ok, entries}, key, value), do: {:ok, [{key, value} | entries]}
  defp prepend_entry(error, _key, _value), do: error

  defp normalize_entries(entries, fields, tag) do
    named_entries = Enum.map(entries, &name_entry/1)

    cond do
      Enum.any?(named_entries, &match?({:invalid, _}, &1)) ->
        {:error, {tag, :invalid_key}}

      duplicate_fields(named_entries) != [] ->
        {:error, {:duplicate_fields, duplicate_fields(named_entries)}}

      unknown_fields(named_entries, fields) != [] ->
        {:error, {:unknown_fields, unknown_fields(named_entries, fields)}}

      true ->
        {:ok,
         Map.new(named_entries, fn {:ok, name, value} -> {field_atom(name, fields), value} end)}
    end
  end

  defp name_entry({key, value}) do
    case key_name(key) do
      {:ok, name} -> {:ok, name, value}
      :error -> {:invalid, nil}
    end
  end

  defp key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key_name(key) when is_binary(key) and byte_size(key) <= @max_text_bytes, do: {:ok, key}
  defp key_name(_key), do: :error

  defp duplicate_fields(entries) do
    entries
    |> Enum.flat_map(fn
      {:ok, name, _value} -> [name]
      _ -> []
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp unknown_fields(entries, fields) do
    field_names = Enum.map(fields, &Atom.to_string/1)

    entries
    |> Enum.flat_map(fn
      {:ok, name, _value} -> if name in field_names, do: [], else: [name]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp field_atom(name, fields),
    do: Enum.find(fields, fn field -> Atom.to_string(field) == name end)

  defp field_name(field) when is_atom(field), do: Atom.to_string(field)
  defp field_name(field), do: field
end
