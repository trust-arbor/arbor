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

  Use `use Arbor.LLM.Plug` to inherit the halted-passthrough clause —
  any plug that doesn't want to act when an upstream plug has set
  `halted: true` just doesn't have to think about it:

      defmodule Arbor.LLM.Plugs.MyPlug do
        use Arbor.LLM.Plug
        alias Arbor.LLM.Call

        # This clause only runs when halted: false (the use-injected
        # clause matches halted: true first and passes through).
        def call(%Call{} = call) do
          # ... transform the call ...
          call
        end
      end

  Plugs that should run even on halted calls (telemetry, logging)
  can override the halted clause:

      defmodule Arbor.LLM.Plugs.AlwaysRun do
        @behaviour Arbor.LLM.Plug

        def call(%Arbor.LLM.Call{} = call) do
          # runs regardless of halted state
          call
        end
      end

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

      # Halted calls pass through this plug unchanged. The plug's
      # actual `call/1` clauses below only see non-halted calls.
      # Override this clause explicitly if you want to run on halted
      # calls (e.g. telemetry, post-call observability).
      def call(%Arbor.LLM.Call{halted: true} = call), do: call

      defoverridable call: 1
    end
  end
end
