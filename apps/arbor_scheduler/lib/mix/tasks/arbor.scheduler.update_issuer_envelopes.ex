defmodule Mix.Tasks.Arbor.Scheduler.UpdateIssuerEnvelopes do
  @shortdoc "Replace the envelope list for an enrolled scheduler issuer"

  @moduledoc """
  Replace the envelope list of an active issuer in
  `Arbor.Security.IssuerRegistry` — expand or narrow what they're
  authorized to sign WITHOUT going through revoke + re-enroll.

  Companion to `mix arbor.scheduler.enroll_issuer`. Use this when the
  set of pipelines an issuer needs to sign for grows over time:
  expanding the issuer's authority via update_envelopes lets every
  previously-signed `.caps.json` that still fits within the new
  envelopes keep loading without re-signing.

  ## Usage

      mix arbor.scheduler.update_issuer_envelopes \\
        --issuer-id agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e \\
        --envelope-uri "arbor://fs/read/Users/azmaveth/.arbor/reports/**" \\
        --envelope-uri "arbor://fs/write/Users/azmaveth/.arbor/reports/**" \\
        --envelope-uri "arbor://fs/read/Users/azmaveth/code/trust-arbor/arbor/**" \\
        --envelope-uri "arbor://shell/exec/git" \\
        --envelope-uri "arbor://shell/exec/mix/test" \\
        --envelope-uri "arbor://shell/exec/gh" \\
        --envelope-uri "arbor://action/code_review/apply_changes" \\
        --envelope-uri "arbor://action/tdd/record_attempt" \\
        --reason "adding code review pipeline support"

  ## Options

    * `--issuer-id <id>` (required) — agent_id of the enrolled issuer
    * `--envelope-uri <uri>` (required, repeatable) — the FULL new
      envelope set. This REPLACES the issuer's existing envelopes; what
      isn't in this list is removed. Pass every URI you want the issuer
      to be able to sign for (including ones they already had).
    * `--reason <text>` (optional) — recorded with the update for audit

  ## Semantics

  REPLACE, not append. The intent is explicit: callers state the FULL
  new authority set so the registry's persisted state is unambiguous.
  If you want to add one URI to an issuer with five existing envelopes,
  you must pass all six on the command line.

  Run `mix arbor.scheduler.audit_caps` after to verify the existing
  signed `.caps.json` files in the tree still load under the new
  envelope set.

  ## Errors

  Fails closed on:
    - issuer not enrolled (`:not_found`)
    - issuer revoked (`:revoked`) — revoked issuers can't be updated;
      explicit re-enroll required (deliberate friction)
    - no `--envelope-uri` flags supplied (`:empty_envelopes`)
    - malformed envelope URI (`:invalid_envelope_uri`)
  """

  use Mix.Task

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.IssuerRegistry

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _} =
      OptionParser.parse(args,
        strict: [issuer_id: :string, envelope_uri: :keep, reason: :string],
        aliases: [i: :issuer_id, e: :envelope_uri, r: :reason]
      )

    with {:ok, issuer_id} <- fetch_required(opts, :issuer_id),
         {:ok, envelope_uris} <- fetch_envelope_uris(opts),
         {:ok, envelopes} <- build_envelopes(issuer_id, envelope_uris),
         :ok <- update(issuer_id, envelopes, opts[:reason]) do
      Mix.shell().info("Updated issuer envelopes:")
      Mix.shell().info("  issuer_id:     #{issuer_id}")
      Mix.shell().info("  new envelopes:")
      for uri <- envelope_uris, do: Mix.shell().info("    - #{uri}")
      Mix.shell().info("  reason:        #{opts[:reason] || "(none)"}")
    else
      {:error, reason} -> abort(reason)
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_required_option, key}}
      v -> {:ok, v}
    end
  end

  defp fetch_envelope_uris(opts) do
    case Keyword.get_values(opts, :envelope_uri) do
      [] -> {:error, {:missing_required_option, :envelope_uri}}
      uris -> {:ok, uris}
    end
  end

  defp build_envelopes(issuer_id, uris) do
    uris
    |> Enum.reduce_while({:ok, []}, fn uri, {:ok, acc} ->
      case Capability.new(resource_uri: uri, principal_id: issuer_id) do
        {:ok, cap} -> {:cont, {:ok, [cap | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_envelope_uri, uri, reason}}}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      err -> err
    end
  end

  defp update(issuer_id, envelopes, reason) do
    opts = if reason, do: [reason: reason], else: []
    IssuerRegistry.update_envelopes(issuer_id, envelopes, opts)
  end

  defp abort(reason) do
    Mix.shell().error("update_issuer_envelopes failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
