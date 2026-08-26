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
end
