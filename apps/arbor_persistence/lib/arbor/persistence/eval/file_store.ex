defmodule Arbor.Persistence.Eval.FileStore do
  @moduledoc false

  # Internal JSON file store for eval run results.
  # Public access is via Arbor.Persistence only.
  #
  # Security contract:
  # - Closed ASCII run-id grammar (no traversal / percent / absolute paths)
  # - Root is a **trusted private directory** (operator-owned, mode without
  #   group/world bits). Existing roots are verified before any chmod or
  #   enumeration; insecure existing roots fail closed (never silently
  #   "fixed"). Missing roots are created, then lstat/verified/chmod'd only
  #   when the path is a real directory (never chmod a symlink target).
  # - OTP has no openat/O_NOFOLLOW publish primitive that fully eliminates
  #   rename races against a hostile concurrent root mutator. We fail closed
  #   on identity changes. File metadata checks (type/device/inode/size/
  #   mtime/ctime) are **best-effort under the trusted-root contract**, not
  #   proof against an owner restoring timestamps after same-inode mutation.
  # - Atomic exclusive temp publish (mode 0600) + file fsync + root-stable
  #   rename + post-rename identity verify. Directory fsync is unsupported
  #   on this pinned macOS/OTP host (`:eisdir` when opening a directory) and
  #   is treated as best-effort — not a crash-durability claim.
  # - Budgeted encode (depth/node/string/key/integer-bit/estimated-byte)
  #   before Jason materialization; non-bypassable ceilings on file size /
  #   file count / aggregate bytes
  # - Load/list bind decoded "id" exactly to the validated filename run_id
  # - Directory enumeration runs in a bounded monitored worker (heap / name /
  #   output / timeout ceilings); the caller never materializes File.ls

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
  # Hard integer bit ceiling (reject before decimal materialization / Jason).
  # 65536 bits ⇒ at most ~20k decimal digits; well under encode budgets.
  @max_integer_bits 65_536
  @max_integer_abs Bitwise.bsl(1, @max_integer_bits) - 1

  # Directory enumeration: File.ls/1 materializes names inside a **worker**
  # with hard heap/output/name/timeout ceilings. Caller only receives the
  # bounded candidate list / error evidence — not the full name list.
  @dir_name_slack 4
  @ceiling_dir_names 8_000
  @list_worker_timeout_ms 5_000
  # ~32 MiB heap words on 64-bit BEAM (word = 8 bytes); kill worker on exceed.
  @list_worker_max_heap_words 4_194_304
  @max_filename_bytes 256

  @max_run_id_bytes 128
  # Single path component: starts alphanumeric, then [A-Za-z0-9._-], no dots-only,
  # no percent, no separators. Length 1..128.
  @run_id_re ~r/^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$/

  @json_suffix ".json"
  @json_suffix_size byte_size(@json_suffix)

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
         :ok <- assert_root_stable(root_state),
         :ok <- assert_root_private(root_state) do
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
      open_or_create_root(abs, create?)
    end
  end

  defp open_or_create_root(abs, create?) do
    case File.lstat(abs, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} ->
        # Never chmod a symlink (or its target). Fail closed immediately.
        {:error, :symlink_root}

      {:ok, %File.Stat{type: :directory} = stat} ->
        # Existing root: verify trusted-private contract BEFORE any chmod.
        # Do not silently chmod an insecure root into compliance.
        finalize_existing_root(abs, stat)

      {:ok, _} ->
        {:error, :not_a_directory}

      {:error, :enoent} when create? ->
        create_trusted_root(abs)

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp finalize_existing_root(abs, stat) do
    with :ok <- reject_symlink_path(abs),
         :ok <- assert_trusted_private_stat(stat),
         :ok <- usable_identity(stat) do
      {:ok,
       %{
         path: abs,
         identity: directory_identity(stat),
         uid: stat.uid,
         mode: Bitwise.band(stat.mode, 0o777)
       }}
    end
  end

  defp create_trusted_root(abs) do
    # Create then lstat/verify/chmod only the actual directory leaf.
    # Intermediate parents created by mkdir_p are not chmod'd here.
    case File.mkdir_p(abs) do
      :ok ->
        case File.lstat(abs, time: :posix) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:error, :symlink_root}

          {:ok, %File.Stat{type: :directory} = stat} ->
            with :ok <- reject_symlink_path(abs),
                 :ok <- assert_owner(stat),
                 :ok <- usable_identity(stat),
                 :ok <- chmod_real_directory(abs),
                 {:ok, stat2} <- File.lstat(abs, time: :posix),
                 :ok <- reject_symlink_path(abs),
                 :ok <- assert_trusted_private_stat(stat2) do
              {:ok,
               %{
                 path: abs,
                 identity: directory_identity(stat2),
                 uid: stat2.uid,
                 mode: Bitwise.band(stat2.mode, 0o777)
               }}
            end

          {:ok, _} ->
            {:error, :not_a_directory}

          {:error, reason} ->
            {:error, {:file_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp chmod_real_directory(abs) do
    # lstat already confirmed :directory and not a symlink leaf; recheck link
    # so we never chmod through a raced symlink replacement.
    case File.read_link(abs) do
      {:ok, _} ->
        {:error, :symlink_root}

      {:error, _} ->
        case File.chmod(abs, 0o700) do
          :ok -> :ok
          {:error, reason} -> {:error, {:file_error, reason}}
        end
    end
  end

  defp reject_symlink_path(path) do
    case File.read_link(path) do
      {:ok, _} -> {:error, :symlink_root}
      {:error, _} -> :ok
    end
  end

  defp assert_trusted_private_stat(%File.Stat{} = stat) do
    with :ok <- assert_owner(stat),
         :ok <- assert_private_mode(stat) do
      :ok
    end
  end

  defp assert_private_mode(%File.Stat{mode: mode}) do
    perms = Bitwise.band(mode, 0o777)

    if Bitwise.band(perms, 0o077) == 0 do
      :ok
    else
      {:error, :insecure_root_permissions}
    end
  end

  defp assert_owner(%File.Stat{uid: uid}) when is_integer(uid) do
    case current_euid() do
      {:ok, euid} when euid == uid ->
        :ok

      {:ok, _} ->
        {:error, :insecure_root_owner}

      :unsupported ->
        # Platform does not expose uid; permission bits still enforced.
        :ok

      :error ->
        {:error, :unusable_owner_check}
    end
  end

  defp assert_owner(_), do: {:error, :unusable_owner_check}

  # Resolve euid by ownership of an exclusive temp we create (OTP has no
  # :os.getuid on this pinned release). Cached in the process dictionary.
  defp current_euid do
    case :os.type() do
      {:unix, _} ->
        case Process.get({:arbor_persistence_eval, :euid}) do
          uid when is_integer(uid) ->
            {:ok, uid}

          _ ->
            case probe_euid() do
              {:ok, uid} = ok ->
                Process.put({:arbor_persistence_eval, :euid}, uid)
                ok

              other ->
                other
            end
        end

      _ ->
        :unsupported
    end
  end

  defp probe_euid do
    dir = System.tmp_dir!()
    path = Path.join(dir, ".arbor-euid-#{System.unique_integer([:positive])}")

    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} ->
        _ = :file.close(io)

        result =
          case File.lstat(path, time: :posix) do
            {:ok, %File.Stat{uid: uid}} when is_integer(uid) -> {:ok, uid}
            _ -> :error
          end

        _ = File.rm(path)
        result

      {:error, _} ->
        :error
    end
  end

  defp assert_root_stable(%{path: path, identity: expected}) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with :ok <- reject_symlink_path(path),
             :ok <- assert_trusted_private_stat(stat) do
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

  defp assert_root_private(%{path: path}) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with :ok <- reject_symlink_path(path) do
          assert_trusted_private_stat(stat)
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

  # Full regular-file identity. mtime/ctime are native OTP posix seconds on this
  # pin (high-resolution file times are not exposed by File.Stat / :file on
  # OTP 28.4.1). Metadata equality is best-effort under the trusted-root
  # contract — not proof against an owner restoring timestamps.
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
    filename = run_id <> @json_suffix

    case SafePath.safe_join(root, filename) do
      {:ok, path} ->
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
        case canonicalize_object_keys(value, budget) do
          {:ok, pairs, key_budget} ->
            budget = %{
              budget
              | nodes: budget.nodes + 1,
                estimated: budget.estimated + 2 + key_budget
            }

            if budget.estimated > budget.max_bytes do
              {:error, :max_file_bytes_exceeded}
            else
              Enum.reduce_while(pairs, {:ok, budget}, fn {key, child}, {:ok, acc} ->
                # key node already counted during canonicalize key scan
                _ = key

                if acc.nodes + 1 > acc.max_nodes do
                  {:halt, {:error, :max_encode_nodes_exceeded}}
                else
                  acc = %{acc | nodes: acc.nodes + 1}

                  case walk_budget(child, depth + 1, acc) do
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
                end
              end)
            end

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

    # Reject by byte_size BEFORE UTF-8 scanning so oversized invalid UTF-8
    # never forces a full binary walk.
    cond do
      size > budget.max_bytes ->
        {:error, :max_file_bytes_exceeded}

      size > budget.max_string_bytes ->
        {:error, :max_string_bytes_exceeded}

      not String.valid?(value) ->
        {:error, :invalid_utf8}

      budget.nodes + 1 > budget.max_nodes ->
        {:error, :max_encode_nodes_exceeded}

      true ->
        # Quotes + conservative worst-case JSON escape (\\uXXXX per byte → 6x)
        estimated = budget.estimated + json_string_byte_estimate(size)

        if estimated > budget.max_bytes do
          {:error, :max_file_bytes_exceeded}
        else
          {:ok, %{budget | nodes: budget.nodes + 1, estimated: estimated}}
        end
    end
  end

  defp walk_budget(value, _depth, budget) when is_integer(value) do
    if budget.nodes + 1 > budget.max_nodes do
      {:error, :max_encode_nodes_exceeded}
    else
      case integer_preflight(value, budget) do
        {:ok, est} ->
          estimated = budget.estimated + est

          if estimated > budget.max_bytes do
            {:error, :max_file_bytes_exceeded}
          else
            {:ok, %{budget | nodes: budget.nodes + 1, estimated: estimated}}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp walk_budget(value, _depth, budget) when is_float(value) do
    if budget.nodes + 1 > budget.max_nodes do
      {:error, :max_encode_nodes_exceeded}
    else
      # Conservative fixed-width estimate for IEEE floats in JSON.
      estimated = budget.estimated + 32

      if estimated > budget.max_bytes do
        {:error, :max_file_bytes_exceeded}
      else
        {:ok, %{budget | nodes: budget.nodes + 1, estimated: estimated}}
      end
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

  # Hard bit ceiling via comparison to a compile-time threshold (no decimal
  # materialization of the attacker's integer). Then conservative digit estimate
  # from bit length: digits <= floor(bits * log10(2)) + 1 < floor(bits*302/1000)+1.
  defp integer_preflight(n, budget) when is_integer(n) do
    abs_n = abs_integer(n)

    cond do
      abs_n > @max_integer_abs ->
        {:error, {:encode_preflight, :max_integer_bits_exceeded}}

      true ->
        est = integer_decimal_byte_estimate(n, abs_n)

        if est > budget.max_bytes do
          {:error, {:encode_preflight, :max_integer_bytes_exceeded}}
        else
          {:ok, est}
        end
    end
  end

  defp abs_integer(n) when n < 0, do: -n
  defp abs_integer(n), do: n

  defp integer_decimal_byte_estimate(n, abs_n) do
    sign = if n < 0, do: 1, else: 0
    bits = integer_bit_length(abs_n)
    digits = if abs_n == 0, do: 1, else: div(bits * 302, 1000) + 1
    sign + digits
  end

  defp integer_bit_length(0), do: 1

  defp integer_bit_length(n) when is_integer(n) and n > 0 do
    # Within @max_integer_bits, encode_unsigned is bounded (≤ 8 KiB).
    bin = :binary.encode_unsigned(n)
    byte_count = byte_size(bin)
    <<top, _::binary>> = bin
    (byte_count - 1) * 8 + top_byte_bit_length(top)
  end

  defp top_byte_bit_length(b) when b >= 128, do: 8
  defp top_byte_bit_length(b) when b >= 64, do: 7
  defp top_byte_bit_length(b) when b >= 32, do: 6
  defp top_byte_bit_length(b) when b >= 16, do: 5
  defp top_byte_bit_length(b) when b >= 8, do: 4
  defp top_byte_bit_length(b) when b >= 4, do: 3
  defp top_byte_bit_length(b) when b >= 2, do: 2
  defp top_byte_bit_length(b) when b >= 1, do: 1
  defp top_byte_bit_length(_), do: 1

  # Worst-case JSON string bytes: quotes + 6× per raw byte (\u00XX).
  defp json_string_byte_estimate(size) when is_integer(size) and size >= 0 do
    size * 6 + 2
  end

  # Build sorted unique string keys; reject atom/string aliases that collide.
  # Key byte_size checked before UTF-8 scan; key-byte budget accumulated
  # before sorting so oversized key sets never reach Enum.sort_by.
  defp canonicalize_object_keys(map, budget) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}, [], 0}, fn {k, v}, {:ok, seen, acc, key_bytes} ->
      case normalize_object_key(k, budget) do
        {:ok, key} ->
          if Map.has_key?(seen, key) do
            {:halt, {:error, :duplicate_json_key}}
          else
            # key JSON string + colon separator contribution
            cost = json_string_byte_estimate(byte_size(key)) + 1
            new_key_bytes = key_bytes + cost

            cond do
              budget.estimated + new_key_bytes > budget.max_bytes ->
                {:halt, {:error, :max_file_bytes_exceeded}}

              true ->
                {:cont, {:ok, Map.put(seen, key, true), [{key, v} | acc], new_key_bytes}}
            end
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, _seen, pairs, key_bytes} ->
        {:ok, Enum.sort_by(pairs, &elem(&1, 0)), key_bytes}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_object_key(k, budget) when is_binary(k) do
    size = byte_size(k)

    cond do
      size > budget.max_bytes ->
        {:error, :max_file_bytes_exceeded}

      size > budget.max_string_bytes ->
        {:error, {:encode_preflight, :max_key_bytes_exceeded}}

      not String.valid?(k) ->
        {:error, :invalid_utf8}

      true ->
        {:ok, k}
    end
  end

  defp normalize_object_key(k, budget) when is_atom(k) do
    normalize_object_key(Atom.to_string(k), budget)
  end

  defp normalize_object_key(_, _), do: {:error, :encode_unsupported_key}

  # ---------------------------------------------------------------------------
  # Atomic exclusive temp publish
  # ---------------------------------------------------------------------------

  defp atomic_publish(root_state, target, json) do
    root = root_state.path

    with :ok <- reject_symlink_ancestors(root, target),
         :ok <- assert_root_stable(root_state),
         :ok <- assert_root_private(root_state) do
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
                    _ = :file.close(io)
                    finalize_temp_publish(root_state, tmp, target)

                  {:error, reason} ->
                    _ = :file.close(io)
                    cleanup_temp(tmp)
                    {:error, {:file_error, reason}}
                end

              {:error, reason} ->
                _ = :file.close(io)
                cleanup_temp(tmp)
                {:error, {:file_error, reason}}
            end
          rescue
            e ->
              _ = :file.close(io)
              cleanup_temp(tmp)
              {:error, {:file_error, Exception.message(e)}}
          catch
            kind, reason ->
              _ = :file.close(io)
              cleanup_temp(tmp)
              {:error, {:file_error, {kind, reason}}}
          end

        {:error, reason} ->
          {:error, {:file_error, reason}}
      end
    end
  end

  defp finalize_temp_publish(root_state, tmp, target) do
    with :ok <- chmod_temp(tmp),
         {:ok, tmp_identity} <- capture_temp_identity(tmp),
         :ok <- assert_root_stable(root_state),
         :ok <- assert_root_private(root_state),
         :ok <- rename_temp(tmp, target),
         :ok <- best_effort_sync_directory(root_state.path),
         :ok <- verify_published(target, tmp_identity),
         :ok <- assert_root_stable(root_state) do
      :ok
    else
      {:error, _} = err ->
        cleanup_temp(tmp)
        err
    end
  end

  defp chmod_temp(tmp) do
    case File.chmod(tmp, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  defp capture_temp_identity(tmp) do
    case File.lstat(tmp, time: :posix) do
      {:ok, stat} ->
        case regular_identity(stat) do
          {:ok, id} ->
            if Bitwise.band(stat.mode, 0o777) == 0o600 do
              {:ok, id}
            else
              {:error, :temp_mode_incorrect}
            end

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp rename_temp(tmp, target) do
    case File.rename(tmp, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  defp verify_published(target, expected_identity) do
    case File.lstat(target, time: :posix) do
      {:ok, stat} ->
        case regular_identity(stat) do
          {:ok, id} ->
            if identity_match?(id, expected_identity) and
                 Bitwise.band(stat.mode, 0o777) == 0o600 do
              :ok
            else
              {:error, :publish_identity_mismatch}
            end

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp cleanup_temp(tmp) do
    _ = File.rm(tmp)
    :ok
  end

  # On this pinned macOS/OTP host, `:file.open(dir, [:raw, :read])` returns
  # `{:error, :eisdir}`. Directory fsync is therefore unsupported and must not
  # be reported as crash durability. File sync of the temp payload still runs.
  defp best_effort_sync_directory(root) do
    case :file.open(String.to_charlist(root), [:raw, :read]) do
      {:ok, dio} ->
        _ = :file.sync(dio)
        _ = :file.close(dio)
        :ok

      {:error, :eisdir} ->
        # Unsupported on this host — best-effort only, not a durability claim.
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
  # Bounded read (single opened handle + full identity recheck)
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
               {:ok, data} <- read_exact_size(io, expected.size, max_bytes),
               {:ok, info2} <- :file.read_file_info(io, time: :posix),
               stat2 = File.Stat.from_record(info2),
               {:ok, id2} <- regular_identity(stat2),
               true <- identity_match?(id2, expected) or {:error, :file_changed},
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

  # Compare full regular-file identity: type, device, inode, size, mtime, ctime.
  defp identity_match?(a, b) when is_map(a) and is_map(b) do
    a.type == b.type and a.inode == b.inode and a.major_device == b.major_device and
      a.minor_device == b.minor_device and a.size == b.size and a.mtime == b.mtime and
      a.ctime == b.ctime
  end

  defp identity_match?(_, _), do: false

  # Read exactly `size` bytes (the captured initial size), never past it, and
  # never more than max_bytes. Reject growth probes (extra readable byte) and
  # short reads (truncation during read).
  defp read_exact_size(_io, size, max_bytes)
       when is_integer(size) and size > max_bytes do
    {:error, :max_file_bytes_exceeded}
  end

  defp read_exact_size(io, size, _max_bytes) when is_integer(size) and size >= 0 do
    case read_n_bytes(io, size, []) do
      {:ok, data} ->
        # Probe one extra byte: growth during read must fail closed.
        case :file.read(io, 1) do
          :eof ->
            {:ok, data}

          {:ok, <<>>} ->
            {:ok, data}

          {:ok, _} ->
            {:error, :file_changed}

          {:error, reason} ->
            {:error, {:file_error, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp read_exact_size(_, _, _), do: {:error, :unusable_inode}

  defp read_n_bytes(_io, 0, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp read_n_bytes(io, remaining, acc) when remaining > 0 do
    chunk_size = min(remaining, 65_536)

    case :file.read(io, chunk_size) do
      {:ok, chunk} when byte_size(chunk) == chunk_size ->
        read_n_bytes(io, remaining - chunk_size, [chunk | acc])

      {:ok, chunk} when byte_size(chunk) < chunk_size ->
        # Short read vs captured size — same-inode truncation / mutation.
        _ = chunk
        {:error, :file_changed}

      :eof ->
        {:error, :file_changed}

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
  defp bind_run_id(data, run_id) when is_map(data) and is_binary(run_id) do
    case Map.fetch(data, "id") do
      {:ok, ^run_id} ->
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
        {:error, :run_id_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # List with bounds — monitored worker under trusted-private-root
  # ---------------------------------------------------------------------------

  defp list_json_entries(root_state, max_files) do
    # Enforce private-root contract before any enumeration.
    with :ok <- assert_root_stable(root_state),
         :ok <- assert_root_private(root_state) do
      name_ceiling = min(@ceiling_dir_names, max(max_files * @dir_name_slack, max_files + 1))
      run_bounded_list_worker(root_state.path, max_files, name_ceiling)
    end
  end

  defp run_bounded_list_worker(root, max_files, name_ceiling) do
    parent = self()
    ref = make_ref()

    {worker, mon} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: @list_worker_max_heap_words,
          kill: true,
          error_logger: false
        })

        result = safe_list_dir_candidates(root, max_files, name_ceiling)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^worker, reason} ->
        {:error,
         {:max_files_exceeded,
          %{
            reason: :enumeration_worker_killed,
            detail: inspect(reason),
            max_files: max_files,
            name_ceiling: name_ceiling
          }}}
    after
      @list_worker_timeout_ms ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^mon, :process, ^worker, _} -> :ok
        after
          1_000 -> :ok
        end

        {:error,
         {:max_files_exceeded,
          %{
            reason: :enumeration_timeout,
            max_files: max_files,
            name_ceiling: name_ceiling,
            timeout_ms: @list_worker_timeout_ms
          }}}
    end
  end

  defp safe_list_dir_candidates(root, max_files, name_ceiling) do
    case File.ls(root) do
      {:ok, files} ->
        collect_entries_bounded(files, root, max_files, name_ceiling, [], 0, 0)

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp collect_entries_bounded([], _root, _max_files, _name_ceiling, acc, _json_seen, _names) do
    {:ok, Enum.reverse(acc)}
  end

  defp collect_entries_bounded(
         [name | rest],
         root,
         max_files,
         name_ceiling,
         acc,
         json_seen,
         names_seen
       ) do
    names_seen = names_seen + 1

    cond do
      names_seen > name_ceiling ->
        {:error,
         {:max_files_exceeded,
          %{
            reason: :directory_overpopulated,
            name_count: names_seen,
            name_ceiling: name_ceiling,
            max_files: max_files
          }}}

      byte_size(name) > @max_filename_bytes ->
        # Skip absurd names; still counted toward name ceiling.
        collect_entries_bounded(rest, root, max_files, name_ceiling, acc, json_seen, names_seen)

      true ->
        case run_id_from_filename(name) do
          {:ok, run_id} ->
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
                  collect_entries_bounded(
                    rest,
                    root,
                    max_files,
                    name_ceiling,
                    [{run_id, path} | acc],
                    json_seen,
                    names_seen
                  )
                end

              _ ->
                collect_entries_bounded(
                  rest,
                  root,
                  max_files,
                  name_ceiling,
                  acc,
                  json_seen,
                  names_seen
                )
            end

          :error ->
            collect_entries_bounded(
              rest,
              root,
              max_files,
              name_ceiling,
              acc,
              json_seen,
              names_seen
            )
        end
    end
  end

  # Remove exactly one terminal ".json" suffix and validate reconstruction.
  # `String.trim_trailing/2` is wrong here — it strips every repeated suffix
  # ("legit.json.json" → "legit", "a.json.json" → "a").
  defp run_id_from_filename(name) when is_binary(name) do
    cond do
      String.starts_with?(name, ".") ->
        :error

      not String.ends_with?(name, @json_suffix) ->
        :error

      byte_size(name) <= @json_suffix_size ->
        :error

      true ->
        run_id = binary_part(name, 0, byte_size(name) - @json_suffix_size)

        if run_id <> @json_suffix == name and validate_run_id(run_id) == :ok do
          {:ok, run_id}
        else
          :error
        end
    end
  end

  defp run_id_from_filename(_), do: :error

  defp decode_listed(entries, max_files, max_total, model_filter, provider_filter, opts) do
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

      {:error, :file_changed} ->
        # Do not mask identity failures as soft skips during list.
        {:error, :file_changed}

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
