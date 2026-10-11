defmodule Arbor.Actions.Code.HotLoadModuleBindingSecurityRegressionTest do
  @moduledoc """
  Security regression tests for F-007 (2026-10-11 cross-library review):
  `Arbor.Actions.Code.HotLoad` never bound the compiled module to the
  authorized `params.module`, and validated the source at `:limited`.

  - A capability for `arbor://code/hot_load/<Target>` let the source define
    (and load) any other module, including protected ones, because only
    `params.module` was checked against the capability and the protected
    list.
  - `:limited` allows `System.cmd`, `Port.open`, `:os.cmd` and every Erlang
    module, so model-supplied source could execute OS commands at load time.
  - `verify_fn` applied any 0-arity function on any module.

  Harness copied from `code_hot_load_test.exs`.
  """

  use ExUnit.Case, async: false

  # HotLoad modifies global VM state (loaded modules), so async: false is required.

  alias Arbor.Actions.Code.HotLoad

  @moduletag :integration

  @target_module "Arbor.Actions.Code.HotLoadModuleBindingSecurityRegressionTest.Target"
  @target_fqn "Elixir.#{@target_module}"
  @resource "arbor://code/hot_load/#{@target_module}"

  @imposter_module "Arbor.Actions.Code.HotLoadModuleBindingSecurityRegressionTest.Imposter"
  @imposter_fqn "Elixir.#{@imposter_module}"

  @original_source """
  defmodule #{@target_fqn} do
    def value, do: :original
    def health_check, do: :ok
  end
  """

  # A module that is NOT the hot-load target: used to prove `verify_fn`
  # cannot be pointed at a foreign module.
  defmodule Oracle do
    @moduledoc false
    def ping do
      :persistent_term.put({__MODULE__, :called}, true)
      :ok
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    assert :ok = Arbor.Trust.restore_runtime_fixture()

    previous = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      trust_approval: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    agent_id = "agent_hot_load_binding_#{System.unique_integer([:positive])}"

    assert {:ok, _profile} =
             Arbor.Trust.ensure_trust_profile(agent_id,
               baseline: :block,
               rules: %{@resource => :auto}
             )

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: @resource)

    # Write the Target module's .beam file to disk so that HotLoad's
    # save_original/1 (which uses :code.get_object_code) can find it.
    beam_dir =
      Path.join(System.tmp_dir!(), "hot_load_binding_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(beam_dir)

    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    [{module, binary}] = Code.compile_string(@original_source)

    beam_file = Path.join(beam_dir, "#{module}.beam")
    File.write!(beam_file, binary)
    true = :code.add_patha(String.to_charlist(beam_dir))

    on_exit(fn ->
      :code.load_binary(module, String.to_charlist(beam_file), binary)
      :code.del_path(String.to_charlist(beam_dir))
      File.rm_rf!(beam_dir)

      # Make sure no test leaves the imposter behind.
      imposter = Module.concat([@imposter_module])
      :code.purge(imposter)
      :code.delete(imposter)
      :persistent_term.erase({Oracle, :called})

      if Arbor.Security.capability_authorization_available?() do
        Arbor.Security.revoke_all_fixture(agent_id)
      end

      _ = Arbor.Trust.delete_trust_profile(agent_id)

      restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore(:arbor_security, :capability_signing_required, previous.signing)
      restore(:arbor_security, :identity_verification, previous.identity)
      restore(:arbor_security, :strict_identity_mode, previous.strict)
      restore(:arbor_security, :uri_registry_enforcement, previous.uri)
      restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
      restore(:arbor_trust, :approval_guard_enabled, previous.trust_approval)
      restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
    end)

    {:ok, agent_id: agent_id, target: module, imposter: Module.concat([@imposter_module])}
  end

  describe "security regression: compiled module is bound to the authorized module" do
    test "source defining a different module than params.module is refused and not loaded",
         %{agent_id: agent_id, target: target, imposter: imposter} do
      refute Code.ensure_loaded?(imposter)

      imposter_source = """
      defmodule #{@imposter_fqn} do
        def value, do: :imposter
      end
      """

      assert {:error, msg} =
               authorized_hot_load(agent_id, %{module: @target_module, source: imposter_source})

      assert msg =~ "module_mismatch"
      refute Code.ensure_loaded?(imposter)
      assert target.value() == :original
    end

    test "source defining the target plus a nested module is refused and the target is rolled back",
         %{agent_id: agent_id, target: target} do
      nested = Module.concat([target, Nested])
      refute Code.ensure_loaded?(nested)

      source = """
      defmodule #{@target_fqn} do
        defmodule Nested do
          def value, do: :smuggled
        end

        def value, do: :changed
        def health_check, do: :ok
      end
      """

      assert {:error, msg} =
               authorized_hot_load(agent_id, %{module: @target_module, source: source})

      assert msg =~ "module_mismatch"
      refute Code.ensure_loaded?(nested)
      assert target.value() == :original
    end

    test "source with a dynamic module name is refused", %{agent_id: agent_id, target: target} do
      source = """
      defmodule Module.concat([#{inspect(@imposter_module)}]) do
        def value, do: :dynamic
      end
      """

      assert {:error, msg} =
               authorized_hot_load(agent_id, %{module: @target_module, source: source})

      assert msg =~ "module_mismatch" or msg =~ "code_violations"
      assert target.value() == :original
    end
  end

  describe "security regression: hot-loaded source is validated at :hot_load" do
    test "source containing System.cmd is refused before compilation",
         %{agent_id: agent_id, target: target} do
      source = """
      defmodule #{@target_fqn} do
        def value, do: :pwned
        def health_check, do: System.cmd("id", [])
      end
      """

      assert {:error, msg} =
               authorized_hot_load(agent_id, %{module: @target_module, source: source})

      assert msg =~ "code_violations"
      assert msg =~ "System.cmd"
      assert target.value() == :original
    end

    test "source using dynamic dispatch or Erlang escapes is refused",
         %{agent_id: agent_id, target: target} do
      for body <- [
            ~S|m = System; m.cmd("id", [])|,
            ~S|:os.cmd(~c"id")|,
            ~S|:erpc.call(:n, :os, :cmd, [~c"id"])|,
            ~S|:file.write_file("/tmp/x", "y")|,
            ~S|Kernel.apply(System, :cmd, ["id", []])|,
            ~S|Port.open({:spawn, "id"}, [])|,
            ~S|Code.string_to_quoted("1")|
          ] do
        source = """
        defmodule #{@target_fqn} do
          def value, do: :pwned
          def health_check, do: #{body}
        end
        """

        assert {:error, msg} =
                 authorized_hot_load(agent_id, %{module: @target_module, source: source})

        assert msg =~ "code_violations", "expected refusal for: #{body}"
        assert target.value() == :original
      end
    end

    test "a legitimate hot-load of the authorized module still works",
         %{agent_id: agent_id, target: target} do
      source = """
      defmodule #{@target_fqn} do
        require Logger

        def value, do: :updated

        def health_check do
          Logger.debug("health check")
          Enum.all?([1, 2], &is_integer/1)
        end
      end
      """

      assert {:ok, result} =
               authorized_hot_load(agent_id, %{
                 module: @target_module,
                 source: source,
                 verify_fn: "#{@target_module}.health_check/0"
               })

      assert result.loaded == true
      assert result.verification_passed == true
      assert target.value() == :updated
    end
  end

  describe "security regression: verify_fn is bound to the authorized module" do
    test "verify_fn on a foreign module is refused and never invoked",
         %{agent_id: agent_id, target: target} do
      :persistent_term.erase({Oracle, :called})

      source = """
      defmodule #{@target_fqn} do
        def value, do: :should_rollback
        def health_check, do: :ok
      end
      """

      assert {:ok, result} =
               authorized_hot_load(agent_id, %{
                 module: @target_module,
                 source: source,
                 verify_fn: "#{inspect(Oracle)}.ping/0"
               })

      assert result.verification_passed == false
      assert result.rolled_back == true
      assert result.output =~ "authorized module"
      refute :persistent_term.get({Oracle, :called}, false)
      assert target.value() == :original
    end
  end

  defp authorized_hot_load(agent_id, params) do
    Arbor.Actions.authorize_and_execute(agent_id, HotLoad, params, %{agent_id: agent_id})
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
