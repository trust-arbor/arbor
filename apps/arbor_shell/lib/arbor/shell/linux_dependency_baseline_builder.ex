defmodule Arbor.Shell.LinuxDependencyBaselineBuilder do
  @moduledoc """
  Bounded operator-facing builder for Linux dependency-baseline documents.

  The builder only reads an explicitly supplied source root. It does not install
  files, alter runtime configuration, invoke processes, or infer image
  authority. Symlinks, special files, hardlinks, device crossings, and unstable
  entries are rejected before the resulting document is admitted by
  `LinuxDependencyBaselineCore`.

  The closed guest platforms `linux/arm64` and `linux/amd64` require regular
  files whose names identify shared objects (`.so` or versioned `.so.N` forms)
  to be ELF64 little-endian with `e_machine` 183 (AArch64) or 62 (x86-64).
  There is no host-arch bypass and no qemu translation.
  """

  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.RegularTreeInventory

  @schema "1"
  @allowed_platforms MapSet.new(["linux/amd64", "linux/arm64"])
  @elf_machine_aarch64 183
  @elf_machine_x86_64 62
  @metadata_keys [
    :platform,
    :image_index_digest,
    :image_manifest_digest,
    :mix_lock_digest,
    :toolchain
  ]
  @toolchain_keys [:erlang, :elixir]
  @listing_errors [:scan_timeout, :listing_failed, :listing_memory_exceeded]

  @spec build(term(), term()) ::
          {:ok, %{manifest: map(), entries: [map()]}, map()} | {:error, term()}
  def build(source_root, metadata), do: build(source_root, metadata, [])

  @spec build(term(), term(), keyword()) ::
          {:ok, %{manifest: map(), entries: [map()]}, map()} | {:error, term()}
  def build(source_root, metadata, []) do
    with {:ok, normalized_metadata} <- normalize_metadata(metadata),
         {:ok, facts} <- scan_source(source_root),
         :ok <-
           validate_linux_native_artifacts(
             facts.regular_files,
             normalized_metadata.platform
           ) do
      finish_document(normalized_metadata, facts)
    end
  end

  def build(_source_root, _metadata, _opts), do: {:error, :invalid_options}

  @doc """
  Inventory a source tree and return only the canonical baseline tree digest.

  Applies the same native-artifact architecture check as `build/2` but does
  not require image or mix.lock metadata.
  """
  @spec tree_digest(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def tree_digest(source_root, platform) when is_binary(platform) do
    with :ok <- require_platform(platform),
         {:ok, facts} <- scan_source(source_root),
         :ok <- validate_linux_native_artifacts(facts.regular_files, platform),
         {:ok, digest} <- Core.tree_digest(project_linux_entries(facts)) do
      {:ok, digest}
    end
  end

  def tree_digest(_source_root, _platform), do: {:error, :unsupported_platform}

  defp finish_document(metadata, facts) do
    entries = project_linux_entries(facts)

    with {:ok, baseline_tree_digest} <- Core.tree_digest(entries),
         {:ok, state} <- Core.new(build_document(metadata, baseline_tree_digest, entries)) do
      {:ok, document_from_state(state), Core.show(state)}
    end
  end

  # Collapse walker control errors to the pre-refactor public atom so Linux
  # callers still see :source_list_failed, not :scan_timeout / listing failures.
  defp scan_source(source_root) do
    case RegularTreeInventory.scan_resolved(source_root) do
      {:ok, facts} ->
        {:ok, facts}

      {:error, reason} when reason in @listing_errors ->
        {:error, :source_list_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_linux_native_artifacts([], _platform), do: :ok

  defp validate_linux_native_artifacts([%{path: path, prefix: prefix} | rest], platform) do
    case validate_native_artifact(prefix, path, platform) do
      :ok -> validate_linux_native_artifacts(rest, platform)
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_linux_entries(%{directories: directories, regular_files: regular_files}) do
    Enum.map(directories, &linux_directory/1) ++ Enum.map(regular_files, &linux_regular/1)
  end

  defp linux_directory(%{path: path}), do: %{path: path, type: "directory"}

  defp linux_regular(%{path: path, size: size, sha256: sha256, executable: executable}) do
    %{path: path, type: "regular", size: size, sha256: sha256, executable: executable}
  end

  defp validate_native_artifact(prefix, path, platform) do
    if native_artifact_path?(path) do
      match_linux_elf(prefix, platform)
    else
      :ok
    end
  end

  defp match_linux_elf(prefix, "linux/arm64"), do: match_elf64_le(prefix, @elf_machine_aarch64)
  defp match_linux_elf(prefix, "linux/amd64"), do: match_elf64_le(prefix, @elf_machine_x86_64)
  defp match_linux_elf(_prefix, _platform), do: {:error, :unsupported_platform}

  defp match_elf64_le(
         <<0x7F, "ELF", 2, 1, _version, _osabi, _abiversion, _padding::binary-size(7),
           _type::little-unsigned-16, machine::little-unsigned-16, _rest::binary>>,
         expected
       )
       when machine == expected do
    :ok
  end

  defp match_elf64_le(_prefix, _expected), do: {:error, :native_artifact_wrong_architecture}

  defp native_artifact_path?(path) do
    filename = Path.basename(path)
    String.ends_with?(filename, ".so") or String.contains?(filename, ".so.")
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    with :ok <- validate_closed_keys(metadata, @metadata_keys, :metadata),
         {:ok, platform} <- fetch_required(metadata, :platform, :missing_platform),
         :ok <- require_platform(platform),
         {:ok, image_index_digest} <-
           fetch_required(metadata, :image_index_digest, :missing_image_index_digest),
         {:ok, image_manifest_digest} <-
           fetch_required(metadata, :image_manifest_digest, :missing_image_manifest_digest),
         {:ok, mix_lock_digest} <-
           fetch_required(metadata, :mix_lock_digest, :missing_mix_lock_digest),
         {:ok, toolchain} <- fetch_required(metadata, :toolchain, :missing_toolchain),
         {:ok, toolchain} <- normalize_toolchain(toolchain) do
      {:ok,
       %{
         schema: @schema,
         platform: platform,
         image_index_digest: image_index_digest,
         image_manifest_digest: image_manifest_digest,
         mix_lock_digest: mix_lock_digest,
         toolchain: toolchain
       }}
    end
  end

  defp normalize_metadata(_metadata), do: {:error, :invalid_metadata}

  defp require_platform(platform) when is_binary(platform) do
    if MapSet.member?(@allowed_platforms, platform) do
      :ok
    else
      {:error, :unsupported_platform}
    end
  end

  defp require_platform(_platform), do: {:error, :unsupported_platform}

  defp normalize_toolchain(toolchain) when is_map(toolchain) do
    with :ok <- validate_closed_keys(toolchain, @toolchain_keys, :toolchain),
         {:ok, erlang} <- fetch_required(toolchain, :erlang, :missing_toolchain_erlang),
         {:ok, elixir} <- fetch_required(toolchain, :elixir, :missing_toolchain_elixir) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  defp normalize_toolchain(_toolchain), do: {:error, :invalid_toolchain}

  defp validate_closed_keys(map, keys, scope) do
    allowed = MapSet.new(keys ++ Enum.map(keys, &Atom.to_string/1))

    cond do
      map_size(map) > length(keys) ->
        {:error, {:unsupported_keys, scope}}

      Enum.any?(map, fn {key, _value} -> not MapSet.member?(allowed, key) end) ->
        {:error, {:unsupported_keys, scope}}

      Enum.any?(keys, &(Map.has_key?(map, &1) and Map.has_key?(map, Atom.to_string(&1)))) ->
        {:error, {:duplicate_key_alias, scope}}

      true ->
        :ok
    end
  end

  defp fetch_required(map, key, missing) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, _value}, {:ok, _other}} -> {:error, {:duplicate_key_alias, key}}
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> {:error, missing}
    end
  end

  defp build_document(metadata, digest, entries) do
    total_bytes =
      Enum.reduce(entries, 0, fn
        %{type: "regular", size: size}, total -> total + size
        %{type: "directory"}, total -> total
      end)

    %{
      manifest:
        Map.merge(metadata, %{
          baseline_tree_digest: digest,
          entry_count: length(entries),
          total_bytes: total_bytes
        }),
      entries: entries
    }
  end

  defp document_from_state(state) do
    %{
      manifest: %{
        schema: state.schema,
        platform: state.platform,
        image_index_digest: state.image_index_digest,
        image_manifest_digest: state.image_manifest_digest,
        mix_lock_digest: state.mix_lock_digest,
        baseline_tree_digest: state.baseline_tree_digest,
        toolchain: state.toolchain,
        entry_count: state.entry_count,
        total_bytes: state.total_bytes
      },
      entries: state.entries
    }
  end
end
