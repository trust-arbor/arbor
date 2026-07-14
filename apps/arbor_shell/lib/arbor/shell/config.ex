defmodule Arbor.Shell.Config do
  @moduledoc """
  Internal configuration facade for `arbor_shell`.

  Reads only Application environment values for this library. Performs no
  filesystem IO and never falls back to HOME, the current user, or service
  output when resolving Apple Container locators.
  """

  @app :arbor_shell
  @max_path_bytes 4_096

  @logical_apple_container_keys [:kernel_path, :app_root]
  @allowed_apple_container_keys MapSet.new(
                                  @logical_apple_container_keys ++
                                    Enum.map(@logical_apple_container_keys, &Atom.to_string/1)
                                )

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
