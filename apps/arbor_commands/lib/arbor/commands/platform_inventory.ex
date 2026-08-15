defmodule Arbor.Commands.PlatformInventory do
  @moduledoc """
  Imperative shell for the Platform (E0A) source inventory.

  Production reads exact stage-0 Git blobs for the closed Platform app set and
  optionally compares them with a reviewed classification list. `run/1` admits
  only CLI-facing options; synthetic inventory and classifications are confined
  to `run_for_test/1`.

  Review files are repo-contained regular files with no symlink redirection.
  The 32 MiB ceiling is a protective outer bound over Encode's 5,000 rows times
  its 4,000-byte rationale limit, with room for JSON structure and other fields.
  """

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.PlatformInventory.{Core, Encode}
  alias Arbor.Commands.SourceCoupling.GitInventory
  alias Arbor.Common.SafePath

  @default_review_rel "apps/arbor_commands/priv/packaging/platform_inventory_classifications.v1.json"
  @max_review_bytes 32 * 1024 * 1024

  @production_opt_keys MapSet.new([:mode, :json, :root, :review])
  @test_opt_keys MapSet.union(@production_opt_keys, MapSet.new([:inventory, :classifications]))

  @default_opts %{mode: "report", json: false, root: nil, review: nil}

  @doc """
  Build a Platform inventory report from trusted repository inputs.

  Accepted options are `:mode`, `:json`, `:root`, and `:review` only.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, admitted, seen} <- admit_options(opts, :production) do
      do_run(admitted, seen, allow_synthetic: false)
    end
  end

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) do
    with {:ok, admitted, seen} <- admit_options(opts, :test) do
      do_run(admitted, seen, allow_synthetic: true)
    end
  end

  @doc false
  @spec default_review_path() :: String.t()
  def default_review_path, do: @default_review_rel

  @doc false
  @spec max_review_bytes() :: pos_integer()
  def max_review_bytes, do: @max_review_bytes

  defp do_run(opts, seen, allow_synthetic: allow_synthetic) do
    output = if opts.json, do: "json", else: "human"

    with {:ok, root} <- resolve_root(opts.root),
         {:ok, inventory} <- load_inventory(root, opts, seen, allow_synthetic),
         {:ok, classifications} <- load_classifications(root, opts, seen, allow_synthetic),
         bundle <- put_classifications(inventory, classifications),
         {:ok, report} <- Core.project(bundle) do
      Core.show(report, mode: opts.mode, output: output)
    end
  end

  defp resolve_root(path) do
    with {:ok, root} <- PackagingRoot.resolve(path),
         {:ok, real_root} <- SafePath.resolve_real(root) do
      {:ok, real_root}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, _} = error -> error
    end
  end

  defp load_inventory(root, opts, seen, true) do
    if MapSet.member?(seen, :inventory) do
      {:ok, opts.inventory}
    else
      load_git_inventory(root)
    end
  end

  defp load_inventory(root, _opts, _seen, false), do: load_git_inventory(root)

  defp load_git_inventory(root) do
    GitInventory.load_selected_blobs(root, Core.platform_apps(), [])
  end

  defp load_classifications(root, opts, seen, true) do
    if MapSet.member?(seen, :classifications) do
      if MapSet.member?(seen, :review) and not is_nil(opts.review) do
        {:error, :conflicting_classification_sources}
      else
        validate_injected_classifications(opts.classifications)
      end
    else
      load_review(root, opts.review)
    end
  end

  defp load_classifications(root, opts, _seen, false), do: load_review(root, opts.review)

  defp validate_injected_classifications(classifications) do
    case Encode.validate_classification_list(classifications) do
      {:ok, admitted} -> {:ok, admitted}
      {:error, reason} -> {:error, {:invalid_classifications, reason}}
    end
  end

  defp put_classifications(bundle, classifications) when is_map(bundle) do
    keys = Map.keys(bundle)

    if keys != [] and Enum.all?(keys, &is_binary/1) do
      Map.put(bundle, "classifications", classifications)
    else
      Map.put(bundle, :classifications, classifications)
    end
  end

  defp load_review(root, nil) do
    with {:ok, path} <- resolve_review_path(root, @default_review_rel) do
      read_review(path, required: false)
    end
  end

  defp load_review(root, path) when is_binary(path) do
    with {:ok, path} <- resolve_review_path(root, path) do
      read_review(path, required: true)
    end
  end

  defp resolve_review_path(root, path) do
    case SafePath.resolve_within(path, root) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _reason} -> {:error, :review_path_escape}
    end
  end

  defp read_review(path, required: required) do
    case SafePath.resolve_real(path) do
      {:ok, ^path} -> read_regular_review(path)
      {:ok, _redirected} -> {:error, :review_symlink_redirection}
      {:error, :not_found} when not required -> {:ok, []}
      {:error, :not_found} -> {:error, :review_missing}
      {:error, reason} -> {:error, {:review_realpath, reason}}
    end
  end

  defp read_regular_review(path) do
    with {:ok, stat} <- stat_review(path),
         :ok <- require_regular(stat),
         :ok <- require_bounded_size(stat),
         {:ok, bytes} <- read_review_bytes(path),
         {:ok, decoded} <- decode_review(bytes) do
      validate_review(decoded)
    end
  end

  defp stat_review(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:review_stat, reason}}
    end
  end

  defp require_regular(%File.Stat{type: :regular}), do: :ok
  defp require_regular(%File.Stat{}), do: {:error, :review_not_regular}

  defp require_bounded_size(%File.Stat{size: size}) when size <= @max_review_bytes, do: :ok
  defp require_bounded_size(%File.Stat{}), do: {:error, :review_too_large}

  defp read_review_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:review_read, reason}}
    end
  end

  defp decode_review(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :review_invalid_json}
    end
  end

  defp validate_review(decoded) do
    case Encode.validate_classification_list(decoded) do
      {:ok, admitted} -> {:ok, admitted}
      {:error, reason} -> {:error, {:review_invalid, reason}}
    end
  end

  defp admit_options(opts, kind) when is_list(opts) do
    allowed = if kind == :production, do: @production_opt_keys, else: @test_opt_keys

    Enum.reduce_while(opts, {:ok, @default_opts, MapSet.new()}, fn option,
                                                                   {:ok, admitted, seen} ->
      admit_option(option, admitted, seen, allowed, kind)
    end)
  end

  defp admit_options(_opts, _kind), do: {:error, :invalid_opts}

  defp admit_option({key, value}, admitted, seen, allowed, kind) when is_atom(key) do
    cond do
      MapSet.member?(seen, key) ->
        {:halt, {:error, {:duplicate_option, key}}}

      not MapSet.member?(allowed, key) ->
        {:halt, unknown_option(kind, key)}

      true ->
        case validate_option(key, value) do
          :ok ->
            {:cont, {:ok, Map.put(admitted, key, value), MapSet.put(seen, key)}}

          {:error, _} = error ->
            {:halt, error}
        end
    end
  end

  defp admit_option(_option, _admitted, _seen, _allowed, _kind),
    do: {:halt, {:error, :invalid_opts}}

  defp unknown_option(:production, key),
    do: {:error, {:production_opts_forbid_synthetic, [key]}}

  defp unknown_option(:test, key), do: {:error, {:unknown_option, key}}

  defp validate_option(:mode, mode) when mode in ["report", "check"], do: :ok
  defp validate_option(:json, json) when is_boolean(json), do: :ok
  defp validate_option(key, nil) when key in [:root, :review], do: :ok
  defp validate_option(key, value) when key in [:root, :review] and is_binary(value), do: :ok

  defp validate_option(:inventory, inventory) when is_map(inventory) and not is_struct(inventory),
    do: :ok

  defp validate_option(:classifications, classifications) when is_list(classifications), do: :ok
  defp validate_option(key, _value), do: {:error, {:invalid_option, key}}
end
