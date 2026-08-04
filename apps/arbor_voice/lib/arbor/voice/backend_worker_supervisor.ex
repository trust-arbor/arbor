defmodule Arbor.Voice.BackendWorkerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Arbor.Voice.BackendWorker
  alias Arbor.Voice.Redacted

  @name __MODULE__

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, @name)
    supervisor_opts = if is_nil(name), do: [], else: [name: name]
    DynamicSupervisor.start_link(__MODULE__, :ok, supervisor_opts)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc false
  @spec start_worker(
          DynamicSupervisor.supervisor(),
          pid(),
          reference(),
          module(),
          keyword(),
          Arbor.Voice.RealtimeBackend.egress_route(),
          keyword()
        ) :: {:ok, pid(), binary()} | {:error, atom()}
  def start_worker(
        supervisor,
        coordinator,
        generation,
        backend_module,
        backend_opts,
        frozen_route,
        opts \\ []
      )

  def start_worker(
        supervisor,
        coordinator,
        generation,
        backend_module,
        backend_opts,
        frozen_route,
        opts
      )
      when is_pid(coordinator) and is_reference(generation) and is_atom(backend_module) and
             is_list(backend_opts) and is_list(opts) do
    if coordinator != self() do
      {:error, :foreign_coordinator}
    else
      worker_token = :crypto.strong_rand_bytes(32)

      child_spec = %{
        id: make_ref(),
        start:
          {BackendWorker, :start_link,
           [
             coordinator,
             generation,
             Redacted.new(worker_token),
             backend_module,
             Redacted.new(backend_opts),
             Redacted.new(frozen_route),
             opts
           ]},
        restart: :temporary,
        shutdown: :brutal_kill,
        type: :worker
      }

      case DynamicSupervisor.start_child(supervisor, child_spec) do
        {:ok, worker} -> {:ok, worker, worker_token}
        {:ok, worker, _info} -> {:ok, worker, worker_token}
        {:error, _reason} -> {:error, :worker_start_failed}
      end
    end
  rescue
    _exception -> {:error, :worker_start_failed}
  catch
    _kind, _reason -> {:error, :worker_start_failed}
  end

  def start_worker(
        _supervisor,
        _coordinator,
        _generation,
        _backend_module,
        _backend_opts,
        _frozen_route,
        _opts
      ),
      do: {:error, :invalid_worker_config}
end
