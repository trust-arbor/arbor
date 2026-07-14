defmodule Arbor.Shell.LinuxDependencyBaselineCore do
  @moduledoc """
  Pure Linux dependency-baseline manifest and inventory validation.

  This CRC core admits a closed v1 baseline document (manifest + inventory
  entries), canonicalizes the tree, binds the length-framed SHA-256 tree digest,
  and returns a normalized state/receipt suitable for a later imperative
  materializer.

  All functions are pure: plain data in/out. No File, System, Application,
  GenServer, ETS, process messaging, time, randomness, logging, or IO.
  Deterministic `:crypto.hash/2` is the only crypto primitive used.

  A returned receipt is **evidence**, never executable authority. The production
  spawn backend and materializer remain separate imperative shells that must
  re-verify and apply authority gates independently.
  """

  # --- Fixed v1 constants ---

  @schema "1"
  @platform "linux/arm64"
  @domain_tag "arbor-linux-dependency-baseline-v1\0"

  @max_map_keys 64
  @max_entries 50_000
  @max_total_bytes 512 * 1024 * 1024
  @max_path_bytes 4_096
  @max_component_bytes 255
  @max_path_depth 48
  @max_digest_hex 64
  @max_toolchain_version_bytes 64
  @max_status_bytes 64

  @digest_re ~r/\Asha256:([0-9a-f]{64})\z/
  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @toolchain_version_re ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,62}\z/

  # --- Closed request / manifest / entry surfaces ---

  @logical_request_keys [:manifest, :entries]
  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @logical_manifest_keys [
    :schema,
    :platform,
    :image_index_digest,
    :image_manifest_digest,
    :mix_lock_digest,
    :baseline_tree_digest,
    :toolchain,
    :entry_count,
    :total_bytes
  ]
  @allowed_manifest_keys MapSet.new(
                           @logical_manifest_keys ++
                             Enum.map(@logical_manifest_keys, &Atom.to_string/1)
                         )

  @logical_toolchain_keys [:erlang, :elixir]
  @allowed_toolchain_keys MapSet.new(
                            @logical_toolchain_keys ++
                              Enum.map(@logical_toolchain_keys, &Atom.to_string/1)
                          )

  @logical_directory_keys [:path, :type]
  @allowed_directory_keys MapSet.new(
                            @logical_directory_keys ++
                              Enum.map(@logical_directory_keys, &Atom.to_string/1)
                          )

  @logical_regular_keys [:path, :type, :size, :sha256, :executable]
  @allowed_regular_keys MapSet.new(
                          @logical_regular_keys ++
                            Enum.map(@logical_regular_keys, &Atom.to_string/1)
                        )

  # Symlink / special types are explicitly rejected in v1 (not normalized).
  @unsupported_entry_types MapSet.new([
                             "symlink",
                             "softlink",
                             "hardlink",
                             "block",
                             "character",
                             "fifo",
                             "socket",
                             "unknown",
                             "other"
                           ])

  @type directory_entry :: %{path: String.t(), type: String.t()}
  @type regular_entry :: %{
          path: String.t(),
          type: String.t(),
          size: non_neg_integer(),
          sha256: String.t(),
          executable: boolean()
        }
  @type entry :: directory_entry() | regular_entry()

  @type toolchain :: %{erlang: String.t(), elixir: String.t()}

  @type state :: %{
          schema: String.t(),
          platform: String.t(),
          image_index_digest: String.t(),
          image_manifest_digest: String.t(),
          mix_lock_digest: String.t(),
          baseline_tree_digest: String.t(),
          toolchain: toolchain(),
          entry_count: non_neg_integer(),
          total_bytes: non_neg_integer(),
          entries: [entry()]
        }

  @type dependency_baseline_evidence :: %{
          image_index_digest: String.t(),
          image_manifest_digest: String.t(),
          mix_lock_digest: String.t(),
          baseline_tree_digest: String.t(),
          platform: String.t(),
          provisioning: %{status: String.t(), mode: String.t()}
        }

  @doc """
  Construct and validate a Linux dependency baseline from a closed document.

  Input must be a map with exactly `manifest` and `entries` (atom or string
  aliases, never both). Returns `{:ok, state}` with sorted normalized entries
  and a digest-bound receipt, or a stable fail-closed error.
  """
  @spec new(term()) :: {:ok, state()} | {:error, term()}
  def new(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(input, @allowed_request_keys, @logical_request_keys, :request),
         {:ok, manifest} <-
           fetch_required_map(input, :manifest, :missing_manifest, :invalid_manifest),
         {:ok, entries} <- fetch_entries_list(input),
         :ok <-
           validate_closed_keys(
             manifest,
             @allowed_manifest_keys,
             @logical_manifest_keys,
             :manifest
           ),
         {:ok, normalized_manifest} <- normalize_manifest(manifest),
         {:ok, normalized_entries, total_bytes} <- normalize_inventory(entries),
         :ok <-
           validate_inventory_counts(
             normalized_manifest,
             length(normalized_entries),
             total_bytes
           ),
         sorted_entries = Enum.sort_by(normalized_entries, & &1.path, &path_lte?/2),
         :ok <- validate_tree_structure(sorted_entries),
         computed_digest = compute_baseline_tree_digest(sorted_entries),
         :ok <- match_tree_digest(normalized_manifest.baseline_tree_digest, computed_digest) do
      state = %{
        schema: normalized_manifest.schema,
        platform: normalized_manifest.platform,
        image_index_digest: normalized_manifest.image_index_digest,
        image_manifest_digest: normalized_manifest.image_manifest_digest,
        mix_lock_digest: normalized_manifest.mix_lock_digest,
        baseline_tree_digest: computed_digest,
        toolchain: normalized_manifest.toolchain,
        entry_count: length(sorted_entries),
        total_bytes: total_bytes,
        entries: sorted_entries
      }

      {:ok, state}
    end
  end

  def new(_), do: {:error, :invalid_request}

  @doc """
  Convert validated state to a compact JSON-clean attestation (no inventory).

  A receipt is evidence only — never executable authority.
  """
  @spec show(state()) :: map()
  def show(%{
        schema: schema,
        platform: platform,
        image_index_digest: image_index_digest,
        image_manifest_digest: image_manifest_digest,
        mix_lock_digest: mix_lock_digest,
        baseline_tree_digest: baseline_tree_digest,
        toolchain: %{erlang: erlang, elixir: elixir},
        entry_count: entry_count,
        total_bytes: total_bytes
      })
      when is_binary(schema) and is_binary(platform) and is_integer(entry_count) and
             is_integer(total_bytes) do
    %{
      "schema" => schema,
      "platform" => platform,
      "image_index_digest" => image_index_digest,
      "image_manifest_digest" => image_manifest_digest,
      "mix_lock_digest" => mix_lock_digest,
      "baseline_tree_digest" => baseline_tree_digest,
      "toolchain" => %{
        "erlang" => erlang,
        "elixir" => elixir
      },
      "entry_count" => entry_count,
      "total_bytes" => total_bytes
    }
  end

  @doc """
  Project the dependency_baseline evidence shape used by
  `Arbor.Shell.AppleContainerAdmissionCore`.

  Returns a closed map with provisioning `%{status: "ready", mode: "offline"}`.
  Evidence only — not executable authority.
  """
  @spec to_dependency_baseline_evidence(state()) :: dependency_baseline_evidence()
  def to_dependency_baseline_evidence(%{
        image_index_digest: image_index_digest,
        image_manifest_digest: image_manifest_digest,
        mix_lock_digest: mix_lock_digest,
        baseline_tree_digest: baseline_tree_digest,
        platform: platform
      }) do
    %{
      image_index_digest: image_index_digest,
      image_manifest_digest: image_manifest_digest,
      mix_lock_digest: mix_lock_digest,
      baseline_tree_digest: baseline_tree_digest,
      platform: platform,
      provisioning: %{status: "ready", mode: "offline"}
    }
  end

  @doc """
  Return the normalized, bytewise-sorted inventory for a later materializer shell.

  Explicitly named so callers do not treat `show/1` receipts as materialization
  plans. Evidence only — not executable authority.
  """
  @spec materialization_entries(state()) :: [entry()]
  def materialization_entries(%{entries: entries}) when is_list(entries), do: entries

  @doc """
  Alias for `materialization_entries/1` — sorted normalized inventory plan.
  """
  @spec sorted_entries(state()) :: [entry()]
  def sorted_entries(state), do: materialization_entries(state)

  # --- Manifest ---

  defp normalize_manifest(manifest) do
    with {:ok, schema} <- fetch_schema(manifest),
         {:ok, platform} <- fetch_platform(manifest),
         {:ok, image_index_digest} <-
           fetch_digest_field(
             manifest,
             :image_index_digest,
             :missing_image_index_digest,
             :invalid_image_index_digest
           ),
         {:ok, image_manifest_digest} <-
           fetch_digest_field(
             manifest,
             :image_manifest_digest,
             :missing_image_manifest_digest,
             :invalid_image_manifest_digest
           ),
         {:ok, mix_lock_digest} <-
           fetch_hex64_field(manifest, :mix_lock_digest, :missing_mix_lock_digest),
         {:ok, baseline_tree_digest} <-
           fetch_hex64_field(
             manifest,
             :baseline_tree_digest,
             :missing_baseline_tree_digest
           ),
         {:ok, toolchain} <- fetch_toolchain(manifest),
         {:ok, entry_count} <- fetch_nonneg_integer(manifest, :entry_count, :missing_entry_count),
         {:ok, total_bytes} <- fetch_nonneg_integer(manifest, :total_bytes, :missing_total_bytes) do
      {:ok,
       %{
         schema: schema,
         platform: platform,
         image_index_digest: image_index_digest,
         image_manifest_digest: image_manifest_digest,
         mix_lock_digest: mix_lock_digest,
         baseline_tree_digest: baseline_tree_digest,
         toolchain: toolchain,
         entry_count: entry_count,
         total_bytes: total_bytes
       }}
    end
  end

  defp fetch_schema(manifest) do
    case get_field(manifest, :schema) do
      nil ->
        {:error, :missing_schema}

      @schema ->
        {:ok, @schema}

      value when is_binary(value) ->
        with :ok <- bounded_string(value, @max_status_bytes, :schema_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_or_whitespace(value, :unsafe_schema) do
          {:error, :unsupported_schema}
        end

      _other ->
        {:error, :invalid_schema}
    end
  end

  defp fetch_platform(manifest) do
    case get_field(manifest, :platform) do
      nil ->
        {:error, :missing_platform}

      @platform ->
        {:ok, @platform}

      value when is_binary(value) ->
        with :ok <- bounded_string(value, @max_status_bytes, :platform_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_or_whitespace(value, :unsafe_platform) do
          {:error, :unsupported_platform}
        end

      _other ->
        {:error, :invalid_platform}
    end
  end

  defp fetch_toolchain(manifest) do
    with {:ok, toolchain} <-
           fetch_required_map(manifest, :toolchain, :missing_toolchain, :invalid_toolchain),
         :ok <-
           validate_closed_keys(
             toolchain,
             @allowed_toolchain_keys,
             @logical_toolchain_keys,
             :toolchain
           ),
         {:ok, erlang} <-
           require_bounded_binary_field(
             toolchain,
             :erlang,
             @max_toolchain_version_bytes,
             :missing_toolchain_erlang,
             :invalid_toolchain_erlang,
             :toolchain_erlang_too_long
           ),
         {:ok, elixir} <-
           require_bounded_binary_field(
             toolchain,
             :elixir,
             @max_toolchain_version_bytes,
             :missing_toolchain_elixir,
             :invalid_toolchain_elixir,
             :toolchain_elixir_too_long
           ),
         :ok <- require_valid_utf8(erlang),
         :ok <- require_valid_utf8(elixir),
         :ok <- reject_control_or_whitespace(erlang, :unsafe_toolchain_erlang),
         :ok <- reject_control_or_whitespace(elixir, :unsafe_toolchain_elixir),
         :ok <- validate_toolchain_version(erlang, :invalid_toolchain_erlang),
         :ok <- validate_toolchain_version(elixir, :invalid_toolchain_elixir) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  defp validate_toolchain_version(value, invalid) do
    if Regex.match?(@toolchain_version_re, value), do: :ok, else: {:error, invalid}
  end

  # --- Inventory ---

  defp fetch_entries_list(input) do
    case get_field(input, :entries) do
      nil ->
        {:error, :missing_entries}

      entries when is_list(entries) ->
        {:ok, entries}

      _other ->
        {:error, :invalid_entries}
    end
  end

  defp normalize_inventory(entries) when is_list(entries) do
    case take_bounded(entries, @max_entries) do
      :too_many ->
        {:error, :too_many_entries}

      {:ok, []} ->
        {:error, :empty_inventory}

      {:ok, bounded} ->
        normalize_entries(bounded, [], 0)
    end
  end

  defp normalize_entries([], acc, total_bytes) do
    {:ok, Enum.reverse(acc), total_bytes}
  end

  defp normalize_entries([entry | rest], acc, total_bytes) do
    case normalize_entry(entry) do
      {:ok, %{type: "directory"} = normalized} ->
        normalize_entries(rest, [normalized | acc], total_bytes)

      {:ok, %{type: "regular", size: size} = normalized} ->
        new_total = total_bytes + size

        if new_total > @max_total_bytes do
          {:error, :total_bytes_exceeded}
        else
          normalize_entries(rest, [normalized | acc], new_total)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    if map_size(entry) > @max_map_keys do
      {:error, :map_too_large}
    else
      case get_field(entry, :type) do
        nil ->
          {:error, :missing_entry_type}

        "directory" ->
          normalize_directory_entry(entry)

        "regular" ->
          normalize_regular_entry(entry)

        type when is_binary(type) ->
          with :ok <- bounded_string(type, @max_status_bytes, :entry_type_too_long),
               :ok <- require_valid_utf8(type),
               :ok <- reject_control_or_whitespace(type, :unsafe_entry_type) do
            if MapSet.member?(@unsupported_entry_types, type) or type == "symlink" do
              {:error, {:unsupported_entry_type, type}}
            else
              {:error, {:unsupported_entry_type, type}}
            end
          end

        _other ->
          {:error, :invalid_entry_type}
      end
    end
  end

  defp normalize_entry(_), do: {:error, :invalid_entry}

  defp normalize_directory_entry(entry) do
    with :ok <-
           validate_closed_keys(
             entry,
             @allowed_directory_keys,
             @logical_directory_keys,
             :directory_entry
           ),
         {:ok, path} <- fetch_path(entry) do
      {:ok, %{path: path, type: "directory"}}
    end
  end

  defp normalize_regular_entry(entry) do
    with :ok <-
           validate_closed_keys(
             entry,
             @allowed_regular_keys,
             @logical_regular_keys,
             :regular_entry
           ),
         {:ok, path} <- fetch_path(entry),
         {:ok, size} <- fetch_entry_size(entry),
         {:ok, sha256} <- fetch_hex64_field(entry, :sha256, :missing_entry_sha256),
         {:ok, executable} <- fetch_executable(entry) do
      {:ok,
       %{
         path: path,
         type: "regular",
         size: size,
         sha256: sha256,
         executable: executable
       }}
    end
  end

  defp fetch_entry_size(entry) do
    case get_field(entry, :size) do
      size when is_integer(size) and size >= 0 and size <= @max_total_bytes ->
        {:ok, size}

      size when is_integer(size) and size < 0 ->
        {:error, :negative_entry_size}

      size when is_integer(size) ->
        {:error, :entry_size_out_of_bounds}

      nil ->
        {:error, :missing_entry_size}

      _other ->
        {:error, :invalid_entry_size}
    end
  end

  defp fetch_executable(entry) do
    case get_field(entry, :executable) do
      true -> {:ok, true}
      false -> {:ok, false}
      nil -> {:error, :missing_entry_executable}
      _other -> {:error, :invalid_entry_executable}
    end
  end

  # --- Paths ---

  defp fetch_path(entry) do
    case get_field(entry, :path) do
      nil ->
        {:error, :missing_entry_path}

      path when is_binary(path) ->
        validate_path(path)

      _other ->
        {:error, :invalid_entry_path}
    end
  end

  defp validate_path(path) when is_binary(path) do
    with :ok <- require_valid_utf8(path),
         :ok <- bounded_string(path, @max_path_bytes, :path_too_long) do
      cond do
        path == "" ->
          {:error, :empty_path}

        String.starts_with?(path, "/") ->
          {:error, :absolute_path}

        String.ends_with?(path, "/") ->
          {:error, :trailing_slash}

        has_control_char?(path) or binary_contains?(path, <<0>>) ->
          {:error, :unsafe_path}

        true ->
          validate_path_segments(path)
      end
    end
  end

  defp validate_path_segments(path) do
    segments = String.split(path, "/", trim: false)

    cond do
      Enum.any?(segments, &(&1 == "")) ->
        {:error, :empty_path_segment}

      length(segments) > @max_path_depth ->
        {:error, :path_depth_exceeded}

      true ->
        Enum.reduce_while(segments, :ok, fn segment, :ok ->
          cond do
            segment == "." ->
              {:halt, {:error, :dot_path_segment}}

            segment == ".." ->
              {:halt, {:error, :dotdot_path_segment}}

            byte_size(segment) > @max_component_bytes ->
              {:halt, {:error, :path_component_too_long}}

            has_control_char?(segment) or binary_contains?(segment, <<0>>) ->
              {:halt, {:error, :unsafe_path}}

            true ->
              {:cont, :ok}
          end
        end)
        |> case do
          :ok -> {:ok, path}
          error -> error
        end
    end
  end

  # --- Tree structure ---

  defp validate_tree_structure(sorted_entries) do
    validate_tree_structure(sorted_entries, MapSet.new(), MapSet.new())
  end

  defp validate_tree_structure([], _directories, _all_paths), do: :ok

  defp validate_tree_structure([entry | rest], directories, all_paths) do
    path = entry.path

    cond do
      MapSet.member?(all_paths, path) ->
        {:error, :duplicate_path}

      true ->
        with :ok <- require_parents(path, directories, all_paths) do
          new_all = MapSet.put(all_paths, path)

          new_dirs =
            if entry.type == "directory" do
              MapSet.put(directories, path)
            else
              directories
            end

          # A regular file must not be an ancestor of any later path.
          if entry.type == "regular" and Enum.any?(rest, &path_is_descendant?(&1.path, path)) do
            {:error, :file_descendant_conflict}
          else
            validate_tree_structure(rest, new_dirs, new_all)
          end
        end
    end
  end

  defp require_parents(path, directories, all_paths) do
    case parent_path(path) do
      nil ->
        :ok

      parent ->
        cond do
          MapSet.member?(directories, parent) ->
            :ok

          MapSet.member?(all_paths, parent) ->
            {:error, :parent_not_directory}

          true ->
            {:error, :missing_parent_directory}
        end
    end
  end

  defp parent_path(path) do
    case :binary.split(path, "/", [:global]) do
      [_] ->
        nil

      parts ->
        parts
        |> Enum.drop(-1)
        |> Enum.join("/")
        |> case do
          "" -> nil
          parent -> parent
        end
    end
  end

  defp path_is_descendant?(candidate, prefix) do
    String.starts_with?(candidate, prefix <> "/")
  end

  defp path_lte?(a, b) when is_binary(a) and is_binary(b), do: a <= b

  # --- Digests ---

  defp compute_baseline_tree_digest(sorted_entries) do
    binary =
      Enum.reduce(sorted_entries, @domain_tag, fn entry, acc ->
        acc <> frame_entry(entry)
      end)

    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp frame_entry(%{type: "directory", path: path}) do
    <<0, byte_size(path)::unsigned-32, path::binary>>
  end

  defp frame_entry(%{
         type: "regular",
         path: path,
         size: size,
         sha256: sha256_hex,
         executable: executable
       }) do
    flag = if executable, do: 1, else: 0
    # Hex already validated as lowercase 64-char; decode cannot fail for that set.
    {:ok, raw} = Base.decode16(sha256_hex, case: :lower)

    <<1, byte_size(path)::unsigned-32, path::binary, flag::unsigned-8, size::unsigned-64,
      raw::binary-size(32)>>
  end

  defp match_tree_digest(expected, computed) when expected == computed, do: :ok
  defp match_tree_digest(_expected, _computed), do: {:error, :baseline_tree_digest_mismatch}

  defp validate_inventory_counts(manifest, actual_count, actual_bytes) do
    cond do
      manifest.entry_count != actual_count ->
        {:error, :entry_count_mismatch}

      manifest.total_bytes != actual_bytes ->
        {:error, :total_bytes_mismatch}

      true ->
        :ok
    end
  end

  # --- Field helpers (mirrored closed-map discipline from admission core) ---

  defp validate_closed_keys(map, allowed, logical, scope) when is_map(map) do
    if map_size(map) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(map)

      with :ok <- reject_unknown_keys(keys, allowed, scope),
           :ok <- reject_duplicate_key_aliases(keys, logical, scope) do
        :ok
      end
    end
  end

  defp reject_unknown_keys(keys, allowed, scope) do
    if Enum.all?(keys, &MapSet.member?(allowed, &1)) do
      :ok
    else
      {:error, {:unsupported_keys, scope}}
    end
  end

  defp reject_duplicate_key_aliases(keys, logical, scope) do
    key_set = MapSet.new(keys)

    Enum.reduce_while(logical, :ok, fn atom_key, :ok ->
      has_atom? = MapSet.member?(key_set, atom_key)
      has_string? = MapSet.member?(key_set, Atom.to_string(atom_key))

      if has_atom? and has_string? do
        {:halt, {:error, {:duplicate_key_alias, scope, atom_key}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp fetch_required_map(map, key, missing, invalid) do
    case get_field(map, key) do
      nil -> {:error, missing}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, invalid}
    end
  end

  defp require_bounded_binary_field(map, key, max, missing, invalid, too_long) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_binary(value) ->
        if byte_size(value) > max, do: {:error, too_long}, else: {:ok, value}

      _other ->
        {:error, invalid}
    end
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_digest_field(map, key, missing, invalid) do
    case get_field(map, key) do
      nil -> {:error, missing}
      value -> validate_digest(value, invalid)
    end
  end

  defp fetch_hex64_field(map, key, missing) do
    case get_field(map, key) do
      nil -> {:error, missing}
      value -> validate_hex64(value, {:invalid, key})
    end
  end

  defp fetch_nonneg_integer(map, key, missing) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      value when is_integer(value) ->
        {:error, {:negative, key}}

      _other ->
        {:error, {:invalid, key}}
    end
  end

  defp validate_digest(digest, invalid) when is_binary(digest) do
    with :ok <- bounded_string(digest, 7 + @max_digest_hex, invalid),
         :ok <- require_valid_utf8(digest) do
      cond do
        has_control_or_whitespace?(digest) ->
          {:error, invalid}

        Regex.match?(@digest_re, digest) ->
          {:ok, digest}

        true ->
          {:error, invalid}
      end
    end
  end

  defp validate_digest(_, invalid), do: {:error, invalid}

  defp validate_hex64(value, invalid) when is_binary(value) do
    with :ok <- bounded_string(value, @max_digest_hex, invalid),
         :ok <- require_valid_utf8(value) do
      cond do
        has_control_or_whitespace?(value) ->
          {:error, invalid}

        Regex.match?(@hex64_re, value) ->
          {:ok, value}

        true ->
          {:error, invalid}
      end
    end
  end

  defp validate_hex64(_, invalid), do: {:error, invalid}

  defp take_bounded(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    take_bounded(list, max + 1, 0, [])
  end

  defp take_bounded(_list, limit, count, _acc) when count >= limit, do: :too_many
  defp take_bounded([], _limit, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_bounded([head | rest], limit, count, acc) do
    take_bounded(rest, limit, count + 1, [head | acc])
  end

  defp require_valid_utf8(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end

  defp bounded_string(value, max, too_long) when is_binary(value) do
    if byte_size(value) <= max, do: :ok, else: {:error, too_long}
  end

  defp reject_control_or_whitespace(value, reason) when is_binary(value) do
    if has_control_or_whitespace?(value), do: {:error, reason}, else: :ok
  end

  defp has_control_or_whitespace?(value) when is_binary(value) do
    has_control_char?(value) or has_whitespace?(value) or binary_contains?(value, <<0>>)
  end

  defp has_whitespace?(value) when is_binary(value) do
    :binary.match(value, [" ", "\t", "\n", "\r", "\f", "\v"]) != :nomatch or
      String.match?(value, ~r/[[:space:]]/)
  end

  defp has_control_char?(value) when is_binary(value) do
    has_control_char_bytes?(value)
  end

  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)

  defp binary_contains?(haystack, needle)
       when is_binary(haystack) and is_binary(needle) and needle != "" do
    :binary.match(haystack, needle) != :nomatch
  end
end
