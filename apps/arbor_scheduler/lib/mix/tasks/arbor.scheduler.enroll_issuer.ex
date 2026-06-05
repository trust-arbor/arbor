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
        --envelope-uri "arbor://fs/write/reports/**" \\
        --reason "primary author for scheduler-internal pipelines"

  ## Options

    * `--issuer-id <id>` (required) — agent_id of the identity to enroll
    * `--envelope-uri <uri>` (required) — resource_uri pattern bounding what
      caps this issuer can sign. Anything outside this envelope will be
      rejected at `.caps.json` load time.
    * `--reason <text>` (optional) — human-readable note recorded with the
      enrollment for audit

  ## Behavior

  Builds a `Capability` with the supplied envelope_uri (no constraints,
  no expiry) and registers it in IssuerRegistry. Fails if the identity
  isn't registered, the envelope_uri is malformed, or the issuer is
  already enrolled.

  ## Revocation

  To revoke an issuer (e.g., on key compromise), use `IssuerRegistry.revoke/2`
  directly in iex or implement a follow-on `mix arbor.scheduler.revoke_issuer`
  task. Revocation is a separate operation because it requires presence
  (the operator pulling cap-signing privileges from a misbehaving author).
  """

  use Mix.Task

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.IssuerRegistry

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _} =
      OptionParser.parse(args,
        strict: [issuer_id: :string, envelope_uri: :string, reason: :string],
        aliases: [i: :issuer_id, e: :envelope_uri, r: :reason]
      )

    with {:ok, issuer_id} <- fetch_required(opts, :issuer_id),
         {:ok, envelope_uri} <- fetch_required(opts, :envelope_uri),
         {:ok, envelope} <- build_envelope(issuer_id, envelope_uri),
         :ok <- enroll(issuer_id, envelope, opts[:reason]) do
      Mix.shell().info("Enrolled issuer:")
      Mix.shell().info("  issuer_id:    #{issuer_id}")
      Mix.shell().info("  envelope_uri: #{envelope_uri}")
      Mix.shell().info("  reason:       #{opts[:reason] || "(none)"}")
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

  defp build_envelope(issuer_id, envelope_uri) do
    # principal_id on the envelope cap is the issuer themselves —
    # the envelope is "what this issuer is allowed to sign for."
    # constraints/expiry are intentionally empty: the bound is on URI
    # space, not on rate or time.
    Capability.new(resource_uri: envelope_uri, principal_id: issuer_id)
  end

  defp enroll(issuer_id, envelope, reason) do
    opts = if reason, do: [reason: reason], else: []
    IssuerRegistry.register(issuer_id, envelope, opts)
  end

  defp abort(reason) do
    Mix.shell().error("enroll_issuer failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
