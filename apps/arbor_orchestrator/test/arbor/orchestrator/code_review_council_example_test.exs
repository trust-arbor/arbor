defmodule Arbor.Orchestrator.CodeReviewCouncilExampleTest do
  @moduledoc """
  Demo runner for `specs/pipelines/examples/code-review-council.dot`.
  Drops a small Elixir module into a scratch workdir, writes a
  review-spec.json alongside it, runs the parallel-fan-out council
  against LM Studio, and asserts a report landed on disk.

  Tagged `:integration_lm_studio` — skipped by default. Run manually:

      mix test apps/arbor_orchestrator/test/arbor/orchestrator/code_review_council_example_test.exs \\
        --only integration_lm_studio

  Exercises engine surface area the other example pipelines don't hit:
    * `parallel` handler with 4 concurrent compute branches
    * 4 simultaneous LLM calls (each with its own in-call heartbeat ticker)
    * Concurrent context_updates from parallel branches
    * `transform=format json` serialization of the parallel.results list
    * Synthesizer compute node consuming structured JSON from context
  """

  use ExUnit.Case, async: false
  @moduletag :integration_lm_studio
  # Each parallel branch hits LM Studio; total wall-clock = max(branch),
  # but the synthesizer is sequential after. Allow plenty of headroom.
  @moduletag timeout: 1_200_000

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Signer.ProxyCore

  @dot_path Path.expand("../../../specs/pipelines/examples/code-review-council.dot", __DIR__)
  @default_key "~/.claude/arbor-personal/claude_cli_mbp.arbor.key"

  setup_all do
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

  test "council produces a synthesized review for a deliberately-imperfect module" do
    {agent_id, _private_key, signer} = load_identity_and_signer()

    grant_capabilities(agent_id, [
      "arbor://orchestrator/execute/**",
      "arbor://orchestrator/execute/llm_query",
      "arbor://fs/**"
    ])

    workdir = setup_workdir()
    on_exit(fn -> File.rm_rf(workdir) end)

    spec_path = "spec.json"
    report_path = Path.join(workdir, "review.md")
    write_spec_file(workdir, spec_path, report_path)

    logs_root =
      Path.join(System.tmp_dir!(), "arbor_council_logs_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(logs_root) end)

    initial_values = %{
      "spec_path" => spec_path,
      "workdir" => workdir,
      "session.agent_id" => agent_id
    }

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               signer: signer,
               initial_values: initial_values,
               logs_root: logs_root,
               max_steps: 200
             )

    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    # All four reviewers should have run.
    for branch <- ~w(review_security review_correctness review_performance review_idioms) do
      assert branch in result.completed_nodes,
             "expected branch #{branch} in completed_nodes; got #{inspect(result.completed_nodes)}"
    end

    assert "parallel_review" in result.completed_nodes
    assert "format_reviews" in result.completed_nodes
    assert "synthesize" in result.completed_nodes
    assert "write_report" in result.completed_nodes

    assert File.exists?(report_path), "expected synthesized report at #{report_path}"

    content = File.read!(report_path)

    # Stash a copy under /tmp so we can inspect it after on_exit cleanup.
    # This is intentionally observable side-effect — running this test
    # writes /tmp/arbor_last_council_review.md regardless.
    File.write!("/tmp/arbor_last_council_review.md", content)

    assert byte_size(content) > 100, "report is suspiciously short: #{inspect(content)}"

    # Sanity: the model should mention multiple lenses somewhere. We don't
    # grade quality — just confirm the synthesis pulled material from more
    # than one branch.
    lens_hits =
      ~w(security correctness performance idiom)
      |> Enum.count(fn lens -> String.contains?(String.downcase(content), lens) end)

    assert lens_hits >= 2,
           "synthesized report didn't reference multiple lenses; got: #{String.slice(content, 0, 400)}"
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
        name: "code-review-council-test"
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

  # ── Workdir + spec setup ──────────────────────────────────────────

  defp setup_workdir do
    path = Path.join(System.tmp_dir!(), "arbor_council_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp write_spec_file(workdir, spec_path, report_path) do
    spec_json = %{
      "review_brief" => """
      Review this small Elixir helper for production readiness. It's
      intentionally rough — there are at least one issue in each lens.
      """,
      "code_under_review" => sample_code(),
      "report_path" => report_path,
      "model_provider" => "lm_studio",
      "model_id" => "granite-4.1-3b"
    }

    File.write!(Path.join(workdir, spec_path), Jason.encode!(spec_json, pretty: true))
  end

  # A deliberately imperfect module: each reviewer should find something.
  defp sample_code do
    """
    defmodule UserCache do
      def fetch(id) do
        # Hits arbitrary user-controlled path.
        path = "/var/cache/users/" <> id <> ".json"
        case File.read(path) do
          {:ok, body} -> Jason.decode!(body)
          _ -> nil
        end
      end

      def find_user(users, target_name) do
        # Quadratic on `users` because filter + List.first instead of find/1.
        users
          |> Enum.filter(fn u -> u["name"] == target_name end)
          |> List.first()
      end

      def all_emails(users) do
        # Builds string with ++ in a reduce — quadratic.
        Enum.reduce(users, "", fn u, acc -> acc ++ "," ++ u["email"] end)
      end
    end
    """
  end
end
