defmodule Arbor.Contracts.Coding.WorkspaceReleaseDescriptor do
  @moduledoc """
  Closed public descriptor for the terminal disposition of a coding workspace.

  This contract is evidence only. It contains no workspace handle, path,
  ownership identity, cleanup authority, callback, or replay instruction.
  """

  use TypedStruct

  @statuses ~w(retained removed)
  @fields [:workspace_release_status, :workspace_expires_at]
  @max_fields 2
  @max_timestamp_bytes 64

  typedstruct enforce: true do
    @typedoc "A bounded, authority-free coding workspace release descriptor."

    field(:workspace_release_status, String.t())
    field(:workspace_expires_at, String.t() | nil, default: nil)
  end

  @doc "Construct a descriptor from a closed atom/string-keyed JSON object."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         {:ok, status} <- required_status(attrs),
         {:ok, expires_at} <- optional_expiry(attrs, status) do
      {:ok,
       %__MODULE__{
         workspace_release_status: status,
         workspace_expires_at: expires_at
       }}
    end
  rescue
    _ -> {:error, {:invalid_workspace_release_descriptor, :malformed}}
  catch
    _, _ -> {:error, {:invalid_workspace_release_descriptor, :malformed}}
  end

  @doc "Return the canonical closed string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => String.t()}
  def to_map(%__MODULE__{} = descriptor) do
    %{"workspace_release_status" => descriptor.workspace_release_status}
    |> maybe_put_expiry(descriptor.workspace_expires_at)
  end

  @doc "Normalize a release descriptor directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, descriptor} <- new(attrs), do: {:ok, to_map(descriptor)}
  end

  @doc "Return true only for a complete valid release descriptor or struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = descriptor), do: match?({:ok, _}, new(to_map(descriptor)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp normalize_object(attrs) when is_map(attrs) do
    if map_size(attrs) <= @max_fields,
      do: normalize_entries(attrs),
      else: {:error, {:invalid_workspace_release_descriptor, :object_too_large}}
  end

  defp normalize_object(attrs) when is_list(attrs) do
    entries = Enum.take(attrs, @max_fields + 1)

    cond do
      length(entries) > @max_fields ->
        {:error, {:invalid_workspace_release_descriptor, :object_too_large}}

      Enum.all?(entries, &match?({_, _}, &1)) ->
        normalize_entries(entries)

      true ->
        {:error, {:invalid_workspace_release_descriptor, :object_required}}
    end
  end

  defp normalize_object(_attrs),
    do: {:error, {:invalid_workspace_release_descriptor, :object_required}}

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

  defp required_status(attrs) do
    case Map.fetch(attrs, :workspace_release_status) do
      {:ok, status} when is_atom(status) -> normalize_status(Atom.to_string(status))
      {:ok, status} -> normalize_status(status)
      :error -> {:error, {:missing_field, "workspace_release_status"}}
    end
  end

  defp normalize_status(status) when status in @statuses, do: {:ok, status}
  defp normalize_status(_status), do: {:error, {:invalid_field, "workspace_release_status"}}

  defp optional_expiry(attrs, "removed") do
    if Map.has_key?(attrs, :workspace_expires_at),
      do: {:error, {:invalid_field, "workspace_expires_at"}},
      else: {:ok, nil}
  end

  defp optional_expiry(attrs, "retained") do
    case Map.fetch(attrs, :workspace_expires_at) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        normalize_timestamp(value)

      {:ok, _value} ->
        {:error, {:invalid_field, "workspace_expires_at"}}
    end
  end

  defp normalize_timestamp(value) do
    valid_text =
      String.valid?(value) and value != "" and byte_size(value) <= @max_timestamp_bytes and
        not String.contains?(value, <<0>>) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)

    with true <- valid_text,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, DateTime.to_iso8601(datetime)}
    else
      _ -> {:error, {:invalid_field, "workspace_expires_at"}}
    end
  end

  defp maybe_put_expiry(map, nil), do: map
  defp maybe_put_expiry(map, expires_at), do: Map.put(map, "workspace_expires_at", expires_at)

  defp printable_key(key) when is_binary(key), do: key
  defp printable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp printable_key(_key), do: "<non-string-key>"
end
