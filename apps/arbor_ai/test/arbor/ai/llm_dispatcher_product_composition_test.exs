defmodule Arbor.AI.LLMDispatcherProductCompositionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Dispatcher

  describe "impl/0" do
    test "defaults to Arbor.AI.Runtime.Dispatch when no override set" do
      # Capture the default actually applied by product Root configuration.
      product_default = Application.fetch_env!(:arbor_llm, :llm_dispatcher)
      on_exit(fn -> Application.put_env(:arbor_llm, :llm_dispatcher, product_default) end)
      Application.delete_env(:arbor_llm, :llm_dispatcher)
      Application.put_env(:arbor_llm, :llm_dispatcher, product_default)
      assert Dispatcher.impl() == Arbor.AI.Runtime.Dispatch
    end
  end
end
