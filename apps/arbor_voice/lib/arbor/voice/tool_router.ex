defmodule Arbor.Voice.ToolRouter do
  @moduledoc """
  Library-local contract for voice tool routing (VP-04E3 / VOICE-8).

  Implementations run under a supervised owner/worker outside the Session
  process. Production uses `Arbor.Voice.ToolRouter.EmptyCatalog`.
  """

  @doc """
  Invoke one tool with a Session-built closed context map.

  Context keys: `:call_id`, `:name`, `:arguments`, `:user_id`, `:agent_id`,
  `:engagement_id`. Must not contain credentials, capabilities, pids, tokens,
  or transcript text.
  """
  @callback invoke(context :: map()) :: {:ok, term()} | {:error, atom()}
end
