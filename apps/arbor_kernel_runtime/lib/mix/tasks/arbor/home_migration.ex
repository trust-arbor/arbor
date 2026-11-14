defmodule Mix.Tasks.Arbor.HomeMigration do
  use Boundary, classify_to: Arbor.KernelRuntime.DevTools

  @moduledoc """
  Imperative shell for `mix arbor.home.migrate`.

  Gathers the legacy (`~/.arbor/distribution/.arbor`) and target
  (`~/.arbor`) listings without following symlinks, hands them to
  `Mix.Tasks.Arbor.HomeMigrationCore.plan/2`, and performs the plan's
  operations in order, stopping at the first failure.

  File moves are no-clobber: a hard link publishes the legacy file under its
  target name (it fails if that name exists) before the legacy name is
  unlinked. A replacement first hard-links the current target to its archive
  name, then renames the legacy file over the target, so the target path
  always names one complete copy. Erlang cannot fsync a directory, so the
  shell runs `sync` once after applying.
  """

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.HomeMigrationCore, as: Core

  @root ""

  @doc """
  True when the legacy tree exists in any form. Any lstat answer other than
  `:enoent` counts, so an unreadable or odd legacy root still blocks launch.
  """
  @spec legacy_state_present?(String.t()) :: boolean()
  def legacy_state_present?(home) do
    File.lstat(Config.legacy_home_root(home)) != {:error, :enoent}
  end

  @doc "Gathers both listings and plans the migration."
  @spec plan(String.t()) :: {:ok, Core.t()} | :absent | {:error, term()}
  def plan(home) do
    case gather(home) do
      {:ok, legacy, target} -> {:ok, Core.plan(legacy, target)}
      other -> other
    end
  end

  @doc false
  @spec gather(String.t()) :: {:ok, Core.listing(), Core.listing()} | :absent | {:error, term()}
  def gather(home) do
    legacy_root = Config.legacy_home_root(home)

    case File.lstat(legacy_root) do
      {:error, :enoent} ->
        :absent

      {:ok, %File.Stat{type: :directory}} ->
        legacy = list_tree(legacy_root)
        {:ok, legacy, list_target(home, legacy)}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:legacy_root_not_a_directory, type}}

      {:error, reason} ->
        {:error, {:legacy_root_unreadable, reason}}
    end
  catch
    {:gather_failed, path, reason} -> {:error, {:unreadable, path, reason}}
  end

  @doc """
  Applies a plan's operations in order. Returns `{:ok, done}` or
  `{:error, %{done: done, failed: {op, reason}, remaining: ops}}`.
  """
  @spec apply_plan(Core.t(), String.t()) ::
          {:ok, [Core.op()]} | {:error, %{done: [Core.op()], failed: term(), remaining: [term()]}}
  def apply_plan(%Core{ops: ops} = plan, home) do
    true = Core.applicable?(plan)
    roots = {Config.legacy_home_root(home), home}

    result =
      Enum.reduce_while(ops, {[], ops}, fn op, {done, [_ | remaining]} ->
        case perform(op, roots) do
          :ok -> {:cont, {[op | done], remaining}}
          {:error, reason} -> {:halt, {:error, Enum.reverse(done), {op, reason}, remaining}}
        end
      end)

    sync_filesystems()

    case result do
      {done, []} ->
        {:ok, Enum.reverse(done)}

      {:error, done, failed, remaining} ->
        {:error, %{done: done, failed: failed, remaining: remaining}}
    end
  end

  # --- gather ---------------------------------------------------------------

  defp list_tree(root), do: list_dir(root, @root, %{})

  defp list_dir(root, rel, acc) do
    path = join(root, rel)

    names =
      case File.ls(path) do
        {:ok, names} -> names
        {:error, reason} -> throw({:gather_failed, path, reason})
      end

    Enum.reduce(names, acc, fn name, acc ->
      child = join(rel, name)
      entry = entry(join(root, child), true)
      acc = Map.put(acc, child, entry)
      if entry.kind == :directory, do: list_dir(root, child, acc), else: acc
    end)
  end

  # The target listing covers every legacy path plus the other names in each
  # directory both trees share, so the core can see archive-name collisions.
  defp list_target(home, legacy) do
    exact =
      Map.new(legacy, fn {rel, l} -> {rel, entry(join(home, rel), l.kind == :regular)} end)
      |> Enum.reject(fn {_rel, entry} -> entry == :absent end)
      |> Map.new()

    shared_dirs =
      [@root | for({rel, %{kind: :directory}} <- exact, do: rel)]

    Enum.reduce(shared_dirs, exact, &add_siblings(&2, home, &1))
  end

  defp add_siblings(acc, home, dir) do
    names =
      case File.ls(join(home, dir)) do
        {:ok, names} -> names
        {:error, reason} -> throw({:gather_failed, join(home, dir), reason})
      end

    names
    |> Enum.map(&join(dir, &1))
    |> Enum.reject(&Map.has_key?(acc, &1))
    |> Enum.reduce(acc, fn rel, acc -> put_present(acc, rel, entry(join(home, rel), false)) end)
  end

  defp put_present(acc, _rel, :absent), do: acc
  defp put_present(acc, rel, entry), do: Map.put(acc, rel, entry)

  defp entry(path, digest?) do
    case File.lstat(path, time: :local) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        base = %{kind: :regular, size: size, mtime: mtime}
        if digest?, do: Map.put(base, :digest, digest!(path)), else: base

      {:ok, %File.Stat{type: :directory}} ->
        %{kind: :directory}

      {:ok, %File.Stat{type: :symlink}} ->
        %{kind: :symlink}

      {:ok, %File.Stat{}} ->
        %{kind: :other}

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        throw({:gather_failed, path, reason})
    end
  end

  defp digest!(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  rescue
    error in File.Error -> throw({:gather_failed, path, error.reason})
  end

  # --- apply ----------------------------------------------------------------

  defp perform({:move, rel, :regular}, {legacy, home}) do
    publish(join(legacy, rel), join(home, rel))
  end

  defp perform({:move, rel, :directory}, {legacy, home}) do
    target = join(home, rel)

    case File.lstat(target) do
      {:error, :enoent} -> File.rename(join(legacy, rel), target)
      {:ok, _} -> {:error, :target_appeared}
      error -> error
    end
  end

  defp perform({:replace, rel, archive}, {legacy, home}) do
    source = join(legacy, rel)
    target = join(home, rel)

    with :ok <- expect_regular(source),
         :ok <- expect_regular(target),
         :ok <- link(target, join(home, archive)) do
      File.rename(source, target)
    end
  end

  defp perform({:remove_identical, rel}, {legacy, home}) do
    source = join(legacy, rel)

    with :ok <- expect_regular(source),
         :ok <- expect_regular(join(home, rel)) do
      if digest!(source) == digest!(join(home, rel)),
        do: File.rm(source),
        else: {:error, :changed_since_plan}
    end
  catch
    {:gather_failed, _path, reason} -> {:error, reason}
  end

  defp perform({:remove_empty_dir, rel}, {legacy, _home}) do
    File.rmdir(join(legacy, rel))
  end

  defp publish(source, target) do
    with :ok <- expect_regular(source),
         :ok <- link(source, target) do
      File.rm(source)
    end
  end

  defp link(existing, new) do
    case File.ln(existing, new) do
      :ok -> :ok
      {:error, :eexist} -> {:error, {:exists, new}}
      {:error, reason} -> {:error, {:link_failed, reason}}
    end
  end

  defp expect_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, path, type}}
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  # Best effort: a missing `sync` must not turn a completed migration into
  # a reported failure.
  defp sync_filesystems do
    System.cmd("sync", [], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp join(root, @root), do: root
  defp join(root, rel), do: Path.join(root, rel)
end
