defmodule Arbor.Orchestrator.TDDCycleExampleTest do
  @moduledoc """
  Demo runner for `specs/pipelines/examples/tdd-cycle.dot`. Sets up a
  fresh tmp mix project, pre-writes a held-out acceptance test from
  examples, runs the TDD loop against LM Studio + a small model, and
  asserts the loop converged (acceptance tests passed within the
  iteration cap).

  Tagged `:integration_lm_studio` — skipped by default. Run manually:

      mix test apps/arbor_orchestrator/test/arbor/orchestrator/tdd_cycle_example_test.exs \\
        --only integration_lm_studio

  The hypothesis being demonstrated: a small model (granite-4.1-3b)
  + a TDD harness with held-out acceptance criteria can produce
  correct code within a few iterations, even when the model alone
  wouldn't get there in one shot. The held-out test is the oracle
  the model can't game.
  """

  use ExUnit.Case, async: false
  @moduletag :integration_lm_studio

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Signer.ProxyCore

  @dot_path Path.expand("../../../specs/pipelines/examples/tdd-cycle.dot", __DIR__)
  @default_key "~/.claude/arbor-personal/claude_cli_mbp.arbor.key"

  setup_all do
    # See hello_world_example_test.exs for why each of these is needed.
    Application.put_env(:arbor_orchestrator, :discover_local_providers, true)
    Arbor.LLM.Client.clear_default_client()

    case Process.whereis(Arbor.Security.Identity.Registry) do
      nil -> {:ok, _} = Arbor.Security.Identity.Registry.start_link([])
      _ -> :ok
    end

    case Process.whereis(Arbor.Security.Identity.NonceCache) do
      nil -> {:ok, _} = Arbor.Security.Identity.NonceCache.start_link([])
      _ -> :ok
    end

    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Arbor.Shell.ExecutionRegistry.start_link([])
      _ -> :ok
    end

    :ok
  end

  test "TDD cycle: Double.run converges within 3 iterations" do
    spec = %{
      module_name: "Double",
      file_basename: "double",
      signature: "@spec run(integer()) :: integer()",
      description: "Returns the input integer multiplied by two.",
      # Acceptance examples — the model never sees these directly.
      examples: [{1, 2}, {0, 0}, {-5, -10}, {100, 200}],
      max_iterations: 3
    }

    run_tdd_cycle(spec)
  end

  test "TDD cycle: Rle.encode converges within 5 iterations" do
    # Run-length encoding — chosen because small models commonly trip on:
    #   - The "1" for singleton runs (omit it, return just the char)
    #   - Confusing runs with total counts ("aabbaa" — is it "a4b2" or "a2b2a2"?)
    #   - Off-by-one on the last group (drop it entirely)
    #   - Empty-string handling
    #
    # If granite-4.1-3b one-shots this, the convergence hypothesis is
    # underdetermined by these problems. If it fumbles and recovers, the
    # feedback loop is doing real work.
    spec = %{
      module_name: "Rle",
      file_basename: "rle",
      signature: "@spec encode(String.t()) :: String.t()",
      description: """
      Run-length encode a string. Each MAXIMAL RUN of consecutive identical
      characters becomes that character followed by the run's length as a
      decimal number. EVERY run gets a count — even runs of length 1.
      The empty string encodes to the empty string.
      """,
      examples: [
        {"", ""},
        {"a", "a1"},
        {"aaa", "a3"},
        {"aaabb", "a3b2"},
        {"abcd", "a1b1c1d1"},
        {"wwwwxxyz", "w4x2y1z1"},
        # The classic trap: groups, not total counts.
        {"aabbaa", "a2b2a2"},
        # Mixed case + repeats with a single-char tail.
        {"AAAAAAAAAB", "A9B1"}
      ],
      function_name: "encode",
      max_iterations: 5
    }

    run_tdd_cycle(spec)
  end

  test "TDD cycle: FizzBuzz.run converges within 5 iterations" do
    # FizzBuzz is a classic small-model trap. Common failure modes:
    #   - Check 3 and 5 before 15 (so 15 returns "Fizz", not "FizzBuzz")
    #   - Use `or` instead of `and` for the 15 case
    #   - Return integers for the default case instead of strings
    #
    # The held-out acceptance includes the 15-multiple cases that small
    # models reliably miss on first generation. That's the rigor we're
    # testing: even when the model gets it wrong, the test runner says
    # which examples failed (without revealing the expected values),
    # and the model iterates.
    spec = %{
      module_name: "FizzBuzz",
      file_basename: "fizz_buzz",
      signature: "@spec run(integer()) :: String.t()",
      description: """
      Returns "Fizz" for multiples of 3, "Buzz" for multiples of 5,
      "FizzBuzz" for multiples of 15 (both 3 AND 5), and the number
      itself as a string for all other integers.
      """,
      examples: [
        {1, "1"},
        {3, "Fizz"},
        {5, "Buzz"},
        {15, "FizzBuzz"},
        {30, "FizzBuzz"},
        {7, "7"},
        {45, "FizzBuzz"},
        {-3, "Fizz"}
      ],
      max_iterations: 5
    }

    run_tdd_cycle(spec)
  end

  # ── Pipeline runner ───────────────────────────────────────────────

  defp run_tdd_cycle(spec) do
    {agent_id, _private_key, signer} = load_identity_and_signer()

    grant_capabilities(agent_id, [
      "arbor://orchestrator/execute/**",
      "arbor://orchestrator/execute/llm_query",
      "arbor://shell/exec/mix/**",
      "arbor://fs/**",
      "arbor://action/tdd/**"
    ])

    workdir = setup_tmp_mix_project(spec)
    on_exit(fn -> File.rm_rf(workdir) end)

    # Write the spec file inside workdir. The DOT reads it via a `read`
    # node, json_extracts each field, and writes the acceptance test from
    # the spec's `acceptance_test_code` string.
    spec_path = "spec.json"
    write_spec_file(workdir, spec_path, spec)

    initial_values = %{
      "spec_path" => spec_path,
      "workdir" => workdir,
      "iteration" => 0,
      "session.agent_id" => agent_id
    }

    logs_root =
      Path.join(System.tmp_dir!(), "arbor_tdd_logs_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               signer: signer,
               initial_values: initial_values,
               logs_root: logs_root,
               # Each iteration visits ~15 nodes; bump cap for headroom.
               max_steps: 200
             )

    # Confirm the pipeline reached a terminal node via convergence,
    # not via escalation. The `mark_converged` node only fires when
    # tests.passed=true; `mark_escalated` fires on exhaustion.
    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    converged = "mark_converged" in result.completed_nodes

    if not converged do
      checkpoint =
        Path.join(logs_root, "checkpoint.json")
        |> File.read!()
        |> Jason.decode!()

      ctx = checkpoint["context_values"]

      IO.puts("""

      ═══════════════════════════════════════════════════════════════
      Did not converge in #{spec.max_iterations} iterations.

      Last impl produced:
      #{ctx["last_impl"] || "<nil>"}

      Last test failure:
      #{ctx["last_failure"] || "<nil>"}
      ═══════════════════════════════════════════════════════════════
      """)
    end

    assert converged,
           "Pipeline did not reach mark_converged within #{spec.max_iterations} iterations."

    refute "mark_escalated" in result.completed_nodes
  end

  # ── Identity / capability setup ───────────────────────────────────

  defp load_identity_and_signer do
    key_path = (System.get_env("ARBOR_KEY") || @default_key) |> Path.expand()

    if not File.exists?(key_path) do
      flunk("No arbor identity key at #{key_path}. Set ARBOR_KEY.")
    end

    {:ok, %{agent_id: agent_id, private_key: private_key}} =
      key_path |> File.read!() |> ProxyCore.parse_key_file()

    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)

    {:ok, identity} =
      Arbor.Contracts.Security.Identity.new(
        public_key: public_key,
        name: "tdd-cycle-example-test"
      )

    case Arbor.Security.Identity.Registry.register(identity) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    signer = fn resource -> SignedRequest.sign(resource, agent_id, private_key) end

    {agent_id, private_key, signer}
  end

  defp grant_capabilities(principal_id, uris) do
    Enum.each(uris, fn uri ->
      {:ok, cap} =
        Arbor.Contracts.Security.Capability.new(
          resource_uri: uri,
          principal_id: principal_id,
          delegation_depth: 0,
          constraints: %{},
          metadata: %{test: true}
        )

      Arbor.Security.CapabilityStore.put(cap)
    end)
  end

  # ── Tmp mix project setup ─────────────────────────────────────────

  defp setup_tmp_mix_project(_spec) do
    path = Path.join(System.tmp_dir!(), "arbor_tdd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule TddSandbox.MixProject do
      use Mix.Project
      def project, do: [app: :tdd_sandbox, version: "0.0.1", elixir: "~> 1.14"]
    end
    """)

    File.write!(Path.join([path, "test", "test_helper.exs"]), "ExUnit.start()\n")

    # No lib/ file — the model writes it. No acceptance test either —
    # the DOT does that from the spec we drop into workdir.
    path
  end

  defp write_spec_file(workdir, spec_path, spec) do
    test_file_path = Path.join([workdir, "test", "model_test.exs"])
    impl_file_path = Path.join([workdir, "lib", "#{spec.file_basename}.ex"])
    acceptance_file_path = Path.join([workdir, "test", "acceptance_test.exs"])

    spec_json = %{
      "module_name" => spec.module_name,
      "signature" => spec.signature,
      "description" => spec.description,
      "test_prompt" => build_test_prompt(spec),
      "acceptance_test_code" => build_acceptance_test(spec),
      "test_file_path" => test_file_path,
      "impl_file_path" => impl_file_path,
      "acceptance_file_path" => acceptance_file_path,
      "max_iterations" => spec.max_iterations
    }

    File.write!(Path.join(workdir, spec_path), Jason.encode!(spec_json, pretty: true))
  end

  defp build_acceptance_test(spec) do
    function = Map.get(spec, :function_name, "run")

    cases =
      spec.examples
      |> Enum.with_index()
      |> Enum.map(fn {{input, expected}, idx} ->
        # Test name uses ONLY the index — embedding inspect(expected)
        # in the description string breaks parsing when expected is a
        # string ("\"1\"" → embedded quotes in the test name).
        """
            test "acceptance case #{idx}" do
              assert #{spec.module_name}.#{function}(#{inspect(input)}) == #{inspect(expected)}
            end
        """
      end)
      |> Enum.join("\n")

    """
    defmodule AcceptanceTest do
      use ExUnit.Case

    #{cases}
    end
    """
  end

  # ── Prompt construction ───────────────────────────────────────────

  defp build_test_prompt(spec) do
    """
    Write an ExUnit test module for the function below.

    Module: #{spec.module_name}
    Signature: #{spec.signature}
    Description: #{spec.description}

    Write at least three test cases covering typical and edge inputs.
    Use `assert <expression> == <expected>` form. Name the test module
    `#{spec.module_name}Test`.
    """
  end
end
