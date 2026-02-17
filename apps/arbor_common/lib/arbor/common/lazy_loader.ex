defmodule Arbor.Common.LazyLoader do
  @moduledoc """
  Safe optional-module bridge for cross-library calls.

  Combines `Code.ensure_loaded?/1` and `function_exported?/3` into a single
  check, eliminating the duplicated bridge pattern found across 14+ modules.

  ## Usage

      if LazyLoader.exported?(Arbor.AI, :generate_text, 2) do
        Arbor.AI.generate_text(prompt, opts)
      else
        {:error, :not_available}
      end
  """

  @doc """
  Returns `true` when `module` is loadable and exports `function/arity`.

  Equivalent to:

      Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  """
  @spec exported?(module(), atom(), non_neg_integer()) :: boolean()
  def exported?(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
