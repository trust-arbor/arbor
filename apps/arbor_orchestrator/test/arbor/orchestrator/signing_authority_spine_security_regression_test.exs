defmodule Arbor.Orchestrator.SigningAuthoritySpineSecurityRegressionTest do
  @moduledoc """
  Security regressions for Signing Authority migration Slice 1B-A.

  Proves the dual-path authority spine through `Arbor.Orchestrator.run_as/4`,
  RunAuthorization validation (without retention), Engine checkpoint HMAC v3
  derivation, and fixed Security facade authorization.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.Authorization
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.RunAuthorization
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  @dot """
  digraph AuthoritySpine {
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  setup do
    ensure_authority_stack!()

    {:ok, identity} = Identity.generate(name: "orch-authority-spine")
    public_identity = Identity.public_only(identity)
    :ok = Security.register_identity(public_identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)
    :ok = Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(identity.agent_id)

    # Restore pre-existing env exactly — never unconditionally delete.
    prev_override = Application.get_env(:arbor_orchestrator, :security_available_override)
    prev_required = Application.get_env(:arbor_orchestrator, :security_required)
    prev_module = Application.get_env(:arbor_orchestrator, :security_module)

    Application.put_env(:arbor_orchestrator, :security_available_override, true)

    on_exit(fn ->
      _ = Arbor.Orchestrator.TestCapabilities.revoke_all(identity.agent_id)
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
      restore_env(:security_available_override, prev_override)
      restore_env(:security_required, prev_required)
      restore_env(:security_module, prev_module)
      ensure_broker_started()
    end)

    %{
      agent_id: identity.agent_id,
      private_key: identity.private_key
    }
  end

  # ---------------------------------------------------------------------------
  # run_as dual-path fail-closed
  # ---------------------------------------------------------------------------

  describe "run_as SigningAuthority path — fail closed" do
    test "security regression: principal mismatch is rejected", ctx do
      {:ok, authority} = open_authority(ctx)

      assert {:error, :principal_mismatch} =
               Arbor.Orchestrator.run_as(@dot, "agent_" <> String.duplicate("ab", 32), authority)
    end

    test "security regression: mixed legacy credentials in opts fail closed", ctx do
      {:ok, authority} = open_authority(ctx)
      signer = fn _payload -> {:ok, :fake} end

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority, signer: signer)

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority,
                 authorizer: fn _, _ -> :ok end
               )

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority,
                 identity_private_key: ctx.private_key
               )

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority,
                 signing_authority: authority
               )
    end

    test "security regression: key-presence exclusivity rejects nil/malformed mixed keys",
         ctx do
      {:ok, authority} = open_authority(ctx)
      signer = Security.make_signer(ctx.agent_id, ctx.private_key)

      # Presence of the key is enough — values need not be valid callables/keys.
      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority, signer: nil)

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority, authorizer: nil)

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority, identity_private_key: nil)

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority,
                 identity_private_key: :not_a_key
               )

      # Legacy rejects any present :signing_authority key, including nil.
      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, signer, signing_authority: nil)
    end

    test "security regression: legacy signer path rejects signing_authority in opts", ctx do
      {:ok, authority} = open_authority(ctx)
      signer = Security.make_signer(ctx.agent_id, ctx.private_key)

      assert {:error, :mixed_signing_credentials} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, signer, signing_authority: authority)
    end

    test "security regression: closed authority cannot authorize", ctx do
      {:ok, authority} = open_authority(ctx)
      assert :ok = Security.close_signing_authority(authority)

      assert {:error, {:authority_signing_failed, :authority_not_found}} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority)
    end

    test "security regression: forged authority cannot authorize", ctx do
      forged_token = :crypto.strong_rand_bytes(32)

      {:ok, forged} =
        SigningAuthority.new(
          token: forged_token,
          principal_id: ctx.agent_id,
          purpose: :session
        )

      assert {:error, {:authority_signing_failed, :authority_not_found}} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, forged)
    end

    test "security regression: valid broker authority authorizes a minimal graph", ctx do
      {:ok, authority} = open_authority(ctx)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_run_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, result} =
               Arbor.Orchestrator.run_as(@dot, ctx.agent_id, authority,
                 workdir: root,
                 logs_root: root
               )

      assert is_map(result)
    end
  end

  # ---------------------------------------------------------------------------
  # RunAuthorization: validate but never retain
  # ---------------------------------------------------------------------------

  describe "RunAuthorization does not retain SigningAuthority" do
    test "security regression: authority absent from struct, digest, projection, seed values",
         ctx do
      {:ok, authority} = open_authority(ctx)
      {:ok, graph} = Arbor.Orchestrator.compile(@dot)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_ra_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      opts = [
        authorization: true,
        agent_id: ctx.agent_id,
        workdir: root,
        signing_authority: authority
      ]

      assert {:ok, {run_auth, bound_opts}} = RunAuthorization.prepare(graph, opts)
      assert %RunAuthorization{} = run_auth
      assert run_auth.execution_principal == ctx.agent_id

      # Struct / Map projection must not carry the opaque authority.
      refute Map.has_key?(Map.from_struct(run_auth), :signing_authority)
      projection = RunAuthorization.projection(run_auth)
      refute Map.has_key?(projection, "signing_authority")
      refute Map.has_key?(projection, :signing_authority)
      # Token is arbitrary binary — never use =~; match via term_to_binary.
      refute contains_binary?(projection, authority.token)
      refute contains_binary?(run_auth, authority.token)
      refute contains_binary?(run_auth.binding_digest, authority.token)

      # Process-local Engine opts keep the authority for middleware/HMAC.
      assert %SigningAuthority{} = Keyword.get(bound_opts, :signing_authority)

      # Seed values / initial context stay JSON-clean.
      seeds = RunAuthorization.seed_values(%{}, run_auth, root)
      refute Map.has_key?(seeds, "signing_authority")
      refute Map.has_key?(seeds, :signing_authority)
      refute contains_binary?(seeds, authority.token)
    end

    test "security regression: mixed credentials at RunAuthorization fail closed", ctx do
      {:ok, authority} = open_authority(ctx)
      {:ok, graph} = Arbor.Orchestrator.compile(@dot)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_mixed_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert {:error, :mixed_signing_credentials} =
               RunAuthorization.prepare(graph,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: authority,
                 signer: fn _ -> {:ok, :x} end
               )

      # Key-presence: nil/malformed legacy keys also mix.
      assert {:error, :mixed_signing_credentials} =
               RunAuthorization.prepare(graph,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: authority,
                 signer: nil
               )

      assert {:error, :mixed_signing_credentials} =
               RunAuthorization.prepare(graph,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: authority,
                 authorizer: :not_a_function
               )

      assert {:error, :mixed_signing_credentials} =
               RunAuthorization.prepare(graph,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: authority,
                 identity_private_key: nil
               )

      assert {:error, :principal_mismatch} =
               RunAuthorization.prepare(graph,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: %{
                   authority
                   | principal_id: "agent_" <> String.duplicate("cd", 32)
                 }
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization gate: authority path never consults Config security seams
  # ---------------------------------------------------------------------------

  describe "Authorization.check_orchestrator_access SigningAuthority path" do
    test "security regression: ignores Config.security_available? and still authorizes",
         ctx do
      {:ok, authority} = open_authority(ctx)

      prev_override = Application.get_env(:arbor_orchestrator, :security_available_override)
      prev_required = Application.get_env(:arbor_orchestrator, :security_required)

      Application.put_env(:arbor_orchestrator, :security_available_override, false)
      Application.put_env(:arbor_orchestrator, :security_required, true)

      on_exit(fn ->
        restore_env(:security_available_override, prev_override)
        restore_env(:security_required, prev_required)
      end)

      # Parent consulted Config.security_available? and returned
      # :security_unavailable. Candidate uses fixed Arbor.Security only.
      assert :ok = Authorization.check_orchestrator_access(ctx.agent_id, authority)
    end

    test "security regression: never fails open via security_required?: false", ctx do
      {:ok, authority} = open_authority(ctx)
      assert :ok = Security.close_signing_authority(authority)

      prev_override = Application.get_env(:arbor_orchestrator, :security_available_override)
      prev_required = Application.get_env(:arbor_orchestrator, :security_required)

      # Parent: unavailable + not required → :ok (fail-open) before signing.
      Application.put_env(:arbor_orchestrator, :security_available_override, false)
      Application.put_env(:arbor_orchestrator, :security_required, false)

      on_exit(fn ->
        restore_env(:security_available_override, prev_override)
        restore_env(:security_required, prev_required)
      end)

      assert {:error, {:authority_signing_failed, :authority_not_found}} =
               Authorization.check_orchestrator_access(ctx.agent_id, authority)
    end
  end

  # ---------------------------------------------------------------------------
  # Checkpoint HMAC v3 via broker
  # ---------------------------------------------------------------------------

  describe "checkpoint HMAC authority derivation" do
    test "security regression: derives via broker :engine_checkpoint_hmac_v3", ctx do
      {:ok, authority} = open_authority(ctx)

      secret = Engine.derive_checkpoint_hmac_secret(signing_authority: authority)
      assert is_binary(secret)
      assert byte_size(secret) == 32

      assert {:ok, expected} =
               Security.derive_secret_with_authority(authority, :engine_checkpoint_hmac_v3)

      assert secret == expected

      # Distinct from legacy v2 raw-key derivation.
      legacy = Engine.derive_checkpoint_hmac_secret(identity_private_key: ctx.private_key)
      assert is_binary(legacy)
      refute secret == legacy
    end

    test "security regression: derivation remains stable across facade purge/reload while owner lives",
         ctx do
      {:ok, authority} = open_authority(ctx)

      secret_before = Engine.derive_checkpoint_hmac_secret(signing_authority: authority)
      assert is_binary(secret_before)

      beam_path = :code.which(Arbor.Security)
      assert is_list(beam_path)
      abs_path = beam_path |> List.to_string() |> String.replace_suffix(".beam", "")

      :code.purge(Arbor.Security)
      :code.delete(Arbor.Security)
      assert {:module, Arbor.Security} = :code.load_abs(String.to_charlist(abs_path))

      secret_after = Engine.derive_checkpoint_hmac_secret(signing_authority: authority)
      assert secret_after == secret_before
    end

    test "security regression: closed authority aborts derivation (no silent disable)", ctx do
      {:ok, authority} = open_authority(ctx)
      assert :ok = Security.close_signing_authority(authority)

      assert {:error, {:checkpoint_hmac_derivation_failed, :authority_not_found}} =
               Engine.derive_checkpoint_hmac_secret(signing_authority: authority)
    end

    test "security regression: mixed authority + identity_private_key fails closed", ctx do
      {:ok, authority} = open_authority(ctx)

      assert {:error, :mixed_signing_credentials} =
               Engine.derive_checkpoint_hmac_secret(
                 signing_authority: authority,
                 identity_private_key: ctx.private_key
               )

      # Key-presence: nil/malformed legacy keys also mix.
      assert {:error, :mixed_signing_credentials} =
               Engine.derive_checkpoint_hmac_secret(
                 signing_authority: authority,
                 identity_private_key: nil
               )

      assert {:error, :mixed_signing_credentials} =
               Engine.derive_checkpoint_hmac_secret(
                 signing_authority: authority,
                 signer: nil
               )

      assert {:error, :mixed_signing_credentials} =
               Engine.derive_checkpoint_hmac_secret(
                 signing_authority: authority,
                 authorizer: :bogus
               )
    end

    test "security regression: authorized run with closed authority aborts before resume disable",
         ctx do
      {:ok, authority} = open_authority(ctx)
      assert :ok = Security.close_signing_authority(authority)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_hmac_abort_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      # Direct Engine path with auth + closed authority must abort with derivation
      # failure — not succeed as a non-resumable unsigned run.
      {:ok, graph} = Arbor.Orchestrator.compile(@dot)

      assert {:error, {:checkpoint_hmac_derivation_failed, :authority_not_found}} =
               Engine.run(graph,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 logs_root: root,
                 signing_authority: authority
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Present invalid authority / partial struct-tagged maps
  # ---------------------------------------------------------------------------

  describe "present invalid SigningAuthority fails closed" do
    test "security regression: Arbor.Orchestrator.run with present nil authority never falls back",
         ctx do
      # Fails on a3928b18: Keyword.get treated nil as absence → legacy path.
      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_nil_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert {:error, :invalid_signing_authority} =
               Arbor.Orchestrator.run(@dot,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 authorizer: fn _, _ ->
                   send(self(), :legacy_authorizer_called)
                   :ok
                 end,
                 signing_authority: nil
               )

      refute_received :legacy_authorizer_called
    end

    test "security regression: partial struct-tagged map returns shaped error without crashing broker",
         ctx do
      # Fails on a3928b18 / R3 gaps: field access on partial maps raised KeyError
      # or could crash SigningAuthorityBroker GenServer.
      broker_pid = Process.whereis(SigningAuthorityBroker)
      assert is_pid(broker_pid)
      assert Process.alive?(broker_pid)

      partial = %{
        __struct__: SigningAuthority,
        token: "too-short"
      }

      assert {:error, {:invalid_signing_authority, _reason}} =
               Authorization.check_orchestrator_access(ctx.agent_id, partial)

      assert {:error, :invalid_signing_authority} =
               Engine.derive_checkpoint_hmac_secret(signing_authority: partial)

      # Broker must still be alive after partial-map rejection.
      assert Process.whereis(SigningAuthorityBroker) == broker_pid
      assert Process.alive?(broker_pid)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_partial_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert {:error, {:invalid_signing_authority, _}} =
               Arbor.Orchestrator.run(@dot,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: partial
               )

      assert Process.alive?(broker_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Nested Engine boundaries retain fixed-facade authority mode
  # ---------------------------------------------------------------------------

  describe "nested Engine boundaries retain SigningAuthority" do
    test "security regression: subgraph child with authorized transform requires forwarded signing_authority",
         ctx do
      # Fails on a3928b18: SubgraphHandler allowlist omitted :signing_authority.
      # start/done-only children never exercise handler authorization, so a
      # child transform (not always-authorized) is required. Without the
      # forwarded authority the child falls to legacy authorizer (absent) and
      # fails closed.
      {:ok, authority} = open_authority(ctx)
      grant_pipeline_run!(ctx.agent_id)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_nested_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      child = """
      digraph NestedChild {
        start [shape=Mdiamond]
        work [type="transform", transform="identity", source_key="seed", output_key="out"]
        done [shape=Msquare]
        start -> work -> done
      }
      """

      parent = """
      digraph NestedParent {
        start [shape=Mdiamond]
        child [type="graph.compose", source_key="child_dot", pass_all_context="true"]
        done [shape=Msquare]
        start -> child -> done
      }
      """

      assert {:ok, result} =
               Arbor.Orchestrator.run_as(parent, ctx.agent_id, authority,
                 workdir: root,
                 logs_root: root,
                 initial_values: %{"child_dot" => child, "seed" => "nested-ok"}
               )

      assert is_map(result)
      # Child transform must have run under the forwarded authority path.
      assert result.final_outcome.status == :success
    end

    test "security regression: pipeline.run child with authorized transform requires forwarded signing_authority",
         ctx do
      # Fails on a3928b18: PipelineRunHandler allowlist omitted :signing_authority.
      {:ok, authority} = open_authority(ctx)
      grant_pipeline_run!(ctx.agent_id)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_pipeline_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      child = """
      digraph PipelineChild {
        start [shape=Mdiamond]
        work [type="transform", transform="identity", source_key="seed", output_key="out"]
        done [shape=Msquare]
        start -> work -> done
      }
      """

      parent = """
      digraph PipelineParent {
        start [shape=Mdiamond]
        child [type="pipeline.run", source_key="child_dot"]
        done [shape=Msquare]
        start -> child -> done
      }
      """

      assert {:ok, result} =
               Arbor.Orchestrator.run_as(parent, ctx.agent_id, authority,
                 workdir: root,
                 logs_root: root,
                 initial_values: %{"child_dot" => child, "seed" => "pipeline-ok"}
               )

      assert result.final_outcome.status == :success
    end

    test "security regression: ActionsExecutor does not expose authority in nested action opts",
         ctx do
      # ExecHandler receives the Engine credential, but ActionsExecutor must
      # terminate that bearer-token path before invoking an action.
      {:ok, authority} = open_authority(ctx)

      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_exec_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, binding} = Arbor.Actions.runtime_descriptor(Arbor.Actions.Session.Classify)
      bindings = %{"session_classify" => binding}
      manifest = %{"actions" => [binding]}
      {:ok, manifest_digest} = Arbor.Actions.execution_binding_digest(manifest)

      graph =
        %Arbor.Orchestrator.Graph{
          id: "ExecAuthorityForward",
          compiled: true,
          nodes: %{
            "invoke" => %Arbor.Orchestrator.Graph.Node{
              id: "invoke",
              attrs: %{"type" => "exec", "target" => "action", "action" => "session_classify"}
            }
          }
        }

      {:ok, run_auth} =
        RunAuthorization.new(graph,
          agent_id: ctx.agent_id,
          workdir: root
        )

      # Nil node bindings so an injected capture executor is not rejected as
      # module drift; action pins still drive ActionsExecutor when used.
      run_auth = %{
        run_auth
        | execution_manifest: manifest,
          execution_manifest_digest: manifest_digest,
          pinned_action_bindings: bindings,
          pinned_node_bindings: nil
      }

      outcome =
        Arbor.Orchestrator.Handlers.ExecHandler.execute(
          graph.nodes["invoke"],
          Arbor.Orchestrator.Engine.Context.new(%{"input" => "hello"}),
          graph,
          authorization: true,
          run_authorization: run_auth,
          signing_authority: authority,
          actions_executor:
            Arbor.Orchestrator.SigningAuthoritySpineSecurityRegressionTest.CaptureActionsExecutor
        )

      assert outcome.status == :success
      assert_receive {:executor_opts, executor_opts}, 1_000
      assert Keyword.fetch!(executor_opts, :signing_authority) == authority

      # Real ActionsExecutor nested projection (production nested_engine_opts).
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

      on_exit(fn ->
        :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
      end)

      tracer = self()

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        Arbor.Orchestrator.ActionsExecutor.execute(
          "session_classify",
          %{"input" => "hello"},
          root,
          agent_id: ctx.agent_id,
          authorization: true,
          run_authorization: run_auth,
          signing_authority: authority,
          execution_manifest: manifest,
          execution_manifest_digest: manifest_digest,
          pinned_action_bindings: bindings,
          max_depth: 4
        )
      end)
      |> Task.await(10_000)

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [_agent_id, Arbor.Actions.Session.Classify, _params, action_context]}}

      nested = Map.get(action_context, :nested_engine_opts)
      assert is_list(nested)
      assert Keyword.get(nested, :max_depth) == 3
      refute Keyword.has_key?(nested, :signing_authority)
      refute Keyword.has_key?(nested, :signer)
      refute Keyword.has_key?(nested, :authorizer)
      refute Map.has_key?(action_context, :signing_authority)
    end

    test "security regression: nested compose with present nil signing_authority fails closed",
         ctx do
      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_nested_invalid_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      child = """
      digraph NestedInvalidChild {
        start [shape=Mdiamond]
        work [type="transform", transform="identity", source_key="seed", output_key="out"]
        done [shape=Msquare]
        start -> work -> done
      }
      """

      parent = """
      digraph NestedInvalidParent {
        start [shape=Mdiamond]
        child [type="graph.compose", source_key="child_dot", pass_all_context="true"]
        done [shape=Msquare]
        start -> child -> done
      }
      """

      # Present nil authority fails closed — never legacy authorizer fallback.
      assert {:error, :invalid_signing_authority} =
               Arbor.Orchestrator.run(parent,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: nil,
                 authorizer: fn _, _ ->
                   send(self(), :legacy_authorizer_called)
                   :ok
                 end,
                 initial_values: %{"child_dot" => child, "seed" => "x"}
               )

      refute_received :legacy_authorizer_called
    end

    test "security regression: nested compose with partial struct-tagged authority fails closed",
         ctx do
      root =
        Path.join(
          System.tmp_dir!(),
          "authority_spine_nested_partial_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
      on_exit(fn -> File.rm_rf(root) end)

      partial = %{__struct__: SigningAuthority, token: "too-short"}

      child = """
      digraph NestedPartialChild {
        start [shape=Mdiamond]
        work [type="transform", transform="identity", source_key="seed", output_key="out"]
        done [shape=Msquare]
        start -> work -> done
      }
      """

      parent = """
      digraph NestedPartialParent {
        start [shape=Mdiamond]
        child [type="graph.compose", source_key="child_dot", pass_all_context="true"]
        done [shape=Msquare]
        start -> child -> done
      }
      """

      assert {:error, {:invalid_signing_authority, _}} =
               Arbor.Orchestrator.run(parent,
                 authorization: true,
                 agent_id: ctx.agent_id,
                 workdir: root,
                 signing_authority: partial,
                 authorizer: fn _, _ ->
                   send(self(), :legacy_authorizer_called)
                   :ok
                 end,
                 initial_values: %{"child_dot" => child, "seed" => "x"}
               )

      refute_received :legacy_authorizer_called
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp open_authority(ctx, purpose \\ :session) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             ctx.agent_id,
             ctx.private_key,
             purpose: purpose,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end

  # graph.compose / pipeline.run authorize arbor://action/pipeline/run, which is
  # outside the orchestrator/execute/** grant used by the suite setup.
  defp grant_pipeline_run!(agent_id) do
    {:ok, cap} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: "arbor://action/pipeline/run",
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    on_exit(fn -> Arbor.Security.revoke(cap.id) end)
    :ok
  end

  # authority.token is an arbitrary binary — never use String =~ / Regex.
  defp contains_binary?(term, needle) when is_binary(needle) do
    :binary.match(:erlang.term_to_binary(term), needle) != :nomatch
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, val), do: Application.put_env(:arbor_orchestrator, key, val)

  defp ensure_authority_stack! do
    ensure_buffered_store!(:arbor_security_identities, "identities")
    ensure_buffered_store!(:arbor_security_signing_keys, "signing_keys")
    ensure_buffered_store!(:arbor_security_capabilities, "capabilities")
    ensure_child!(Arbor.Security.Identity.Registry, [])
    ensure_child!(Arbor.Security.Identity.NonceCache, [])
    ensure_child!(Arbor.Security.SystemAuthority, [])
    ensure_broker_started()
  end

  defp ensure_buffered_store!(name, collection) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        child =
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: name, backend: nil, write_mode: :sync, collection: collection},
            id: name
          )

        case Supervisor.start_child(Arbor.Security.Supervisor, child) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, {:already_present, _}} ->
            _ = Supervisor.restart_child(Arbor.Security.Supervisor, name)
            :ok

          other ->
            flunk("failed to start #{name}: #{inspect(other)}")
        end
    end
  end

  defp ensure_child!(module, args) do
    case Process.whereis(module) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.start_child(Arbor.Security.Supervisor, {module, args}) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, {:already_present, _}} ->
            _ = Supervisor.restart_child(Arbor.Security.Supervisor, module)
            :ok

          other ->
            flunk("failed to start #{module}: #{inspect(other)}")
        end
    end
  end

  defp ensure_broker_started do
    case {Process.whereis(Arbor.Security.SigningAuthorityStateOwner),
          Process.whereis(SigningAuthorityBroker)} do
      {owner, broker} when is_pid(owner) and is_pid(broker) ->
        :ok

      {nil, nil} ->
        token = make_ref()
        ensure_child!(Arbor.Security.SigningAuthorityStateOwner, broker_token: token)
        ensure_child!(SigningAuthorityBroker, state_owner_token: token)

      {owner, nil} when is_pid(owner) ->
        case Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          other -> flunk("failed to restart SigningAuthorityBroker: #{inspect(other)}")
        end

      partial ->
        flunk("partial signing authority stack: #{inspect(partial)}")
    end
  end
end

defmodule Arbor.Orchestrator.SigningAuthoritySpineSecurityRegressionTest.CaptureActionsExecutor do
  @moduledoc false

  def execute(_name, _args, _workdir, opts) do
    send(self(), {:executor_opts, opts})
    {:ok, %{"status" => "captured"}}
  end
end
