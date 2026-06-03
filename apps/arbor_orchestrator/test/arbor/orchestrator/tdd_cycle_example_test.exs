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

    test_file_path = Path.join([workdir, "test", "model_test.exs"])
    impl_file_path = Path.join([workdir, "lib", "#{spec.file_basename}.ex"])

    initial_values = %{
      "module_name" => spec.module_name,
      "signature" => spec.signature,
      "description" => spec.description,
      "max_iterations" => spec.max_iterations,
      "iteration" => 0,
      "workdir" => workdir,
      "test_file_path" => test_file_path,
      "impl_file_path" => impl_file_path,
      "test_prompt" => build_test_prompt(spec),
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

  defp setup_tmp_mix_project(spec) do
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

    # The acceptance test — the held-out oracle. The model never sees
    # this file or its contents. Each example pair becomes one ExUnit
    # test case.
    File.write!(Path.join([path, "test", "acceptance_test.exs"]), build_acceptance_test(spec))

    # Skip the lib/ file — the model will produce it.

    path
  end

  defp build_acceptance_test(spec) do
    cases =
      spec.examples
      |> Enum.with_index()
      |> Enum.map(fn {{input, expected}, idx} ->
        # Test name uses ONLY the index — embedding inspect(expected)
        # in the description string breaks parsing when expected is a
        # string ("\"1\"" → embedded quotes in the test name).
        """
            test "acceptance case #{idx}" do
              assert #{spec.module_name}.run(#{inspect(input)}) == #{inspect(expected)}
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
