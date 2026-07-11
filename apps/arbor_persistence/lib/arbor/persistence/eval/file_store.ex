defmodule Arbor.Persistence.Eval.FileStore do
  @moduledoc false

  # Internal JSON file store for eval run results.
  # Public access is via Arbor.Persistence only.
  #
  # Security contract:
  # - Closed ASCII run-id grammar (no traversal / percent / absolute paths)
  # - Root is a **trusted private directory** (operator-owned, not attacker-
  #   mutable). OTP has no openat/O_NOFOLLOW publish primitive that fully
  #   eliminates rename races against a hostile concurrent root mutator, so
  #   we fail closed on identity changes and document the assumption rather
  #   than claiming "never follow symlinks" in absolute terms.
  # - Root + path containment via SafePath; reject symlink leaves/roots when
  #   detectable; re-check device/inode/type/size/mtime/ctime identities
  # - Atomic exclusive temp publish (mode 0600) + fsync + rename + dir fsync
  # - Budgeted encode (depth/node/string/key/estimated-byte) before iodata
  #   materialization; non-bypassable ceilings on file size / file count /
  #   aggregate bytes
  # - Load/list bind decoded "id" exactly to the validated filename run_id

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

  # Encode traversal budgets (relative to max_file_bytes / hard ceilings)
  @max_encode_depth 32
  @max_encode_nodes 50_000
  @max_string_bytes 1_048_576
  @max_object_keys 10_000

  # Directory name-list multiplier under the trusted-root contract: OTP's
  # File.ls/1 materializes the full name list. We still refuse to *process*
  # more than max_files run candidates and refuse directories whose total
  # name count exceeds a multiple of max_files (DoS signal / overpopulation).
  @dir_name_slack 4
  @ceiling_dir_names 8_000

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
         {:ok, root_state} <- prepare_root(opts, create?: true),
         {:ok, target} <- contained_run_path(root_state.path, run_id),
         :ok <- reject_symlink_target(target),
         {:ok, json} <- encode_bounded(run_data, run_id, opts),
         :ok <- assert_root_stable(root_state) do
      atomic_publish(root_state, target, json)
    end
  end

  @spec load_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_run(run_id, opts \\ []) do
    with :ok <- validate_run_id(run_id),
         {:ok, root_state} <- prepare_root(opts, create?: false),
         {:ok, path} <- contained_run_path(root_state.path, run_id),
         {:ok, content} <- read_regular_file_bounded(path, opts),
         :ok <- assert_root_stable(root_state),
         {:ok, data} <- decode_json(content),
         {:ok, bound} <- bind_run_id(data, run_id) do
      {:ok, bound}
    end
  end

  @spec list_runs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_runs(opts \\ []) do
    model_filter = filter_string(Keyword.get(opts, :model))
    provider_filter = filter_string(Keyword.get(opts, :provider))
    max_files = bound(opts, :max_files, @default_max_files, @ceiling_max_files)
    max_total = bound(opts, :max_total_bytes, @default_max_total_bytes, @ceiling_max_total_bytes)

    case prepare_root(opts, create?: false) do
      {:ok, root_state} ->
        case list_json_entries(root_state, max_files) do
          {:ok, entries} ->
            with {:ok, runs} <-
                   decode_listed(
                     entries,
                     max_files,
                     max_total,
                     model_filter,
                     provider_filter,
                     opts
                   ),
                 :ok <- assert_root_stable(root_state) do
              {:ok, runs}
            end

          {:error, :enoent} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
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
  # Root / path (trusted private root + identity)
  # ---------------------------------------------------------------------------

  defp prepare_root(opts, create?: create?) do
    dir = Keyword.get(opts, :dir, @default_dir)

    if not is_binary(dir) or dir == "" do
      {:error, :invalid_dir}
    else
      abs = Path.expand(dir)

      mkdir_result =
        if create? do
          # Least-privilege directory creation (0700). mkdir_p does not set
          # mode on intermediate parents that already exist; we chmod the leaf.
          case File.mkdir_p(abs) do
            :ok ->
              case File.chmod(abs, 0o700) do
                :ok -> :ok
                {:error, reason} -> {:error, reason}
              end

            {:error, _} = err ->
              err
          end
        else
          :ok
        end

      case mkdir_result do
        :ok ->
          capture_root_state(abs)

        {:error, reason} ->
          {:error, {:file_error, reason}}
      end
    end
  end

  defp capture_root_state(abs) do
    case File.lstat(abs, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        case File.read_link(abs) do
          {:ok, _} ->
            {:error, :symlink_root}

          {:error, _} ->
            case usable_identity(stat) do
              :ok ->
                {:ok,
                 %{
                   path: abs,
                   identity: directory_identity(stat)
                 }}

              {:error, _} = err ->
                err
            end
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
  end

  defp assert_root_stable(%{path: path, identity: expected}) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        case File.read_link(path) do
          {:ok, _} ->
            {:error, :symlink_root}

          {:error, _} ->
            current = directory_identity(stat)

            if current == expected do
              :ok
            else
              {:error, :root_identity_changed}
            end
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_root}

      {:ok, _} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  # Root identity deliberately omits mtime/ctime/size: legitimate child creates
  # update directory timestamps. We still re-check type/device/inode so a root
  # swap (different mount/inode) fails closed.
  defp directory_identity(%File.Stat{} = stat) do
    %{
      type: stat.type,
      inode: stat.inode,
      major_device: stat.major_device,
      minor_device: stat.minor_device
    }
  end

  defp regular_identity(%File.Stat{type: :regular} = stat) do
    case usable_identity(stat) do
      :ok ->
        {:ok,
         %{
           type: stat.type,
           inode: stat.inode,
           major_device: stat.major_device,
           minor_device: stat.minor_device,
           size: stat.size,
           mtime: stat.mtime,
           ctime: stat.ctime
         }}

      {:error, _} = err ->
        err
    end
  end

  defp regular_identity(%File.Stat{type: :symlink}), do: {:error, :symlink_target}
  defp regular_identity(%File.Stat{}), do: {:error, :not_a_regular_file}

  defp usable_identity(%File.Stat{inode: inode, major_device: major}) do
    cond do
      not is_integer(inode) or inode <= 0 ->
        {:error, :unusable_inode}

      not is_integer(major) ->
        {:error, :unusable_inode}

      true ->
        :ok
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
    case File.lstat(path, time: :posix) do
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
  # Budgeted encode — traverse before Jason materialization
  # ---------------------------------------------------------------------------

  defp encode_bounded(run_data, run_id, opts) when is_map(run_data) do
    max_bytes = bound(opts, :max_file_bytes, @default_max_file_bytes, @ceiling_max_file_bytes)

    with {:ok, timestamp} <- resolve_timestamp(run_data),
         {:ok, body} <- strip_id_and_timestamp(run_data) do
      # Persist exactly one string-key "id" and "timestamp" (no atom aliases).
      payload =
        body
        |> Map.put("id", run_id)
        |> Map.put("timestamp", timestamp)

      with {:ok, _estimated} <- budget_check(payload, max_bytes) do
        case Jason.encode_to_iodata(payload, pretty: true) do
          {:ok, iodata} ->
            # Flatten only after encode, still under hard ceiling.
            size = IO.iodata_length(iodata)

            if size > max_bytes or size > @ceiling_max_file_bytes do
              {:error, :max_file_bytes_exceeded}
            else
              {:ok, IO.iodata_to_binary(iodata)}
            end

          {:error, reason} ->
            {:error, {:encode_error, reason}}
        end
      end
    end
  end

  defp resolve_timestamp(run_data) do
    case fetch_timestamp(run_data) do
      {:ok, ts} -> {:ok, ts}
      :missing -> {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}
      {:error, _} = err -> err
    end
  end

  defp fetch_timestamp(data) do
    atom? = Map.has_key?(data, :timestamp)
    str? = Map.has_key?(data, "timestamp")

    cond do
      atom? and str? and data[:timestamp] != data["timestamp"] ->
        {:error, :duplicate_json_key}

      atom? and str? ->
        normalize_timestamp(data[:timestamp])

      atom? ->
        normalize_timestamp(data[:timestamp])

      str? ->
        normalize_timestamp(data["timestamp"])

      true ->
        :missing
    end
  end

  defp normalize_timestamp(ts) when is_binary(ts) do
    if String.valid?(ts) and byte_size(ts) <= 64 do
      {:ok, ts}
    else
      {:error, :invalid_timestamp}
    end
  end

  defp normalize_timestamp(_), do: {:error, :invalid_timestamp}

  defp strip_id_and_timestamp(data) do
    # Reject ambiguous dual id/timestamp *values*, then drop both key forms so
    # the encoder emits exactly one string-key each.
    with :ok <- reject_conflicting_aliases(data, :id, "id"),
         :ok <- reject_conflicting_aliases(data, :timestamp, "timestamp") do
      cleaned =
        data
        |> Map.delete(:id)
        |> Map.delete("id")
        |> Map.delete(:timestamp)
        |> Map.delete("timestamp")

      {:ok, cleaned}
    end
  end

  defp reject_conflicting_aliases(data, atom_key, str_key) do
    atom? = Map.has_key?(data, atom_key)
    str? = Map.has_key?(data, str_key)

    cond do
      atom? and str? and data[atom_key] != data[str_key] ->
        {:error, :duplicate_json_key}

      true ->
        :ok
    end
  end

  defp budget_check(value, max_bytes) do
    budget = %{
      max_bytes: max_bytes,
      max_depth: @max_encode_depth,
      max_nodes: min(@max_encode_nodes, max_bytes),
      max_string_bytes: min(@max_string_bytes, max_bytes),
      max_keys: @max_object_keys,
      nodes: 0,
      estimated: 0
    }

    case walk_budget(value, 0, budget) do
      {:ok, final} when final.estimated > max_bytes ->
        {:error, :max_file_bytes_exceeded}

      {:ok, final} ->
        {:ok, final.estimated}

      {:error, _} = err ->
        err
    end
  end

  defp walk_budget(value, depth, budget) when is_map(value) do
    cond do
      depth > budget.max_depth ->
        {:error, :max_encode_depth_exceeded}

      budget.nodes + 1 > budget.max_nodes ->
        {:error, :max_encode_nodes_exceeded}

      map_size(value) > budget.max_keys ->
        {:error, :max_object_keys_exceeded}

      true ->
        case canonicalize_object_keys(value) do
          {:ok, pairs} ->
            budget = %{budget | nodes: budget.nodes + 1, estimated: budget.estimated + 2}

            Enum.reduce_while(pairs, {:ok, budget}, fn {key, child}, {:ok, acc} ->
              key_cost = byte_size(key) + 3

              acc = %{
                acc
                | estimated: acc.estimated + key_cost,
                  nodes: acc.nodes + 1
              }

              cond do
                acc.nodes > acc.max_nodes ->
                  {:halt, {:error, :max_encode_nodes_exceeded}}

                acc.estimated > acc.max_bytes ->
                  {:halt, {:error, :max_file_bytes_exceeded}}

                true ->
                  case walk_budget(child, depth + 1, acc) do
                    {:ok, next} ->
                      next = %{next | estimated: next.estimated + 1}
                      {:cont, {:ok, next}}

                    {:error, _} = err ->
                      {:halt, err}
                  end
              end
            end)

          {:error, _} = err ->
            err
        end
    end
  end

  defp walk_budget(value, depth, budget) when is_list(value) do
    cond do
      depth > budget.max_depth ->
        {:error, :max_encode_depth_exceeded}

      budget.nodes + 1 > budget.max_nodes ->
        {:error, :max_encode_nodes_exceeded}

      true ->
        budget = %{budget | nodes: budget.nodes + 1, estimated: budget.estimated + 2}

        Enum.reduce_while(value, {:ok, budget}, fn item, {:ok, acc} ->
          case walk_budget(item, depth + 1, acc) do
            {:ok, next} ->
              next = %{next | estimated: next.estimated + 1}

              if next.estimated > next.max_bytes do
                {:halt, {:error, :max_file_bytes_exceeded}}
              else
                {:cont, {:ok, next}}
              end

            {:error, _} = err ->
              {:halt, err}
          end
        end)
    end
  end

  defp walk_budget(value, _depth, budget) when is_binary(value) do
    size = byte_size(value)

    cond do
      not String.valid?(value) ->
        {:error, :invalid_utf8}

      # Prefer the caller's file-byte budget when the string alone exceeds it.
      size > budget.max_bytes ->
        {:error, :max_file_bytes_exceeded}

      size > budget.max_string_bytes ->
        {:error, :max_string_bytes_exceeded}

      budget.nodes + 1 > budget.max_nodes ->
        {:error, :max_encode_nodes_exceeded}

      true ->
        # Quotes + conservative escape overhead (worst-case every byte escaped)
        estimated = budget.estimated + size * 2 + 2

        if estimated > budget.max_bytes do
          {:error, :max_file_bytes_exceeded}
        else
          {:ok, %{budget | nodes: budget.nodes + 1, estimated: estimated}}
        end
    end
  end

  defp walk_budget(value, _depth, budget) when is_integer(value) or is_float(value) do
    if budget.nodes + 1 > budget.max_nodes do
      {:error, :max_encode_nodes_exceeded}
    else
      {:ok, %{budget | nodes: budget.nodes + 1, estimated: budget.estimated + 24}}
    end
  end

  defp walk_budget(value, _depth, budget) when is_boolean(value) or is_nil(value) do
    if budget.nodes + 1 > budget.max_nodes do
      {:error, :max_encode_nodes_exceeded}
    else
      {:ok, %{budget | nodes: budget.nodes + 1, estimated: budget.estimated + 5}}
    end
  end

  defp walk_budget(value, depth, budget) when is_atom(value) do
    walk_budget(Atom.to_string(value), depth, budget)
  end

  defp walk_budget(_, _, _), do: {:error, :encode_unsupported_type}

  # Build sorted unique string keys; reject atom/string aliases that collide.
  defp canonicalize_object_keys(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}, []}, fn {k, v}, {:ok, seen, acc} ->
      key =
        cond do
          is_binary(k) and String.valid?(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> nil
        end

      cond do
        is_nil(key) ->
          {:halt, {:error, :encode_unsupported_key}}

        Map.has_key?(seen, key) ->
          {:halt, {:error, :duplicate_json_key}}

        true ->
          {:cont, {:ok, Map.put(seen, key, true), [{key, v} | acc]}}
      end
    end)
    |> case do
      {:ok, _seen, pairs} ->
        {:ok, Enum.sort_by(pairs, &elem(&1, 0))}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Atomic exclusive temp publish
  # ---------------------------------------------------------------------------

  defp atomic_publish(root_state, target, json) do
    root = root_state.path

    with :ok <- reject_symlink_ancestors(root, target),
         :ok <- assert_root_stable(root_state) do
      tmp =
        Path.join(
          root,
          ".eval-tmp-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}.json"
        )

      # Exclusive create. `{:mode, 0o600}` is accepted by OTP 28.4.1 but does
      # not reliably set permission bits under common umasks; enforce 0600 via
      # chmod on the exclusive temp path before rename.
      case :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]) do
        {:ok, io} ->
          try do
            case :file.write(io, json) do
              :ok ->
                case :file.sync(io) do
                  :ok ->
                    :ok = :file.close(io)

                    case File.chmod(tmp, 0o600) do
                      :ok ->
                        case File.rename(tmp, target) do
                          :ok ->
                            # Best-effort directory durability after rename.
                            _ = sync_directory(root)

                            case assert_root_stable(root_state) do
                              :ok -> :ok
                              {:error, _} = err -> err
                            end

                          {:error, reason} ->
                            _ = File.rm(tmp)
                            {:error, {:file_error, reason}}
                        end

                      {:error, reason} ->
                        _ = File.rm(tmp)
                        {:error, {:file_error, reason}}
                    end

                  {:error, reason} ->
                    _ = :file.close(io)
                    _ = File.rm(tmp)
                    {:error, {:file_error, reason}}
                end

              {:error, reason} ->
                _ = :file.close(io)
                _ = File.rm(tmp)
                {:error, {:file_error, reason}}
            end
          rescue
            e ->
              _ = :file.close(io)
              _ = File.rm(tmp)
              {:error, {:file_error, Exception.message(e)}}
          catch
            kind, reason ->
              _ = :file.close(io)
              _ = File.rm(tmp)
              {:error, {:file_error, {kind, reason}}}
          end

        {:error, reason} ->
          {:error, {:file_error, reason}}
      end
    end
  end

  defp sync_directory(root) do
    case :file.open(String.to_charlist(root), [:raw, :read]) do
      {:ok, dio} ->
        _ = :file.sync(dio)
        _ = :file.close(dio)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp reject_symlink_ancestors(root, target) do
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
  # Bounded read (single opened handle + identity recheck)
  # ---------------------------------------------------------------------------

  defp read_regular_file_bounded(path, opts) do
    max_bytes = bound(opts, :max_file_bytes, @default_max_file_bytes, @ceiling_max_file_bytes)

    case File.lstat(path, time: :posix) do
      {:error, :enoent} ->
        {:error, {:file_error, :enoent}}

      {:error, reason} ->
        {:error, {:file_error, reason}}

      {:ok, stat} ->
        case regular_identity(stat) do
          {:ok, expected} ->
            if is_integer(stat.size) and stat.size > max_bytes do
              {:error, :max_file_bytes_exceeded}
            else
              open_and_read_stable(path, max_bytes, expected)
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp open_and_read_stable(path, max_bytes, expected) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, info1} <- :file.read_file_info(io, time: :posix),
               stat1 = File.Stat.from_record(info1),
               {:ok, id1} <- regular_identity(stat1),
               true <- identity_match?(id1, expected) or {:error, :file_changed},
               {:ok, data} <- read_up_to(io, max_bytes),
               {:ok, info2} <- :file.read_file_info(io, time: :posix),
               stat2 = File.Stat.from_record(info2),
               {:ok, id2} <- regular_identity(stat2),
               true <- identity_match?(id2, expected) or {:error, :file_changed},
               # Pathname recheck (trusted-root race detection)
               {:ok, lstat} <- File.lstat(path, time: :posix),
               {:ok, id3} <- regular_identity(lstat),
               true <- identity_match?(id3, expected) or {:error, :file_changed} do
            {:ok, data}
          else
            {:error, _} = err ->
              err

            false ->
              {:error, :file_changed}

            other ->
              {:error, {:file_error, other}}
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

  defp identity_match?(a, b) when is_map(a) and is_map(b) do
    a.type == b.type and a.inode == b.inode and a.major_device == b.major_device and
      a.minor_device == b.minor_device
  end

  defp identity_match?(_, _), do: false

  defp read_up_to(io, max_bytes) do
    limit = max_bytes + 1

    case :file.read(io, limit) do
      {:ok, data} when byte_size(data) > max_bytes ->
        {:error, :max_file_bytes_exceeded}

      {:ok, data} ->
        {:ok, data}

      :eof ->
        {:ok, ""}

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

  # Bind decoded object "id" exactly to the validated filename/run_id.
  # Reject missing, mismatched, non-string, or ambiguous multi-id payloads.
  defp bind_run_id(data, run_id) when is_map(data) and is_binary(run_id) do
    # JSON decode only yields string keys; still guard against non-string ids.
    case Map.fetch(data, "id") do
      {:ok, ^run_id} ->
        # Ensure no secondary id channel (should not exist post-decode).
        if Map.has_key?(data, :id) and data[:id] != run_id do
          {:error, :run_id_mismatch}
        else
          {:ok, Map.put(data, "id", run_id)}
        end

      {:ok, other} when is_binary(other) ->
        {:error, :run_id_mismatch}

      {:ok, _} ->
        {:error, :run_id_mismatch}

      :error ->
        # Missing id: bind to filename (strict for integrity of list/load).
        {:error, :run_id_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # List with bounds — constrain enumeration under trusted-private-root
  # ---------------------------------------------------------------------------

  defp list_json_entries(root_state, max_files) do
    root = root_state.path

    # Trusted-private-root contract: File.ls/1 materializes all names. We
    # refuse overpopulated directories (total names) before any decode work,
    # then collect at most max_files valid run candidates while scanning.
    case File.ls(root) do
      {:ok, files} ->
        name_count = length(files)
        name_ceiling = min(@ceiling_dir_names, max(max_files * @dir_name_slack, max_files + 1))

        cond do
          name_count > name_ceiling ->
            {:error,
             {:max_files_exceeded,
              %{
                reason: :directory_overpopulated,
                name_count: name_count,
                name_ceiling: name_ceiling,
                max_files: max_files
              }}}

          true ->
            collect_entries(files, root, max_files, [], 0)
        end

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp collect_entries([], _root, _max_files, acc, _json_seen), do: {:ok, Enum.reverse(acc)}

  defp collect_entries([name | rest], root, max_files, acc, json_seen) do
    cond do
      not String.ends_with?(name, ".json") ->
        collect_entries(rest, root, max_files, acc, json_seen)

      String.starts_with?(name, ".") ->
        collect_entries(rest, root, max_files, acc, json_seen)

      true ->
        run_id = String.trim_trailing(name, ".json")

        case validate_run_id(run_id) do
          :ok ->
            path = Path.join(root, name)

            case File.lstat(path, time: :posix) do
              {:ok, %File.Stat{type: :regular}} ->
                json_seen = json_seen + 1

                if json_seen > max_files do
                  {:error,
                   {:max_files_exceeded,
                    %{
                      reason: :too_many_run_files,
                      seen: json_seen,
                      max_files: max_files
                    }}}
                else
                  collect_entries(rest, root, max_files, [{run_id, path} | acc], json_seen)
                end

              _ ->
                # Skip symlinks, dirs, unreadable — no follow
                collect_entries(rest, root, max_files, acc, json_seen)
            end

          _ ->
            collect_entries(rest, root, max_files, acc, json_seen)
        end
    end
  end

  defp decode_listed(entries, max_files, max_total, model_filter, provider_filter, opts) do
    # entries already constrained to max_files; still enforce while decoding.
    if length(entries) > max_files do
      {:error,
       {:max_files_exceeded,
        %{reason: :too_many_run_files, seen: length(entries), max_files: max_files}}}
    else
      do_decode_listed(entries, max_total, 0, [], model_filter, provider_filter, opts)
    end
  end

  defp do_decode_listed([], _max_total, _used, acc, model_filter, provider_filter, _opts) do
    runs =
      acc
      |> maybe_filter("model", model_filter)
      |> maybe_filter("provider", provider_filter)
      |> Enum.sort_by(&sort_timestamp/1, :desc)

    {:ok, runs}
  end

  defp do_decode_listed(
         [{run_id, path} | rest],
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
              case bind_run_id(data, run_id) do
                {:ok, bound} ->
                  do_decode_listed(
                    rest,
                    max_total,
                    used + size,
                    [bound | acc],
                    model_filter,
                    provider_filter,
                    opts
                  )

                {:error, _} ->
                  # Skip mismatched ids during list (do not fail whole list)
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

            {:error, _} ->
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
        do_decode_listed(rest, max_total, used, acc, model_filter, provider_filter, opts)
    end
  end

  defp maybe_filter(runs, _field, nil), do: runs

  defp maybe_filter(runs, field, value) when is_binary(field) and is_binary(value) do
    Enum.filter(runs, fn run -> run[field] == value end)
  end

  defp filter_string(nil), do: nil
  defp filter_string(v) when is_binary(v), do: v
  defp filter_string(v) when is_atom(v), do: Atom.to_string(v)
  defp filter_string(_), do: nil

  defp sort_timestamp(%{"timestamp" => ts}) when is_binary(ts), do: ts
  defp sort_timestamp(_), do: ""

  defp bound(opts, key, default, ceiling) do
    requested =
      case Keyword.get(opts, key, default) do
        n when is_integer(n) and n > 0 -> n
        _ -> default
      end

    min(requested, ceiling)
  end
end
