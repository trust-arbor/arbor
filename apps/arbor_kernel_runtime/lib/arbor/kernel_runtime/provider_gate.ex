defmodule Arbor.KernelRuntime.ProviderGate do
  @moduledoc """
  Generic startup-ordering barrier for closed provider roots.

  After this process wins its exact registered name, `init/1` admits
  its ordered roots via `Application.ensure_all_started/1`. It is not an
  application owner, rollback coordinator, or liveness bridge. Provider
  applications are VM-global monotonic state. A `rest_for_one` restart may
  re-call `ensure_all_started/1` (idempotent) and restart later Arbor
  children; that does not own provider liveness.

  Full-release inclusion and permanence of these `runtime: false` roots
  remain an explicit unsatisfied P1E-2 exit gate.
  """

  use GenServer

  alias Arbor.Common.SafePath
  alias Arbor.KernelRuntime.ProviderGate.SDKPath

  @roots [:os_mon, :recon, :mint, :finch, :req]

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Arbor.KernelRuntime.provider_gate_child_spec(__MODULE__, @roots)
  end

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    roots = Keyword.fetch!(opts, :roots)

    case GenServer.start_link(__MODULE__, roots, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:error, {:provider_gate_name_collision, pid}}

      other ->
        other
    end
  end

  @impl true
  def init(roots) do
    maybe_recover_curated_sdk_path(roots)

    case start_each(roots) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Recovery uses current full configuration plus an existing valid binding.
  # The binding does not attest an immutable startup mode. Other named gates,
  # current activation_only, and name collisions never perform this discovery.
  defp maybe_recover_curated_sdk_path(roots) do
    recover_curated_sdk_path(roots)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp recover_curated_sdk_path(@roots) do
    if Process.whereis(__MODULE__) == self() and
         Arbor.KernelRuntime.start_profile() == :full do
      case Arbor.KernelRuntime.boot_profile() do
        {:ok, _snapshot} -> recover_os_mon_path()
        {:error, :not_bound} -> :ok
      end
    else
      :ok
    end
  end

  defp recover_curated_sdk_path(_roots), do: :ok

  defp recover_os_mon_path do
    if not is_nil(Application.spec(:os_mon)) or
         :code.where_is_file(~c"os_mon.app") != :non_existing do
      :ok
    else
      case :code.lib_dir(:os_mon) do
        path when is_list(path) -> :ok
        {:error, :bad_name} -> append_normal_os_mon_ebin()
      end
    end
  end

  defp append_normal_os_mon_ebin do
    with {:ok, ebin} <- normal_os_mon_ebin() do
      case :code.add_pathz(String.to_charlist(ebin)) do
        true -> :ok
        {:error, _reason} -> {:error, {:provider_sdk_path_unavailable, :path_rejected}}
      end
    end
  end

  defp normal_os_mon_ebin do
    root = List.to_string(:code.root_dir())
    lib = List.to_string(:code.lib_dir())

    with {:ok, canonical_root} <- SafePath.resolve_real(root),
         {:ok, canonical_lib} <- SafePath.resolve_real(lib),
         :ok <- SDKPath.validate_root(canonical_root, canonical_lib),
         {:ok, %File.Stat{type: :directory, uid: uid}} <- File.lstat(canonical_root),
         :ok <- normal_sdk_entry(canonical_root, :directory, uid),
         :ok <- normal_sdk_entry(canonical_lib, :directory, uid),
         {:ok, entries} <- File.ls(canonical_lib),
         {:ok, name} <- SDKPath.one_component(entries),
         component = Path.join(canonical_lib, name),
         ebin = Path.join(component, "ebin"),
         :ok <- normal_sdk_entry(component, :directory, uid),
         :ok <- normal_sdk_entry(ebin, :directory, uid),
         :ok <- normal_sdk_entry(Path.join(ebin, "os_mon.app"), :regular, uid) do
      {:ok, ebin}
    else
      {:error, {:provider_sdk_path_unavailable, _reason}} = error -> error
      {:error, :enoent} -> {:error, {:provider_sdk_path_unavailable, :missing}}
      {:error, :not_found} -> {:error, {:provider_sdk_path_unavailable, :missing}}
      _other -> {:error, {:provider_sdk_path_unavailable, :unsafe}}
    end
  end

  defp normal_sdk_entry(path, type, uid) do
    SDKPath.validate_entry(
      path,
      SafePath.resolve_real(path),
      File.lstat(path),
      type,
      uid
    )
  end

  defp start_each([]), do: :ok

  defp start_each([root | rest]) do
    case Application.ensure_all_started(root) do
      {:ok, _started} -> start_each(rest)
      {:error, reason} -> {:error, {:provider_start_failed, root, reason}}
    end
  end
end
