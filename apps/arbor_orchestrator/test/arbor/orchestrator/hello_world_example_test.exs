defmodule Arbor.Orchestrator.HelloWorldExampleTest do
  @moduledoc """
  Demo runner for `specs/pipelines/examples/hello-world.dot`. Loads the
  caller's arbor identity, builds a signer, runs the pipeline against
  LM Studio, asserts a file landed on disk.

  Tagged `:integration_lm_studio` — skipped by default. Run manually:

      ARBOR_KEY=~/.claude/arbor-personal/claude_cli_mbp.arbor.key \
        mix test apps/arbor_orchestrator/test/arbor/orchestrator/hello_world_example_test.exs \
        --only integration_lm_studio

  Prerequisites:

    * LM Studio running at `http://localhost:1234/v1` with `granite-4.1-3b`
      loaded (or change `llm_model=` in the DOT)
    * The agent owning the key file has `arbor://orchestrator/execute/llm_query`
      and `arbor://fs/write` capabilities granted in the local cluster
      (the test will grant them if missing for the test agent ID)

  Why this is a test, not a public CLI:

    Bypassing the capability check requires either (a) a real signer
    threaded into `Orchestrator.run/2`, or (b) `authorization: false`
    in opts. The mix task `arbor.pipeline.run` deliberately does NOT
    expose `authorization: false` as a flag, because that would give
    any caller of `mix` the ability to skip caps on any pipeline. Test
    code is itself the trust boundary (if you can edit the test, you
    have the keys to the kingdom), so it can legitimately set up a
    signer or pass `authorization: false`.
  """

  use ExUnit.Case, async: false
  @moduletag :integration_lm_studio

  setup_all do
    # Umbrella test config disables local LLM provider discovery to keep
    # the unit-test suite hermetic. This integration test needs lm_studio
    # registered as an adapter, so flip the flag back on and clear the
    # cached default client so the next call to Client.default_client/1
    # rebuilds with local providers in the adapter map.
    original_flag = Application.get_env(:arbor_orchestrator, :discover_local_providers, true)
    Application.put_env(:arbor_orchestrator, :discover_local_providers, true)
    Arbor.LLM.Client.clear_default_client()

    # IdentityRegistry is normally started by the arbor_security supervision
    # tree, but `arbor_security, start_children: false` in the test config
    # means it's not running. Start it explicitly so SignedRequest
    # verification can look up our public key.
    case Process.whereis(Arbor.Security.Identity.Registry) do
      nil -> {:ok, _pid} = Arbor.Security.Identity.Registry.start_link([])
      _ -> :ok
    end

    # SignedRequest verification consults the nonce cache to prevent replay.
    case Process.whereis(Arbor.Security.Identity.NonceCache) do
      nil -> {:ok, _pid} = Arbor.Security.Identity.NonceCache.start_link([])
      _ -> :ok
    end

    on_exit(fn ->
      Application.put_env(:arbor_orchestrator, :discover_local_providers, original_flag)
      Arbor.LLM.Client.clear_default_client()
    end)

    :ok
  end

  # Resolve relative to the arbor_orchestrator app root, not the caller's
  # cwd — tests run from the app dir under the umbrella but a manual
  # `mix test` invocation can be from anywhere.
  @dot_path Path.expand("../../../specs/pipelines/examples/hello-world.dot", __DIR__)
  @default_key "~/.claude/arbor-personal/claude_cli_mbp.arbor.key"

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Signer.ProxyCore

  test "generates hello-world for Python, Rust, and Elixir from the same DOT" do
    key_path = (System.get_env("ARBOR_KEY") || @default_key) |> Path.expand()

    if not File.exists?(key_path) do
      flunk("""
      No arbor identity key found at #{key_path}.
      Set ARBOR_KEY to the path of an .arbor.key file, or register an
      external agent via the dashboard and place the key there.
      """)
    end

    {:ok, %{agent_id: agent_id, private_key: private_key}} =
      key_path |> File.read!() |> ProxyCore.parse_key_file()

    # Register the agent's public key in IdentityRegistry so
    # SignedRequest verification has something to look up. Derive the
    # public key from the 32-byte seed (private_key) via Ed25519.
    {public_key, _full_private} = :crypto.generate_key(:eddsa, :ed25519, private_key)

    {:ok, identity} =
      Arbor.Contracts.Security.Identity.new(
        public_key: public_key,
        name: "hello-world-example-test"
      )

    # The derived agent_id is a hash of the public key — it MUST match
    # the agent_id in the key file, otherwise the key file was tampered.
    assert identity.agent_id == agent_id,
           "derived agent_id #{identity.agent_id} doesn't match key file agent_id #{agent_id}"

    :ok = Arbor.Security.Identity.Registry.register(identity)

    # Build the per-resource signer the orchestrator middleware expects.
    # Each capability check produces a fresh SignedRequest with its own
    # nonce + timestamp, signed over the resource URI.
    signer = fn resource ->
      SignedRequest.sign(resource, agent_id, private_key)
    end

    # Ensure the agent has the capabilities the DOT needs. Grants are
    # idempotent — if they're already in place this is a no-op.
    # `arbor://orchestrator/execute/**` covers per-node-type checks
    # (start, transform, exec, gate, etc.). FileGuard expects an
    # `arbor://fs/<op>/<root>` URI so it can validate the requested path
    # against the granted root — we scope the test to /tmp.
    # FileGuard resolves symlinks post-H2. On macOS, /tmp is a symlink to
    # /private/tmp, so a /tmp-scoped grant would reject the symlink-resolved
    # path. Wildcard grant keeps the test portable.
    for uri <- [
          "arbor://orchestrator/execute/**",
          "arbor://orchestrator/execute/llm_query",
          "arbor://fs/**"
        ] do
      grant_capability(agent_id, uri)
    end

    # Three different languages → same DOT, only `language` varies.
    # Demonstrates that pipeline composition decouples policy from any
    # language-specific code-gen logic.
    for {language, ext} <- [{"Python", "py"}, {"Rust", "rs"}, {"Elixir", "exs"}] do
      output_path =
        Path.join(
          System.tmp_dir!(),
          "arbor_hello_#{language}_#{System.unique_integer([:positive])}.#{ext}"
        )

      logs_root =
        Path.join(
          System.tmp_dir!(),
          "arbor_hello_logs_#{language}_#{System.unique_integer([:positive])}"
        )

      on_exit(fn ->
        File.rm(output_path)
        File.rm_rf(logs_root)
      end)

      initial_values = %{
        "language" => language,
        "path" => output_path,
        "session.agent_id" => agent_id
      }

      assert {:ok, result} =
               Arbor.Orchestrator.run_file(@dot_path,
                 signer: signer,
                 initial_values: initial_values,
                 logs_root: logs_root
               )

      assert result.final_outcome.status == :success,
             "[#{language}] pipeline ended with status #{inspect(result.final_outcome.status)}: " <>
               "#{result.final_outcome.failure_reason}"

      assert "generate" in result.completed_nodes
      assert "prepare_content" in result.completed_nodes
      assert "write" in result.completed_nodes

      assert File.exists?(output_path),
             "[#{language}] expected file at #{output_path}"

      content = File.read!(output_path)
      assert byte_size(content) > 0, "[#{language}] file is empty"

      # Smoke-check that the output looks language-appropriate. Each language
      # has a characteristic hello-world signature.
      assert content =~ ~r/hello/i or content =~ ~r/print|println|puts|IO\.puts/,
             "[#{language}] expected hello-world-ish content; got #{inspect(String.slice(content, 0, 200))}"
    end
  end

  defp grant_capability(principal_id, resource_uri) do
    {:ok, cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: resource_uri,
        principal_id: principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true, source: "hello_world_example_test"}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end
end
