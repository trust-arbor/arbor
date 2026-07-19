defmodule Arbor.Commands.CodingBenchmarkHostileInspect do
  @moduledoc false

  # Compiled under test elixirc_paths so the Inspect implementation is
  # available before protocol consolidation. Used only to prove terminal
  # reason sanitization never dispatches custom Inspect callbacks.
  defstruct [:secret]

  defimpl Inspect do
    def inspect(%{secret: secret}, _opts) do
      raise "hostile inspect leaked #{inspect(secret)}"
    end
  end
end
