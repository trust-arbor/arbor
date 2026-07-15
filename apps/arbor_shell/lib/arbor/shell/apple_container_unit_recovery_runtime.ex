defmodule Arbor.Shell.AppleContainerUnitRecoveryRuntime do
  @moduledoc """
  Production runtime for durable Apple Container unit-intent recovery.

  Invokes only `Executor.run_bound/3` with a startup-pinned Executable and
  structured argv. Does not shell out, look up PATH, or use session-supervised
  ports.
  """

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.Executor

  @doc false
  @spec run_bound(Executable.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_bound(%Executable{} = executable, args, opts)
      when is_list(args) and is_list(opts) do
    case Executor.run_bound(executable, args, opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def run_bound(_executable, _args, _opts), do: {:error, :invalid_run_bound}

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_tuple(reason) do
    components = Tuple.to_list(reason)

    if components != [] and Enum.all?(components, &is_atom/1) do
      reason
    else
      :runtime_operation_failed
    end
  end

  defp bound_reason(_reason), do: :runtime_operation_failed
end
