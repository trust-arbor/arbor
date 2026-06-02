defmodule Arbor.LLM.Plugs.Replay do
  @moduledoc """
  Short-circuit plug — looks up a fixture for the call and, if one
  exists, fills in `:result` and halts the pipeline. If no fixture
  exists, passes through unchanged so downstream plugs (typically
  `Plugs.Dispatch`) can handle the real call.

  When this plug halts, it records the fixture's path and recording
  timestamp in `call.metadata`:

      %{
        replayed_from: "test/fixtures/llm_recordings/<hash>.json",
        recorded_at: ~U[2026-06-02 16:45:00Z]
      }

  Downstream plugs like `Plugs.StalenessWarn` read these to act on
  the replay provenance.

  ## When to use

  Add this to your pipeline when you want tests to short-circuit
  against persisted responses instead of hitting real LLM endpoints.
  Pair with `Plugs.Record` (in a separate pipeline configuration) to
  capture new fixtures.
  """

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Fixture

  def call(%Call{halted: true} = call), do: call

  def call(%Call{result: nil} = call) do
    case Fixture.load(call) do
      {:ok, response, recorded_at} ->
        call
        |> Map.put(:result, response)
        |> Call.put_metadata(%{
          replayed_from: Fixture.path_for(call),
          recorded_at: recorded_at
        })
        |> Call.halt()

      :not_found ->
        call
    end
  end

  # Result already set by an earlier plug — pass through.
  def call(%Call{} = call), do: call
end
