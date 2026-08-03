defmodule Arbor.Voice.ToolRouter do
  @moduledoc """
  Library-local contract for voice tool routing (VP-04E3 / VP-05B / VOICE-8/9).

  Implementations run under a supervised owner/worker outside the Session
  process. Production uses `Arbor.Voice.ToolRouter.FrontDesk`.
  """

  @doc """
  Static backend-native function declarations for `configure/2`.

  Must return a small, unique-name, strict list of function schemas. Session
  validates before resource/backend effects.
  """
  @callback tools() :: [map()]

  @doc """
  Invoke one tool with a Session-built closed context map and a private
  scope-locked authority object.

  Context keys: `:call_id`, `:name`, `:arguments`, `:user_id`, `:agent_id`,
  `:engagement_id`. Must not contain credentials, capabilities, pids, tokens,
  or transcript text.

  Authority is a private map of callables (e.g. `:consult_agent`); never raw
  credentials or caller-selectable MFA.
  """
  @callback invoke(context :: map(), authority :: map()) ::
              {:ok, term()} | {:error, atom()}
end
