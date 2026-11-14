defmodule Mix.Tasks.Arbor.HomeMigrationCore do
  use Boundary, classify_to: Arbor.KernelRuntime.DevTools

  @moduledoc """
  Pure planner for `mix arbor.home.migrate`.

  From 2026-10-07 until the gated-distribution launcher, the dev daemon ran
  with its VM HOME set to `~/.arbor/distribution`, so every `~/.arbor/...`
  path inside the daemon resolved under `~/.arbor/distribution/.arbor/...`
  (the "legacy" tree), while Mix tasks kept using the real `~/.arbor` (the
  "target" tree). This module decides how to fold the legacy tree back into
  the target. It never touches the filesystem: `Mix.Tasks.Arbor.HomeMigration`
  gathers both listings and performs the returned operations.

  ## Listings

  A listing maps a path relative to its tree root (`"security/master.key"`)
  to `%{kind: kind}` plus, for regular files, `:size`, `:digest` (any stable
  content hash) and `:mtime` (an `:calendar.datetime()` in local time). Kinds
  are `:regular`, `:directory`, `:symlink` or `:other`. The target listing
  needs entries for every legacy path and for the other names in each
  directory the two trees share (to detect archive-name collisions).

  ## Policy (owner decision, 2026-11-13)

    * A legacy entry absent from the target is **moved** (a directory moves
      whole).
    * A legacy file byte-identical to its target is **removed**.
    * A legacy file that differs from its target **wins**: it is what the live
      daemon used. The target copy is archived as
      `<name>.pre-home-migration-<YYYYMMDD of its mtime>`, never deleted.
    * Directories whose subtree holds no files are **removed**.
    * Anything else blocks the whole migration: symlinks or special files on
      either side, a file facing a directory, an archive name already taken,
      or a legacy `distribution/` entry (it would land in the cookie
      directory).
    * SQLite files are not swapped piecemeal: a legacy `*.db` /
      `*.sqlite[3]` file or its `-wal`/`-shm`/`-journal` sibling blocks when
      the target holds any member of the same database. Replacing the main
      file under a foreign WAL corrupts it. (Added 2026-11-13 on top of the
      owner's key-file policy; the legacy SQLite copy is usually the empty,
      unmigrated database a fresh install failed to boot with.)
  """

  @type kind :: :regular | :directory | :symlink | :other
  @type entry :: %{
          required(:kind) => kind(),
          optional(:size) => non_neg_integer(),
          optional(:digest) => binary(),
          optional(:mtime) => :calendar.datetime()
        }
  @type listing :: %{String.t() => entry()}
  @type op ::
          {:move, String.t(), :regular | :directory}
          | {:replace, String.t(), String.t()}
          | {:remove_identical, String.t()}
          | {:remove_empty_dir, String.t()}
  @type reason ::
          :reserved_path
          | :unsupported_legacy_kind
          | :unsupported_target_kind
          | :kind_mismatch
          | :missing_digest
          | :missing_mtime
          | :archive_name_taken
          | :sqlite_family_conflict
  @type t :: %__MODULE__{ops: [op()], blocked: [{String.t(), reason()}]}

  defstruct ops: [], blocked: []

  @archive_infix ".pre-home-migration-"
  @sqlite_file ~r/\A(?<base>.+\.(?:db|sqlite|sqlite3))(?:-wal|-shm|-journal)?\z/
  @sqlite_suffixes ["", "-wal", "-shm", "-journal"]
  @root ""

  @doc """
  Builds the plan. Operations are ordered for sequential execution: a
  directory's children come before its removal, and the legacy root
  (`""`) is removed last.
  """
  @spec plan(listing(), listing()) :: t()
  def plan(legacy, target) when is_map(legacy) and is_map(target) do
    children = Enum.group_by(Map.keys(legacy), &parent/1)
    acc = walk(@root, legacy, target, children, %__MODULE__{})

    %__MODULE__{
      ops: Enum.reverse([{:remove_empty_dir, @root} | acc.ops]),
      blocked: Enum.reverse(acc.blocked)
    }
  end

  @doc "True when nothing blocks the plan."
  @spec applicable?(t()) :: boolean()
  def applicable?(%__MODULE__{blocked: blocked}), do: blocked == []

  @doc "Archive path for a replaced target file, dated by the target's mtime."
  @spec archive_path(String.t(), :calendar.datetime()) :: String.t()
  def archive_path(rel, {{year, month, day}, _time}) do
    date =
      :io_lib.format("~4..0B~2..0B~2..0B", [year, month, day])
      |> IO.iodata_to_binary()

    rel <> @archive_infix <> date
  end

  @doc """
  Admission for `--apply`, from the lifecycle check of the managed daemon's
  recorded PID. Moving key material under a running daemon would race its
  writes, so only a confirmed-absent daemon admits.
  """
  @spec admit_apply(term()) :: :ok | {:refuse, term()}
  def admit_apply(check) when check in [:absent, :no_such_process, :present_not_arbor], do: :ok
  def admit_apply({:verified_arbor, node}), do: {:refuse, {:daemon_running, node}}
  def admit_apply(_check), do: {:refuse, :daemon_state_unverified}

  @doc "Human-readable plan, one line per operation or blocker."
  @spec describe(t()) :: [String.t()]
  def describe(%__MODULE__{ops: ops, blocked: blocked}) do
    op_lines = Enum.flat_map(ops, &describe_op/1)

    blocked_lines =
      case blocked do
        [] ->
          []

        _ ->
          [
            "",
            "Blocked (nothing is applied until these are resolved by hand):"
            | Enum.map(blocked, fn {rel, reason} ->
                "  #{display(rel)}  #{describe_reason(reason)}"
              end)
          ]
      end

    op_lines ++ ["", summary(ops)] ++ blocked_lines
  end

  # --- walk ---------------------------------------------------------------

  defp walk(dir, legacy, target, children, acc) do
    children
    |> Map.get(dir, [])
    |> Enum.sort()
    |> Enum.reduce(acc, fn rel, acc ->
      decide(rel, Map.fetch!(legacy, rel), Map.get(target, rel), legacy, target, children, acc)
    end)
  end

  defp decide("distribution", _l, _t, _legacy, _target, _children, acc),
    do: block(acc, "distribution", :reserved_path)

  defp decide(rel, %{kind: kind}, _t, _legacy, _target, _children, acc)
       when kind not in [:regular, :directory],
       do: block(acc, rel, :unsupported_legacy_kind)

  defp decide(rel, %{kind: :directory}, t, legacy, target, children, acc) do
    descendants = descendants(rel, legacy)

    cond do
      Enum.all?(descendants, &(legacy[&1].kind == :directory)) ->
        remove_dirs([rel | descendants], acc)

      is_nil(t) ->
        case Enum.find(descendants, &(legacy[&1].kind not in [:regular, :directory])) do
          nil -> op(acc, {:move, rel, :directory})
          bad -> block(acc, bad, :unsupported_legacy_kind)
        end

      t.kind == :directory ->
        rel
        |> walk(legacy, target, children, acc)
        |> op({:remove_empty_dir, rel})

      t.kind == :regular ->
        block(acc, rel, :kind_mismatch)

      true ->
        block(acc, rel, :unsupported_target_kind)
    end
  end

  defp decide(rel, %{kind: :regular} = l, t, legacy, target, _children, acc) do
    if sqlite_family_in_target?(rel, target),
      do: block(acc, rel, :sqlite_family_conflict),
      else: decide_file(rel, l, t, legacy, target, acc)
  end

  defp decide_file(rel, _l, nil, _legacy, _target, acc), do: op(acc, {:move, rel, :regular})

  defp decide_file(rel, l, %{kind: :regular} = t, legacy, target, acc) do
    cond do
      not (has_digest?(l) and has_digest?(t)) ->
        block(acc, rel, :missing_digest)

      l.size == t.size and l.digest == t.digest ->
        op(acc, {:remove_identical, rel})

      not match?({{_, _, _}, {_, _, _}}, Map.get(t, :mtime)) ->
        block(acc, rel, :missing_mtime)

      true ->
        archive = archive_path(rel, t.mtime)

        if Map.has_key?(target, archive) or Map.has_key?(legacy, archive) do
          block(acc, rel, :archive_name_taken)
        else
          op(acc, {:replace, rel, archive})
        end
    end
  end

  defp decide_file(rel, _l, %{kind: :directory}, _legacy, _target, acc),
    do: block(acc, rel, :kind_mismatch)

  defp decide_file(rel, _l, _t, _legacy, _target, acc),
    do: block(acc, rel, :unsupported_target_kind)

  defp sqlite_family_in_target?(rel, target) do
    case Regex.named_captures(@sqlite_file, rel) do
      %{"base" => base} -> Enum.any?(@sqlite_suffixes, &Map.has_key?(target, base <> &1))
      nil -> false
    end
  end

  defp has_digest?(entry),
    do: is_binary(Map.get(entry, :digest)) and is_integer(Map.get(entry, :size))

  # Deepest first so each rmdir sees an already-emptied directory.
  defp remove_dirs(dirs, acc) do
    dirs
    |> Enum.sort_by(&{-depth(&1), &1})
    |> Enum.reduce(acc, &op(&2, {:remove_empty_dir, &1}))
  end

  defp descendants(rel, legacy) do
    prefix = rel <> "/"
    legacy |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  defp parent(rel) do
    case Path.dirname(rel) do
      "." -> @root
      dir -> dir
    end
  end

  defp depth(rel), do: rel |> Path.split() |> length()

  defp op(acc, op), do: %{acc | ops: [op | acc.ops]}
  defp block(acc, rel, reason), do: %{acc | blocked: [{rel, reason} | acc.blocked]}

  # --- describe -----------------------------------------------------------

  defp describe_op({:move, rel, :regular}), do: ["  move     #{rel}"]
  defp describe_op({:move, rel, :directory}), do: ["  move     #{rel}/ (whole directory)"]

  defp describe_op({:replace, rel, archive}) do
    [
      "  replace  #{rel}  (legacy copy wins)",
      "           current #{rel} is kept as #{archive}"
    ]
  end

  defp describe_op({:remove_identical, rel}),
    do: ["  drop     #{rel}  (identical to the current copy)"]

  defp describe_op({:remove_empty_dir, @root}), do: ["  rmdir    (legacy root, once empty)"]
  defp describe_op({:remove_empty_dir, rel}), do: ["  rmdir    #{rel}/ (no files left)"]

  defp summary(ops) do
    counts = Enum.frequencies_by(ops, &elem(&1, 0))

    "#{Map.get(counts, :move, 0)} to move, #{Map.get(counts, :replace, 0)} to replace " <>
      "(current copy archived), #{Map.get(counts, :remove_identical, 0)} identical " <>
      "copies to drop, #{Map.get(counts, :remove_empty_dir, 0)} directories to remove."
  end

  defp display(@root), do: "(legacy root)"
  defp display(rel), do: rel

  defp describe_reason(:reserved_path),
    do: "would land in the cookie directory ~/.arbor/distribution"

  defp describe_reason(:unsupported_legacy_kind), do: "legacy entry is a symlink or special file"
  defp describe_reason(:unsupported_target_kind), do: "current entry is a symlink or special file"
  defp describe_reason(:kind_mismatch), do: "a file on one side faces a directory on the other"
  defp describe_reason(:missing_digest), do: "contents could not be compared"

  defp describe_reason(:missing_mtime),
    do: "current copy has no modification time to date its archive"

  defp describe_reason(:sqlite_family_conflict),
    do: "both locations hold this SQLite database; reconcile it by hand"

  defp describe_reason(:archive_name_taken),
    do: "the archive name for the current copy already exists"
end
