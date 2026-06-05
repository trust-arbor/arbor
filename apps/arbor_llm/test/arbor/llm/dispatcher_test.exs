defmodule Arbor.LLM.DispatcherTest do
  @moduledoc """
  Unit tests for the dispatcher behaviour seam: `Arbor.LLM.Dispatcher.impl/0`
  resolution from Application env + the `dispatch/2` convenience wrapper
  that lets callers in `arbor_orchestrator` reach the canonical
  `Arbor.AI.Runtime.Dispatch` without a horizontal cross-library alias.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Dispatcher

  defmodule FakeDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    @impl true
    def dispatch(_request, opts) do
      {:ok, %Arbor.LLM.Response{text: "fake from dispatcher", raw: %{opts: opts}}}
    end
  end

  describe "impl/0" do
    test "defaults to Arbor.AI.Runtime.Dispatch when no override set" do
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      assert Dispatcher.impl() == Arbor.AI.Runtime.Dispatch
    end

    test "respects Application env override" do
      Application.put_env(:arbor_orchestrator, :llm_dispatcher, FakeDispatcher)
      on_exit(fn -> Application.delete_env(:arbor_orchestrator, :llm_dispatcher) end)

      assert Dispatcher.impl() == FakeDispatcher
    end
  end

  describe "dispatch/2 — convenience wrapper" do
    test "routes through the configured implementation" do
      Application.put_env(:arbor_orchestrator, :llm_dispatcher, FakeDispatcher)
      on_exit(fn -> Application.delete_env(:arbor_orchestrator, :llm_dispatcher) end)

      request = %Arbor.LLM.Request{model: "any", messages: []}
      assert {:ok, response} = Dispatcher.dispatch(request, foo: :bar)
      assert response.text == "fake from dispatcher"
      assert response.raw.opts == [foo: :bar]
    end
  end

  # Note: behaviour-conformance tests for `Arbor.AI.Runtime.Dispatch`
  # live in arbor_ai's test suite — arbor_llm doesn't depend on arbor_ai
  # so the canonical impl module isn't loaded here.
end
