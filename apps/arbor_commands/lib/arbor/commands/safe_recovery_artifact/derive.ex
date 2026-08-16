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

  @spec application_class(term()) :: String.t() | {:error, atom()}
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

  def application_class(_), do: {:error, :invalid_manifest}

  @spec findings(term(), term()) :: [map()] | {:error, atom()}
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

  def findings(_, _), do: {:error, :invalid_manifest}

  @spec owner_application(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def owner_application(path, identities) when is_binary(path) and is_list(identities) do
    matches =
      path
      |> String.split("/")
      |> adjacent_lib_identities(identities)

    case Enum.uniq(matches) do
      [] -> {:ok, nil}
      [{name, _vsn}] -> {:ok, name}
      _many -> {:error, :ownership_ambiguity}
    end
  end

  def owner_application(_, _), do: {:error, :ownership_ambiguity}

  @spec applications_consistent?([map()], [map()]) :: :ok | {:error, term()}
  def applications_consistent?(applications, entries)
      when is_list(applications) and is_list(entries) do
    names = MapSet.new(Enum.map(applications, & &1["name"]))
    by_path = Map.new(entries, &{&1["path"], &1})
    identities = Enum.map(applications, &{&1["name"], &1["version"]})

    with :ok <- selected_present(names),
         :ok <- app_spec_bindings(applications, by_path),
         :ok <- declared_deps_present(applications, names),
         :ok <- declared_deps_disjoint(applications) do
      entry_owners(entries, identities)
    end
  end

  def applications_consistent?(_, _), do: {:error, :invalid_manifest}

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

  # Residual: second-snapshot applications are not in the manifest, so
  # app-only drift is status=different with equal payload digests and
  # empty differing_paths. Do not reject that shape.
  @spec reproducibility_consistent?(map(), map()) :: :ok | {:error, atom()}
  def reproducibility_consistent?(repro, facts) when is_map(repro) and is_map(facts) do
    with :ok <- first_digest_match(repro, facts),
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

  defp selected_present(names) do
    if MapSet.subset?(Encode.selected_first_party_names(), names) do
      :ok
    else
      {:error, :missing_selected_application}
    end
  end

  defp app_spec_bindings([], _by_path), do: :ok

  defp app_spec_bindings([app | rest], by_path) do
    path = "lib/" <> app["name"] <> "-" <> app["version"] <> "/ebin/" <> app["name"] <> ".app"
    entry = Map.get(by_path, path)

    cond do
      app["app_spec_path"] != path ->
        {:error, {:invalid_field, "app_spec_path", :derived_mismatch}}

      is_nil(entry) ->
        {:error, {:invalid_field, "app_spec_path", :missing_app_spec}}

      entry["sha256"] != app["app_spec_sha256"] ->
        {:error, {:invalid_field, "app_spec_sha256", :derived_mismatch}}

      entry["content_kind"] != "app_spec" ->
        {:error, {:invalid_field, "content_kind", :derived_mismatch}}

      entry["owner_application"] != app["name"] ->
        {:error, {:invalid_field, "owner_application", :derived_mismatch}}

      true ->
        app_spec_bindings(rest, by_path)
    end
  end

  defp declared_deps_present([], _names), do: :ok

  defp declared_deps_present([app | rest], names) do
    declared = app["declared_applications"]
    needed = declared["required"] ++ declared["included"]

    if Enum.all?(needed, &MapSet.member?(names, &1)) do
      declared_deps_present(rest, names)
    else
      {:error, :missing_dependency}
    end
  end

  defp entry_owners([], _identities), do: :ok

  defp entry_owners([entry | rest], identities) do
    expected_owner = entry["owner_application"]

    case owner_application(entry["path"], identities) do
      {:ok, ^expected_owner} ->
        entry_owners(rest, identities)

      {:ok, _} ->
        {:error, {:invalid_field, "owner_application", :derived_mismatch}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adjacent_lib_identities(segments, identities) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(&match_lib_pair(&1, identities))
  end

  defp match_lib_pair(["lib", ident], identities) do
    Enum.filter(identities, fn
      {name, vsn} when is_binary(name) and is_binary(vsn) -> ident == name <> "-" <> vsn
      _other -> false
    end)
  end

  defp match_lib_pair(_, _), do: []

  defp first_digest_match(%{"payload_tree_digests" => [first, _second]}, facts) do
    if first == facts["payload_tree_digest"] do
      :ok
    else
      {:error, :inconsistent_reproducibility}
    end
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

  # App-only drift: equal payload digests and empty differing_paths.
  defp status_consistent(%{"status" => "different"}), do: :ok
  defp status_consistent(_), do: {:error, :inconsistent_reproducibility}

  defp declared_deps_disjoint([]), do: :ok

  defp declared_deps_disjoint([app | rest]) do
    declared = app["declared_applications"]
    required = MapSet.new(declared["required"])
    included = MapSet.new(declared["included"])
    optional = MapSet.new(declared["optional"])

    overlap? =
      not MapSet.disjoint?(required, included) or not MapSet.disjoint?(required, optional) or
        not MapSet.disjoint?(included, optional)

    if overlap? do
      {:error, :invalid_dependency_list}
    else
      declared_deps_disjoint(rest)
    end
  end
end
