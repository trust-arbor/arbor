defmodule Arbor.Commands.SafeRecoveryArtifact.Derive do
  @moduledoc false

  # Shared pure derivation so Core and Encode cannot drift.

  alias Arbor.Commands.SafeRecoveryArtifact.Encode

  @blocker_owner "p1e_release_separation"
  @severity "blocker"

  @finding_unexpected "unexpected_first_party_applications"
  @finding_third "third_party_applications"
  @finding_forbidden "forbidden_runtime_applications"
  @finding_unsafe "unsafe_native_or_executable_ownership"

  @spec application_class(String.t()) :: String.t()
  def application_class(name) when is_binary(name) do
    cond do
      MapSet.member?(Encode.selected_first_party_names(), name) ->
        "selected_first_party"

      arbor_prefix?(name) ->
        "unexpected_first_party"

      MapSet.member?(Encode.runtime_application_names(), name) ->
        "runtime"

      true ->
        "third_party"
    end
  end

  @spec findings([map()], [map()]) :: [map()]
  def findings(applications, entries) when is_list(applications) and is_list(entries) do
    [
      class_finding(@finding_unexpected, "unexpected_first_party", applications, entries),
      class_finding(@finding_third, "third_party", applications, entries),
      forbidden_finding(applications, entries),
      unsafe_finding(entries)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1["id"])
  end

  @spec release_facts([map()], [map()]) :: {:ok, map()} | {:error, term()}
  def release_facts(applications, entries)
      when is_list(applications) and is_list(entries) do
    with {:ok, payload} <- Encode.payload_tree_digest(entries),
         {:ok, apps_digest} <- Encode.applications_digest(applications) do
      {:ok,
       %{
         "entry_count" => length(entries),
         "total_bytes" => sum_sizes(entries, 0),
         "application_count" => length(applications),
         "payload_tree_digest" => payload,
         "applications_digest" => apps_digest
       }}
    end
  end

  def release_facts(_, _), do: {:error, :invalid_manifest}

  @spec reproducibility_consistent?(map(), String.t()) :: :ok | {:error, atom()}
  def reproducibility_consistent?(repro, payload_digest)
      when is_map(repro) and is_binary(payload_digest) do
    with :ok <- first_digest_match(repro, payload_digest),
         :ok <- rule_match(repro) do
      status_consistent(repro)
    end
  end

  def reproducibility_consistent?(_, _), do: {:error, :inconsistent_reproducibility}

  defp arbor_prefix?(<<"arbor_", _::binary>>), do: true
  defp arbor_prefix?(_), do: false

  defp class_finding(id, class, applications, entries) do
    names = names_with_class(applications, class)
    finding_if_names(id, names, paths_for_owners(entries, names, applications))
  end

  defp forbidden_finding(applications, entries) do
    forbidden = Encode.forbidden_runtime_application_names()
    names = Enum.filter(Enum.map(applications, & &1["name"]), &MapSet.member?(forbidden, &1))
    finding_if_names(@finding_forbidden, names, paths_for_owners(entries, names, applications))
  end

  defp unsafe_finding(entries) do
    selected = Encode.selected_first_party_names()

    unsafe =
      Enum.filter(entries, fn entry ->
        unsafe_kind?(entry["content_kind"]) and
          not selected_owner?(entry["owner_application"], selected)
      end)

    names =
      unsafe
      |> Enum.map(& &1["owner_application"])
      |> Enum.reject(&is_nil/1)

    paths = Enum.map(unsafe, & &1["path"])
    maybe_finding(@finding_unsafe, names, paths)
  end

  defp unsafe_kind?(kind) when kind in ["native", "executable"], do: true
  defp unsafe_kind?(_), do: false

  defp selected_owner?(owner, selected) when is_binary(owner), do: MapSet.member?(selected, owner)
  defp selected_owner?(_, _), do: false

  defp names_with_class(applications, class) do
    applications
    |> Enum.filter(&(&1["class"] == class))
    |> Enum.map(& &1["name"])
  end

  defp paths_for_owners(entries, names, applications) do
    name_set = MapSet.new(names)

    spec_paths =
      applications
      |> Enum.filter(&MapSet.member?(name_set, &1["name"]))
      |> Enum.map(& &1["app_spec_path"])

    owned =
      entries
      |> Enum.filter(&MapSet.member?(name_set, &1["owner_application"]))
      |> Enum.map(& &1["path"])

    spec_paths ++ owned
  end

  defp finding_if_names(_id, [], _paths), do: nil
  defp finding_if_names(id, names, paths), do: maybe_finding(id, names, paths)

  defp maybe_finding(_id, [], []), do: nil

  defp maybe_finding(id, names, paths) do
    %{
      "id" => id,
      "severity" => @severity,
      "blocker_owner" => @blocker_owner,
      "applications" => names |> Enum.uniq() |> Enum.sort(),
      "paths" => paths |> Enum.uniq() |> Enum.sort()
    }
  end

  defp sum_sizes([], acc), do: acc
  defp sum_sizes([entry | rest], acc), do: sum_sizes(rest, acc + entry["size"])

  defp first_digest_match(%{"payload_tree_digests" => [first, _second]}, expected)
       when first == expected do
    :ok
  end

  defp first_digest_match(_, _), do: {:error, :inconsistent_reproducibility}

  defp rule_match(%{"rule" => "remove_exact_releases_cookie_before_scan"}), do: :ok
  defp rule_match(_), do: {:error, :inconsistent_reproducibility}

  defp status_consistent(%{
         "status" => "identical",
         "payload_tree_digests" => [same, same],
         "differing_paths" => []
       }) do
    :ok
  end

  defp status_consistent(%{"status" => "identical"}), do: {:error, :inconsistent_reproducibility}

  defp status_consistent(%{"status" => "different"}), do: :ok
  defp status_consistent(_), do: {:error, :inconsistent_reproducibility}
end
