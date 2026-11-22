defmodule Arbor.LLM.Plug do
  @moduledoc """
  Behaviour for the `Arbor.LLM` plug pipeline.

  Models the same shape as `Plug.Conn` for HTTP: each plug takes a
  `%Arbor.LLM.Call{}`, returns a (possibly transformed)
  `%Arbor.LLM.Call{}`, and the pipeline composes them via the `|>`
  operator.

  ## Why this pattern

  As the LLM call layer accumulates concerns — record/replay,
  cost tracking, telemetry, throttling, retry, circuit breaking — a
  plug pipeline composes them cleanly. Each plug is a single-purpose
  pure-ish function (side effects allowed but explicit), and the
  pipeline's order is visible at the call site.

  The pattern follows Arbor's CRC (Construct-Reduce-Convert)
  convention: `Arbor.LLM.Call.new/2` constructs, each plug reduces,
  the caller extracts `:result` to convert.

  ## Defining a plug

  Use `use Arbor.LLM.Plug` to declare the behaviour. If your plug
  shouldn't run on halted calls (most plugs), pattern-match
  `halted: true` as the first clause and pass through:

      defmodule Arbor.LLM.Plugs.MyPlug do
        use Arbor.LLM.Plug
        alias Arbor.LLM.Call

        def call(%Call{halted: true} = call), do: call

        def call(%Call{} = call) do
          # ... transform the call ...
          call
        end
      end

  Plugs that should run regardless of halted state (telemetry,
  logging, post-call observability) just don't add the halted clause:

      defmodule Arbor.LLM.Plugs.Telemetry do
        use Arbor.LLM.Plug

        def call(%Arbor.LLM.Call{} = call) do
          # runs regardless of halted state
          call
        end
      end

  Note: `Arbor.LLM.Pipeline.through/2` does NOT short-circuit
  halted calls — `halted` is a per-plug signal. Mutating plugs
  match it and pass through; observability plugs ignore it and
  fire. This lets a single pipeline serve both "do the work" and
  "warn me about how this call resolved" without two passes.

  ## Composing a pipeline

  At the call site, just pipe:

      Call.new(:complete, {model_spec, messages, opts})
      |> Plugs.Replay.call()
      |> Plugs.Dispatch.call()
      |> Plugs.Record.call()
      |> Plugs.StalenessWarn.call()
      |> Map.fetch!(:result)

  For dynamic / config-driven pipelines, use `Arbor.LLM.Pipeline.through/2`:

      Call.new(:complete, {model_spec, messages, opts})
      |> Pipeline.through(Application.get_env(:arbor_llm, :pipeline))
      |> Map.fetch!(:result)

  ## See also

  - `.claude/skills/llm-plug-pipeline.md` for the project-level guide
    on when and how to add new plugs.
  """

  @callback call(Arbor.LLM.Call.t()) :: Arbor.LLM.Call.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Arbor.LLM.Plug
    end
  end
end
