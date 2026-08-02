defmodule Arbor.Voice.Config do
  @moduledoc """
  Configuration seam for arbor_voice (CONTRACT_RULES §8). One function per
  setting, reading Application.get_env(:arbor_voice, key, default) with a
  default matching current behaviour.
  """

  @doc """
  The Arbor.Voice.RealtimeBackend implementation Arbor.Voice.Session
  (VP-04) opens. Swappable via `config :arbor_voice, backend: MyBackend`.
  Defaults to the xAI Realtime backend name (VP-03) — that module does not
  exist yet in this slice; naming it here only fixes the intended default
  atom, nothing calls it until VP-03 lands.
  """
  @spec backend_module() :: module()
  def backend_module,
    do: Application.get_env(:arbor_voice, :backend, Arbor.Voice.Backend.XaiRealtime)

  @doc """
  Identifier used to resolve the :user-scoped engagement voice shares with
  the dashboard (VOICE-2). nil until an operator configures it (VP-04
  defines how the value is chosen/defaulted).
  """
  @spec user_id() :: String.t() | nil
  def user_id, do: Application.get_env(:arbor_voice, :user_id)
end
