defmodule Arbor.KernelRuntime.SafeManagementSurface do
  @moduledoc """
  Public facade for the temporary P1A safe-management surface.

  `project/1` and `schema/0` delegate to the closed construct core.
  A receipt is never bearer authority. Callers inject authorization
  independently. This module does not apply mutation effects.
  """

  alias Arbor.KernelRuntime.SafeManagementSurface.Core

  @doc "Closed safe-management surface schema identifier."
  @spec schema() :: String.t()
  defdelegate schema(), to: Core

  @doc "Admit a closed safe-management candidate and return the decision document."
  @spec project(map()) :: {:ok, map()} | {:error, term()}
  defdelegate project(candidate), to: Core
end
