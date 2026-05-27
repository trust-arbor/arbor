defmodule Mix.Tasks.Arbor.CheckModels do
  @shortdoc "Verify configured local LLM models are loaded on their providers"

  @moduledoc """
  Preflight-check that every model id the orchestrator is configured to call on a
  local provider (LM Studio / Ollama) is actually loaded there.

  Local providers fail in opposite, both-bad ways when a configured model isn't
  loaded: LM Studio *silently serves a different model* (200, no error), Ollama 404s
  at call time. This task surfaces those before they bite — especially important for
  evals, where a silent quant substitution would invalidate results.

      mix arbor.check_models

  Warn-only: it reports and always exits 0; it never changes anything.
  """

  use Mix.Task

  alias Arbor.Orchestrator.UnifiedLLM.Preflight

  @impl true
  def run(_args) do
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:arbor_orchestrator)

    results = Preflight.check()

    if results == [] do
      Mix.shell().info("No local-provider models configured — nothing to check.")
    else
      Enum.each(results, &print/1)
      summarize(results)
    end
  end

  defp print(%{entry: e, status: status}) do
    tag = "#{e.provider} #{e.model} (#{e.stage}/#{e.kind}) @ #{e.base_url}"

    case status do
      :ok ->
        Mix.shell().info("  ✓ #{tag}")

      :missing ->
        detail =
          if e.provider == :lm_studio,
            do: "LM Studio will silently serve a DIFFERENT model",
            else: "Ollama will 404 at call time"

        Mix.shell().error("  ✗ #{tag} — NOT LOADED (#{detail})")

      {:wrong_quant, served} ->
        Mix.shell().info("  ⚠ #{tag} — configured quant not loaded; '#{served}' will be served")

      :unverified_quant ->
        Mix.shell().info(
          "  ⚠ #{tag} — base loaded but listed without a quant tag; the loaded quant will be served (can't confirm it's the configured one)"
        )

      :unreachable ->
        Mix.shell().error("  ? #{tag} — could not reach provider to verify")
    end
  end

  defp summarize(results) do
    counts = Enum.frequencies_by(results, fn %{status: s} -> bucket(s) end)
    ok = Map.get(counts, :ok, 0)
    missing = Map.get(counts, :missing, 0)
    unreachable = Map.get(counts, :unreachable, 0)
    soft = Map.get(counts, :soft, 0)

    Mix.shell().info(
      "\n#{ok} ok, #{soft} soft mismatch, #{missing} missing, #{unreachable} unreachable " <>
        "(of #{length(results)} configured)"
    )

    cond do
      missing > 0 ->
        Mix.shell().info(
          "Fix: load the missing model(s) in the provider, or update the configured id to one that's loaded."
        )

      unreachable > 0 ->
        Mix.shell().info(
          "Note: some providers were unreachable — start them and re-run to verify."
        )

      true ->
        :ok
    end
  end

  defp bucket(:ok), do: :ok
  defp bucket(:missing), do: :missing
  defp bucket(:unreachable), do: :unreachable
  defp bucket(_), do: :soft
end
