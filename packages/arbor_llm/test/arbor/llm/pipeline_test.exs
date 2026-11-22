defmodule Arbor.LLM.PipelineTest do
  @moduledoc """
  Tests `Pipeline.through/2` semantics — reduce over a list of plugs
  WITHOUT short-circuiting on `halted: true`.

  `halted` is per-plug, not pipeline-wide: mutating plugs ignore
  halted calls; observability plugs run on them. Pipeline.through
  hands every call to every plug and lets each one decide.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.Call
  alias Arbor.LLM.Pipeline

  # Stamping plugs that record their own invocation in metadata.order.

  defmodule First do
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{} = call) do
      Call.put_metadata(call, %{order: List.wrap(call.metadata[:order]) ++ [:first]})
    end
  end

  defmodule Second do
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{} = call) do
      Call.put_metadata(call, %{order: List.wrap(call.metadata[:order]) ++ [:second]})
    end
  end

  defmodule Third do
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{} = call) do
      Call.put_metadata(call, %{order: List.wrap(call.metadata[:order]) ++ [:third]})
    end
  end

  # Mutating plug pattern: skips on halted.
  defmodule MutatingStamper do
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{halted: true} = call), do: call

    def call(%Call{} = call) do
      Call.put_metadata(call, %{
        mutating_order: List.wrap(call.metadata[:mutating_order]) ++ [__MODULE__]
      })
    end
  end

  defmodule Halt do
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{} = call), do: call |> First.call() |> Call.halt()
  end

  describe "through/2" do
    test "runs plugs in list order" do
      call =
        :complete
        |> Call.new({})
        |> Pipeline.through([First, Second, Third])

      assert call.metadata.order == [:first, :second, :third]
    end

    test "empty plug list returns the call unchanged" do
      call = :complete |> Call.new({}) |> Pipeline.through([])
      assert call.operation == :complete
      assert call.metadata[:order] == nil
    end

    test "DOES NOT short-circuit on halted — every plug gets the call" do
      call =
        :complete
        |> Call.new({})
        |> Pipeline.through([Halt, Second, Third])

      assert call.halted == true
      # Halt ran First, then halted. Second and Third still received
      # the (halted) call and stamped themselves — they don't have
      # explicit halted clauses, so they fire on every call.
      assert call.metadata.order == [:first, :second, :third]
    end

    test "mutating-pattern plugs respect halted state themselves" do
      # MutatingStamper has its own `halted: true` clause and
      # passes through; Second/Third have no halted clause and fire.
      call =
        :complete
        |> Call.new({})
        |> Pipeline.through([Halt, MutatingStamper, Second])

      assert call.halted == true
      assert call.metadata.order == [:first, :second]
      assert call.metadata[:mutating_order] == nil
    end

    test "equivalent to explicit pipe chain" do
      pipeline_result =
        :complete |> Call.new({}) |> Pipeline.through([First, Second, Third])

      explicit_pipe_result =
        :complete |> Call.new({}) |> First.call() |> Second.call() |> Third.call()

      assert pipeline_result.metadata.order == explicit_pipe_result.metadata.order
      assert pipeline_result.halted == explicit_pipe_result.halted
      assert pipeline_result.assigns == explicit_pipe_result.assigns
    end
  end
end
