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
        --key-file ~/.arbor/operator.key \\
        --envelope-uri "arbor://fs/read/Users/azmaveth/.arbor/reports/**" \\
        --envelope-uri "arbor://fs/write/Users/azmaveth/.arbor/reports/**" \\
        --envelope-uri "arbor://fs/read/Users/azmaveth/code/trust-arbor/arbor/**" \\
        --envelope-uri "arbor://shell/exec/git" \\
        --envelope-uri "arbor://action/git/branch" \\
        --envelope-uri "arbor://action/git/commit" \\
        --envelope-uri "arbor://action/mix/test" \\
        --envelope-uri "arbor://action/github/pr" \\
        --envelope-uri "arbor://action/code_review/apply_changes" \\
        --envelope-uri "arbor://action/tdd/record_attempt" \\
        --envelope-uri "arbor://action/security/run_dependency_scan" \\
        --reason "adding code review pipeline support"

  ## Options

    * `--issuer-id <id>` (required) — agent_id of the enrolled issuer
    * `--key-file <path>` — private operator key used to authenticate the
      registry mutation (default `~/.arbor/operator.key`)
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
    - issuer not enrolled (`:not_found`, from `IssuerRegistry`)
    - issuer revoked (`:revoked`, from `IssuerRegistry`) — revoked
      issuers can't be updated; explicit re-enroll required (deliberate
      friction)
    - no `--envelope-uri` flags supplied
      (`{:missing_required_option, :envelope_uri}`, from this task —
      the CLI flag is missing, distinct from `IssuerRegistry`'s
      `:empty_envelopes` which fires if the registry receives an empty
      list at the API layer)
    - malformed envelope URI (`{:invalid_envelope_uri, uri, reason}`,
      from this task)
  """

  use Mix.Task

  alias Arbor.Contracts.Security.Capability

  @default_key_path "~/.arbor/operator.key"

  @impl true
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        strict: [issuer_id: :string, envelope_uri: :keep, reason: :string, key_file: :string],
        aliases: [i: :issuer_id, e: :envelope_uri, r: :reason, k: :key_file]
      )

    with {:ok, issuer_id} <- fetch_required(opts, :issuer_id),
         {:ok, envelope_uris} <- fetch_envelope_uris(opts),
         {:ok, envelopes} <- build_envelopes(issuer_id, envelope_uris),
         registry_opts <- registry_opts(opts[:reason]),
         {:ok, payload_digest} <-
           Arbor.Security.issuer_mutation_payload_digest(
             :update,
             issuer_id,
             envelopes,
             registry_opts
           ),
         {:ok, _actor_id, actor_proof} <-
           prepare_key_file_issuer_mutation(
             Path.expand(opts[:key_file] || @default_key_path),
             :update,
             payload_digest
           ),
         :ok <- start_application(),
         :ok <-
           Arbor.Security.update_issuer_envelopes(
             issuer_id,
             envelopes,
             Keyword.put(registry_opts, :actor_proof, actor_proof)
           ) do
      Mix.shell().info("Updated issuer envelopes:")
      Mix.shell().info("  issuer_id:     #{issuer_id}")
      Mix.shell().info("  new envelopes:")
      for uri <- envelope_uris, do: Mix.shell().info("    - #{uri}")
      Mix.shell().info("  reason:        #{opts[:reason] || "(none)"}")
    else
      {:error, reason} -> abort(reason)
    end
  end

  defp prepare_key_file_issuer_mutation(path, operation, payload_digest) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io_device} ->
        try do
          Arbor.Security.prepare_key_file_issuer_mutation(io_device, operation, payload_digest)
        after
          :file.close(io_device)
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
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

  defp registry_opts(nil), do: []
  defp registry_opts(reason), do: [reason: reason]

  # See the enroll task: private-key proof construction is available only
  # before the supervised security boundary starts in production.
  defp start_application do
    Mix.Task.run("app.start")
    :ok
  rescue
    exception -> {:error, {:application_start_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:application_start_failed, reason}}
  end

  defp abort(reason) do
    Mix.shell().error("update_issuer_envelopes failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
