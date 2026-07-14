defmodule Arbor.Shell.Config do
  @moduledoc """
  Internal configuration facade for `arbor_shell`.

  Reads only Application environment values for this library. Performs no
  filesystem IO and never falls back to HOME, the current user, or service
  output when resolving Apple Container or Linux dependency-baseline locators.
  """

  @app :arbor_shell
  @max_path_bytes 4_096

  @logical_apple_container_keys [:kernel_path, :app_root]
  @allowed_apple_container_keys MapSet.new(
                                  @logical_apple_container_keys ++
                                    Enum.map(@logical_apple_container_keys, &Atom.to_string/1)
                                )

  @logical_linux_dependency_baseline_keys [:source_root, :manifest_path]
  @allowed_linux_dependency_baseline_keys MapSet.new(
                                            @logical_linux_dependency_baseline_keys ++
                                              Enum.map(
                                                @logical_linux_dependency_baseline_keys,
                                                &Atom.to_string/1
                                              )
                                          )

  # Closed image-policy surface mirrors AppleContainerAdmissionCore policy keys.
  @logical_image_policy_keys [
    :image,
    :manifest_digest,
    :vminit_image,
    :vminit_manifest_digest,
    :env,
    :labels,
    :mix_lock_digest,
    :baseline_tree_digest,
    :toolchain
  ]
  @allowed_image_policy_keys MapSet.new(
                               @logical_image_policy_keys ++
                                 Enum.map(@logical_image_policy_keys, &Atom.to_string/1)
                             )

  @logical_image_policy_toolchain_keys [:erlang, :elixir]
  @allowed_image_policy_toolchain_keys MapSet.new(
                                         @logical_image_policy_toolchain_keys ++
                                           Enum.map(
                                             @logical_image_policy_toolchain_keys,
                                             &Atom.to_string/1
                                           )
                                       )

  # Gross structural bounds only — semantic validation is AdmissionCore.
  @max_image_policy_map_keys 64
  @max_image_policy_string_bytes 4_096
  @max_image_policy_env_entries 64
  @max_image_policy_label_keys 32

  @type apple_container_config :: %{
          kernel_path: String.t(),
          app_root: String.t()
        }

  @type apple_container_error ::
          :apple_container_config_absent
          | :apple_container_config_malformed
          | :unknown_apple_container_config_key
          | :duplicate_apple_container_config_key
          | :missing_kernel_path
          | :missing_app_root
          | {:invalid_kernel_path, atom()}
          | {:invalid_app_root, atom()}

  @type linux_dependency_baseline_config :: %{
          source_root: String.t(),
          manifest_path: String.t()
        }

  @type linux_dependency_baseline_error ::
          :linux_dependency_baseline_config_absent
          | :linux_dependency_baseline_config_malformed
          | :unknown_linux_dependency_baseline_config_key
          | :duplicate_linux_dependency_baseline_config_key
          | :missing_source_root
          | :missing_manifest_path
          | {:invalid_source_root, atom()}
          | {:invalid_manifest_path, atom()}

  @type apple_container_image_policy :: %{
          image: String.t(),
          manifest_digest: String.t(),
          vminit_image: String.t(),
          vminit_manifest_digest: String.t(),
          env: [String.t()],
          labels: %{optional(String.t()) => String.t()},
          mix_lock_digest: String.t(),
          baseline_tree_digest: String.t(),
          toolchain: %{erlang: String.t(), elixir: String.t()}
        }

  @type apple_container_image_policy_error ::
          :apple_container_image_policy_config_absent
          | :apple_container_image_policy_config_malformed
          | :unknown_apple_container_image_policy_config_key
          | :duplicate_apple_container_image_policy_config_key
          | :missing_image
          | :missing_manifest_digest
          | :missing_vminit_image
          | :missing_vminit_manifest_digest
          | :missing_env
          | :missing_labels
          | :missing_mix_lock_digest
          | :missing_baseline_tree_digest
          | :missing_toolchain
          | :invalid_image
          | :invalid_manifest_digest
          | :invalid_vminit_image
          | :invalid_vminit_manifest_digest
          | :invalid_env
          | :invalid_labels
          | :invalid_mix_lock_digest
          | :invalid_baseline_tree_digest
          | :invalid_toolchain
          | :missing_toolchain_erlang
          | :missing_toolchain_elixir
          | :invalid_toolchain_erlang
          | :invalid_toolchain_elixir
          | :duplicate_image_policy_toolchain_key
          | :unknown_image_policy_toolchain_key
          | :image_policy_config_too_large
          | :image_policy_string_too_long
          | :image_policy_env_too_large
          | :image_policy_labels_too_large

  @doc """
  Read and validate the closed Apple Container operator locator config.

  Accepts only `kernel_path` and `app_root` as absolute, lexically canonical
  path strings. Rejects identities, bindings, evidence, module callbacks,
  platform overrides, and fixed executable path overrides.
  """
  @spec apple_container() ::
          {:ok, apple_container_config()} | {:error, apple_container_error()}
  def apple_container do
    case Application.get_env(@app, :apple_container) do
      nil ->
        {:error, :apple_container_config_absent}

      config ->
        normalize_apple_container(config)
    end
  end

  @doc """
  Read and validate the closed Linux dependency-baseline operator locator config.

  Accepts only `source_root` and `manifest_path` as absolute, lexically
  canonical path strings. Rejects identities, bindings, evidence, digests,
  readiness overrides, destination selection, and module injection.
  """
  @spec linux_dependency_baseline() ::
          {:ok, linux_dependency_baseline_config()}
          | {:error, linux_dependency_baseline_error()}
  def linux_dependency_baseline do
    case Application.get_env(@app, :linux_dependency_baseline) do
      nil ->
        {:error, :linux_dependency_baseline_config_absent}

      config ->
        normalize_linux_dependency_baseline(config)
    end
  end

  @doc """
  Read and validate the closed Apple Container image admission policy.

  Accepts the full operator policy surface consumed by
  `AppleContainerAdmissionCore` (image/manifest/vminit digests, env, labels,
  mix-lock/tree digests, toolchain). Structural atom/string aliases are
  normalized; labels remain string-keyed. Rejects execution aliases, baseline
  receipts, readiness, paths, module names, and authority callbacks.

  Gross size bounds apply before retention. Semantic validation (image shape,
  fixed attestation labels, digest grammar) is performed later by
  `AppleContainerAdmissionCore.execution_references/1`.
  """
  @spec apple_container_image_policy() ::
          {:ok, apple_container_image_policy()}
          | {:error, apple_container_image_policy_error()}
  def apple_container_image_policy do
    case Application.get_env(@app, :apple_container_image_policy) do
      nil ->
        {:error, :apple_container_image_policy_config_absent}

      config ->
        normalize_apple_container_image_policy(config)
    end
  end

  defp normalize_apple_container(config) when is_list(config) do
    if Keyword.keyword?(config) do
      config
      |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &accumulate_apple_container_pair/2)
      |> finish_apple_container()
    else
      {:error, :apple_container_config_malformed}
    end
  end

  defp normalize_apple_container(config) when is_map(config) do
    config
    |> Map.to_list()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &accumulate_apple_container_pair/2)
    |> finish_apple_container()
  end

  defp normalize_apple_container(_config), do: {:error, :apple_container_config_malformed}

  defp accumulate_apple_container_pair({key, value}, {:ok, acc, seen}) do
    case normalize_apple_container_key(key) do
      {:ok, logical} ->
        if MapSet.member?(seen, logical) do
          {:halt, {:error, :duplicate_apple_container_config_key}}
        else
          {:cont, {:ok, Map.put(acc, logical, value), MapSet.put(seen, logical)}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp normalize_apple_container_key(key) when is_atom(key) or is_binary(key) do
    if MapSet.member?(@allowed_apple_container_keys, key) do
      logical =
        case key do
          atom when is_atom(atom) -> atom
          "kernel_path" -> :kernel_path
          "app_root" -> :app_root
        end

      {:ok, logical}
    else
      {:error, :unknown_apple_container_config_key}
    end
  end

  defp normalize_apple_container_key(_key), do: {:error, :apple_container_config_malformed}

  defp finish_apple_container({:error, reason}), do: {:error, reason}

  defp finish_apple_container({:ok, acc, _seen}) do
    with {:ok, kernel_path} <-
           required_path(acc, :kernel_path, :missing_kernel_path, :invalid_kernel_path),
         {:ok, app_root} <- required_path(acc, :app_root, :missing_app_root, :invalid_app_root) do
      {:ok, %{kernel_path: kernel_path, app_root: app_root}}
    end
  end

  defp normalize_linux_dependency_baseline(config) when is_list(config) do
    if Keyword.keyword?(config) do
      config
      |> Enum.reduce_while(
        {:ok, %{}, MapSet.new()},
        &accumulate_linux_dependency_baseline_pair/2
      )
      |> finish_linux_dependency_baseline()
    else
      {:error, :linux_dependency_baseline_config_malformed}
    end
  end

  defp normalize_linux_dependency_baseline(config) when is_map(config) do
    config
    |> Map.to_list()
    |> Enum.reduce_while(
      {:ok, %{}, MapSet.new()},
      &accumulate_linux_dependency_baseline_pair/2
    )
    |> finish_linux_dependency_baseline()
  end

  defp normalize_linux_dependency_baseline(_config),
    do: {:error, :linux_dependency_baseline_config_malformed}

  defp accumulate_linux_dependency_baseline_pair({key, value}, {:ok, acc, seen}) do
    case normalize_linux_dependency_baseline_key(key) do
      {:ok, logical} ->
        if MapSet.member?(seen, logical) do
          {:halt, {:error, :duplicate_linux_dependency_baseline_config_key}}
        else
          {:cont, {:ok, Map.put(acc, logical, value), MapSet.put(seen, logical)}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp normalize_linux_dependency_baseline_key(key) when is_atom(key) or is_binary(key) do
    if MapSet.member?(@allowed_linux_dependency_baseline_keys, key) do
      logical =
        case key do
          atom when is_atom(atom) -> atom
          "source_root" -> :source_root
          "manifest_path" -> :manifest_path
        end

      {:ok, logical}
    else
      {:error, :unknown_linux_dependency_baseline_config_key}
    end
  end

  defp normalize_linux_dependency_baseline_key(_key),
    do: {:error, :linux_dependency_baseline_config_malformed}

  defp finish_linux_dependency_baseline({:error, reason}), do: {:error, reason}

  defp finish_linux_dependency_baseline({:ok, acc, _seen}) do
    with {:ok, source_root} <-
           required_path(acc, :source_root, :missing_source_root, :invalid_source_root),
         {:ok, manifest_path} <-
           required_path(
             acc,
             :manifest_path,
             :missing_manifest_path,
             :invalid_manifest_path
           ) do
      {:ok, %{source_root: source_root, manifest_path: manifest_path}}
    end
  end

  defp required_path(acc, key, missing, invalid) do
    case Map.fetch(acc, key) do
      :error ->
        {:error, missing}

      {:ok, value} ->
        case validate_locator_path(value) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {invalid, reason}}
        end
    end
  end

  # --- Apple container image policy ------------------------------------------

  defp normalize_apple_container_image_policy(config) when is_list(config) do
    if Keyword.keyword?(config) do
      if length(config) > @max_image_policy_map_keys do
        {:error, :image_policy_config_too_large}
      else
        config
        |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &accumulate_image_policy_pair/2)
        |> finish_image_policy()
      end
    else
      {:error, :apple_container_image_policy_config_malformed}
    end
  end

  defp normalize_apple_container_image_policy(config) when is_map(config) do
    if map_size(config) > @max_image_policy_map_keys do
      {:error, :image_policy_config_too_large}
    else
      config
      |> Map.to_list()
      |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &accumulate_image_policy_pair/2)
      |> finish_image_policy()
    end
  end

  defp normalize_apple_container_image_policy(_config),
    do: {:error, :apple_container_image_policy_config_malformed}

  defp accumulate_image_policy_pair({key, value}, {:ok, acc, seen}) do
    case normalize_image_policy_key(key) do
      {:ok, logical} ->
        if MapSet.member?(seen, logical) do
          {:halt, {:error, :duplicate_apple_container_image_policy_config_key}}
        else
          {:cont, {:ok, Map.put(acc, logical, value), MapSet.put(seen, logical)}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp normalize_image_policy_key(key) when is_atom(key) or is_binary(key) do
    if MapSet.member?(@allowed_image_policy_keys, key) do
      logical =
        case key do
          atom when is_atom(atom) -> atom
          "image" -> :image
          "manifest_digest" -> :manifest_digest
          "vminit_image" -> :vminit_image
          "vminit_manifest_digest" -> :vminit_manifest_digest
          "env" -> :env
          "labels" -> :labels
          "mix_lock_digest" -> :mix_lock_digest
          "baseline_tree_digest" -> :baseline_tree_digest
          "toolchain" -> :toolchain
        end

      {:ok, logical}
    else
      {:error, :unknown_apple_container_image_policy_config_key}
    end
  end

  defp normalize_image_policy_key(_key),
    do: {:error, :apple_container_image_policy_config_malformed}

  defp finish_image_policy({:error, reason}), do: {:error, reason}

  defp finish_image_policy({:ok, acc, _seen}) do
    with {:ok, image} <-
           required_bounded_string(acc, :image, :missing_image, :invalid_image),
         {:ok, manifest_digest} <-
           required_bounded_string(
             acc,
             :manifest_digest,
             :missing_manifest_digest,
             :invalid_manifest_digest
           ),
         {:ok, vminit_image} <-
           required_bounded_string(
             acc,
             :vminit_image,
             :missing_vminit_image,
             :invalid_vminit_image
           ),
         {:ok, vminit_manifest_digest} <-
           required_bounded_string(
             acc,
             :vminit_manifest_digest,
             :missing_vminit_manifest_digest,
             :invalid_vminit_manifest_digest
           ),
         {:ok, env} <- required_env_list(acc),
         {:ok, labels} <- required_labels_map(acc),
         {:ok, mix_lock_digest} <-
           required_bounded_string(
             acc,
             :mix_lock_digest,
             :missing_mix_lock_digest,
             :invalid_mix_lock_digest
           ),
         {:ok, baseline_tree_digest} <-
           required_bounded_string(
             acc,
             :baseline_tree_digest,
             :missing_baseline_tree_digest,
             :invalid_baseline_tree_digest
           ),
         {:ok, toolchain} <- required_toolchain(acc) do
      {:ok,
       %{
         image: image,
         manifest_digest: manifest_digest,
         vminit_image: vminit_image,
         vminit_manifest_digest: vminit_manifest_digest,
         env: env,
         labels: labels,
         mix_lock_digest: mix_lock_digest,
         baseline_tree_digest: baseline_tree_digest,
         toolchain: toolchain
       }}
    end
  end

  defp required_bounded_string(acc, key, missing, invalid) do
    case Map.fetch(acc, key) do
      :error ->
        {:error, missing}

      {:ok, value} when is_binary(value) ->
        cond do
          not String.valid?(value) ->
            {:error, invalid}

          byte_size(value) > @max_image_policy_string_bytes ->
            {:error, :image_policy_string_too_long}

          String.contains?(value, <<0>>) ->
            {:error, invalid}

          true ->
            {:ok, value}
        end

      {:ok, _other} ->
        {:error, invalid}
    end
  end

  defp required_env_list(acc) do
    case Map.fetch(acc, :env) do
      :error ->
        {:error, :missing_env}

      {:ok, env} when is_list(env) ->
        if length(env) > @max_image_policy_env_entries do
          {:error, :image_policy_env_too_large}
        else
          if Enum.all?(env, &is_binary/1) do
            Enum.reduce_while(env, {:ok, []}, fn entry, {:ok, collected} ->
              case bound_policy_string(entry, :invalid_env) do
                {:ok, ok} -> {:cont, {:ok, [ok | collected]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
            |> case do
              {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
              error -> error
            end
          else
            {:error, :invalid_env}
          end
        end

      {:ok, _other} ->
        {:error, :invalid_env}
    end
  end

  defp required_labels_map(acc) do
    case Map.fetch(acc, :labels) do
      :error ->
        {:error, :missing_labels}

      {:ok, labels} when is_map(labels) ->
        if map_size(labels) > @max_image_policy_label_keys do
          {:error, :image_policy_labels_too_large}
        else
          keys = Map.keys(labels)
          values = Map.values(labels)

          if Enum.all?(keys, &is_binary/1) and Enum.all?(values, &is_binary/1) do
            Enum.reduce_while(labels, {:ok, %{}}, fn {key, value}, {:ok, collected} ->
              with {:ok, ok_key} <- bound_policy_string(key, :invalid_labels),
                   {:ok, ok_value} <- bound_policy_string(value, :invalid_labels) do
                {:cont, {:ok, Map.put(collected, ok_key, ok_value)}}
              else
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
          else
            # Atom label keys are rejected — labels stay string-keyed only.
            {:error, :invalid_labels}
          end
        end

      {:ok, _other} ->
        {:error, :invalid_labels}
    end
  end

  defp required_toolchain(acc) do
    case Map.fetch(acc, :toolchain) do
      :error ->
        {:error, :missing_toolchain}

      {:ok, toolchain} when is_list(toolchain) ->
        if Keyword.keyword?(toolchain) do
          toolchain
          |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &accumulate_toolchain_pair/2)
          |> finish_toolchain()
        else
          {:error, :invalid_toolchain}
        end

      {:ok, toolchain} when is_map(toolchain) ->
        if map_size(toolchain) > @max_image_policy_map_keys do
          {:error, :image_policy_config_too_large}
        else
          toolchain
          |> Map.to_list()
          |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &accumulate_toolchain_pair/2)
          |> finish_toolchain()
        end

      {:ok, _other} ->
        {:error, :invalid_toolchain}
    end
  end

  defp accumulate_toolchain_pair({key, value}, {:ok, acc, seen}) do
    case normalize_toolchain_key(key) do
      {:ok, logical} ->
        if MapSet.member?(seen, logical) do
          {:halt, {:error, :duplicate_image_policy_toolchain_key}}
        else
          {:cont, {:ok, Map.put(acc, logical, value), MapSet.put(seen, logical)}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp normalize_toolchain_key(key) when is_atom(key) or is_binary(key) do
    if MapSet.member?(@allowed_image_policy_toolchain_keys, key) do
      logical =
        case key do
          atom when is_atom(atom) -> atom
          "erlang" -> :erlang
          "elixir" -> :elixir
        end

      {:ok, logical}
    else
      {:error, :unknown_image_policy_toolchain_key}
    end
  end

  defp normalize_toolchain_key(_key), do: {:error, :invalid_toolchain}

  defp finish_toolchain({:error, reason}), do: {:error, reason}

  defp finish_toolchain({:ok, acc, _seen}) do
    with {:ok, erlang} <-
           required_bounded_string(
             acc,
             :erlang,
             :missing_toolchain_erlang,
             :invalid_toolchain_erlang
           ),
         {:ok, elixir} <-
           required_bounded_string(
             acc,
             :elixir,
             :missing_toolchain_elixir,
             :invalid_toolchain_elixir
           ) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  defp bound_policy_string(value, invalid) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, invalid}

      byte_size(value) > @max_image_policy_string_bytes ->
        {:error, :image_policy_string_too_long}

      String.contains?(value, <<0>>) ->
        {:error, invalid}

      true ->
        {:ok, value}
    end
  end

  defp bound_policy_string(_value, invalid), do: {:error, invalid}

  # Lexical validation only — no filesystem IO and no HOME expansion.
  # Spaces are allowed (Apple's default app root contains them).
  defp validate_locator_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :empty_path}

      byte_size(path) > @max_path_bytes ->
        {:error, :path_too_long}

      not String.valid?(path) ->
        {:error, :invalid_utf8}

      String.contains?(path, <<0>>) ->
        {:error, :nul_byte}

      has_control_char?(path) ->
        {:error, :control_char}

      Path.type(path) != :absolute ->
        {:error, :relative_path}

      String.contains?(path, "//") ->
        {:error, :non_canonical_path}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, :trailing_slash}

      Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
        {:error, :dot_segment}

      true ->
        {:ok, path}
    end
  end

  defp validate_locator_path(_path), do: {:error, :invalid_path}

  defp has_control_char?(path) do
    path
    |> String.to_charlist()
    |> Enum.any?(fn
      c when c < 32 or c == 127 -> true
      _ -> false
    end)
  end
end
