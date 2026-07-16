defmodule Arbor.Actions.TestLinuxBaselineMaterializer do
  @moduledoc false

  # Test-only stand-in for `Arbor.Shell` Linux baseline materialization.
  # Wired exclusively through WorkspaceLeaseRegistry start opts/state — never
  # via Application env or caller-supplied module/destination options.
  #
  # Acquire/release run inside the registry GenServer, so test seams live in a
  # named Agent rather than the caller's process dictionary.

  use Agent

  alias Arbor.Common.SafePath

  @baseline_marker "linux-baseline-marker"
  @host_secret "host-only-secret-marker"
  @max_deadline_ms 3_600_000

  defmodule Lease do
    @moduledoc false
    @enforce_keys [:token, :owner, :worker, :root_path, :candidate_path, :base_path]
    defstruct [:token, :owner, :worker, :root_path, :candidate_path, :base_path]
  end

  defimpl Inspect, for: Lease do
    def inspect(_lease, _opts), do: "#Arbor.Actions.TestLinuxBaselineLease<redacted>"
  end

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{acquire: :ok, release_failures: 0} end, name: name)
  end

  @doc false
  def baseline_marker, do: @baseline_marker

  @doc false
  def host_secret_marker, do: @host_secret

  @doc false
  def reset_seams do
    ensure_agent()
    Agent.update(__MODULE__, fn _ -> %{acquire: :ok, release_failures: 0} end)
  end

  @doc false
  def force_acquire(:fail), do: put_acquire(:fail)
  def force_acquire(:cleanup_required), do: put_acquire(:cleanup_required)
  def force_acquire(:invalid_view), do: put_acquire(:invalid_view)
  def force_acquire(:non_map_view), do: put_acquire(:non_map_view)
  def force_acquire(:ok), do: put_acquire(:ok)

  @doc false
  def force_release_failures(n) when is_integer(n) and n >= 0 do
    ensure_agent()
    Agent.update(__MODULE__, &Map.put(&1, :release_failures, n))
  end

  defp put_acquire(mode) do
    ensure_agent()
    Agent.update(__MODULE__, &Map.put(&1, :acquire, mode))
  end

  defp ensure_agent do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc """
  Acquire a private candidate/base baseline pair.

  Test seams (via Agent):
  * `:fail` — ordinary acquire failure
  * `:cleanup_required` — cleanup_required with a live lease
  * `:invalid_view` — returns a map view that fails admission
  * `:non_map_view` — returns a live lease plus a non-map view
  """
  def acquire_linux_dependency_baseline_lease(deadline_ms)
      when is_integer(deadline_ms) and deadline_ms > 0 and deadline_ms <= @max_deadline_ms do
    ensure_agent()
    mode = Agent.get(__MODULE__, &Map.get(&1, :acquire, :ok))

    # One-shot seam: clear after read so subsequent acquires are normal.
    Agent.update(__MODULE__, &Map.put(&1, :acquire, :ok))

    case mode do
      :fail ->
        {:error, :dependency_snapshot_failed}

      :cleanup_required ->
        case materialize_pair() do
          {:ok, lease, _view} ->
            {:error, {:cleanup_required, :test_cleanup_required, lease}}

          other ->
            other
        end

      :invalid_view ->
        case materialize_pair() do
          {:ok, lease, view} ->
            {:ok, lease, Map.put(view, "verified_copy", false)}

          other ->
            other
        end

      :non_map_view ->
        case materialize_pair() do
          {:ok, lease, _view} ->
            {:ok, lease, :not_a_map_view}

          other ->
            other
        end

      _ ->
        materialize_pair()
    end
  end

  def acquire_linux_dependency_baseline_lease(_deadline_ms), do: {:error, :invalid_deadline}

  @doc false
  def acquire_linux_dependency_baseline_lease_with_cleanup_locator(deadline_ms) do
    case acquire_linux_dependency_baseline_lease(deadline_ms) do
      {:ok, %Lease{root_path: root_path} = lease, view} ->
        {:ok, lease, view, %{root_path: root_path}}

      {:error, {:cleanup_required, reason, %Lease{root_path: root_path} = lease}} ->
        {:error, {:cleanup_required, reason, lease, %{root_path: root_path}}}

      other ->
        other
    end
  end

  @doc """
  Release a previously acquired lease.

  `force_release_failures/1` injects N failures before success. Successful prior
  teardown is idempotent (proves root absence).
  """
  def release_linux_dependency_baseline_lease(%Lease{owner: owner, root_path: root} = lease)
      when is_pid(owner) and is_binary(root) do
    if self() != owner do
      {:error, :foreign_release}
    else
      ensure_agent()

      failures =
        Agent.get_and_update(__MODULE__, fn state ->
          n = Map.get(state, :release_failures, 0)

          if n > 0 do
            {n, %{state | release_failures: n - 1}}
          else
            {0, state}
          end
        end)

      if failures > 0 do
        {:error, :test_shell_release_failed}
      else
        do_release(lease)
      end
    end
  end

  def release_linux_dependency_baseline_lease(_lease), do: {:error, :invalid_lease}

  @doc false
  def release_linux_dependency_baseline_lease(lease, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    release_linux_dependency_baseline_lease(lease)
  end

  def release_linux_dependency_baseline_lease(_lease, _timeout_ms),
    do: {:error, :invalid_lease}

  defp materialize_pair do
    # Owner is the registry GenServer that called acquire — release must match.
    owner = self()

    with {:ok, tmp} <- resolve_tmp(),
         token <- Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         root <- Path.join(tmp, "arbor-test-linux-baseline-#{token}"),
         :ok <- mkdir_private(root),
         candidate <- Path.join(root, "candidate"),
         base <- Path.join(root, "base"),
         :ok <- write_baseline_tree(candidate),
         :ok <- write_baseline_tree(base),
         worker <- start_cleanup_worker(owner, root, token) do
      lease = %Lease{
        token: token,
        owner: owner,
        worker: worker,
        root_path: root,
        candidate_path: candidate,
        base_path: base
      }

      view = %{
        "candidate_path" => candidate,
        "base_path" => base,
        "receipt" => %{
          "schema" => "1",
          "platform" => "linux/test",
          "baseline_tree_digest" => String.duplicate("a", 64),
          "entry_count" => 1,
          "total_bytes" => byte_size(@baseline_marker)
        },
        "verified_copy" => true
      }

      {:ok, lease, view}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :dependency_baseline_acquire_failed}
    end
  end

  defp do_release(%Lease{token: token, owner: owner, worker: worker, root_path: root}) do
    if Process.alive?(worker) do
      reply_ref = make_ref()
      send(worker, {:release, token, owner, reply_ref})

      receive do
        {:released, ^reply_ref, result} -> result
      after
        5_000 -> {:error, :baseline_release_timeout}
      end
    else
      prove_root_absent(root)
    end
  end

  defp prove_root_absent(root) do
    case File.lstat(root) do
      {:error, :enoent} -> :ok
      _ -> {:error, :baseline_root_still_exists}
    end
  end

  defp start_cleanup_worker(owner, root, token) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)

      receive do
        {:release, ^token, ^owner, reply_ref} ->
          result = remove_root(root)
          send(owner, {:released, reply_ref, result})

        {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
          _ = remove_root(root)
      end
    end)
  end

  defp remove_root(root) do
    _ = File.rm_rf(root)
    prove_root_absent(root)
  end

  defp write_baseline_tree(path) do
    with :ok <- mkdir_private(path),
         :ok <- File.write(Path.join(path, "MARKER"), @baseline_marker),
         :ok <- File.chmod(Path.join(path, "MARKER"), 0o600) do
      :ok
    end
  end

  defp mkdir_private(path) do
    case File.mkdir(path) do
      :ok ->
        File.chmod(path, 0o700)

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> File.chmod(path, 0o700)
          _ -> {:error, :baseline_root_invalid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_tmp do
    case SafePath.resolve_real(System.tmp_dir!()) do
      {:ok, path} -> {:ok, path}
      _ -> {:error, :tmp_unavailable}
    end
  end
end
