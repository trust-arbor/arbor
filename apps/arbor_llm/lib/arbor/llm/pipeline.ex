defmodule Arbor.LLM.Pipeline do
  @moduledoc """
  Compose a list of `Arbor.LLM.Plug` modules into a single
  transformation of an `Arbor.LLM.Call`.

  For static, known-at-compile-time pipelines, prefer explicit
  pipes — they're more readable and the plug order is visible at
  the call site:

      Call.new(:complete, request)
      |> Plugs.Replay.call()
      |> Plugs.Dispatch.call()
      |> Plugs.Record.call()
      |> Map.fetch!(:result)

  Use `through/2` when the pipeline needs to be configured at
  runtime — operator overrides, test-specific compositions, etc.:

      Call.new(:complete, request)
      |> Pipeline.through(Application.get_env(:arbor_llm, :pipeline, default()))
      |> Map.fetch!(:result)
  """

  alias Arbor.LLM.Call

  @doc """
  Run `call` through `plugs`, returning the final call.

  Each plug's `call/1` is invoked in order. Plugs that pattern-match
  on `halted: true` (via `use Arbor.LLM.Plug`) pass through unchanged,
  which lets a single short-circuit (e.g. `Plugs.Replay` finding a
  fixture) skip the rest of the pipeline's meaningful work.
  """
  @spec through(Call.t(), [module()]) :: Call.t()
  def through(%Call{} = call, plugs) when is_list(plugs) do
    Enum.reduce(plugs, call, fn plug, acc -> plug.call(acc) end)
  end
end
