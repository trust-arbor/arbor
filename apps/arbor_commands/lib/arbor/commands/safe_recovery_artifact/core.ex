defmodule Arbor.Commands.SafeRecoveryArtifact.Core do
  @moduledoc """
  Pure construct core for the E0B2B safe-recovery artifact payload.

  `project/1` admits one closed in-memory candidate and returns a
  string-keyed canonical manifest. No filesystem, Git, Mix, or process
  state is consulted.
  """

  import Bitwise

  alias Arbor.Commands.SafeRecoveryArtifact.{Classify, Derive, Encode, Parse}

  @candidate_keys ["builds", "profile", "release", "source", "toolchain"]
  @snapshot_keys ["inventory", "term_contents"]
  @inventory_keys ["counts", "directories", "regular_files", "schema"]
  @directory_keys ["mode", "path"]
  @file_keys ["executable", "mode", "path", "prefix_hex", "sha256", "size"]
  @counts_keys ["directories", "entries", "regular_files", "total_regular_bytes"]
  @content_keys ["bytes", "path"]
  @profile_keys ["architecture_status", "digest", "evidence_status", "name", "schema"]
  @source_keys ["build_inputs", "commit", "object_format", "platform_inventory", "tree"]
  @inventory_source_keys [
    "entries_digest",
    "platform_inventory_schema",
    "review_digest",
    "selected_file_count",
    "selected_index_digest"
  ]
  @toolchain_keys [
    "elixir",
    "environment",
    "erlang",
    "erts",
    "mix",
    "mix_lock_sha256",
    "target",
    "tool_versions_sha256"
  ]
  @release_id_keys ["logical_root", "name", "version"]
  @build_input_keys ["path", "sha256"]

  @inventory_schema "arbor.shell.regular_tree_inventory.v1"
  @max_entries 50_000
  @max_total_bytes 512 * 1024 * 1024
  @max_build_inputs 5_000
  @max_term_body 256 * 1024
  @max_term_aggregate 16 * 1024 * 1024
  @prefix_bytes 256

  @spec schema() :: String.t()
  def schema, do: Encode.schema()

  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(candidate) when is_map(candidate) and not is_struct(candidate) do
    with {:ok, admitted} <- Encode.admit_closed_map(candidate, @candidate_keys),
         {:ok, profile} <- admit_profile(admitted["profile"]),
         {:ok, source} <- admit_source(admitted["source"]),
         {:ok, toolchain} <- admit_toolchain(admitted["toolchain"]),
         {:ok, release_id} <- admit_release_id(admitted["release"]),
         {:ok, snapshots} <- admit_builds(admitted["builds"]),
         {:ok, first} <- project_snapshot(hd(snapshots), release_id, toolchain),
         {:ok, second} <- project_snapshot(List.last(snapshots), release_id, toolchain) do
      assemble(profile, source, toolchain, release_id, first, second)
    end
  end

  def project(_), do: {:error, :invalid_candidate}

  defp admit_profile(profile) do
    case Encode.admit_closed_map(profile, @profile_keys) do
      {:ok, admitted} -> validate_profile_fields(admitted)
      error -> error
    end
  end

  defp validate_profile_fields(profile) do
    expected = %{
      "schema" => Encode.profile_schema(),
      "name" => Encode.profile_name(),
      "digest" => Encode.profile_digest_value(),
      "evidence_status" => "conformant",
      "architecture_status" => "blocked"
    }

    if profile == expected, do: {:ok, profile}, else: profile_mismatch(profile, expected)
  end

  defp profile_mismatch(profile, expected) do
    cond do
      profile["schema"] != expected["schema"] ->
        {:error, {:invalid_field, "schema", :invalid_schema}}

      profile["digest"] != expected["digest"] ->
        {:error, {:invalid_field, "digest", :digest_mismatch}}

      true ->
        {:error, {:invalid_field, "profile", :profile_mismatch}}
    end
  end

  defp admit_source(source) do
    with {:ok, admitted} <- Encode.admit_closed_map(source, @source_keys),
         {:ok, inventory} <-
           Encode.admit_closed_map(admitted["platform_inventory"], @inventory_source_keys),
         :ok <- require_e0a(inventory),
         {:ok, inputs} <- admit_build_inputs(admitted["build_inputs"]),
         :ok <- admit_git(admitted) do
      {:ok, %{admitted | "platform_inventory" => inventory, "build_inputs" => inputs}}
    end
  end

  defp require_e0a(inventory) do
    expected = %{
      "platform_inventory_schema" => Encode.platform_inventory_schema(),
      "selected_file_count" => Encode.selected_file_count(),
      "selected_index_digest" => Encode.e0a_index_digest(),
      "entries_digest" => Encode.e0a_entries_digest(),
      "review_digest" => Encode.e0a_review_digest()
    }

    if inventory == expected do
      :ok
    else
      {:error, {:invalid_field, "platform_inventory", :digest_mismatch}}
    end
  end

  defp admit_git(source) do
    format = source["object_format"]
    width = if format == "sha1", do: 40, else: 64

    cond do
      format not in ["sha1", "sha256"] ->
        {:error, {:invalid_field, "object_format", :invalid_object_format}}

      not oid?(source["commit"], width) ->
        {:error, {:invalid_field, "commit", :invalid_object_format}}

      not oid?(source["tree"], width) ->
        {:error, {:invalid_field, "tree", :invalid_object_format}}

      true ->
        :ok
    end
  end

  defp oid?(value, width) when is_binary(value) do
    byte_size(value) == width and Regex.match?(~r/\A[0-9a-f]+\z/, value)
  end

  defp oid?(_, _), do: false

  defp admit_build_inputs(list) do
    with {:ok, items} <- Encode.take_proper_list(list, @max_build_inputs),
         {:ok, admitted} <- admit_input_items(items, []),
         :ok <- unique_sorted_paths(admitted) do
      {:ok, Enum.sort_by(admitted, & &1["path"])}
    else
      {:error, reason} -> {:error, {:invalid_field, "build_inputs", reason}}
    end
  end

  defp admit_input_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp admit_input_items([item | rest], acc) do
    case Encode.admit_closed_map(item, @build_input_keys) do
      {:ok, admitted} ->
        with :ok <- Encode.valid_path?(admitted["path"]),
             :ok <- Encode.valid_digest?(admitted["sha256"]) do
          admit_input_items(rest, [admitted | acc])
        end

      error ->
        error
    end
  end

  defp unique_sorted_paths(items) do
    paths = Enum.map(items, & &1["path"])

    if length(Enum.uniq(paths)) == length(paths) do
      :ok
    else
      {:error, :duplicate_path}
    end
  end

  defp admit_toolchain(toolchain) do
    with {:ok, admitted} <- Encode.admit_closed_map(toolchain, @toolchain_keys),
         :ok <- Encode.valid_digest?(admitted["tool_versions_sha256"]),
         :ok <- Encode.valid_digest?(admitted["mix_lock_sha256"]) do
      require_toolchain(admitted)
    end
  end

  defp require_toolchain(toolchain) do
    constants = Encode.toolchain_constants()

    match? =
      toolchain["target"] == constants["target"] and
        toolchain["erlang"] == constants["erlang"] and
        toolchain["erts"] == constants["erts"] and
        toolchain["elixir"] == constants["elixir"] and
        toolchain["mix"] == constants["mix"] and
        toolchain["environment"] == constants["environment"]

    if match?, do: {:ok, toolchain}, else: {:error, {:invalid_field, "toolchain", :profile_mismatch}}
  end

  defp admit_release_id(release) do
    with {:ok, admitted} <- Encode.admit_closed_map(release, @release_id_keys) do
      if admitted["name"] == Encode.release_name() and
           admitted["version"] == Encode.release_version() and
           admitted["logical_root"] == Encode.logical_root() do
        {:ok, admitted}
      else
        {:error, {:invalid_field, "release", :release_mismatch}}
      end
    end
  end

  defp admit_builds(list) do
    case Encode.take_proper_list(list, 2) do
      {:ok, [first, second]} ->
        with {:ok, snap1} <- admit_snapshot(first),
             {:ok, snap2} <- admit_snapshot(second) do
          {:ok, [snap1, snap2]}
        end

      {:ok, _} ->
        {:error, :snapshot_count}

      {:error, :unbounded} ->
        {:error, :snapshot_count}

      {:error, reason} ->
        {:error, {:invalid_field, "builds", reason}}
    end
  end

  defp admit_snapshot(snapshot), do: Encode.admit_closed_map(snapshot, @snapshot_keys)

  defp project_snapshot(snapshot, release_id, toolchain) do
    with {:ok, inventory} <- admit_inventory(snapshot["inventory"]),
         {:ok, contents} <- admit_contents(snapshot["term_contents"], inventory),
         {:ok, parsed} <- parse_contents(contents),
         {:ok, applications} <- agree_release(parsed, release_id, toolchain),
         {:ok, {applications, entries}} <- project_entries(inventory, parsed, applications) do
      {:ok, %{applications: applications, entries: entries}}
    end
  end

  defp admit_inventory(document) do
    with {:ok, admitted} <- Encode.admit_closed_map(document, @inventory_keys),
         :ok <- require_inventory_schema(admitted["schema"]),
         {:ok, dirs} <- admit_directories(admitted["directories"]),
         {:ok, files} <- admit_regular_files(admitted["regular_files"]),
         {:ok, counts} <- Encode.admit_closed_map(admitted["counts"], @counts_keys),
         :ok <- require_counts(dirs, files, counts),
         :ok <- require_sorted_inventory(dirs, files),
         :ok <- reject_cookie(files) do
      {:ok, %{admitted | "directories" => dirs, "regular_files" => files, "counts" => counts}}
    end
  end

  defp require_inventory_schema(@inventory_schema), do: :ok

  defp require_inventory_schema(value) when is_binary(value),
    do: {:error, {:invalid_field, "schema", :inventory_schema}}

  defp require_inventory_schema(_), do: {:error, {:invalid_field, "schema", :not_a_string}}

  defp admit_directories(list) do
    case Encode.take_proper_list(list, @max_entries) do
      {:ok, items} -> admit_dir_items(items, [])
      error -> error
    end
  end

  defp admit_dir_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp admit_dir_items([item | rest], acc) do
    with {:ok, admitted} <- Encode.admit_closed_map(item, @directory_keys),
         :ok <- Encode.valid_path?(admitted["path"]),
         :ok <- mode_ok(admitted["mode"]) do
      admit_dir_items(rest, [admitted | acc])
    end
  end

  defp admit_regular_files(list) do
    case Encode.take_proper_list(list, @max_entries) do
      {:ok, items} -> admit_file_items(items, [])
      error -> error
    end
  end

  defp admit_file_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp admit_file_items([item | rest], acc) do
    with {:ok, admitted} <- Encode.admit_closed_map(item, @file_keys),
         :ok <- admit_file_fields(admitted) do
      admit_file_items(rest, [admitted | acc])
    end
  end

  defp admit_file_fields(file) do
    with :ok <- Encode.valid_path?(file["path"]),
         :ok <- mode_ok(file["mode"]),
         :ok <- bool_ok(file["executable"]),
         :ok <- size_ok(file["size"]),
         :ok <- Encode.valid_digest?(file["sha256"]),
         :ok <- prefix_ok(file["prefix_hex"], file["size"]),
         :ok <- executable_agrees(file) do
      :ok
    end
  end

  defp mode_ok(mode) when is_integer(mode) and mode >= 0 and mode <= 0o7777, do: :ok
  defp mode_ok(mode) when is_integer(mode), do: {:error, :unbounded}
  defp mode_ok(_), do: {:error, :not_an_integer}

  defp bool_ok(value) when is_boolean(value), do: :ok
  defp bool_ok(_), do: {:error, :not_a_string}

  defp size_ok(size) when is_integer(size) and size >= 0 and size <= @max_total_bytes, do: :ok
  defp size_ok(size) when is_integer(size) and size < 0, do: {:error, :negative}
  defp size_ok(size) when is_integer(size), do: {:error, :unbounded}
  defp size_ok(_), do: {:error, :not_an_integer}

  defp prefix_ok(hex, size) when is_binary(hex) do
    expected = 2 * min(size, @prefix_bytes)

    cond do
      byte_size(hex) != expected -> {:error, :invalid_digest}
      not Regex.match?(~r/\A[0-9a-f]*\z/, hex) -> {:error, :invalid_digest}
      rem(byte_size(hex), 2) != 0 -> {:error, :invalid_digest}
      true -> :ok
    end
  end

  defp prefix_ok(_, _), do: {:error, :not_a_string}

  defp executable_agrees(%{"mode" => mode, "executable" => executable}) do
    expected = (mode &&& 0o111) != 0

    if executable == expected do
      :ok
    else
      {:error, :count_mismatch}
    end
  end

  defp require_counts(dirs, files, counts) do
    total = Enum.reduce(files, 0, fn file, acc -> acc + file["size"] end)
    entries = length(dirs) + length(files)

    cond do
      entries > @max_entries ->
        {:error, :unbounded}

      total > @max_total_bytes ->
        {:error, :unbounded}

      counts["directories"] != length(dirs) ->
        {:error, :inventory_counts}

      counts["regular_files"] != length(files) ->
        {:error, :inventory_counts}

      counts["entries"] != entries ->
        {:error, :inventory_counts}

      counts["total_regular_bytes"] != total ->
        {:error, :inventory_counts}

      true ->
        unique_inventory_paths(dirs, files)
    end
  end

  defp unique_inventory_paths(dirs, files) do
    paths = Enum.map(dirs, & &1["path"]) ++ Enum.map(files, & &1["path"])

    if length(Enum.uniq(paths)) == length(paths) do
      :ok
    else
      {:error, :duplicate_path}
    end
  end

  defp require_sorted_inventory(dirs, files) do
    dir_paths = Enum.map(dirs, & &1["path"])
    file_paths = Enum.map(files, & &1["path"])

    if dir_paths == Enum.sort(dir_paths) and file_paths == Enum.sort(file_paths) do
      :ok
    else
      {:error, :inventory_not_sorted}
    end
  end

  defp reject_cookie(files) do
    if Enum.any?(files, &(&1["path"] == "releases/COOKIE")) do
      {:error, :cookie_present}
    else
      :ok
    end
  end

  defp admit_contents(list, inventory) do
    needed = term_paths(inventory["regular_files"])

    with {:ok, items} <- Encode.take_proper_list(list, length(needed) + 1),
         {:ok, admitted} <- admit_content_items(items, [], 0),
         :ok <- match_content_paths(admitted, needed),
         :ok <- match_content_bytes(admitted, inventory["regular_files"]) do
      {:ok, Map.new(admitted, &{&1["path"], &1["bytes"]})}
    end
  end

  defp term_paths(files) do
    files
    |> Enum.filter(&(String.ends_with?(&1["path"], ".app") or String.ends_with?(&1["path"], ".rel")))
    |> Enum.map(& &1["path"])
    |> Enum.sort()
  end

  defp admit_content_items([], acc, _total), do: {:ok, Enum.reverse(acc)}

  defp admit_content_items([item | rest], acc, total) do
    with {:ok, admitted} <- Encode.admit_closed_map(item, @content_keys),
         :ok <- Encode.valid_path?(admitted["path"]),
         :ok <- bytes_ok(admitted["bytes"]),
         :ok <- aggregate_ok(total, admitted["bytes"]) do
      admit_content_items(rest, [admitted | acc], total + byte_size(admitted["bytes"]))
    end
  end

  defp bytes_ok(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_term_body, do: :ok
  defp bytes_ok(bytes) when is_binary(bytes), do: {:error, :unbounded}
  defp bytes_ok(_), do: {:error, :malformed_term}

  defp aggregate_ok(total, bytes) do
    if total + byte_size(bytes) <= @max_term_aggregate, do: :ok, else: {:error, :unbounded}
  end

  defp match_content_paths(items, needed) do
    paths = items |> Enum.map(& &1["path"]) |> Enum.sort()

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :duplicate_path}

      paths == needed ->
        :ok

      extra?(paths, needed) ->
        {:error, :extra_content}

      true ->
        {:error, :missing_content}
    end
  end

  defp extra?(paths, needed) do
    Enum.any?(paths, &(&1 not in needed))
  end

  defp match_content_bytes(items, files) do
    by_path = Map.new(files, &{&1["path"], &1})

    Enum.reduce_while(items, :ok, fn item, :ok ->
      file = Map.fetch!(by_path, item["path"])
      bytes = item["bytes"]
      digest = sha256_hex(bytes)

      cond do
        byte_size(bytes) != file["size"] ->
          {:halt, {:error, :content_size_mismatch}}

        digest != file["sha256"] ->
          {:halt, {:error, :content_digest_mismatch}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp parse_contents(contents) do
    Enum.reduce_while(contents, {:ok, %{apps: %{}, rels: %{}}}, fn {path, bytes}, {:ok, acc} ->
      parse_one(path, bytes, acc)
    end)
  end

  defp parse_one(path, bytes, acc) do
    case content_role(path) do
      :app -> parse_app_content(path, bytes, acc)
      :rel -> parse_rel_content(path, bytes, acc)
    end
  end

  defp content_role(path) do
    if String.ends_with?(path, ".app"), do: :app, else: :rel
  end

  defp parse_app_content(path, bytes, acc) do
    case Parse.app_spec(bytes) do
      {:ok, spec} -> {:cont, {:ok, put_in(acc, [:apps, path], spec)}}
      {:error, reason} -> {:halt, {:error, {:invalid_field, "term_contents", reason}}}
    end
  end

  defp parse_rel_content(path, bytes, acc) do
    case Parse.release(bytes) do
      {:ok, spec} -> {:cont, {:ok, put_in(acc, [:rels, path], spec)}}
      {:error, reason} -> {:halt, {:error, {:invalid_field, "term_contents", reason}}}
    end
  end

  defp agree_release(parsed, release_id, toolchain) do
    with {:ok, {_rel_path, release}} <- single_release(parsed.rels),
         :ok <- release_identity(release, release_id, toolchain),
         :ok <- unique_release_apps(release.apps),
         :ok <- require_selected(release.apps),
         {:ok, apps} <- pair_app_specs(release.apps, parsed.apps),
         :ok <- require_deps(apps) do
      {:ok, sort_applications(apps)}
    end
  end

  defp single_release(rels) when map_size(rels) == 1 do
    [pair] = Map.to_list(rels)
    {:ok, pair}
  end

  defp single_release(rels) when map_size(rels) == 0, do: {:error, :missing_release_term}
  defp single_release(_rels), do: {:error, :multiple_release_terms}

  defp release_identity(release, release_id, toolchain) do
    cond do
      release.name != release_id["name"] or release.version != release_id["version"] ->
        {:error, :release_mismatch}

      release.erts != toolchain["erts"] ->
        {:error, :erts_mismatch}

      true ->
        :ok
    end
  end

  defp unique_release_apps(apps) do
    names = Enum.map(apps, & &1.name)

    if length(Enum.uniq(names)) == length(names) do
      :ok
    else
      {:error, :duplicate_application}
    end
  end

  defp require_selected(apps) do
    present = MapSet.new(Enum.map(apps, & &1.name))
    selected = Encode.selected_first_party_names()

    if MapSet.subset?(selected, present) do
      :ok
    else
      {:error, :missing_selected_application}
    end
  end

  defp pair_app_specs(rel_apps, specs) do
    case no_undeclared(rel_apps, specs) do
      :ok -> pair_each(rel_apps, specs, [])
      error -> error
    end
  end

  defp no_undeclared(rel_apps, specs) do
    expected =
      MapSet.new(
        Enum.map(rel_apps, fn app ->
          "lib/" <> app.name <> "-" <> app.version <> "/ebin/" <> app.name <> ".app"
        end)
      )

    actual = MapSet.new(Map.keys(specs))

    cond do
      MapSet.subset?(actual, expected) and MapSet.subset?(expected, actual) ->
        :ok

      MapSet.size(MapSet.difference(actual, expected)) > 0 ->
        {:error, :undeclared_app_spec}

      true ->
        {:error, :missing_app_spec}
    end
  end

  defp pair_each([], _specs, acc), do: {:ok, Enum.reverse(acc)}

  defp pair_each([rel_app | rest], specs, acc) do
    path = "lib/" <> rel_app.name <> "-" <> rel_app.version <> "/ebin/" <> rel_app.name <> ".app"

    case Map.fetch(specs, path) do
      {:ok, spec} ->
        if spec.name == rel_app.name and spec.version == rel_app.version do
          pair_each(rest, specs, [{rel_app, spec, path} | acc])
        else
          {:error, :release_mismatch}
        end

      :error ->
        {:error, :missing_app_spec}
    end
  end

  defp require_deps(pairs) do
    present = MapSet.new(Enum.map(pairs, fn {rel_app, _spec, _path} -> rel_app.name end))

    Enum.reduce_while(pairs, :ok, fn {_rel, spec, _path}, :ok ->
      missing =
        Enum.any?(spec.required ++ spec.included, fn name ->
          not MapSet.member?(present, name)
        end)

      if missing, do: {:halt, {:error, :missing_dependency}}, else: {:cont, :ok}
    end)
  end

  defp sort_applications(pairs) do
    pairs
    |> Enum.map(&application_record/1)
    |> Enum.sort_by(& &1["name"])
  end

  defp application_record({rel_app, spec, path}) do
    %{
      "name" => rel_app.name,
      "version" => rel_app.version,
      "start_type" => rel_app.start_type,
      "class" => Derive.application_class(rel_app.name),
      "app_spec_path" => path,
      "app_spec_sha256" => "",
      "declared_applications" => %{
        "required" => Enum.sort(spec.required),
        "included" => Enum.sort(spec.included),
        "optional" => Enum.sort(spec.optional)
      }
    }
  end

  defp project_entries(inventory, parsed, applications) do
    files = inventory["regular_files"]
    identities = Enum.map(applications, &{&1["name"], &1["version"]})
    sha_by_path = Map.new(files, &{&1["path"], &1["sha256"]})

    applications = bind_app_digests(applications, sha_by_path)

    case project_file_entries(files, parsed, identities, []) do
      {:ok, entries} -> {:ok, {applications, Enum.sort_by(entries, & &1["path"])}}
      error -> error
    end
  end

  defp bind_app_digests(applications, sha_by_path) do
    Enum.map(applications, fn app ->
      %{app | "app_spec_sha256" => Map.fetch!(sha_by_path, app["app_spec_path"])}
    end)
  end

  defp project_file_entries([], _parsed, _identities, acc), do: {:ok, Enum.reverse(acc)}

  defp project_file_entries([file | rest], parsed, identities, acc) do
    case project_one_entry(file, parsed, identities) do
      {:ok, entry} -> project_file_entries(rest, parsed, identities, [entry | acc])
      error -> error
    end
  end

  defp project_one_entry(file, parsed, identities) do
    with {:ok, owner} <- owner_for(file["path"], identities),
         {:ok, prefix} <- decode_prefix(file["prefix_hex"]),
         {:ok, kind} <-
           Classify.kind(%{
             path: file["path"],
             size: file["size"],
             prefix: prefix,
             executable: file["executable"],
             term_role: term_role(file["path"], parsed),
             owner: owner,
             identities: identities
           }) do
      {:ok,
       %{
         "path" => file["path"],
         "owner_application" => owner,
         "mode" => file["mode"],
         "size" => file["size"],
         "sha256" => file["sha256"],
         "content_kind" => kind
       }}
    end
  end

  defp term_role(path, parsed) do
    cond do
      Map.has_key?(parsed.apps, path) -> :app
      Map.has_key?(parsed.rels, path) -> :rel
      true -> nil
    end
  end

  defp owner_for(path, identities) do
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

  defp adjacent_lib_identities(segments, identities) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(&match_lib_pair(&1, identities))
  end

  defp match_lib_pair(["lib", ident], identities) do
    Enum.filter(identities, fn {name, vsn} -> ident == name <> "-" <> vsn end)
  end

  defp match_lib_pair(_, _), do: []

  defp decode_prefix(""), do: {:ok, <<>>}

  defp decode_prefix(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :invalid_digest}
    end
  end

  defp assemble(profile, source, toolchain, release_id, first, second) do
    {apps, entries} = first_payload(first)

    {second_apps, second_entries} = projected_payload(second)

    with {:ok, inputs_digest} <- Encode.build_inputs_digest(source["build_inputs"]),
         {:ok, facts} <- Derive.release_facts(apps, entries),
         {:ok, first_digest} <- Encode.payload_tree_digest(entries),
         {:ok, second_digest} <- Encode.payload_tree_digest(second_entries) do
      findings = Derive.findings(apps, entries)
      repro = reproducibility(apps, entries, second_apps, second_entries, first_digest, second_digest)

      manifest = %{
        "schema" => Encode.schema(),
        "version" => Encode.version(),
        "profile" => profile,
        "source" => Map.put(source, "build_inputs_digest", inputs_digest),
        "toolchain" => toolchain,
        "release" => Map.merge(release_id, facts),
        "applications" => apps,
        "entries" => entries,
        "findings" => findings,
        "reproducibility" => repro
      }

      finish_project(manifest)
    end
  end

  defp first_payload(%{applications: apps, entries: entries}), do: {apps, entries}
  defp projected_payload(projected), do: first_payload(projected)

  defp reproducibility(apps1, entries1, apps2, entries2, digest1, digest2) do
    same_apps = apps1 == apps2
    same_entries = entries1 == entries2
    same_digests = digest1 == digest2
    identical? = same_apps and same_entries and same_digests

    %{
      "status" => if(identical?, do: "identical", else: "different"),
      "payload_tree_digests" => [digest1, digest2],
      "differing_paths" => differing_paths(entries1, entries2),
      "rule" => "remove_exact_releases_cookie_before_scan"
    }
  end

  defp differing_paths(first, second) do
    by_path = fn entries -> Map.new(entries, &{&1["path"], &1}) end
    left = by_path.(first)
    right = by_path.(second)
    keys = MapSet.union(MapSet.new(Map.keys(left)), MapSet.new(Map.keys(right)))

    keys
    |> Enum.filter(fn path -> Map.get(left, path) != Map.get(right, path) end)
    |> Enum.sort()
  end

  defp finish_project(manifest) do
    case Encode.validate_manifest(manifest) do
      :ok -> {:ok, manifest}
      error -> error
    end
  end

end
