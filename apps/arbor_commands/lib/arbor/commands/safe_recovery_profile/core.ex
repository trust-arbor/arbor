defmodule Arbor.Commands.SafeRecoveryProfile.Core do
  @moduledoc """
  Pure construct core for the E0B1 safe-recovery profile intent.

  `project/1` admits a closed in-memory candidate — never a claim that safe
  boot already works — and returns a string-keyed canonical profile. No
  filesystem, Git, configuration, process, or runtime state is consulted.
  """

  alias Arbor.Commands.SafeRecoveryProfile.Encode

  @profile_atom_keys [
    :schema,
    :version,
    :profile,
    :evidence_status,
    :architecture_status,
    :source_inventory,
    :selected_applications,
    :mandatory_host_responsibilities,
    :forbidden_facilities,
    :expected_external_dependencies,
    :blockers
  ]

  @inventory_atom_keys [
    :platform_inventory_schema,
    :selected_file_count,
    :selected_index_digest,
    :entries_digest,
    :review_digest
  ]

  @application_atom_keys [:name, :role, :rationale]
  @responsibility_atom_keys [:id, :owner, :rationale]
  @facility_atom_keys [:id, :rationale]
  @dependency_atom_keys [:id, :kind, :rationale]
  @blocker_atom_keys [:id, :owner, :rationale]

  @max_map_keys 16
  @max_list_items 32
  @max_key_bytes 256

  @doc "Closed intent schema identifier."
  @spec schema() :: String.t()
  def schema, do: Encode.schema()

  @doc "Closed profile name."
  @spec profile_name() :: String.t()
  def profile_name, do: Encode.profile_name()

  @doc "Admit a closed candidate and return the sorted canonical profile."
  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(candidate) when is_map(candidate) and not is_struct(candidate) do
    with {:ok, normalized} <- normalize_candidate(candidate),
         :ok <- Encode.validate_profile(normalized) do
      {:ok, sort_profile(normalized)}
    end
  end

  def project(_), do: {:error, :invalid_candidate}

  defp normalize_candidate(candidate) do
    with {:ok, profile} <- normalize_map(candidate, @profile_atom_keys),
         {:ok, inventory} <-
           normalize_nested_map(profile, "source_inventory", @inventory_atom_keys),
         {:ok, applications} <-
           normalize_nested_list(profile, "selected_applications", @application_atom_keys),
         {:ok, responsibilities} <-
           normalize_nested_list(
             profile,
             "mandatory_host_responsibilities",
             @responsibility_atom_keys
           ),
         {:ok, facilities} <-
           normalize_nested_list(profile, "forbidden_facilities", @facility_atom_keys),
         {:ok, dependencies} <-
           normalize_nested_list(
             profile,
             "expected_external_dependencies",
             @dependency_atom_keys
           ),
         {:ok, blockers} <- normalize_nested_list(profile, "blockers", @blocker_atom_keys) do
      {:ok,
       %{
         profile
         | "source_inventory" => inventory,
           "selected_applications" => applications,
           "mandatory_host_responsibilities" => responsibilities,
           "forbidden_facilities" => facilities,
           "expected_external_dependencies" => dependencies,
           "blockers" => blockers
       }}
    end
  end

  defp normalize_nested_map(profile, field, atom_keys) do
    case normalize_map(Map.fetch!(profile, field), atom_keys) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:invalid_field, field, reason}}
    end
  end

  defp normalize_nested_list(profile, field, atom_keys) do
    case normalize_map_list(Map.fetch!(profile, field), atom_keys) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:invalid_field, field, reason}}
    end
  end

  defp normalize_map(map, atom_keys) when is_map(map) and not is_struct(map) do
    if map_size(map) > @max_map_keys do
      {:error, :unbounded}
    else
      normalize_bounded_map(map, atom_keys)
    end
  end

  defp normalize_map(_, _), do: {:error, :invalid_map}

  defp normalize_bounded_map(map, atom_keys) do
    keys = Map.keys(map)

    with :ok <- admit_key_types(keys),
         :ok <- admit_map_keys(keys) do
      normalize_key_style(map, keys, atom_keys)
    end
  end

  defp admit_key_types(keys) do
    if Enum.any?(keys, &(is_nil(&1) or (not is_atom(&1) and not is_binary(&1)))) do
      {:error, :invalid_map_keys}
    else
      :ok
    end
  end

  defp normalize_key_style(map, keys, atom_keys) do
    cond do
      Enum.all?(keys, &is_atom/1) -> admit_key_style(map, keys, atom_keys, :atom)
      Enum.all?(keys, &is_binary/1) -> admit_key_style(map, keys, atom_keys, :string)
      true -> {:error, :mixed_keys}
    end
  end

  defp admit_key_style(map, keys, atom_keys, :atom) do
    if MapSet.new(keys) == MapSet.new(atom_keys) do
      {:ok,
       Map.new(atom_keys, fn atom ->
         {Atom.to_string(atom), Map.fetch!(map, atom)}
       end)}
    else
      field_mismatch(keys, atom_keys)
    end
  end

  defp admit_key_style(map, keys, atom_keys, :string) do
    expected = Enum.map(atom_keys, &Atom.to_string/1)

    if MapSet.new(keys) == MapSet.new(expected) do
      {:ok, map}
    else
      field_mismatch(keys, atom_keys)
    end
  end

  defp admit_map_keys(keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case admit_map_key(key) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp admit_map_key(key) when is_atom(key), do: :ok

  defp admit_map_key(key) when is_binary(key) do
    cond do
      byte_size(key) > @max_key_bytes -> {:error, :unbounded}
      not String.valid?(key) -> {:error, :invalid_map_keys}
      true -> :ok
    end
  end

  defp admit_map_key(_), do: {:error, :invalid_map_keys}

  defp field_mismatch(keys, atom_keys) do
    expected = Enum.map(atom_keys, &Atom.to_string/1)
    expected_set = MapSet.new(expected)
    missing = Enum.reject(expected, fn key -> Enum.any?(keys, &(stringify_key(&1) == key)) end)
    extra_count = Enum.count(keys, &(stringify_key(&1) not in expected_set))

    {:error, {:field_mismatch, %{missing: missing, extra_count: extra_count}}}
  end

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_binary(key), do: key

  defp normalize_map_list(list, atom_keys) do
    case take_proper_list(list, @max_list_items) do
      {:ok, items} ->
        normalize_map_items(items, atom_keys, [])

      {:error, _} = error ->
        error
    end
  end

  defp normalize_map_items([], _atom_keys, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_map_items([item | rest], atom_keys, acc) do
    case normalize_map(item, atom_keys) do
      {:ok, normalized} -> normalize_map_items(rest, atom_keys, [normalized | acc])
      {:error, _} = error -> error
    end
  end

  defp take_proper_list([], _max), do: {:ok, []}

  defp take_proper_list([head | tail], max) do
    take_proper_list(tail, max, 1, [head])
  end

  defp take_proper_list(_, _), do: {:error, :not_a_list}

  defp take_proper_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], max, count, acc) do
    if count >= max do
      {:error, :unbounded}
    else
      take_proper_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_proper_list(_, _, _, _), do: {:error, :improper_list}

  defp sort_profile(profile) do
    %{
      profile
      | "selected_applications" => Enum.sort_by(profile["selected_applications"], & &1["name"]),
        "mandatory_host_responsibilities" =>
          Enum.sort_by(profile["mandatory_host_responsibilities"], & &1["id"]),
        "forbidden_facilities" => Enum.sort_by(profile["forbidden_facilities"], & &1["id"]),
        "expected_external_dependencies" =>
          Enum.sort_by(profile["expected_external_dependencies"], & &1["id"]),
        "blockers" => Enum.sort_by(profile["blockers"], & &1["id"])
    }
  end
end
