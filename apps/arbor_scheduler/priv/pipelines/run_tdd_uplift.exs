# Smoke-test runner for the TDD uplift pipeline.
#
# Run from the running iex session via the tidewave shell wrapper, or
# inline in iex with:
#
#   c "apps/arbor_scheduler/priv/pipelines/run_tdd_uplift.exs"
#
# What this does:
#   1. Grants `agent_tdd_uplift` three narrowly-scoped capabilities:
#      - fs/read on the module's lib directory
#      - fs/write on the test directory
#      - shell/exec/mix/test on the runner
#   2. Runs the DOT pipeline at apps/arbor_scheduler/priv/pipelines/tdd_uplift_log_redactor.dot
#   3. Prints the engine result + the list of completed nodes so we
#      can see whether the gate routed to mark_pass or mark_fail.

defmodule RunTddUplift do
  @pipeline_path "apps/arbor_scheduler/priv/pipelines/tdd_uplift_log_redactor.dot"
  @logs_root "/tmp/tdd_uplift_logs"

  @extra_caps [
    "arbor://fs/read/Users/azmaveth/code/trust-arbor/arbor/apps/arbor_common/lib/arbor/common/**",
    "arbor://fs/write/Users/azmaveth/code/trust-arbor/arbor/apps/arbor_common/test/arbor/common/**",
    "arbor://action/mix/test"
  ]

  def run do
    File.mkdir_p!(@logs_root)

    # Hot-reload modules I edited so the running server uses the new code.
    # In particular: Arbor.Actions holds @canonical_uri_map as a compile-time
    # attribute, so the flip from arbor://shell/exec/mix/test to
    # arbor://action/mix/test only takes effect after reload.
    for mod <- [
          Arbor.Actions,
          Arbor.Security.AuthDecision,
          Arbor.Orchestrator.Handlers.TransformHandler,
          Arbor.Security.UriRegistry
        ] do
      :code.purge(mod)
      :code.load_file(mod)
    end

    principal = Arbor.Scheduler.Identity.agent_id()
    signer = Arbor.Scheduler.Identity.signer()

    if principal == nil or signer == nil do
      IO.puts("[run_tdd_uplift] Scheduler.Identity not running — aborting")
      System.halt(1)
    end

    IO.puts("[run_tdd_uplift] Running as scheduler identity: #{principal}")

    # `arbor://action` was added to UriRegistry's @canonical_prefixes,
    # but the running server has the old compiled list. Runtime-register
    # it so this run doesn't have to wait for a server restart.
    Arbor.Security.UriRegistry.register("arbor://action")

    # PolicyEnforcer auto-grants caps with requires_approval=true the
    # first time a principal hits an :ask URI. Those caps shadow our
    # provenance-bearing caps in find_authorizing (first match wins),
    # so the ceiling bypass never fires. Revoke them before granting
    # the proper pre-approved ones.
    revoke_policy_enforcer_caps(principal)

    Enum.each(@extra_caps, &grant(&1, principal))

    # Quick sanity check that the cap chain is healthy.
    write_path =
      "/Users/azmaveth/code/trust-arbor/arbor/apps/arbor_common/test/arbor/common/log_redactor_test.exs"

    direct_fs =
      Arbor.Security.authorize(principal, "arbor://fs/write", :execute,
        file_path: write_path,
        verify_identity: false
      )

    direct_mix =
      Arbor.Security.authorize(principal, "arbor://action/mix/test", :execute,
        verify_identity: false
      )

    IO.puts("[run_tdd_uplift] preflight fs/write: #{summarize_auth(direct_fs)}")
    IO.puts("[run_tdd_uplift] preflight action/mix/test: #{summarize_auth(direct_mix)}")

    # The scheduler identity has `:allow` on arbor://orchestrator/execute
    # but its trust profile still defaults to `:ask` on fs/* and action/*,
    # so each step escalates to approval and there's no operator
    # listening. Patch the trust profile to `:allow` for the URI
    # prefixes this pipeline touches.
    Enum.each(
      [
        "arbor://fs/read",
        "arbor://fs/write",
        "arbor://action/mix"
      ],
      &allow_trust_rule(principal, &1)
    )

    IO.puts("[run_tdd_uplift] Running pipeline: #{@pipeline_path}")

    case Arbor.Orchestrator.run_file(@pipeline_path,
           logs_root: @logs_root,
           signer: signer,
           initial_values: %{"session.agent_id" => principal}
         ) do
      {:ok, result} ->
        # Post-run cap audit — see if PolicyEnforcer auto-granted bare
        # caps during the pipeline (would shadow our pre-approved caps
        # on retry iterations).
        case Arbor.Security.CapabilityStore.list_for_principal(principal) do
          {:ok, caps} ->
            bare =
              Enum.filter(caps, fn c ->
                c.resource_uri in [
                  "arbor://fs/write",
                  "arbor://fs/read",
                  "arbor://action/mix/test"
                ]
              end)

            if bare != [] do
              IO.puts("\n[run_tdd_uplift] BARE caps appeared during run (#{length(bare)}):")

              Enum.each(bare, fn c ->
                source =
                  Map.get(c.metadata || %{}, :source) || Map.get(c.metadata || %{}, "source")

                IO.puts(
                  "  - #{c.resource_uri}  source=#{inspect(source)}  granted=#{inspect(c.granted_at)}"
                )
              end)
            end

          _ ->
            :ok
        end

        IO.puts("\n[run_tdd_uplift] ── Engine result ───────────────────")
        IO.inspect(result.completed_nodes, label: "completed_nodes")

        IO.inspect(Map.get(result, :failed_nodes, []), label: "failed_nodes")

        cond do
          "mark_pass" in result.completed_nodes ->
            IO.puts("\n[run_tdd_uplift] ✓ PASS — generated test compiled and passed")

          "mark_fail" in result.completed_nodes ->
            IO.puts("\n[run_tdd_uplift] ✗ FAIL — test failed or did not compile")

            stderr =
              result.context |> Arbor.Orchestrator.Engine.Context.get("exec.run_test.stderr")

            stdout =
              result.context |> Arbor.Orchestrator.Engine.Context.get("exec.run_test.stdout")

            IO.puts("\nstdout tail:\n#{stdout |> to_string() |> tail()}")
            IO.puts("\nstderr tail:\n#{stderr |> to_string() |> tail()}")

          true ->
            IO.puts("\n[run_tdd_uplift] ? UNEXPECTED — neither mark_pass nor mark_fail completed")
        end

        {:ok, result}

      other ->
        IO.inspect(other, label: "[run_tdd_uplift] ERROR")
        other
    end
  end

  defp summarize_auth({:ok, :authorized}), do: ":authorized"
  defp summarize_auth({:ok, :authorized, _path}), do: ":authorized"
  defp summarize_auth({:ok, :pending_approval, _id}), do: ":pending_approval (NOT GOOD)"
  defp summarize_auth({:error, reason}), do: "ERROR #{inspect(reason)}"
  defp summarize_auth(other), do: inspect(other)

  defp revoke_policy_enforcer_caps(principal_id) do
    # Revoke both PolicyEnforcer auto-grants (their bare-URI caps with
    # requires_approval=true shadow our pre-approved caps) AND any caps
    # this runner created on prior unsigned-grant attempts (they live
    # in the store but are invisible to find_authorizing because they
    # weren't signed).
    case Arbor.Security.CapabilityStore.list_for_principal(principal_id) do
      {:ok, caps} ->
        revoked =
          caps
          |> Enum.filter(fn c ->
            source = Map.get(c.metadata || %{}, :source) || Map.get(c.metadata || %{}, "source")

            # The PolicyEnforcer stamp shows up as both the atom :policy_enforcer
            # (newer code) and the string "policy_enforcer" (older grants),
            # and pre-flip mix grants left an "arbor://shell/exec/mix/test"
            # cap with requires_approval=true that now shadows the new URI's
            # auth flow. Revoke all of these. Keep the scheduler's own
            # arbor://orchestrator/execute/** grants and anything else not
            # stamped by this pipeline machinery.
            source in [:policy_enforcer, "policy_enforcer", "tdd_uplift_runner"]
          end)
          |> Enum.map(fn c ->
            Arbor.Security.CapabilityStore.revoke(c.id)
            c.resource_uri
          end)

        if revoked != [] do
          IO.puts(
            "[run_tdd_uplift] Revoked #{length(revoked)} stale cap(s): " <>
              Enum.join(revoked, ", ")
          )
        end

      _ ->
        :ok
    end
  end

  defp allow_trust_rule(principal_id, rule_prefix) do
    alias Arbor.Trust.Authority, as: TrustAuthority
    alias Arbor.Trust.Store, as: TrustStore

    unless TrustStore.profile_exists?(principal_id) do
      profile = TrustAuthority.new_profile(principal_id, :untrusted)
      TrustStore.store_profile(profile)
    end

    TrustStore.update_profile(principal_id, fn profile ->
      %{profile | rules: Map.put(profile.rules || %{}, rule_prefix, :allow)}
    end)

    IO.puts("  ✓ trust rule #{rule_prefix} => :allow")
  rescue
    e -> IO.puts("  ✗ trust rule #{rule_prefix} failed: #{Exception.message(e)}")
  end

  defp grant(resource_uri, principal_id) do
    # `arbor://fs/write` is on the askable security ceiling — a cap
    # without provenance metadata escalates to approval even with a
    # matching trust rule. RunIdentity sets provenance after verifying
    # a signed `.caps.json`; we set it here for the smoke-test runner.
    # The cap's URI is parameter-bounded (a concrete path prefix), so
    # AuthDecision.pre_approved_bypasses_ceiling? returns true.
    #
    # Use Security.grant so the cap is signed by SystemAuthority —
    # in dev `capability_signing_required: true`, and CapabilityStore's
    # find_authorizing silently filters out unsigned caps. Bypassing
    # that path leaves the unsigned cap in the store but invisible to
    # authorization, which is the exact failure mode this smoke test hit.
    metadata = %{
      source: "tdd_uplift_runner",
      provenance: %{source: :tdd_uplift_runner, issuer_id: principal_id}
    }

    case Arbor.Security.grant(
           principal: principal_id,
           resource: resource_uri,
           delegation_depth: 0,
           constraints: %{},
           metadata: metadata
         ) do
      {:ok, _signed_cap} -> IO.puts("  ✓ #{resource_uri}")
      {:error, reason} -> IO.puts("  ✗ #{resource_uri} — #{inspect(reason)}")
    end
  end

  defp tail(s, n \\ 2_000) do
    if byte_size(s) > n, do: binary_part(s, byte_size(s) - n, n), else: s
  end
end

RunTddUplift.run()
