defmodule Arbor.Shell.OciAdmissionCore do
  @moduledoc """
  Pure OCI image-admission core.

  Binds operator image policy plus already-collected inspect evidence to a
  compact receipt. Performs no IO. Does not call AppleContainerAdmissionCore
  (that core requires Apple control-plane bindings and vminit).

  Policy may name a provisioning digest (`docker.io/arbor/validation@sha256:...`)
  and, for locally built images, a local image id (`sha256:` + 64 hex). Inspect
  Digest must equal that provisioning digest and `manifest_digest`. When
  `image_id` is present, inspect Id must equal it and create argv uses that id
  (Podman does not address local builds by manifest digest). Labels still bind.
  Inspect `.Id` may be Podman's bare 64-hex; comparison uses `Sha256Digest`.
  """

  alias Arbor.Shell.Sha256Digest

  @allowed_platforms MapSet.new(["linux/amd64", "linux/arm64"])

  @fixed_label_schema "org.arbor.validation.schema"
  @fixed_label_role "org.arbor.validation.role"
  @fixed_label_platform "org.arbor.validation.platform"
  @fixed_label_erlang "org.arbor.validation.erlang"
  @fixed_label_elixir "org.arbor.validation.elixir"
  @fixed_label_mix_lock "org.arbor.validation.mix-lock-sha256"
  @fixed_label_deps_tree "org.arbor.validation.deps-tree-sha256"

  @fixed_schema_value "1"
  @fixed_role_value "spawn-containment"

  @logical_request_keys [:policy, :evidence]
  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @logical_policy_keys [
    :image,
    :image_id,
    :manifest_digest,
    :labels,
    :mix_lock_digest,
    :baseline_tree_digest,
    :toolchain,
    :platform
  ]

  @allowed_policy_keys MapSet.new(
                         @logical_policy_keys ++ Enum.map(@logical_policy_keys, &Atom.to_string/1)
                       )

  @forbidden_apple_policy_keys MapSet.new([
                                 :vminit_image,
                                 :vminit_manifest_digest,
                                 "vminit_image",
                                 "vminit_manifest_digest"
                               ])

  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @sha256_digest_re ~r/\Asha256:([0-9a-f]{64})\z/
  @provisioning_digest_re ~r/@sha256:([0-9a-f]{64})\z/

  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(request) when is_map(request) do
    with :ok <- validate_request_keys(request),
         {:ok, policy} <- fetch_map(request, :policy, :missing_policy, :invalid_policy),
         :ok <- validate_policy_keys(policy),
         {:ok, evidence} <- fetch_map(request, :evidence, :missing_evidence, :invalid_evidence),
         {:ok, inspect_map} <- fetch_inspect(evidence),
         {:ok, platform} <- fetch_platform(policy),
         {:ok, toolchain} <- fetch_toolchain(policy),
         {:ok, mix_lock_digest} <- fetch_hex64(policy, :mix_lock_digest, :missing_mix_lock_digest),
         {:ok, baseline_tree_digest} <-
           fetch_hex64(policy, :baseline_tree_digest, :missing_baseline_tree_digest),
         {:ok, labels} <- fetch_labels(policy),
         :ok <-
           validate_fixed_attestation_labels(
             labels,
             platform,
             toolchain,
             mix_lock_digest,
             baseline_tree_digest
           ),
         {:ok, execution_digest} <- fetch_execution_digest(inspect_map),
         :ok <- match_provisioning_digest(policy, execution_digest),
         :ok <- match_manifest_digest(policy, execution_digest),
         :ok <- match_inspect_labels(inspect_map, labels),
         {:ok, local_image} <- local_execution_image(policy, inspect_map, execution_digest) do
      {:ok,
       %{
         "kind" => "oci_validation_image",
         "driver" => "podman",
         "platform" => platform,
         "execution_image" => local_image,
         "mix_lock_digest" => mix_lock_digest,
         "baseline_tree_digest" => baseline_tree_digest
       }}
    end
  end

  def new(_request), do: {:error, :invalid_request}

  defp validate_request_keys(request) do
    keys = Map.keys(request)

    if Enum.any?(keys, &(not MapSet.member?(@allowed_request_keys, &1))) do
      {:error, :unsupported_request_keys}
    else
      :ok
    end
  end

  defp validate_policy_keys(policy) when is_map(policy) do
    keys = Map.keys(policy)

    cond do
      Enum.any?(keys, &MapSet.member?(@forbidden_apple_policy_keys, &1)) ->
        {:error, :apple_only_policy_key}

      Enum.any?(keys, &(not MapSet.member?(@allowed_policy_keys, &1))) ->
        {:error, :unsupported_policy_keys}

      true ->
        :ok
    end
  end

  defp fetch_map(request, key, missing, invalid) do
    case get_field(request, key) do
      nil -> {:error, missing}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, invalid}
    end
  end

  defp fetch_inspect(evidence) do
    case get_field(evidence, :inspect) do
      inspect_map when is_map(inspect_map) -> {:ok, stringify_keys(inspect_map)}
      nil -> {:error, :missing_inspect_evidence}
      _other -> {:error, :invalid_inspect_evidence}
    end
  end

  defp fetch_platform(policy) do
    case get_field(policy, :platform) do
      platform when is_binary(platform) ->
        if MapSet.member?(@allowed_platforms, platform) do
          {:ok, platform}
        else
          {:error, :unsupported_platform}
        end

      nil ->
        {:error, :missing_platform}

      _other ->
        {:error, :invalid_platform}
    end
  end

  defp fetch_toolchain(policy) do
    case get_field(policy, :toolchain) do
      toolchain when is_map(toolchain) ->
        with {:ok, erlang} <- fetch_required_string(toolchain, :erlang, :missing_toolchain_erlang),
             {:ok, elixir} <- fetch_required_string(toolchain, :elixir, :missing_toolchain_elixir) do
          {:ok, %{erlang: erlang, elixir: elixir}}
        end

      nil ->
        {:error, :missing_toolchain}

      _other ->
        {:error, :invalid_toolchain}
    end
  end

  defp fetch_labels(policy) do
    case get_field(policy, :labels) do
      labels when is_map(labels) -> {:ok, stringify_keys(labels)}
      nil -> {:error, :missing_labels}
      _other -> {:error, :invalid_labels}
    end
  end

  defp fetch_hex64(map, key, missing) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_binary(value) ->
        if Regex.match?(@hex64_re, value), do: {:ok, value}, else: {:error, :invalid_hex64}

      _other ->
        {:error, :invalid_hex64}
    end
  end

  defp fetch_required_string(map, key, missing) do
    case get_field(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, missing}
      _other -> {:error, missing}
    end
  end

  defp validate_fixed_attestation_labels(
         labels,
         platform,
         toolchain,
         mix_lock_digest,
         baseline_tree_digest
       ) do
    required = %{
      @fixed_label_schema => @fixed_schema_value,
      @fixed_label_role => @fixed_role_value,
      @fixed_label_platform => platform,
      @fixed_label_erlang => toolchain.erlang,
      @fixed_label_elixir => toolchain.elixir,
      @fixed_label_mix_lock => mix_lock_digest,
      @fixed_label_deps_tree => baseline_tree_digest
    }

    Enum.reduce_while(required, :ok, fn {key, expected}, :ok ->
      case Map.fetch(labels, key) do
        :error -> {:halt, {:error, :missing_fixed_attestation_label}}
        {:ok, ^expected} -> {:cont, :ok}
        {:ok, _other} -> {:halt, {:error, :fixed_attestation_label_mismatch}}
      end
    end)
  end

  defp fetch_execution_digest(inspect_map) do
    digest = Map.get(inspect_map, "Digest") || Map.get(inspect_map, "digest")

    case digest do
      value when is_binary(value) ->
        case Regex.run(@sha256_digest_re, value) do
          [^value, _hex] -> {:ok, value}
          _other -> {:error, :inspect_digest_not_sha256}
        end

      _other ->
        {:error, :missing_inspect_digest}
    end
  end

  defp match_provisioning_digest(policy, "sha256:" <> hex = execution_digest) do
    case get_field(policy, :image) do
      nil ->
        {:error, :missing_policy_image}

      image when is_binary(image) ->
        cond do
          image == execution_digest ->
            :ok

          match?([_, ^hex], Regex.run(@provisioning_digest_re, image)) ->
            :ok

          String.contains?(image, ":") and not String.contains?(image, "@sha256:") ->
            {:error, :mutable_image_tag}

          true ->
            {:error, :execution_digest_mismatch}
        end

      _other ->
        {:error, :invalid_policy_image}
    end
  end

  defp match_manifest_digest(policy, execution_digest) do
    case get_field(policy, :manifest_digest) do
      nil ->
        case get_field(policy, :image_id) do
          nil -> :ok
          _image_id -> {:error, :missing_manifest_digest}
        end

      digest when is_binary(digest) ->
        if digest == execution_digest do
          :ok
        else
          {:error, :manifest_digest_mismatch}
        end

      _other ->
        {:error, :invalid_manifest_digest}
    end
  end

  defp local_execution_image(policy, inspect_map, execution_digest) do
    case get_field(policy, :image_id) do
      nil ->
        {:ok, execution_digest}

      image_id when is_binary(image_id) ->
        case Sha256Digest.normalize(image_id) do
          {:ok, normalized} ->
            with :ok <- match_inspect_id(inspect_map, normalized) do
              {:ok, normalized}
            end

          {:error, _} ->
            {:error, :invalid_image_id}
        end

      _other ->
        {:error, :invalid_image_id}
    end
  end

  defp match_inspect_id(inspect_map, image_id) do
    inspect_id = Map.get(inspect_map, "Id") || Map.get(inspect_map, "id")

    cond do
      is_nil(inspect_id) ->
        {:error, :missing_inspect_id}

      Sha256Digest.equal?(inspect_id, image_id) ->
        :ok

      match?({:ok, _}, Sha256Digest.normalize(inspect_id)) ->
        {:error, :image_id_mismatch}

      true ->
        {:error, :missing_inspect_id}
    end
  end

  defp match_inspect_labels(inspect_map, policy_labels) do
    inspect_labels =
      case Map.get(inspect_map, "Labels") || Map.get(inspect_map, "labels") do
        labels when is_map(labels) -> stringify_keys(labels)
        _other -> %{}
      end

    Enum.reduce_while(policy_labels, :ok, fn {key, expected}, :ok ->
      case Map.fetch(inspect_labels, key) do
        {:ok, ^expected} -> {:cont, :ok}
        {:ok, _other} -> {:halt, {:error, :inspect_label_mismatch}}
        :error -> {:halt, {:error, :inspect_label_missing}}
      end
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {inspect(key), value}
    end)
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
