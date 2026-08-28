defmodule Arbor.Commands.Baseline.BuildCore do
  @moduledoc """
  Pure layout and document decisions for `mix arbor.baseline.build`.
  """

  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @digest_re ~r/\Asha256:[0-9a-f]{64}\z/
  @allowed_platforms MapSet.new(["linux/amd64", "linux/arm64"])

  @type layout :: %{
          baseline_root: String.t(),
          tree_dir: String.t(),
          manifest_path: String.t(),
          baseline_json_path: String.t(),
          unit_journal_path: String.t(),
          default_config_path: String.t()
        }

  @spec guest_platform_for_architecture(term()) :: {:ok, String.t()} | {:error, atom()}
  def guest_platform_for_architecture(arch) when is_binary(arch) do
    trimmed = String.trim(arch)

    cond do
      String.starts_with?(trimmed, "x86_64") or String.starts_with?(trimmed, "amd64") ->
        {:ok, "linux/amd64"}

      String.starts_with?(trimmed, "aarch64") or String.starts_with?(trimmed, "arm64") ->
        {:ok, "linux/arm64"}

      true ->
        {:error, :unsupported_system_architecture}
    end
  end

  def guest_platform_for_architecture(_arch), do: {:error, :unsupported_system_architecture}

  @spec require_platform(term()) :: :ok | {:error, atom()}
  def require_platform(platform) when is_binary(platform) do
    if MapSet.member?(@allowed_platforms, platform),
      do: :ok,
      else: {:error, :unsupported_platform}
  end

  def require_platform(_platform), do: {:error, :unsupported_platform}

  @spec layout(term(), term()) :: {:ok, layout()} | {:error, atom()}
  def layout(arbor_home, tree_digest)
      when is_binary(arbor_home) and is_binary(tree_digest) do
    with :ok <- require_hex64(tree_digest),
         {:ok, home} <- require_absolute(arbor_home) do
      root = Path.join([home, "baseline", tree_digest])

      {:ok,
       %{
         baseline_root: root,
         tree_dir: Path.join(root, "tree"),
         manifest_path: Path.join(root, "manifest.json"),
         baseline_json_path: Path.join(root, "baseline.json"),
         unit_journal_path: Path.join(home, "oci-unit-journal.json"),
         default_config_path: Path.join(home, "validation-runtime.json")
       }}
    end
  end

  def layout(_arbor_home, _tree_digest), do: {:error, :invalid_baseline_layout}

  @spec refuse_active_config_mutation(layout(), term()) :: :ok | {:error, atom()}
  def refuse_active_config_mutation(layout, active_path)
      when is_map(layout) and is_binary(active_path) do
    writes = [
      layout.baseline_json_path,
      layout.manifest_path,
      layout.tree_dir,
      layout.baseline_root
    ]

    if active_path in writes do
      {:error, :must_not_mutate_active_config}
    else
      :ok
    end
  end

  def refuse_active_config_mutation(_layout, _active_path), do: :ok

  @spec image_labels(map(), String.t(), String.t(), String.t()) :: map()
  def image_labels(%{erlang: erlang, elixir: elixir}, platform, mix_lock_digest, tree_digest)
      when is_binary(erlang) and is_binary(elixir) and is_binary(platform) and
             is_binary(mix_lock_digest) and is_binary(tree_digest) do
    %{
      "org.arbor.validation.schema" => "1",
      "org.arbor.validation.role" => "spawn-containment",
      "org.arbor.validation.platform" => platform,
      "org.arbor.validation.erlang" => erlang,
      "org.arbor.validation.elixir" => elixir,
      "org.arbor.validation.mix-lock-sha256" => mix_lock_digest,
      "org.arbor.validation.deps-tree-sha256" => tree_digest
    }
  end

  @spec image_policy(map()) :: {:ok, map()} | {:error, atom()}
  def image_policy(fields) when is_map(fields) do
    with {:ok, image} <- fetch_binary(fields, :image),
         {:ok, manifest_digest} <- fetch_binary(fields, :manifest_digest),
         :ok <- require_digest(image_digest_part(image)),
         :ok <- require_digest(manifest_digest),
         {:ok, mix_lock_digest} <- fetch_binary(fields, :mix_lock_digest),
         :ok <- require_hex64(mix_lock_digest),
         {:ok, baseline_tree_digest} <- fetch_binary(fields, :baseline_tree_digest),
         :ok <- require_hex64(baseline_tree_digest),
         {:ok, erlang} <- fetch_binary(fields, :erlang),
         {:ok, elixir} <- fetch_binary(fields, :elixir),
         {:ok, platform} <- fetch_binary(fields, :platform),
         :ok <- require_platform(platform),
         {:ok, env} <- fetch_env(fields),
         {:ok, labels} <- fetch_labels(fields) do
      policy = %{
        "image" => image,
        "manifest_digest" => manifest_digest,
        "env" => env,
        "labels" => labels,
        "mix_lock_digest" => mix_lock_digest,
        "baseline_tree_digest" => baseline_tree_digest,
        "toolchain" => %{"erlang" => erlang, "elixir" => elixir},
        "platform" => platform
      }

      put_optional_image_id(policy, Map.get(fields, :image_id))
    end
  end

  def image_policy(_fields), do: {:error, :invalid_image_policy}

  @spec activation_document(layout(), map()) :: map()
  def activation_document(layout, image_policy) when is_map(layout) and is_map(image_policy) do
    %{
      "runtime" => "oci",
      "linux_dependency_baseline" => %{
        "source_root" => layout.tree_dir,
        "manifest_path" => layout.manifest_path
      },
      "image_policy" => image_policy,
      "unit_journal_path" => layout.unit_journal_path
    }
  end

  defp fetch_binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_image_policy}
    end
  end

  defp fetch_env(map) do
    case Map.get(map, :env, []) do
      env when is_list(env) ->
        if Enum.all?(env, &is_binary/1), do: {:ok, env}, else: {:error, :invalid_image_policy}

      _other ->
        {:error, :invalid_image_policy}
    end
  end

  defp fetch_labels(map) do
    case Map.get(map, :labels) do
      labels when is_map(labels) -> {:ok, labels}
      _other -> {:error, :invalid_image_policy}
    end
  end

  defp put_optional_image_id(policy, image_id) when image_id in [nil, ""] do
    {:ok, policy}
  end

  defp put_optional_image_id(policy, image_id) when is_binary(image_id) do
    if Regex.match?(@digest_re, image_id) do
      {:ok, Map.put(policy, "image_id", image_id)}
    else
      {:error, :invalid_image_id}
    end
  end

  defp put_optional_image_id(_policy, _image_id), do: {:error, :invalid_image_id}

  defp image_digest_part("docker.io/arbor/validation@sha256:" <> hex = image) do
    if Regex.match?(@hex64_re, hex), do: image, else: ""
  end

  defp image_digest_part(image) when is_binary(image), do: image

  defp require_digest(value) when is_binary(value) do
    cond do
      Regex.match?(@digest_re, value) ->
        :ok

      String.contains?(value, "@sha256:") and Regex.match?(~r/@sha256:[0-9a-f]{64}\z/, value) ->
        :ok

      true ->
        {:error, :invalid_image_digest}
    end
  end

  defp require_digest(_value), do: {:error, :invalid_image_digest}

  defp require_hex64(value) when is_binary(value) do
    if Regex.match?(@hex64_re, value), do: :ok, else: {:error, :invalid_digest}
  end

  defp require_hex64(_value), do: {:error, :invalid_digest}

  defp require_absolute(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :invalid_arbor_home}

      Path.type(path) != :absolute ->
        {:error, :invalid_arbor_home}

      String.contains?(path, ["//", "/./", "/../"]) ->
        {:error, :invalid_arbor_home}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, :invalid_arbor_home}

      true ->
        {:ok, path}
    end
  end

  defp require_absolute(_path), do: {:error, :invalid_arbor_home}

  # ── Image backend selection ───────────────────────────────────────────────
  #
  # The image step used to hardcode `/usr/bin/podman`; on a macOS host the
  # validation runtime is Apple Container, so the build finished the attested
  # tree and then died at `podman: not found` (B2a, reproduced 2026-08 and by
  # Codex on 2026-08-27 at tree 81704a6b…). Select the backend the runtime
  # admission already reports instead of assuming one.

  @image_backends ["podman", "apple_container"]
  @default_image_executables %{
    "podman" => "/usr/bin/podman",
    "apple_container" => "/usr/local/bin/container"
  }

  @doc """
  Pick the image backend: the validation runtime status driver, else the
  probe driver, else the host OS (the first build on a fresh host has no
  activated runtime yet, and both report `"unavailable"`). macOS hosts run
  Apple Container; Linux hosts run rootless Podman. Returns `{:ok, driver}`
  for an admitted backend or `{:error, {:image_backend_unsupported, seen}}`
  naming what was reported.
  """
  @spec image_backend(term(), term(), term()) ::
          {:ok, String.t()} | {:error, {:image_backend_unsupported, term()}}
  def image_backend(runtime_status, probe, host_os \\ nil) do
    reported = driver_of(runtime_status) || driver_of(probe)
    driver = reported || host_default(host_os)

    if driver in @image_backends,
      do: {:ok, driver},
      else: {:error, {:image_backend_unsupported, reported || driver}}
  end

  @absent_drivers ["", "unavailable", "unpinned", "none", "unknown"]

  defp driver_of({:ok, map}), do: driver_of(map)

  defp driver_of(%{"driver" => driver}) when is_binary(driver) and driver not in @absent_drivers,
    do: driver

  defp driver_of(%{driver: driver}) when is_binary(driver) and driver not in @absent_drivers,
    do: driver

  defp driver_of(_other), do: nil

  defp host_default({:unix, :darwin}), do: "apple_container"
  defp host_default({:unix, :linux}), do: "podman"
  defp host_default(_other), do: nil

  @doc """
  Executable for a backend: reviewed host config
  (`config :arbor_commands, :baseline_image_executables`) over the defaults.
  Only absolute paths are accepted.
  """
  @spec image_executable(String.t(), term()) :: {:ok, String.t()} | {:error, atom()}
  def image_executable(driver, configured) when is_binary(driver) do
    configured = if is_map(configured), do: configured, else: %{}

    case Map.get(configured, driver) || Map.get(@default_image_executables, driver) do
      "/" <> _ = path -> {:ok, path}
      _other -> {:error, :image_executable_invalid}
    end
  end

  @doc "Build tag and local workload alias for an Apple Container baseline image."
  @spec apple_container_tags(String.t()) ::
          {:ok, %{build: String.t(), alias: String.t()}} | {:error, atom()}
  def apple_container_tags(tree_digest) when is_binary(tree_digest) do
    case tree_digest do
      <<short::binary-size(8), _rest::binary>> when byte_size(tree_digest) == 64 ->
        if Regex.match?(~r/^[0-9a-f]{64}$/, tree_digest) do
          {:ok,
           %{
             build: "arbor/validation:baseline-" <> short,
             alias: "127.0.0.1:0/arbor/workload:baseline-" <> short
           }}
        else
          {:error, :invalid_tree_digest}
        end

      _other ->
        {:error, :invalid_tree_digest}
    end
  end

  def apple_container_tags(_tree_digest), do: {:error, :invalid_tree_digest}

  @doc """
  Derive the baseline image identity from Apple Container's
  `container image inspect` JSON plus the OCI manifest blob of the platform
  variant. `inspect` gives the index digest (`configuration.descriptor.digest`)
  and the per-platform manifest digest (`variants[].digest`); the image id is
  the manifest's `config.digest` (the same value Podman reports as `.Id`), which
  inspect does not expose, hence `manifest_json`.
  """
  @spec apple_container_image(term(), term(), String.t()) :: {:ok, map()} | {:error, atom()}
  def apple_container_image(inspect_json, manifest_json, platform)
      when is_binary(inspect_json) and is_binary(manifest_json) and is_binary(platform) do
    with {:ok, [resource | _]} when is_map(resource) <- Jason.decode(inspect_json),
         "sha256:" <> ihex = index when byte_size(ihex) == 64 <-
           get_in(resource, ["configuration", "descriptor", "digest"]),
         {:ok, "sha256:" <> mhex = manifest} when byte_size(mhex) == 64 <-
           variant_digest(Map.get(resource, "variants"), platform),
         {:ok, %{"config" => %{"digest" => "sha256:" <> chex = image_id}}}
         when byte_size(chex) == 64 <-
           Jason.decode(manifest_json) do
      {:ok, %{index_digest: index, manifest_digest: manifest, image_id: image_id}}
    else
      _other -> {:error, :image_inspect_failed}
    end
  end

  def apple_container_image(_inspect, _manifest, _platform), do: {:error, :image_inspect_failed}

  @doc false
  @spec apple_container_variant_digest(term(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def apple_container_variant_digest(variants, platform), do: variant_digest(variants, platform)

  defp variant_digest([%{"digest" => digest}], _platform) when is_binary(digest),
    do: {:ok, digest}

  defp variant_digest(variants, platform) when is_list(variants) do
    arch =
      case String.split(platform, "/") do
        [_os, arch | _] -> arch
        _ -> nil
      end

    variants
    |> Enum.find(fn v -> get_in(v, ["platform", "architecture"]) == arch end)
    |> case do
      %{"digest" => digest} when is_binary(digest) -> {:ok, digest}
      _ -> {:error, :variant_not_found}
    end
  end

  defp variant_digest(_variants, _platform), do: {:error, :variant_not_found}
end
