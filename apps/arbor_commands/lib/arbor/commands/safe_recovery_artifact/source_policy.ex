defmodule Arbor.Commands.SafeRecoveryArtifact.SourcePolicy do
  @moduledoc false

  @app_roots [
    "apps/arbor_kernel/",
    "apps/arbor_kernel_runtime/",
    "apps/arbor_security/",
    "apps/arbor_persistence/",
    "apps/arbor_trust/"
  ]
  @app_names ~w(arbor_kernel arbor_kernel_runtime arbor_security arbor_persistence arbor_trust)
  @ignored_generated_dirs ~w(.elixir_ls cover)

  @required_files [
    "apps/arbor_kernel/mix.exs",
    "apps/arbor_kernel_runtime/mix.exs",
    "apps/arbor_security/mix.exs",
    "apps/arbor_persistence/mix.exs",
    "apps/arbor_trust/mix.exs",
    "build_support/mix_project_paths.exs",
    "config/config.exs",
    "config/prod.exs",
    "config/provider_route_profile.exs",
    "config/runtime.exs",
    "bin/mix",
    ".tool-versions",
    "mix.lock"
  ]

  @excluded_paths MapSet.new([
                    "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
                    "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"
                  ])

  @regular_modes MapSet.new(["100644", "100755"])
  @symlink_mode "120000"
  @max_path_bytes 4_096
  @max_component_bytes 255
  @max_path_depth 48
  @required_set MapSet.new(@required_files)
  @max_source_rows 4_999

  @type blob_triple :: %{path: String.t(), mode: String.t(), oid: String.t()}

  @spec required_files() :: [String.t()]
  def required_files, do: @required_files

  @spec excluded_paths() :: MapSet.t(String.t())
  def excluded_paths, do: @excluded_paths

  @spec app_roots() :: [String.t()]
  def app_roots, do: @app_roots

  @spec max_source_rows() :: pos_integer()
  def max_source_rows, do: @max_source_rows

  @spec selected_path?(String.t()) :: boolean()
  def selected_path?(path) when is_binary(path) do
    MapSet.member?(@required_set, path) or under_app_root?(path)
  end

  def selected_path?(_path), do: false

  @doc false
  @spec ignored_generated_extra?(String.t()) :: boolean()
  def ignored_generated_extra?(path) when is_binary(path) do
    case String.split(path, "/", trim: false) do
      ["apps", app, generated | _rest]
      when app in @app_names and generated in @ignored_generated_dirs ->
        true

      ["apps", app, "erl_crash.dump"] when app in @app_names ->
        true

      _other ->
        false
    end
  end

  def ignored_generated_extra?(_path), do: false

  @spec select(term()) :: {:ok, [String.t()]} | {:error, term()}
  def select(triples) when is_list(triples) do
    triples
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn triple, {:ok, acc, seen} ->
      admit_triple(triple, acc, seen)
    end)
    |> case do
      {:ok, acc, _seen} -> finish_selection(acc)
      {:error, _reason} = error -> error
    end
  end

  def select(_triples), do: {:error, :invalid_path}

  defp admit_triple(%{path: path, mode: mode, oid: _oid} = triple, acc, seen)
       when is_binary(path) and is_binary(mode) do
    cond do
      MapSet.member?(@excluded_paths, path) ->
        {:cont, {:ok, acc, seen}}

      not selected_candidate?(path) ->
        {:cont, {:ok, acc, seen}}

      MapSet.member?(seen, path) ->
        {:halt, {:error, :extra_required_input}}

      true ->
        case admit_selected_blob(triple) do
          :ok -> {:cont, {:ok, [path | acc], MapSet.put(seen, path)}}
          {:error, _reason} = error -> {:halt, error}
        end
    end
  end

  defp admit_triple(_triple, _acc, _seen), do: {:halt, {:error, :invalid_path}}

  defp selected_candidate?(path) do
    MapSet.member?(@required_set, path) or under_app_root?(path)
  end

  defp under_app_root?(path) do
    Enum.any?(@app_roots, &String.starts_with?(path, &1))
  end

  defp admit_selected_blob(%{path: path, mode: mode}) do
    with :ok <- admit_path(path) do
      cond do
        mode == @symlink_mode ->
          {:error, :symlink_input}

        MapSet.member?(@regular_modes, mode) ->
          :ok

        true ->
          {:error, :unsupported_mode}
      end
    end
  end

  defp admit_path(path) when is_binary(path) do
    segments = String.split(path, "/", trim: false)

    cond do
      path == "" ->
        {:error, :invalid_path}

      not String.valid?(path) ->
        {:error, :invalid_path}

      String.contains?(path, <<0>>) ->
        {:error, :invalid_path}

      String.contains?(path, "\\") ->
        {:error, :invalid_path}

      Path.type(path) != :relative ->
        {:error, :invalid_path}

      byte_size(path) > @max_path_bytes ->
        {:error, :invalid_path}

      length(segments) > @max_path_depth ->
        {:error, :invalid_path}

      Enum.any?(segments, &(&1 in ["", ".", ".."] or String.downcase(&1) == ".git")) ->
        {:error, :invalid_path}

      Enum.any?(segments, &(byte_size(&1) > @max_component_bytes)) ->
        {:error, :invalid_path}

      true ->
        :ok
    end
  end

  defp admit_path(_path), do: {:error, :invalid_path}

  defp finish_selection(paths) do
    missing = Enum.reject(@required_files, &(&1 in paths))

    cond do
      missing != [] ->
        {:error, :missing_required_input}

      Enum.any?(paths, &MapSet.member?(@excluded_paths, &1)) ->
        {:error, :extra_required_input}

      length(paths) > @max_source_rows ->
        {:error, :file_limit}

      true ->
        {:ok, Enum.sort(paths)}
    end
  end
end
