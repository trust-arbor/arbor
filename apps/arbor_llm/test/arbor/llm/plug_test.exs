defmodule Arbor.LLM.PlugTest do
  @moduledoc """
  Tests the `Arbor.LLM.Plug` behaviour + `use` macro contract.

  `use Arbor.LLM.Plug` attaches the behaviour — nothing more.
  Halted-handling is the plug author's responsibility (Phoenix
  Plug doesn't try to inject it transparently either; both got
  burned by Elixir's `defoverridable` semantics).

  Mutating plugs should pattern-match `halted: true` as their first
  clause and pass through; observability plugs should ignore halted
  and fire. `Plugs.StalenessWarn` is an example of the latter — it
  needs to see replayed (halted) calls.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.Call

  # ── Test plugs ──────────────────────────────────────────────────────

  defmodule MutatingPlug do
    @moduledoc """
    A mutating plug — has an explicit halted clause as its first def,
    so halted calls pass through unchanged.
    """
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{halted: true} = call), do: call

    def call(%Call{} = call) do
      Call.put_metadata(call, %{
        invocations: [__MODULE__ | List.wrap(call.metadata[:invocations])]
      })
    end
  end

  defmodule ObservabilityPlug do
    @moduledoc """
    An observability plug — no halted clause, runs on every call.
    """
    use Arbor.LLM.Plug
    alias Arbor.LLM.Call

    def call(%Call{} = call) do
      Call.put_metadata(call, %{
        observed: [__MODULE__ | List.wrap(call.metadata[:observed])]
      })
    end
  end

  # ── Behaviour contract ─────────────────────────────────────────────

  describe "use Arbor.LLM.Plug" do
    test "attaches the Arbor.LLM.Plug behaviour" do
      behaviours =
        MutatingPlug.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Arbor.LLM.Plug in behaviours
    end
  end

  describe "MutatingPlug — explicit halted-first clause" do
    test "non-halted call runs the body" do
      call = Call.new(:complete, {}) |> MutatingPlug.call()
      assert call.metadata.invocations == [MutatingPlug]
    end

    test "halted call passes through unchanged" do
      call =
        :complete
        |> Call.new({})
        |> Call.halt()
        |> MutatingPlug.call()

      refute Map.has_key?(call.metadata, :invocations)
      assert call.halted == true
    end

    test "halted-passthrough preserves all other call state" do
      call =
        :complete
        |> Call.new({"openai", [], []})
        |> Call.put_metadata(%{trace: "xyz"})
        |> Call.assign(:agent_id, "agent_1")
        |> Call.halt()
        |> MutatingPlug.call()

      assert call.metadata.trace == "xyz"
      assert call.assigns.agent_id == "agent_1"
      assert call.request == {"openai", [], []}
    end
  end

  describe "ObservabilityPlug — no halted clause" do
    test "fires on non-halted calls" do
      call = Call.new(:complete, {}) |> ObservabilityPlug.call()
      assert call.metadata.observed == [ObservabilityPlug]
    end

    test "ALSO fires on halted calls — that's the point of an observability plug" do
      call =
        :complete
        |> Call.new({})
        |> Call.halt()
        |> ObservabilityPlug.call()

      assert call.metadata.observed == [ObservabilityPlug]
      assert call.halted == true
    end
  end
end
