defmodule Arbor.Commands.Baseline do
  @moduledoc """
  Unprivileged Linux validation-runtime baseline provision.

  Build may fetch locked Hex/Rebar. Activate never fetches, compiles, or
  talks to a registry. Status goes through the `Arbor.Shell` facade.
  """

  alias Arbor.Commands.Baseline.{ActivateCore, BuildCore, StatusCore}
  alias Arbor.Shell

  @mix_lock_max_bytes 1_048_576
  @file_mode 0o400
  @exec_file_mode 0o500
  @dir_mode 0o700
  @provisioning_image_prefix "docker.io/arbor/validation@"

  @type runtime_opt ::
          {:arbor_home, String.t()}
          | {:repo_root, String.t()}
          | {:deps_path, String.t()}
          | {:platform, String.t()}
          | {:architecture, String.t()}
          | {:active_config_path, String.t()}
          | {:config_path, String.t()}
          | {:image_build, (map() -> {:ok, map()} | {:error, term()})}
          | {:deps_fetch, (map() -> :ok | {:error, term()})}
          | {:smoke_test, (String.t(), String.t() -> :ok | {:error, term()})}
          | {:network, (term() -> term())}
          | {:shell, module()}
          | {:probe, boolean()}

  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with {:ok, ctx} <- build_context(opts),
         {:ok, toolchain} <- read_toolchain(ctx.repo_root),
         {:ok, platform} <- resolve_platform(ctx),
         :ok <- BuildCore.require_platform(platform),
         {:ok, mix_lock_digest} <- hash_mix_lock(ctx.repo_root),
         :ok <- fetch_deps(ctx),
         :ok <- smoke_test_copy(ctx, platform),
         {:ok, tree_digest} <-
           ctx.shell.linux_dependency_baseline_tree_digest(ctx.deps_path, platform),
         {:ok, layout} <- BuildCore.layout(ctx.arbor_home, tree_digest),
         :ok <- BuildCore.refuse_active_config_mutation(layout, ctx.active_config_path),
         labels =
           BuildCore.image_labels(toolchain, platform, mix_lock_digest, tree_digest),
         {:ok, image} <-
           build_image(ctx, platform, toolchain, mix_lock_digest, tree_digest, labels),
         metadata = %{
           platform: platform,
           image_index_digest: image.index_digest,
           image_manifest_digest: image.manifest_digest,
           mix_lock_digest: mix_lock_digest,
           toolchain: toolchain
         },
         {:ok, document, _receipt} <-
           ctx.shell.build_linux_dependency_baseline(ctx.deps_path, metadata),
         {:ok, image_policy} <-
           BuildCore.image_policy(%{
             image: image.image,
             image_id: Map.get(image, :image_id),
             manifest_digest: image.manifest_digest,
             mix_lock_digest: mix_lock_digest,
             baseline_tree_digest: tree_digest,
             erlang: toolchain.erlang,
             elixir: toolchain.elixir,
             platform: platform,
             env: [],
             labels: labels
           }),
         :ok <- persist(layout, document, ctx.deps_path, image_policy) do
      {:ok,
       %{
         "tree_digest" => tree_digest,
         "mix_lock_digest" => mix_lock_digest,
         "platform" => platform,
         "baseline_root" => layout.baseline_root,
         "active_config_path" => ctx.active_config_path
       }}
    end
  end

  def build(_opts), do: {:error, :invalid_options}

  @spec activate(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate(digest, opts \\ [])

  def activate(digest, opts) when is_list(opts) do
    _ = Keyword.get(opts, :network)

    with {:ok, digest} <- ActivateCore.require_digest(digest),
         {:ok, home} <- arbor_home(opts),
         {:ok, source} <- ActivateCore.source_path(home, digest),
         {:ok, dest} <- ActivateCore.destination_path(home, Keyword.get(opts, :config_path)),
         {:ok, bytes} <- read_regular_file(source),
         {:ok, document} <- decode_json(bytes),
         :ok <- ActivateCore.require_oci_document(document),
         :ok <- write_mode_0400(dest, bytes),
         {:ok, canonical_dest} <- Shell.canonicalize_absolute_path(dest),
         :ok <- admit_activated_document(canonical_dest) do
      {:ok,
       %{
         "path" => dest,
         "digest" => digest,
         "restart_required" => true
       }}
    end
  end

  def activate(_digest, _opts), do: {:error, :invalid_options}

  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ [])

  def status(opts) when is_list(opts) do
    shell = Keyword.get(opts, :shell, Shell)
    architecture = Keyword.get(opts, :architecture, architecture())

    runtime = shell.validation_runtime_status()
    baseline = shell.linux_dependency_baseline_status()
    mix_lock = shell.linux_dependency_baseline_mix_lock_digest()
    probe = maybe_probe(shell, opts)
    guest = guest_platform(opts, architecture)
    head = head_mix_lock_digest(opts)

    {:ok,
     StatusCore.project(%{
       runtime: runtime,
       baseline: baseline,
       mix_lock_digest: mix_lock,
       head_mix_lock_digest: head,
       probe: probe,
       host_platform: architecture,
       guest_platform: guest
     })}
  end

  def status(_opts), do: {:error, :invalid_options}

  defp maybe_probe(shell, opts) do
    if Keyword.get(opts, :probe, true) == true do
      shell.validation_runtime_probe()
    else
      {:error, :probe_skipped}
    end
  end

  defp guest_platform(opts, architecture) do
    case Keyword.get(opts, :platform) do
      platform when is_binary(platform) ->
        platform

      _other ->
        case BuildCore.guest_platform_for_architecture(architecture) do
          {:ok, platform} -> platform
          _error -> nil
        end
    end
  end

  defp head_mix_lock_digest(opts) do
    case Keyword.get(opts, :head_mix_lock_digest) do
      digest when is_binary(digest) ->
        digest

      _other ->
        case Keyword.get(opts, :repo_root) do
          root when is_binary(root) ->
            case hash_mix_lock(root) do
              {:ok, digest} -> digest
              _error -> nil
            end

          _missing ->
            nil
        end
    end
  end

  defp build_context(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, home} <- arbor_home(opts),
           {:ok, repo_root} <- repo_root(opts) do
        deps_path = Keyword.get(opts, :deps_path) || Path.join(home, "baseline-staging")

        {:ok,
         %{
           arbor_home: home,
           repo_root: repo_root,
           deps_path: deps_path,
           platform: Keyword.get(opts, :platform),
           architecture: Keyword.get(opts, :architecture, architecture()),
           active_config_path:
             Keyword.get(opts, :active_config_path) ||
               Path.join(home, "validation-runtime.json"),
           image_build: Keyword.get(opts, :image_build),
           deps_fetch: Keyword.get(opts, :deps_fetch),
           smoke_test: Keyword.get(opts, :smoke_test),
           shell: Keyword.get(opts, :shell, Shell)
         }}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp arbor_home(opts) do
    raw =
      Keyword.get(opts, :arbor_home) ||
        System.get_env("ARBOR_HOME") ||
        Path.expand("~/.arbor")

    home = Path.expand(raw)

    if Path.type(home) == :absolute, do: {:ok, home}, else: {:error, :invalid_arbor_home}
  end

  defp repo_root(opts) do
    raw = Keyword.get(opts, :repo_root) || File.cwd!()
    root = Path.expand(raw)

    if Path.type(root) == :absolute, do: {:ok, root}, else: {:error, :invalid_repo_root}
  end

  defp architecture do
    :erlang.system_info(:system_architecture) |> List.to_string()
  end

  defp resolve_platform(%{platform: platform}) when is_binary(platform), do: {:ok, platform}

  defp resolve_platform(%{architecture: architecture}) do
    BuildCore.guest_platform_for_architecture(architecture)
  end

  defp read_toolchain(repo_root) do
    path = Path.join(repo_root, ".tool-versions")

    case File.read(path) do
      {:ok, text} ->
        with {:ok, erlang} <- capture(~r/^erlang[ \t]+(\S+)\s*$/m, text),
             {:ok, elixir} <- capture(~r/^elixir[ \t]+(\S+)\s*$/m, text) do
          {:ok, %{erlang: erlang, elixir: elixir}}
        else
          _other -> {:error, :invalid_tool_versions}
        end

      {:error, _reason} ->
        {:error, :missing_tool_versions}
    end
  end

  defp capture(regex, text) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing}
    end
  end

  defp hash_mix_lock(repo_root) do
    path = Path.join(repo_root, "mix.lock")

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @mix_lock_max_bytes ->
        case File.read(path) do
          {:ok, bytes} ->
            {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}

          {:error, _reason} ->
            {:error, :mix_lock_unreadable}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :mix_lock_too_large}

      _other ->
        {:error, :mix_lock_unreadable}
    end
  end

  defp fetch_deps(%{deps_fetch: fun} = ctx) when is_function(fun, 1), do: fun.(ctx)

  defp fetch_deps(%{deps_path: deps_path, repo_root: repo_root}) do
    File.mkdir_p!(deps_path)

    # Absolute wrapper path: `System.cmd/3` hands the command to Erlang's
    # `spawn_executable`, which does not resolve a relative `./bin/mix` against
    # `:cd` — on Linux it fails with :enoent before the child starts (V7,
    # 2026-08-26). Same absolute-wrapper contract as `Arbor.Actions.Mix`.
    case System.cmd(Path.join(repo_root, "bin/mix"), ["deps.get"],
           cd: repo_root,
           env: [{"MIX_DEPS_PATH", deps_path}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :deps_fetch_failed}
    end
  end

  defp smoke_test_copy(ctx, platform) do
    copy = ctx.deps_path <> "-smoke"

    try do
      with :ok <- copy_tree(ctx.deps_path, copy) do
        run_smoke(ctx, copy, platform)
      end
    after
      File.rm_rf(copy)
    end
  end

  defp run_smoke(%{smoke_test: fun}, copy, platform) when is_function(fun, 2),
    do: fun.(copy, platform)

  defp run_smoke(%{shell: shell}, copy, platform) do
    case shell.linux_dependency_baseline_tree_digest(copy, platform) do
      {:ok, _digest} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_image(ctx, platform, toolchain, mix_lock_digest, tree_digest, labels) do
    request = %{
      platform: platform,
      erlang: toolchain.erlang,
      elixir: toolchain.elixir,
      mix_lock_digest: mix_lock_digest,
      tree_digest: tree_digest,
      labels: labels,
      containerfile: Path.join(ctx.repo_root, "images/validation-runtime/Containerfile"),
      context: Path.join(ctx.repo_root, "images/validation-runtime")
    }

    result =
      case ctx.image_build do
        fun when is_function(fun, 1) -> fun.(request)
        _missing -> podman_build(request)
      end

    normalize_image_result(result)
  end

  defp normalize_image_result({:ok, image}) when is_map(image) do
    index = Map.get(image, :index_digest) || Map.get(image, "index_digest")
    manifest = Map.get(image, :manifest_digest) || Map.get(image, "manifest_digest")
    image_ref = Map.get(image, :image) || Map.get(image, "image")

    image_id = Map.get(image, :image_id) || Map.get(image, "image_id")

    cond do
      is_binary(index) and is_binary(manifest) and is_binary(image_ref) ->
        with_image_id(
          %{index_digest: index, manifest_digest: manifest, image: image_ref},
          image_id
        )

      is_binary(index) and is_binary(manifest) ->
        with_image_id(
          %{
            index_digest: index,
            manifest_digest: manifest,
            image: @provisioning_image_prefix <> index
          },
          image_id
        )

      true ->
        {:error, :invalid_image_inspect}
    end
  end

  defp normalize_image_result({:error, reason}), do: {:error, reason}
  defp normalize_image_result(_other), do: {:error, :invalid_image_inspect}

  defp podman_build(request) do
    # `podman image inspect --latest` does not exist (the flag belongs to
    # `podman inspect` for containers); it failed every build with
    # `image_inspect_failed` on the first V7 run (2026-08-26). Capture the
    # built image id with `--iidfile` and inspect exactly that image.
    iidfile =
      Path.join(
        System.tmp_dir!(),
        "arbor-baseline-#{System.unique_integer([:positive])}.iid"
      )

    args = [
      "build",
      "--pull=never",
      "--iidfile",
      iidfile,
      "--platform",
      request.platform,
      "--build-arg",
      "ERLANG_VERSION=" <> request.erlang,
      "--build-arg",
      "ELIXIR_VERSION=" <> request.elixir,
      "--build-arg",
      "ARBOR_VALIDATION_PLATFORM=" <> request.platform,
      "--build-arg",
      "MIX_LOCK_SHA256=" <> request.mix_lock_digest,
      "--build-arg",
      "DEPS_TREE_SHA256=" <> request.tree_digest,
      "-f",
      request.containerfile,
      request.context
    ]

    try do
      case System.cmd("/usr/bin/podman", args, stderr_to_stdout: true) do
        {_output, 0} ->
          inspect_built_image(iidfile)

        {_output, _status} ->
          {:error, :image_build_failed}
      end
    after
      File.rm(iidfile)
    end
  end

  defp with_image_id(image, image_id) when image_id in [nil, ""] do
    {:ok, image}
  end

  defp with_image_id(image, "sha256:" <> hex = image_id)
       when is_binary(hex) and byte_size(hex) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, hex) do
      {:ok, Map.put(image, :image_id, image_id)}
    else
      {:error, :invalid_image_id}
    end
  end

  defp with_image_id(_image, _image_id), do: {:error, :invalid_image_id}

  defp inspect_built_image(iidfile) do
    with {:ok, contents} <- File.read(iidfile),
         "sha256:" <> hex = image_id when byte_size(hex) == 64 <- String.trim(contents),
         {json, 0} <-
           System.cmd("/usr/bin/podman", ["image", "inspect", image_id], stderr_to_stdout: true) do
      parse_inspect(json, image_id)
    else
      _other -> {:error, :image_inspect_failed}
    end
  end

  defp parse_inspect(json, image_id) do
    case Jason.decode(json) do
      {:ok, [resource | _rest]} when is_map(resource) ->
        digest = inspect_digest(resource)
        inspect_id = Map.get(resource, "Id") || Map.get(resource, "id")

        cond do
          not is_binary(digest) ->
            {:error, :image_inspect_failed}

          inspect_id != image_id ->
            {:error, :image_id_mismatch}

          true ->
            {:ok,
             %{
               index_digest: digest,
               manifest_digest: digest,
               image: @provisioning_image_prefix <> digest,
               image_id: image_id
             }}
        end

      {:ok, resource} when is_map(resource) ->
        parse_inspect(Jason.encode!([resource]), image_id)

      _other ->
        {:error, :image_inspect_failed}
    end
  end

  defp inspect_digest(resource) do
    case Map.get(resource, "Digest") || Map.get(resource, "digest") do
      "sha256:" <> hex = digest when byte_size(hex) == 64 -> digest
      _other -> nil
    end
  end

  defp persist(layout, document, source_tree, image_policy) do
    # The collection dir (`$ARBOR_HOME/baseline`) is an ANCESTOR of everything
    # the operator-owned pin walks; created by `mkdir_p` under a 002 umask it
    # came out 775 and every pin failed with :untrusted_path even though the
    # digest dir and tree were 0700/0400 (V7-4, 2026-08-26). Own it too.
    with :ok <- mkdir_owner_only(Path.dirname(layout.baseline_root)),
         :ok <- mkdir_owner_only(layout.baseline_root),
         :ok <- copy_tree(source_tree, layout.tree_dir),
         :ok <- write_mode_0400(layout.manifest_path, Jason.encode!(document)),
         :ok <-
           write_mode_0400(
             layout.baseline_json_path,
             Jason.encode!(BuildCore.activation_document(layout, image_policy))
           ) do
      chmod_tree(layout.baseline_root)
    end
  end

  defp mkdir_owner_only(path) do
    case File.mkdir_p(path) do
      :ok ->
        case File.chmod(path, @dir_mode) do
          :ok -> :ok
          {:error, _reason} -> {:error, :baseline_write_failed}
        end

      {:error, _reason} ->
        {:error, :baseline_write_failed}
    end
  end

  defp copy_tree(source, dest) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :directory}} ->
        copy_directory(source, dest)

      {:ok, %File.Stat{type: :regular}} ->
        copy_regular(source, dest)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      _other ->
        {:error, :tree_copy_failed}
    end
  end

  defp copy_directory(source, dest) do
    File.mkdir_p!(dest)
    File.chmod!(dest, @dir_mode)

    case File.ls(source) do
      {:ok, names} ->
        reduce_children(names, &copy_tree(Path.join(source, &1), Path.join(dest, &1)))

      {:error, _reason} ->
        {:error, :tree_copy_failed}
    end
  end

  # The tree digest covers each entry's `executable` flag
  # (`LinuxDependencyBaselineCore` `@logical_regular_keys`), and the digest is
  # computed over the staging copy BEFORE persist. Flattening every file to
  # 0400 here dropped the bit on deps' scripts, so the authority's recompute
  # over the persisted tree disagreed with the recorded digest
  # (`baseline_tree_digest_mismatch`, V7-6, 2026-08-26). Keep executables
  # owner-executable (0500); everything stays owner-only and read-only.
  defp copy_regular(source, dest) do
    with {:ok, %File.Stat{mode: mode}} <- File.lstat(source),
         {:ok, _count} <- File.copy(source, dest) do
      File.chmod!(dest, if(executable_mode?(mode), do: @exec_file_mode, else: @file_mode))
      :ok
    else
      {:error, _reason} -> {:error, :tree_copy_failed}
    end
  end

  defp executable_mode?(mode), do: Bitwise.band(mode, 0o111) != 0

  defp chmod_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> chmod_directory(path)
      {:ok, %File.Stat{type: :regular}} -> chmod_regular(path)
      _other -> {:error, :baseline_write_failed}
    end
  end

  defp chmod_directory(path) do
    File.chmod!(path, @dir_mode)

    case File.ls(path) do
      {:ok, names} -> reduce_children(names, &chmod_tree(Path.join(path, &1)))
      {:error, _reason} -> {:error, :baseline_write_failed}
    end
  end

  defp chmod_regular(path) do
    with {:ok, %File.Stat{mode: mode}} <- File.lstat(path),
         :ok <-
           File.chmod(path, if(executable_mode?(mode), do: @exec_file_mode, else: @file_mode)) do
      :ok
    else
      {:error, _reason} -> {:error, :baseline_write_failed}
    end
  end

  defp reduce_children(names, fun) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case fun.(name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp admit_activated_document(path) when is_binary(path) do
    case Shell.admit_operator_owned_runtime_config(path) do
      {:ok, %{kind: :oci}} ->
        :ok

      {:ok, _other} ->
        {:error, :apple_only_policy_key}

      {:error, :config_file_untrusted} ->
        {:error, {:validation_runtime_untrusted, :config_file_untrusted}}

      {:error, reason} ->
        {:error, {:validation_runtime_untrusted, reason}}
    end
  end

  defp write_mode_0400(path, bytes) when is_binary(path) and is_binary(bytes) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    with :ok <- mkdir_owner_only(dir),
         :ok <- File.write(tmp, bytes),
         :ok <- File.chmod(tmp, @file_mode),
         :ok <- File.rename(tmp, path),
         :ok <- File.chmod(path, @file_mode) do
      :ok
    else
      {:error, _reason} ->
        _ = File.rm(tmp)
        {:error, :baseline_write_failed}
    end
  end

  defp read_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 64 * 1024 ->
        File.read(path)

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :baseline_document_too_large}

      _other ->
        {:error, :baseline_document_missing}
    end
  end

  defp decode_json(bytes) do
    case Jason.decode(bytes) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _other -> {:error, :invalid_baseline_document}
    end
  end
end
