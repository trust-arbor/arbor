defmodule Arbor.Trust.Contracts.RuntimeHost do
  @moduledoc "Trusted product startup and provider composition; callbacks run before PolicyHost claims."
  @callback prepare_startup() :: :ok | {:error, term()}
  @callback start_profile() :: :full | :activation_only | {:error, term()}
  @callback provider_gate_child_spec(atom(), [atom()]) ::
              Supervisor.child_spec() | {:error, term()}
  @callback start_provider_gate_supervisor([Supervisor.child_spec()], atom(), atom()) ::
              {:ok, pid()} | {:error, term()}
end
