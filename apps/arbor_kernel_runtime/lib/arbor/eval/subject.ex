defmodule Arbor.Eval.Subject do
  @moduledoc """
  Behaviour for a callable evaluation subject.

  A subject receives one dataset input and returns the output that graders will
  compare with the sample's expected value.
  """

  @callback run(input :: term(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
end
