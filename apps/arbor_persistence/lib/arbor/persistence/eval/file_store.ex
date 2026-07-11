defmodule Arbor.Persistence.Eval.FileStore do
  @moduledoc false

  # Internal JSON file store for eval run results.
  # Public access is via Arbor.Persistence only.
  #
  # Security properties:
  # - Closed ASCII run-id grammar (no traversal / percent / absolute paths)
  # - Root + path containment via SafePath; never follow symlinks
  # - Atomic exclusive temp publish (mode 0600) + rename
  # - Bounded per-file / file-count / aggregate decode budgets with
  #   non-bypassable system ceilings

  alias Arbor.Common.SafePath

  @default_dir ".arbor/eval_runs"

  # Defaults (caller opts may lower these; ceilings clamp upward attempts)
  @default_max_file_bytes 1_048_576
  @default_max_files 500
  @default_max_total_bytes 10_485_760

  # Non-bypassable system hard ceilings
  @ceiling_max_file_bytes 5_242_880
  @ceiling_max_files 2_000
  @ceiling_max_total_bytes 52_428_800

  @max_run_id_bytes 128
  # Single path component: starts alphanumeric, then [A-Za-z0-9._-], no dots-only,
  # no percent, no separators. Length 1..128.
  @run_id_re ~r/^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$/

  @type run_data :: map()

  @spec validate_run_id(term()) :: :ok | {:error, :invalid_run_id}
  def validate_run_id(run_id) when is_binary(run_id) do
    cond do
      run_id == "" ->
        {:error, :invalid_run_id}

      byte_size(run_id) > @max_run_id_bytes ->
        {:error, :invalid_run_id}

      not String.valid?(run_id) ->
        {:error, :invalid_run_id}

      String.contains?(run_id, <<0>>) ->
        {:error, :invalid_run_id}

      String.contains?(run_id, "/") or String.contains?(run_id, "\\") ->
        {:error, :invalid_run_id}

      String.contains?(run_id, "%") ->
        {:error, :invalid_run_id}

      String.contains?(run_id, "..") ->
        {:error, :invalid_run_id}

      run_id in [".", ".."] ->
        {:error, :invalid_run_id}

      not Regex.match?(@run_id_re, run_id) ->
        {:error, :invalid_run_id}

      true ->
        :ok
    end
  end

  def validate_run_id(_), do: {:error, :invalid_run_id}

  @spec save_run(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_run(run_id, run_data, opts \\ []) when is_map(run_data) do
    with :ok <- validate_run_id(run_id),
         {:ok, root} <- prepare_root(opts, create?: true),
         {:ok, target} <- contained_run_path(root, run_id),
         :ok <- reject_symlink_target(target),
         {:ok, json} <- encode_bounded(Map.put(run_data, :id, run_id), opts) do
      atomic_publish(root, target, json)
    end
  end

  @spec load_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_run(run_id, opts \\ []) do
    with :ok <- validate_run_id(run_id),
         {:ok, root} <- prepare_root(opts, create?: false),
         {:ok, path} <- contained_run_path(root, run_id),
         {:ok, content} <- read_regular_file_bounded(path, opts),
         {:ok, data} <- decode_json(content) do
      {:ok, data}
    end
  end

  @spec list_runs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_runs(opts \\ []) do
    model_filter = Keyword.get(opts, :model)
    provider_filter = Keyword.get(opts, :provider)
    max_files = bound(opts, :max_files, @default_max_files, @ceiling_max_files)
    max_total = bound(opts, :max_total_bytes, @default_max_total_bytes, @ceiling_max_total_bytes)

    case prepare_root(opts, create?: false) do
      {:ok, root} ->
        case list_json_entries(root) do
          {:ok, entries} ->
            decode_listed(
              entries,
              root,
              max_files,
              max_total,
              model_filter,
              provider_filter,
              opts
            )

          {:error, :enoent} ->
            {:ok, []}

          {:error, reason} ->
            {:error, {:file_error, reason}}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, {:file_error, :enoent}} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  @spec latest_run(keyword()) :: {:ok, map()} | {:error, term()}
  def latest_run(opts \\ []) do
    case list_runs(opts) do
      {:ok, [latest | _]} -> {:ok, latest}
      {:ok, []} -> {:error, :no_runs}
      {:error, _} = err -> err
    end
  end

  @spec compare_runs(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare_runs(run_id_a, run_id_b, opts \\ []) do
    with {:ok, run_a} <- load_run(run_id_a, opts),
         {:ok, run_b} <- load_run(run_id_b, opts) do
      metrics_a = run_a["metrics"] || %{}
      metrics_b = run_b["metrics"] || %{}

      all_keys = MapSet.union(MapSet.new(Map.keys(metrics_a)), MapSet.new(Map.keys(metrics_b)))

      diffs =
        Map.new(all_keys, fn key ->
          val_a = metrics_a[key] || 0.0
          val_b = metrics_b[key] || 0.0

          diff =
            if is_number(val_a) and is_number(val_b) do
              val_b - val_a
            else
              nil
            end

          {key, %{"run_a" => val_a, "run_b" => val_b, "diff" => diff}}
        end)

      {:ok,
       %{
         "run_a" => %{
           "id" => run_id_a,
           "model" => run_a["model"],
           "timestamp" => run_a["timestamp"]
         },
         "run_b" => %{
           "id" => run_id_b,
           "model" => run_b["model"],
           "timestamp" => run_b["timestamp"]
         },
         "metrics_diff" => diffs
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Root / path
  # ---------------------------------------------------------------------------

  defp prepare_root(opts, create?: create?) do
    dir = Keyword.get(opts, :dir, @default_dir)

    if not is_binary(dir) or dir == "" do
      {:error, :invalid_dir}
    else
      abs = Path.expand(dir)

      mkdir_result =
        if create? do
          File.mkdir_p(abs)
        else
          :ok
        end

      case mkdir_result do
        :ok ->
          case File.lstat(abs) do
            {:ok, %File.Stat{type: :directory}} ->
              case File.read_link(abs) do
                {:ok, _} -> {:error, :symlink_root}
                {:error, _} -> {:ok, abs}
              end

            {:ok, %File.Stat{type: :symlink}} ->
              {:error, :symlink_root}

            {:ok, _} ->
              {:error, :not_a_directory}

            {:error, :enoent} ->
              {:error, :enoent}

            {:error, reason} ->
              {:error, {:file_error, reason}}
          end

        {:error, reason} ->
          {:error, {:file_error, reason}}
      end
    end
  end

  defp contained_run_path(root, run_id) do
    filename = run_id <> ".json"

    case SafePath.safe_join(root, filename) do
      {:ok, path} ->
        # Extra defense: path must be a direct child of root
        if Path.dirname(path) == root do
          {:ok, path}
        else
          {:error, :invalid_run_id}
        end

      {:error, _} ->
        {:error, :invalid_run_id}
    end
  end

  defp reject_symlink_target(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_target}

      {:ok, _} ->
        {:error, :not_a_regular_file}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Encode / atomic publish
  # ---------------------------------------------------------------------------

  defp encode_bounded(run_data, opts) do
    max_bytes = bound(opts, :max_file_bytes, @default_max_file_bytes, @ceiling_max_file_bytes)

    data =
      run_data
      |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    case Jason.encode(data, pretty: true) do
      {:ok, json} when byte_size(json) > max_bytes ->
        {:error, :max_file_bytes_exceeded}

      {:ok, json} ->
        {:ok, json}

      {:error, reason} ->
        {:error, {:encode_error, reason}}
    end
  end

  defp atomic_publish(root, target, json) do
    # Reject symlink ancestors of target (root already checked)
    with :ok <- reject_symlink_ancestors(root, target) do
      tmp =
        Path.join(
          root,
          ".eval-tmp-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}.json"
        )

      # Exclusive create, mode 0600
      case :file.open(String.to_charlist(tmp), [:write, :binary, :exclusive, {:mode, 0o600}]) do
        {:ok, io} ->
          try do
            case :file.write(io, json) do
              :ok ->
                case :file.sync(io) do
                  :ok ->
                    :file.close(io)

                    case File.rename(tmp, target) do
                      :ok ->
                        :ok

                      {:error, reason} ->
                        _ = File.rm(tmp)
                        {:error, {:file_error, reason}}
                    end

                  {:error, reason} ->
                    :file.close(io)
                    _ = File.rm(tmp)
                    {:error, {:file_error, reason}}
                end

              {:error, reason} ->
                :file.close(io)
                _ = File.rm(tmp)
                {:error, {:file_error, reason}}
            end
          rescue
            e ->
              _ = :file.close(io)
              _ = File.rm(tmp)
              {:error, {:file_error, Exception.message(e)}}
          end

        {:error, reason} ->
          {:error, {:file_error, reason}}
      end
    end
  end

  defp reject_symlink_ancestors(root, target) do
    # Walk from target up to root; none may be symlinks
    do_reject_symlink_ancestors(target, root)
  end

  defp do_reject_symlink_ancestors(path, root) when path == root do
    case File.read_link(path) do
      {:ok, _} -> {:error, :symlink_root}
      {:error, _} -> :ok
    end
  end

  defp do_reject_symlink_ancestors(path, root) do
    case File.read_link(path) do
      {:ok, _} ->
        {:error, :symlink_in_path}

      {:error, _} ->
        parent = Path.dirname(path)

        if parent == path do
          :ok
        else
          do_reject_symlink_ancestors(parent, root)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Bounded read (single opened handle, no lstat-then-File.read TOCTOU)
  # ---------------------------------------------------------------------------

  defp read_regular_file_bounded(path, opts) do
    max_bytes = bound(opts, :max_file_bytes, @default_max_file_bytes, @ceiling_max_file_bytes)

    # lstat first so we never intentionally follow a symlink leaf. Baseline
    # inode/device is then re-checked on the opened handle so a TOCTOU swap
    # (regular→symlink→outside) cannot succeed: fstat of a followed open
    # would not match the pre-open lstat of the path.
    case File.lstat(path) do
      {:error, :enoent} ->
        {:error, {:file_error, :enoent}}

      {:error, reason} ->
        {:error, {:file_error, reason}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_target}

      {:ok, %File.Stat{type: type}} when type != :regular ->
        {:error, :not_a_regular_file}

      {:ok, %File.Stat{type: :regular, size: size, inode: inode, major_device: major}} ->
        cond do
          is_integer(size) and size > max_bytes ->
            {:error, :max_file_bytes_exceeded}

          true ->
            open_and_read_stable(path, max_bytes, inode, major)
        end
    end
  end

  defp open_and_read_stable(path, max_bytes, expected_inode, expected_major) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          case :file.read_file_info(io) do
            {:ok, info} ->
              # file_info record: size=1 type=2 ... major_device=9 inode=11
              type = elem(info, 2)
              major = elem(info, 9)
              inode = elem(info, 11)

              cond do
                type != :regular ->
                  {:error, :not_a_regular_file}

                inode != expected_inode or major != expected_major ->
                  # Path was replaced (e.g. with a symlink to an outside file)
                  {:error, :file_changed}

                true ->
                  limit = max_bytes + 1

                  case :file.read(io, limit) do
                    {:ok, data} when byte_size(data) > max_bytes ->
                      {:error, :max_file_bytes_exceeded}

                    {:ok, data} ->
                      case :file.read_file_info(io) do
                        {:ok, info2} ->
                          if elem(info2, 2) == :regular and elem(info2, 11) == expected_inode and
                               elem(info2, 9) == expected_major do
                            {:ok, data}
                          else
                            {:error, :file_changed}
                          end

                        {:error, reason} ->
                          {:error, {:file_error, reason}}
                      end

                    :eof ->
                      {:ok, ""}

                    {:error, reason} ->
                      {:error, {:file_error, reason}}
                  end
              end

            {:error, reason} ->
              {:error, {:file_error, reason}}
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, {:file_error, :enoent}}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp decode_json(content) when is_binary(content) do
    if not String.valid?(content) do
      {:error, :invalid_utf8}
    else
      case Jason.decode(content) do
        {:ok, data} when is_map(data) -> {:ok, data}
        {:ok, _} -> {:error, {:decode_error, :not_an_object}}
        {:error, reason} -> {:error, {:decode_error, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # List with bounds
  # ---------------------------------------------------------------------------

  defp list_json_entries(root) do
    case File.ls(root) do
      {:ok, files} ->
        # Filter candidate names without following links; then lstat each
        entries =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.flat_map(fn name ->
            path = Path.join(root, name)

            case File.lstat(path) do
              {:ok, %File.Stat{type: :regular}} ->
                run_id = String.trim_trailing(name, ".json")

                case validate_run_id(run_id) do
                  :ok -> [{run_id, path}]
                  _ -> []
                end

              _ ->
                # skip symlinks, dirs, invalid
                []
            end
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_listed(entries, _root, max_files, max_total, model_filter, provider_filter, opts) do
    if length(entries) > max_files do
      {:error, :max_files_exceeded}
    else
      do_decode_listed(entries, max_total, 0, [], model_filter, provider_filter, opts)
    end
  end

  defp do_decode_listed([], _max_total, _used, acc, model_filter, provider_filter, _opts) do
    runs =
      acc
      |> maybe_filter(:model, model_filter)
      |> maybe_filter(:provider, provider_filter)
      |> Enum.sort_by(& &1["timestamp"], :desc)

    {:ok, runs}
  end

  defp do_decode_listed(
         [{_run_id, path} | rest],
         max_total,
         used,
         acc,
         model_filter,
         provider_filter,
         opts
       ) do
    case read_regular_file_bounded(path, opts) do
      {:ok, content} ->
        size = byte_size(content)

        if used + size > max_total do
          {:error, :max_total_bytes_exceeded}
        else
          case decode_json(content) do
            {:ok, data} ->
              do_decode_listed(
                rest,
                max_total,
                used + size,
                [data | acc],
                model_filter,
                provider_filter,
                opts
              )

            {:error, _} ->
              # Skip corrupt individual files during list (don't fail whole list)
              do_decode_listed(
                rest,
                max_total,
                used + size,
                acc,
                model_filter,
                provider_filter,
                opts
              )
          end
        end

      {:error, :max_file_bytes_exceeded} ->
        {:error, :max_file_bytes_exceeded}

      {:error, _} ->
        # Skip unreadable entries
        do_decode_listed(rest, max_total, used, acc, model_filter, provider_filter, opts)
    end
  end

  defp maybe_filter(runs, _field, nil), do: runs

  defp maybe_filter(runs, field, value) do
    key = to_string(field)
    Enum.filter(runs, fn run -> run[key] == value end)
  end

  defp bound(opts, key, default, ceiling) do
    requested =
      case Keyword.get(opts, key, default) do
        n when is_integer(n) and n > 0 -> n
        _ -> default
      end

    min(requested, ceiling)
  end
end
