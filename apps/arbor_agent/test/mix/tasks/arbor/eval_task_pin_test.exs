defmodule Mix.Tasks.Arbor.Eval.TaskPinTest do
  @moduledoc """
  The documented no-arg `mix arbor.eval.task` used to pin `opts[:model]`
  before applying the default, so pinning no-op'd and production routing
  overrode the eval model.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  test "no --model still resolves a pin target" do
    {model, provider} = Mix.Tasks.Arbor.Eval.Task.resolve_pin_target([])

    assert is_binary(model) and model != ""
    assert is_atom(provider)
  end

  test "explicit --model/--provider win over the default" do
    assert {"x-preview-f-free", :opencode_zen} =
             Mix.Tasks.Arbor.Eval.Task.resolve_pin_target(
               model: "x-preview-f-free",
               provider: "opencode_zen"
             )
  end
end
