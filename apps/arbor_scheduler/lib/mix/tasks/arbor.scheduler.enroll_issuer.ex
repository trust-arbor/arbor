defmodule Mix.Tasks.Arbor.Scheduler.EnrollIssuer do
  @shortdoc "Enroll an identity as a scheduler capability-signing issuer"

  @moduledoc """
  Register an existing identity in `Arbor.Security.IssuerRegistry` with a
  bound on what capabilities they may sign.

  Phase 4 of the scheduler-privesc redesign. Run once per operator/issuer.
  The identity must already exist in `Arbor.Security.Identity.Registry`
  (created via the External Agents registration flow or
  `Identity.generate/0`).

  ## Usage

      mix arbor.scheduler.enroll_issuer \\
        --issuer-id agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e \\
        --key-file ~/.arbor/operator.key \\
        --envelope-uri "arbor://fs/read/Users/azmaveth/.arbor/reports/**" \\
        --envelope-uri "arbor://fs/write/Users/azmaveth/.arbor/reports/**" \\
        --reason "primary author for scheduler-internal pipelines"

  ## Options

    * `--issuer-id <id>` (required) — agent_id of the identity to enroll
    * `--key-file <path>` — private operator key used to authenticate the
      registry mutation (default `~/.arbor/operator.key`)
    * `--envelope-uri <uri>` (required, repeatable) — resource_uri pattern
      bounding what caps this issuer can sign. Pass `--envelope-uri`
      multiple times to authorize the issuer for several non-overlapping
      patterns (e.g. read + write of distinct subtrees). A signed cap
      passes verification if it fits within AT LEAST ONE envelope.
    * `--reason <text>` (optional) — human-readable note recorded with the
      enrollment for audit

  ## Behavior

  Builds a `Capability` for each `--envelope-uri` (no constraints, no
  expiry — the bound is on URI space) and registers them as a set in
  IssuerRegistry. Fails if the identity isn't registered, no envelope
  URIs are supplied, or the issuer is already enrolled.

  ## Revocation

  To revoke an issuer (e.g., on key compromise), use `IssuerRegistry.revoke/2`
  directly in iex or implement a follow-on `mix arbor.scheduler.revoke_issuer`
  task. Revocation is a separate operation because it requires presence
  (the operator pulling cap-signing privileges from a misbehaving author).
  """

  use Mix.Task

  alias Arbor.Contracts.Security.Capability

  @default_key_path "~/.arbor/operator.key"

  @impl true
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        # `keep` lets `--envelope-uri` appear multiple times, returning
        # one keyword entry per occurrence
        strict: [issuer_id: :string, envelope_uri: :keep, reason: :string, key_file: :string],
        aliases: [i: :issuer_id, e: :envelope_uri, r: :reason, k: :key_file]
      )

    with {:ok, issuer_id} <- fetch_required(opts, :issuer_id),
         {:ok, envelope_uris} <- fetch_envelope_uris(opts),
         {:ok, envelopes} <- build_envelopes(issuer_id, envelope_uris),
         registry_opts <- registry_opts(opts[:reason]),
         {:ok, payload_digest} <-
           Arbor.Security.issuer_mutation_payload_digest(
             :register,
             issuer_id,
             envelopes,
             registry_opts
           ),
         {:ok, _actor_id, actor_proof} <-
           prepare_key_file_issuer_mutation(
             Path.expand(opts[:key_file] || @default_key_path),
             :register,
             payload_digest
           ),
         :ok <- start_application(),
         :ok <-
           Arbor.Security.register_issuer(
             issuer_id,
             envelopes,
             Keyword.put(registry_opts, :actor_proof, actor_proof)
           ) do
      Mix.shell().info("Enrolled issuer:")
      Mix.shell().info("  issuer_id:     #{issuer_id}")
      Mix.shell().info("  envelopes:")
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
      # principal_id on the envelope cap is the issuer themselves —
      # the envelope is "what this issuer is allowed to sign for."
      # constraints/expiry are intentionally empty: the bound is on URI
      # space, not on rate or time.
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

  # The key-file proof must be prepared before application startup. Production
  # deliberately disables offline private-key access once the supervised
  # security boundary is live.
  defp start_application do
    Mix.Task.run("app.start")
    :ok
  rescue
    exception -> {:error, {:application_start_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:application_start_failed, reason}}
  end

  defp abort(reason) do
    Mix.shell().error("enroll_issuer failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
