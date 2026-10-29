defmodule Arbor.Contracts.Handler.Computable do
  @moduledoc """
  Behaviour for handler backends that perform computation.

  Implementations are registered in ComputeRegistry by backend name
  (e.g., "llm", "routing", "eval"). The ComputeHandler dispatches
  to the appropriate implementation based on the node's `purpose` attribute.

  Computable backends declare their capabilities (what kinds of computation
  they support) and availability (whether they can currently accept work).
  The ComputePolicy selects which backend to use when multiple are available.

  ## Example

      defmodule MyLlmComputable do
        @behaviour Arbor.Contracts.Handler.Computable

        @impl true
        def compute(%ScopedContext{} = ctx, opts) do
          prompt = ScopedContext.get(ctx, "prompt")
          {:ok, LLM.generate(prompt)}
        end

        @impl true
        def capabilities, do: [:text_generation, :code_generation]

        @impl true
        def capability_required(_ctx), do: "arbor://handler/compute/llm"

        @impl true
        def available?, do: true
      end
  """

  alias Arbor.Contracts.Handler.ScopedContext

  @doc """
  Execute computation with this backend.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @callback compute(ScopedContext.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  List the computational capabilities this backend provides.

  Used by ComputePolicy to select the best backend for a given task.
  """
  @callback capabilities() :: [atom()]

  @doc """
  Return the capability URI required for computation with this backend.
  """
  @callback capability_required(ScopedContext.t()) :: String.t()

  @doc """
  Check if this backend is currently available for computation.

  Should return `false` if the backend is down, rate-limited, or
  otherwise unable to accept work. Used by `list_available/0`.
  """
  @callback available?() :: boolean()

  @optional_callbacks [available?: 0]
end
