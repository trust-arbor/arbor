defmodule Arbor.LLM.Plugs.Record do
  @moduledoc """
  Persist the call's result as a fixture on disk.

  Only fires when:

    1. The call has a result (Dispatch ran), AND
    2. The result wasn't itself a replay (no `metadata.replayed_from`).

  The second condition prevents recording a fixture as a side-effect
  of replaying it — otherwise every replay would re-stamp the
  recording timestamp, making `Plugs.StalenessWarn` think the
  fixture was always fresh.

  ## When to use

  Add to your pipeline when capturing new fixtures — typically a
  one-off "record mode" run that calls the real provider and saves
  responses for future replay. Put after `Plugs.Dispatch` (and
  optionally after `Plugs.Replay`, so existing fixtures don't get
  re-recorded).

  Stream results must be eager event lists or `Arbor.LLM.OwnedStream` values.
  Generic lazy enumerables (including `Stream.resource/3`) are rejected before
  enumeration because they cannot guarantee bounded cancellation/finalization.

  Pair with `Application.put_env(:arbor_llm, :recorder, mode:
  :record)` if you want to gate recording on an explicit mode flag
  rather than the pipeline composition itself.
  """

  use Arbor.LLM.Plug
  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Fixture

  def call(%Call{halted: true} = call), do: call

  def call(%Call{result: result, metadata: metadata} = call)
      when not is_nil(result) do
    if Map.has_key?(metadata, :replayed_from) do
      # Don't re-record a replay.
      call
    else
      case Fixture.record(call, result) do
        {:ok, replayable_result} ->
          call
          |> Map.put(:result, replayable_result)
          |> Call.put_metadata(%{recorded_to: Fixture.path_for(call)})

        {:error, reason} ->
          %{call | result: {:error, {:fixture_record_failed, reason}}}
      end
    end
  end

  # No result yet (Dispatch hasn't run) — pass through.
  def call(%Call{} = call), do: call
end
