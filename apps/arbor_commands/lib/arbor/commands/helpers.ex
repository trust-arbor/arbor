defmodule Arbor.Commands.Helpers do
  @moduledoc """
  Shared helpers for the side-effecting slash commands in
  `Arbor.Commands.*`. Currently just the persistence wrapper used by
  `/model`, `/runtime`, and `/fallback` to write per-session edits to
  the agent's profile.
  """

  require Logger

  alias Arbor.Agent.ProfileStore

  @doc """
  Persist a `last_model_config` field to the agent's profile.

  Used by commands that have already updated the live session (via
  `Session.set_model/2`, `Session.set_runtime/2`, etc.) and want the
  change to survive restarts. The session edit is the source of truth
  for this turn; this is best-effort persistence for the next restart.

    * `agent_id` — agent identifier from the command context. If `nil`
      or empty (transient session, test context), this is a no-op.
    * `field` — atom key under `metadata[:last_model_config]`
      (`:model`, `:runtime`, `:fallback_chain`, etc.).
    * `value` — the value to store.
    * `tag` — short string identifying the command for log messages.

  Failures (profile not found, store unavailable, etc.) are logged at
  `:warning` level but never raised — the user's command doesn't fail
  just because persistence didn't reach Postgres.
  """
  @spec persist_model_config_field(String.t() | nil, atom(), term(), String.t()) :: :ok
  def persist_model_config_field(agent_id, field, value, tag) do
    case agent_id do
      id when is_binary(id) and id != "" ->
        try do
          case ProfileStore.put_model_config_value(id, field, value) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[#{tag}] persistence failed for #{id} (#{field}): #{inspect(reason)} — " <>
                  "live session updated but change may not survive restart"
              )

              :ok
          end
        rescue
          e ->
            Logger.warning(
              "[#{tag}] persistence raised for #{agent_id} (#{field}): " <>
                "#{Exception.message(e)} — live session updated, change may not survive restart"
            )

            :ok
        catch
          :exit, reason ->
            Logger.warning(
              "[#{tag}] persistence exited for #{agent_id} (#{field}): " <>
                "#{inspect(reason)} — live session updated, change may not survive restart"
            )

            :ok
        end

      _ ->
        :ok
    end
  end
end
