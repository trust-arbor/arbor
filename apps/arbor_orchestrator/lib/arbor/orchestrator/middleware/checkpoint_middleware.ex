defmodule Arbor.Orchestrator.Middleware.CheckpointMiddleware do
  @moduledoc """
  Mandatory middleware that sanitizes context before checkpoint persistence.

  Strips internal context keys (prefixed with `internal.`) from context updates
  before they reach the checkpoint store. This prevents implementation details
  from leaking into persisted state.

  ## Token Assigns

    - `:skip_checkpoint_sanitization` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  # Keys with these prefixes are stripped before checkpoint persistence
  @internal_prefixes ["internal.", "graph.", "__"]

  @impl true
  def after_node(token) do
    if Map.get(token.assigns, :skip_checkpoint_sanitization, false) do
      token
    else
      sanitize_context_updates(token)
    end
  end

  defp sanitize_context_updates(token) do
    if token.outcome && token.outcome.context_updates do
      sanitized =
        token.outcome.context_updates
        |> Enum.reject(fn {key, _val} ->
          is_binary(key) and internal_key?(key)
        end)
        |> Map.new()

      %{token | outcome: %{token.outcome | context_updates: sanitized}}
    else
      token
    end
  end

  defp internal_key?(key) do
    Enum.any?(@internal_prefixes, &String.starts_with?(key, &1))
  end
end
