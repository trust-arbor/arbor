defmodule Arbor.Orchestrator.Middleware.SecretScan do
  @moduledoc """
  Middleware that scans LLM responses and context updates for leaked secrets.

  Delegates pattern matching to `Arbor.Eval.Checks.PIIDetection.scan_text/2`,
  which provides comprehensive secret detection with Shannon entropy analysis.

  Runs in the after_node phase. Checks the node outcome's context_updates
  values and the last_response context key for patterns matching common
  credential formats.

  Can be configured via token assigns:
    - :secret_scan_action — :fail (default), :warn, :redact
    - :secret_scan_extra_patterns — additional {regex, label} tuples to check
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Middleware.Token

  @impl true
  def before_node(token), do: token

  @impl true
  def after_node(token) do
    if token.outcome && token.outcome.status in [:success, :partial_success] do
      action = Map.get(token.assigns, :secret_scan_action, :fail)
      extra_patterns = Map.get(token.assigns, :secret_scan_extra_patterns, [])
      scan_opts = [additional_patterns: extra_patterns]

      strings_to_scan = collect_scannable_strings(token)
      findings = scan_all(strings_to_scan, scan_opts)

      case {findings, action} do
        {[], _} ->
          token

        {findings, :fail} ->
          summary = format_findings(findings)

          Token.halt(
            token,
            "Secret scan failed: #{summary}",
            %Outcome{status: :fail, failure_reason: "Secrets detected: #{summary}"}
          )

        {findings, :warn} ->
          summary = format_findings(findings)
          existing_notes = token.outcome.notes || ""

          updated_outcome = %{
            token.outcome
            | notes: existing_notes <> "\n[SECRET WARN] #{summary}"
          }

          %{token | outcome: updated_outcome}

        {_findings, :redact} ->
          redact_secrets(token, scan_opts)
      end
    else
      token
    end
  end

  # --- Private functions ---

  defp collect_scannable_strings(token) do
    context_update_strings =
      (token.outcome.context_updates || %{})
      |> Enum.filter(fn {_k, v} -> is_binary(v) end)
      |> Enum.map(fn {k, v} -> {"context_update:#{k}", v} end)

    last_response = Context.get(token.context, "last_response", "")

    last_response_strings =
      if is_binary(last_response) and last_response != "" do
        [{"last_response", last_response}]
      else
        []
      end

    notes = token.outcome.notes || ""

    notes_strings =
      if notes != "" do
        [{"notes", notes}]
      else
        []
      end

    context_update_strings ++ last_response_strings ++ notes_strings
  end

  defp scan_all(strings, scan_opts) do
    for {source, text} <- strings,
        {label, _matched} <- do_scan_text(text, scan_opts) do
      {source, label}
    end
  end

  defp do_scan_text(text, scan_opts) do
    # Use arbor_eval's PIIDetection for pattern matching
    if Code.ensure_loaded?(Arbor.Eval.Checks.PIIDetection) do
      Arbor.Eval.Checks.PIIDetection.scan_text(text, scan_opts)
    else
      # Fallback: no scanning if arbor_eval not available
      []
    end
  end

  defp format_findings(findings) do
    findings
    |> Enum.map(fn {source, label} -> "Found #{label} in #{source}" end)
    |> Enum.join(", ")
  end

  defp redact_secrets(token, scan_opts) do
    # Redact context_updates
    redacted_updates =
      Map.new(token.outcome.context_updates || %{}, fn
        {k, v} when is_binary(v) ->
          {k, redact_string(v, scan_opts)}

        {k, v} ->
          {k, v}
      end)

    updated_outcome = %{token.outcome | context_updates: redacted_updates}
    %{token | outcome: updated_outcome}
  end

  defp redact_string(text, scan_opts) do
    findings = do_scan_text(text, scan_opts)

    Enum.reduce(findings, text, fn {_label, matched}, acc ->
      String.replace(acc, matched, "[REDACTED]")
    end)
  end
end
