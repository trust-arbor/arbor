defmodule Arbor.Actions.Coding.DependencyBaselineAdmission do
  @moduledoc """
  Pre-worker admission gate: does the exact acquired base commit's mix.lock
  match the verified startup-pinned Linux dependency baseline?

  Reads the `mix.lock` blob directly out of the immutable commit object at
  `base_commit` through the canonical repository root (via
  `Arbor.Actions.Git.read_bounded_blob_at_commit/4`) — never the linked
  worktree's live file, so a dirty replacement or TOCTOU substitution on disk
  cannot influence the result. Compares its
  SHA-256 digest against `Arbor.Shell.linux_dependency_baseline_mix_lock_digest/0`,
  the narrow evidence-only projection of the startup-pinned authority.

  Returns only a bounded pass/fail fact — never a digest value, git output,
  or baseline evidence. This is the admission-time gate; the existing
  execution-time check in `Arbor.Actions.Mix` remains unchanged as defense in
  depth once a worker has actually produced a candidate to validate.
  """

  use Jido.Action,
    name: "coding_dependency_baseline_check",
    description: "Verify the acquired base commit's mix.lock matches the pinned Linux baseline",
    category: "coding",
    tags: ["coding", "workspace", "dependency-baseline"],
    schema: [
      repo_path: [
        type: :string,
        required: true,
        doc: "Canonical repository root recorded by workspace acquisition"
      ],
      base_commit: [
        type: :string,
        required: true,
        doc: "Exact base commit resolved at workspace acquisition"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Config
  alias Arbor.Actions.Git

  @mix_lock_max_bytes 1_048_576
  @mix_lock_relative_path "mix.lock"

  def taint_roles do
    %{
      repo_path: {:control, requires: [:path_traversal]},
      base_commit: {:control, requires: [:command_injection]}
    }
  end

  def effect_class, do: :read

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(%{repo_path: repo_path, base_commit: base_commit}, _context)
      when is_binary(repo_path) and is_binary(base_commit) do
    Actions.emit_started(__MODULE__, %{repo_path: repo_path})

    case check_baseline(repo_path, base_commit) do
      {:ok, result} ->
        Actions.emit_completed(__MODULE__, result)
        {:ok, result}

      {:error, reason} = error ->
        Actions.emit_failed(__MODULE__, reason)
        error
    end
  rescue
    _exception ->
      reason = {:dependency_baseline_admission_failed, :mix_lock_unreadable_at_base_commit}
      Actions.emit_failed(__MODULE__, reason)
      {:error, reason}
  catch
    _kind, _reason ->
      reason = {:dependency_baseline_admission_failed, :mix_lock_unreadable_at_base_commit}
      Actions.emit_failed(__MODULE__, reason)
      {:error, reason}
  end

  def run(_params, _context), do: {:error, "repo_path and base_commit are required"}

  defp check_baseline(repo_path, base_commit) do
    with {:ok, blob} <- read_base_mix_lock(repo_path, base_commit),
         actual_digest <- sha256_hex(blob),
         {:ok, expected_digest} <- baseline_mix_lock_digest() do
      if actual_digest == expected_digest do
        {:ok, %{"matched" => true}}
      else
        {:error, {:dependency_baseline_admission_failed, :digest_mismatch}}
      end
    end
  end

  defp read_base_mix_lock(repo_path, base_commit) do
    case Git.read_bounded_blob_at_commit(
           repo_path,
           base_commit,
           @mix_lock_relative_path,
           @mix_lock_max_bytes
         ) do
      {:ok, blob} when is_binary(blob) ->
        {:ok, blob}

      _other ->
        {:error, {:dependency_baseline_admission_failed, :mix_lock_unreadable_at_base_commit}}
    end
  end

  defp baseline_mix_lock_digest do
    with {:ok, module} <- Config.dependency_baseline_digest_module(),
         {:ok, digest} <- call_baseline_digest_module(module),
         true <- valid_digest?(digest) do
      {:ok, digest}
    else
      _other ->
        {:error, {:dependency_baseline_admission_failed, :baseline_unavailable}}
    end
  end

  defp call_baseline_digest_module(module) do
    try do
      case module.linux_dependency_baseline_mix_lock_digest() do
        {:ok, digest} -> {:ok, digest}
        _other -> {:error, :baseline_unavailable}
      end
    rescue
      _exception -> {:error, :baseline_unavailable}
    catch
      _kind, _reason -> {:error, :baseline_unavailable}
    end
  end

  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    digest
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte ->
      (byte >= ?0 and byte <= ?9) or (byte >= ?a and byte <= ?f)
    end)
  end

  defp valid_digest?(_digest), do: false

  defp sha256_hex(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end
end
