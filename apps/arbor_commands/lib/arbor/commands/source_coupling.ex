defmodule Arbor.Commands.SourceCoupling do
  @moduledoc """
  Imperative shell for packaging source-coupling census (SPIKE-3B).

  Resolves paths with SafePath, loads Git blob inventory, runs pure Core,
  and optionally writes the baseline when explicitly requested.

  Production `run/1` only accepts CLI/production options. Synthetic inventory,
  Git runners, and compatibility file injection are test-only via
  `run_for_test/1` and are refused for `write_baseline` so baselines cannot
  claim canonical Git provenance from caller-supplied bytes.
  """

  alias Arbor.Commands.SourceCoupling.{Core, Encode, GitInventory}
  alias Arbor.Common.SafePath

  @default_baseline_rel "apps/arbor_commands/priv/packaging/source_coupling_baseline.v1.json"
  @integrations_rel "apps/arbor_integrations"

  # Public production option keys only (no synthetic injection).
  @production_opt_keys [
    :mode,
    :json,
    :root,
    :baseline,
    :compatibility_integrations,
    :unresolved_review,
    :allow_write
  ]

  @synthetic_opt_keys [:inventory, :run_git, :compatibility_files, :max_blob_bytes, :max_total_bytes]

  @type mode :: String.t()

  @doc """
  Execute census for production CLI use.

  Accepts only production options. Synthetic `inventory` / `run_git` /
  `compatibility_files` are rejected — use `run_for_test/1` in tests.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] ->
        do_run(opts, allow_synthetic: false)

      unexpected ->
        {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, "report")

    # Even in tests, write_baseline must not claim Git provenance from synthetic bytes.
    if mode == "write_baseline" and synthetic_present?(opts) do
      {:error, :write_baseline_requires_git_inventory}
    else
      do_run(opts, allow_synthetic: true)
    end
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  defp synthetic_present?(opts) do
    Enum.any?(@synthetic_opt_keys, &Keyword.has_key?(opts, &1))
  end

  defp do_run(opts, allow_synthetic: allow_synthetic) do
    mode = Keyword.get(opts, :mode, "report")
    json? = Keyword.get(opts, :json, false) == true
    output = if json?, do: "json", else: "human"

    with {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, baseline_path} <- resolve_baseline_path(root, Keyword.get(opts, :baseline)),
         {:ok, review} <- load_unresolved_review(root, Keyword.get(opts, :unresolved_review)),
         {:ok, inventory} <- load_inventory(root, opts, mode, allow_synthetic),
         {:ok, census} <- Core.new(inventory),
         {:ok, census} <- maybe_compat(census, root, opts, allow_synthetic),
         {:ok, baseline_raw} <- read_baseline_for_mode(baseline_path, mode),
         {:ok, compare_result} <- Core.compare(census, mode, baseline_raw, review) do
      report =
        census
        |> Core.show(compare_result)
        |> Map.put("output", output)

      case maybe_write_baseline(mode, baseline_path, compare_result, opts) do
        :ok ->
          {:ok, report}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Discover umbrella root from a starting directory."
  @spec discover_root(String.t()) :: {:ok, String.t()} | {:error, term()}
  def discover_root(start) when is_binary(start) do
    start = Path.expand(start)
    find_root(start)
  end

  def discover_root(_), do: {:error, :invalid_root}

  defp find_root(dir) do
    marker = Path.join([dir, "apps", "arbor_contracts", "mix.exs"])

    cond do
      File.regular?(marker) ->
        {:ok, Path.expand(dir)}

      Path.dirname(dir) == dir ->
        {:error, :umbrella_root_not_found}

      true ->
        find_root(Path.dirname(dir))
    end
  end

  defp resolve_root(nil), do: discover_root(File.cwd!())

  defp resolve_root(path) when is_binary(path) do
    case SafePath.validate(path) do
      :ok ->
        expanded = Path.expand(path)
        marker = Path.join([expanded, "apps", "arbor_contracts", "mix.exs"])

        if File.regular?(marker) do
          {:ok, expanded}
        else
          {:error, :invalid_root_marker}
        end

      {:error, reason} ->
        {:error, {:root_path, reason}}
    end
  end

  defp resolve_baseline_path(root, nil) do
    SafePath.safe_join(root, @default_baseline_rel)
  end

  defp resolve_baseline_path(root, path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      if SafePath.within?(path, root) do
        {:ok, Path.expand(path)}
      else
        {:error, :baseline_path_escape}
      end
    else
      SafePath.safe_join(root, path)
    end
  end

  defp load_unresolved_review(_root, nil), do: {:ok, %{}}

  defp load_unresolved_review(root, path) when is_binary(path) do
    with {:ok, abs} <- resolve_within_root(root, path),
         {:ok, bytes} <- File.read(abs),
         {:ok, decoded} <- Jason.decode(bytes),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :invalid_unresolved_review}
      {:error, reason} -> {:error, {:unresolved_review, reason}}
    end
  end

  defp resolve_within_root(root, path) do
    if String.starts_with?(path, "/") do
      if SafePath.within?(path, root), do: {:ok, Path.expand(path)}, else: {:error, :path_escape}
    else
      SafePath.resolve_within(path, root)
    end
  end

  defp load_inventory(root, opts, mode, allow_synthetic) do
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    case Keyword.get(opts, :inventory) do
      inv when is_map(inv) ->
        cond do
          mode == "write_baseline" ->
            {:error, :write_baseline_requires_git_inventory}

          allow_synthetic ->
            # Test-only: mark provenance as non-canonical so it is never mistaken
            # for a Git-backed write path.
            {:ok, Map.put(inv, :provenance_source, "test_injection")}

          true ->
            {:error, :synthetic_inventory_not_allowed}
        end

      nil ->
        if Keyword.has_key?(opts, :run_git) and not allow_synthetic do
          {:error, :synthetic_run_git_not_allowed}
        else
          case GitInventory.load_canonical(root, git_opts) do
            {:ok, inv} ->
              {:ok, Map.put(inv, :provenance_source, "git_index_blobs")}

            other ->
              other
          end
        end
    end
  end

  defp maybe_compat(census, root, opts, allow_synthetic) do
    if Keyword.get(opts, :compatibility_integrations, false) do
      compat_files =
        case Keyword.get(opts, :compatibility_files) do
          list when is_list(list) and allow_synthetic ->
            {:ok, list}

          list when is_list(list) and not allow_synthetic ->
            {:error, :synthetic_compatibility_files_not_allowed}

          nil ->
            load_compatibility(root)
        end

      case compat_files do
        {:ok, []} ->
          {:ok,
           Map.put(census, "compatibility", %{
             "file_count" => 0,
             "gating" => false,
             "note" => "absent_or_empty",
             "source" => "private_opt_in"
           })}

        {:ok, files} ->
          with {:ok, projection} <- Core.project_compatibility(files, census) do
            {:ok, Map.put(census, "compatibility", projection)}
          end

        {:error, reason} ->
          {:error, {:compatibility, reason}}
      end
    else
      {:ok, Map.put(census, "compatibility", nil)}
    end
  end

  defp load_compatibility(root) do
    case SafePath.safe_join(root, @integrations_rel) do
      {:ok, base} ->
        if File.dir?(base) do
          paths =
            Path.wildcard(Path.join(base, "{mix.exs,lib/**/*.{ex,exs}}"))
            |> Enum.filter(&File.regular?/1)

          Enum.reduce_while(paths, {:ok, []}, fn abs, {:ok, acc} ->
            rel =
              abs
              |> Path.expand()
              |> Path.relative_to(root)

            case SafePath.resolve_within(rel, root) do
              {:ok, _} ->
                case File.read(abs) do
                  {:ok, bytes} ->
                    # Synthetic oid for opt-in FS scan only (never canonical baseline).
                    oid =
                      :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

                    entry = %{
                      path: rel,
                      blob_oid: oid,
                      bytes: bytes
                    }

                    {:cont, {:ok, [entry | acc]}}

                  {:error, reason} ->
                    {:halt, {:error, {:compat_read, rel, reason}}}
                end

              {:error, _} ->
                {:halt, {:error, :compat_path_escape}}
            end
          end)
          |> case do
            {:ok, list} -> {:ok, Enum.reverse(list)}
            err -> err
          end
        else
          {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_baseline_for_mode(path, mode) do
    cond do
      mode == "report" ->
        {:ok, read_baseline_map(path)}

      mode == "write_baseline" ->
        {:ok, read_baseline_map(path)}

      mode == "check" ->
        case read_baseline_map(path) do
          map when is_map(map) -> {:ok, map}
          nil -> {:error, :baseline_missing}
          :invalid -> {:error, :baseline_invalid}
        end

      true ->
        {:error, :invalid_mode}
    end
  end

  defp read_baseline_map(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, bytes} ->
          case Jason.decode(bytes) do
            {:ok, map} when is_map(map) -> map
            _ -> :invalid
          end

        _ ->
          :invalid
      end
    else
      nil
    end
  end

  defp maybe_write_baseline("write_baseline", path, compare_result, opts) do
    if Keyword.get(opts, :allow_write, true) do
      case compare_result["write_plan"] do
        plan when is_map(plan) ->
          with {:ok, bytes} <- Encode.encode_baseline(plan),
               :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, bytes) do
            :ok
          else
            {:error, reason} -> {:error, {:baseline_write, reason}}
          end

        _ ->
          {:error, :missing_write_plan}
      end
    else
      {:error, :write_not_allowed}
    end
  end

  defp maybe_write_baseline(_mode, _path, _compare, _opts), do: :ok
end
