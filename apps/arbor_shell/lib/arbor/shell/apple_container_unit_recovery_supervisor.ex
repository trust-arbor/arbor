defmodule Arbor.Shell.AppleContainerUnitRecoverySupervisor do
  @moduledoc """
  Named static supervisor for Apple Container unit-intent recovery.

  Contains, in order:

  1. A named DynamicSupervisor for temporary recovery workers
  2. `AppleContainerUnitRecoveryReconciler` (permanent)

  Child shutdown is `:infinity`. Strategy is `one_for_all` with a zero internal
  restart budget so DynamicSupervisor or Reconciler loss exits this composite
  supervisor instead of silently restarting inside the same parent PID. Wired
  permanently under `Arbor.Shell.Application` after the unit journal and before
  UnitSupervisor / DrainCoordinator so Shell `rest_for_one` turns over live unit
  owners before a replacement reconciler performs its startup sweep.
  """

  use Supervisor

  alias Arbor.Shell.AppleContainerUnitRecoveryReconciler

  @name __MODULE__
  @worker_supervisor Arbor.Shell.AppleContainerUnitRecoveryWorkerSupervisor

  @doc """
  Start the named recovery composite supervisor.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = if is_list(opts), do: Keyword.get(opts, :name, @name), else: @name
    Supervisor.start_link(__MODULE__, :production, name: name)
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [List.wrap(opts)]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc false
  @spec worker_supervisor_name() :: atom()
  def worker_supervisor_name, do: @worker_supervisor

  @doc false
  @spec name() :: atom()
  def name, do: @name

  @impl true
  def init(:production) do
    children = [
      %{
        id: @worker_supervisor,
        start:
          {DynamicSupervisor, :start_link, [[name: @worker_supervisor, strategy: :one_for_one]]},
        type: :supervisor,
        restart: :permanent,
        shutdown: :infinity
      },
      AppleContainerUnitRecoveryReconciler.child_spec(:production)
    ]

    # Zero restart budget: any permanent child loss terminates this supervisor
    # so a parent rest_for_one chain can restart the composite under a new PID
    # after turning over later unit owners.
    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 0,
      max_seconds: 1
    )
  end

  def init(_other), do: {:stop, :invalid_recovery_supervisor_init}
end
