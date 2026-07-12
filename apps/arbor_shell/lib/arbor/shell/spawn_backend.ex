defmodule Arbor.Shell.SpawnBackend do
  @moduledoc """
  Contract for commands that must spawn descendants inside an external unit.

  A backend is part of the operator-controlled Shell configuration. It must
  create an isolation unit before executing candidate-controlled code, mount
  only the exact `cwd_identity` and pinned tool identity, monitor `owner`,
  enforce the supplied absolute monotonic `deadline` and retained-output limit,
  and synchronously destroy the whole unit before returning any result,
  timeout, or error.

  Declaring capabilities is an admission check, not a substitute for their
  implementation. No host-process fallback is permitted when a configured
  backend is missing, unavailable, or returns an invalid result.
  """

  @required_capabilities MapSet.new([
                           :atomic_executable_identity,
                           :deadline,
                           :isolated_worktree_mount,
                           :owner_lifecycle,
                           :output_limit,
                           :spawn_processes,
                           :whole_unit_termination
                         ])

  @type request :: %{
          required(:tool) => map(),
          required(:args) => [String.t()],
          required(:cwd) => String.t(),
          required(:cwd_identity) => map(),
          required(:env) => %{String.t() => String.t() | false},
          required(:owner) => pid(),
          required(:deadline) => integer(),
          required(:timeout) => pos_integer(),
          required(:max_output_bytes) => pos_integer()
        }

  @callback capabilities() :: [atom()] | MapSet.t(atom())
  @callback available?(request()) :: :ok | {:error, term()}
  @callback execute(request()) :: {:ok, map()} | {:error, term()}

  @doc false
  @spec validate(module(), request()) :: :ok | {:error, term()}
  def validate(backend, request) when is_atom(backend) and is_map(request) do
    with true <- Code.ensure_loaded?(backend),
         true <- function_exported?(backend, :capabilities, 0),
         true <- function_exported?(backend, :available?, 1),
         true <- function_exported?(backend, :execute, 1),
         capabilities <- backend.capabilities() |> MapSet.new(),
         true <- MapSet.subset?(@required_capabilities, capabilities),
         :ok <- backend.available?(request) do
      :ok
    else
      false -> {:error, {:spawn_backend_unavailable, backend}}
      {:error, reason} -> {:error, {:spawn_backend_unavailable, reason}}
      _other -> {:error, {:spawn_backend_capability_missing, backend}}
    end
  rescue
    error -> {:error, {:spawn_backend_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:spawn_backend_unavailable, {kind, reason}}}
  end
end
