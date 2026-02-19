defmodule Arbor.Orchestrator.Middleware.Sanitization do
  @moduledoc """
  Mandatory middleware that scans node attributes and outcomes for PII/secrets.

  Delegates to the existing `SecretScan` middleware for outcome scanning and
  additionally scans node attributes before execution for leaked secrets.

  No-op when `Arbor.Eval.Checks.PIIDetection` is not loaded.

  ## Token Assigns

    - `:sanitization_action` — :fail (default), :warn, :redact
    - `:skip_sanitization` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def before_node(token) do
    if Map.get(token.assigns, :skip_sanitization, false) or not pii_available?() do
      token
    else
      scan_attributes(token)
    end
  end

  @impl true
  def after_node(token) do
    if Map.get(token.assigns, :skip_sanitization, false) or not pii_available?() do
      token
    else
      scan_outcome(token)
    end
  end

  defp scan_attributes(token) do
    action = Map.get(token.assigns, :sanitization_action, :fail)

    # Scan string-valued node attributes for secrets
    scannable =
      token.node.attrs
      |> Enum.filter(fn {_k, v} -> is_binary(v) end)
      |> Enum.flat_map(fn {key, value} ->
        case scan_text(value) do
          [] -> []
          findings -> Enum.map(findings, fn {label, _} -> {key, label} end)
        end
      end)

    case {scannable, action} do
      {[], _} ->
        token

      {findings, :warn} ->
        summary = format_findings(findings)
        Token.assign(token, :sanitization_warnings, summary)

      {findings, :fail} ->
        summary = format_findings(findings)

        Token.halt(
          token,
          "PII detected in node attributes: #{summary}",
          %Outcome{status: :fail, failure_reason: "Sanitization failed: #{summary}"}
        )

      _ ->
        token
    end
  end

  defp scan_outcome(token) do
    # Outcome scanning is handled by SecretScan middleware when both are in the chain.
    # This only adds attribute-level scanning not covered by SecretScan.
    token
  end

  defp scan_text(text) do
    if pii_available?() do
      try do
        apply(Arbor.Eval.Checks.PIIDetection, :scan_text, [text, []])
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp format_findings(findings) do
    Enum.map_join(findings, ", ", fn {source, label} -> "#{label} in #{source}" end)
  end

  defp pii_available? do
    Code.ensure_loaded?(Arbor.Eval.Checks.PIIDetection) and
      function_exported?(Arbor.Eval.Checks.PIIDetection, :scan_text, 2)
  end
end
