defmodule Arbor.Shell.TrustedBuild do
  @moduledoc false

  alias Arbor.Shell.OwnedTree
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.TrustedBuild.HexSeed
  alias Arbor.Shell.TrustedBuild.Identity
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuild.Phase
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuild.Request
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @faults [:none, :force_cleanup_failure, :force_identity_capture_failure, :omit_hex_seed]
  @token_bytes 32

  @spec acquire(term(), atom()) :: {:ok, Lease.Handle.t(), map()} | {:error, term()}
  def acquire(request, fault \\ :none)

  def acquire(request, fault) when fault in @faults do
    with {:ok, admitted} <- Request.admit(request),
         :ok <- require_darwin(),
         {:ok, source_owned} <- bind_source(admitted.identity),
         {:ok, binding, authority_pid, authority_gen} <-
           TrustedBuildToolchainAuthority.checkout(),
         {:ok, registry_pid, registry_gen} <- OwnedTreeRegistry.checkout() do
      materialize(
        admitted.identity,
        source_owned,
        binding,
        {authority_pid, authority_gen},
        {
          registry_pid,
          registry_gen
        },
        fault
      )
    end
  end

  def acquire(_request, _fault), do: {:error, :invalid_trusted_build_request}

  @spec execute(term(), term()) :: {:ok, map()} | {:error, term()}
  def execute(lease, phase) do
    with {:ok, admitted_phase} <- Plan.admit_phase(phase),
         :ok <- require_darwin(),
         %Lease.Handle{} <- lease,
         {:ok, session} <- Lease.begin_phase(lease, admitted_phase, self()) do
      session = Map.put(session, :lease, lease)
      # Phase.run/1 commits the terminal result to the lease itself, inside the
      # phase process, before it replies here -- no separate owner-side commit.
      Phase.run(session)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_lease}
    end
  end

  @spec inventory(Lease.Handle.t()) :: {:ok, map()} | {:error, term()}
  def inventory(%Lease.Handle{} = lease), do: Lease.inventory_release(lease)
  def inventory(_lease), do: {:error, :invalid_lease}

  @spec release(Lease.Handle.t()) :: :ok | {:error, term()}
  def release(%Lease.Handle{} = lease), do: Lease.release(lease)
  def release(_lease), do: {:error, :invalid_lease}

  defp require_darwin do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _other -> {:error, :trusted_build_unavailable}
    end
  end

  defp bind_source(identity) do
    with :ok <- Identity.verify_owned_identity(identity),
         {:ok, :unbound, _gen} <- OwnedTreeRegistry.fetch(identity),
         :ok <- OwnedTreeRegistry.cas(identity, :unbound, :trusted_build_source) do
      {:ok, identity}
    else
      {:ok, _purpose, _gen} -> {:error, :owned_tree_purpose_mismatch}
      {:error, :owned_tree_not_registered} -> {:error, :owned_tree_not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unbind_source(identity) do
    _ = OwnedTreeRegistry.cas(identity, :trusted_build_source, :unbound)
    :ok
  end

  defp materialize(source_identity, source_owned, binding, authority, registry, fault) do
    case create_workspace(source_identity, binding, fault) do
      {:ok, roots, identities} ->
        finish_acquire(
          source_identity,
          source_owned,
          binding,
          authority,
          registry,
          roots,
          identities,
          fault
        )

      {:error, reason} ->
        unbind_source(source_identity)
        {:error, reason}
    end
  end

  defp finish_acquire(
         source_identity,
         source_owned,
         binding,
         {authority_pid, authority_gen},
         {registry_pid, registry_gen},
         roots,
         identities,
         fault
       ) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    attrs = %{
      token: token,
      owner: self(),
      registry: {registry_pid, registry_gen},
      authority: {authority_pid, authority_gen},
      identities: identities,
      roots: roots,
      binding: binding,
      fault: fault
    }

    case Lease.start_worker(attrs) do
      {:ok, worker} ->
        lease = Lease.handle(worker, token, self())
        {:ok, view} = Lease.view(lease)
        {:ok, lease, view}

      {:error, reason} ->
        _ = cleanup_workspace(roots.parent)
        unbind_source(source_identity)
        {:error, reason}
    end
  catch
    kind, reason ->
      _ = cleanup_workspace(roots.parent)
      unbind_source(source_owned)
      {:error, {:trusted_build_acquire_failed, {kind, reason}}}
  end

  defp create_workspace(source_identity, binding, fault) do
    tmp = System.tmp_dir!()
    token = :crypto.strong_rand_bytes(@token_bytes) |> Base.encode16(case: :lower)
    path = Path.join(tmp, "arbor-tb-" <> token)

    case Arbor.Shell.create_private_owned_tree(path) do
      {:ok, parent} ->
        case OwnedTreeRegistry.cas(parent, :unbound, :trusted_build_workspace) do
          :ok ->
            complete_workspace(parent, source_identity, binding, fault)

          {:error, reason} ->
            _ = cleanup_workspace(parent)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_workspace(parent, _source_identity, _binding, :force_identity_capture_failure) do
    _ = cleanup_workspace(parent)
    {:error, :root_identity_capture_failed}
  end

  defp complete_workspace(parent, source_identity, binding, fault) do
    source_root = Plan.source_root(source_identity.path)
    wrapper_path = Plan.wrapper_path(source_identity.path)

    with {:ok, children} <- create_writables(parent.path),
         {:ok, archives, digest} <- seed_archives(parent.path, binding, fault),
         :ok <- seed_hex_cache(children.hex.path, binding, fault),
         :ok <- reject_source_overlap(source_root, children, archives),
         {:ok, source} <- Identity.pin_directory(source_root),
         {:ok, wrapper} <- Identity.pin_regular_file(wrapper_path) do
      roots = Map.merge(children, %{parent: parent, archives: archives})

      identities = %{
        source: source,
        source_owned: source_identity,
        wrapper: wrapper,
        archives: archives,
        archives_digest: digest
      }

      {:ok, roots, identities}
    else
      {:error, reason} ->
        _ = cleanup_workspace(parent)
        {:error, reason}
    end
  end

  defp reject_source_overlap(source_root, children, archives) do
    paths = [archives.path | Enum.map(Map.values(children), & &1.path)]

    if Enum.any?(paths, &Identity.overlap?(source_root, &1)) do
      {:error, :trusted_build_overlap}
    else
      :ok
    end
  end

  defp create_writables(parent_path) do
    Enum.reduce_while(Plan.writable_names(), {:ok, %{}}, fn name, {:ok, acc} ->
      child = Path.join(parent_path, name)

      case File.mkdir(child) do
        :ok ->
          case File.chmod(child, 0o700) do
            :ok ->
              case Identity.pin_writable_directory(child) do
                {:ok, identity} ->
                  {:cont, {:ok, Map.put(acc, String.to_existing_atom(name), identity)}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end

            {:error, _reason} ->
              {:halt, {:error, :owned_tree_chmod_failed}}
          end

        {:error, _reason} ->
          {:halt, {:error, :owned_tree_create_failed}}
      end
    end)
  end

  defp seed_archives(parent_path, binding, fault) do
    dest = Path.join(parent_path, "archives")

    result =
      case {fault, binding.hex_archive} do
        {:omit_hex_seed, _} ->
          HexSeed.seed_empty_readonly(dest)

        {_, :empty} ->
          HexSeed.seed_empty_readonly(dest)

        {_, {:tree, source, _dir, digest}} ->
          child = Path.join(dest, Path.basename(source))

          # `dest` (the outer archives root) must stay writable until `child`
          # has been fully created and finalized inside it -- HexSeed.seed_tree/4
          # already normalizes `child`'s own modes to :readonly; only after that
          # does `dest` itself get its final read-only mode.
          with :ok <- ensure_dir_mode_create(dest, 0o700),
               {:ok, _child_digest} <- HexSeed.seed_tree(source, child, digest, :readonly),
               :ok <- File.chmod(dest, 0o555) do
            Identity.tree_digest(dest)
          end
      end

    case result do
      {:ok, digest} ->
        case Identity.pin_directory(dest) do
          {:ok, dir} -> {:ok, dir, digest}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seed_hex_cache(_hex_home, _binding, :omit_hex_seed), do: :ok

  defp seed_hex_cache(_hex_home, %{hex_cache: :empty}, _fault), do: :ok

  defp seed_hex_cache(hex_home, %{hex_cache: {:tree, source, _dir, digest}}, _fault) do
    case HexSeed.seed_tree(source, hex_home, digest, :writable) do
      {:ok, _digest} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_dir_mode_create(path, mode) do
    case File.mkdir_p(path) do
      :ok ->
        case File.chmod(path, mode) do
          :ok -> :ok
          {:error, _reason} -> {:error, :hex_seed_chmod_failed}
        end

      {:error, _reason} ->
        {:error, :hex_seed_mkdir_failed}
    end
  end

  defp cleanup_workspace(parent) when is_map(parent) do
    identity = Map.take(parent, [:path, :type, :device, :minor_device, :inode])

    case OwnedTree.remove(identity) do
      :ok ->
        _ = OwnedTreeRegistry.delete(identity)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_workspace(_parent), do: :ok
end
