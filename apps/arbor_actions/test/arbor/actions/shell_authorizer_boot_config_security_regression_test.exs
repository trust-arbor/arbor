defmodule Arbor.Actions.ShellAuthorizerBootConfigSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Security
  alias Arbor.Shell
  alias Arbor.Trust
  alias Arbor.Trust.Store
  alias Config.Reader

  @moduletag :integration
  @config_dir Path.expand("../../../../../config", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "shell-boot-" <> Base.encode16(:crypto.strong_rand_bytes(12)))

    :ok = File.mkdir(root)
    {:ok, root} = SafePath.resolve_real(root)
    configs = Path.join(root, "config")
    :ok = File.mkdir(configs)

    # Read the exact real composition source and its environment imports in an
    # empty tree. dev.exs loads ../.env by __DIR__, so merely changing cwd would
    # still expose the developer's dotenv file in the source checkout.
    for name <- ~w(config.exs dev.exs prod.exs provider_route_profile.exs) do
      File.cp!(Path.join(@config_dir, name), Path.join(configs, name))
    end

    fixture_dir = "apps/arbor_kernel/test/fixtures/extension_envelopes/v1"
    File.mkdir_p!(Path.join(root, fixture_dir))

    for name <- ~w(boot_profile_manifest.json boot_profile_signature.json) do
      relative = Path.join(fixture_dir, name)
      File.cp!(Path.join(Path.dirname(@config_dir), relative), Path.join(root, relative))
    end

    previous = Application.fetch_env(:arbor_shell, :agent_authorizer)
    previous_db = System.get_env("ARBOR_DB")
    System.put_env("ARBOR_DB", "sqlite")

    on_exit(fn ->
      restore_env(previous)

      if previous_db,
        do: System.put_env("ARBOR_DB", previous_db),
        else: System.delete_env("ARBOR_DB")

      File.rm_rf!(root)
    end)

    %{root: root, config_path: Path.join(configs, "config.exs")}
  end

  for env <- [:dev, :prod] do
    test "security regression: #{env} composition exposes the real public enforcement identity",
         c do
      apply_binding(c, unquote(env))

      # The missing old binding produces the public typed refusal here, not a
      # config-reader exception. No fake authorizer is injected by this test.
      assert {:ok, identity} = Shell.agent_execution_identity()
      expected = Base.encode16(Actions.Shell.module_info(:md5), case: :lower)
      assert identity["loaded_modules"][Atom.to_string(Actions.Shell)] == expected
      assert identity["supported"] == (:os.type() == {:unix, :darwin})
    end
  end

  @tag skip: :os.type() != {:unix, :darwin}
  test "security regression: boot-configured public Shell reads permitted data and respects revocation",
       c do
    apply_binding(c, :dev)
    identity = principal!(c)

    {:ok, cap} =
      Security.grant(principal: identity.agent_id, resource: "arbor://fs/read#{c.root}/**")

    assert {:ok, %{stdout: "synthetic boot binding", exit_code: 0}} = read(c, identity)
    assert :ok = Security.revoke(cap.id)
    assert {:error, _} = read(c, identity)
  end

  test "command capability alone never grants filesystem access after boot wiring", c do
    apply_binding(c, :prod)
    identity = principal!(c)
    assert {:error, _} = read(c, identity)
  end

  test "explicit missing binding remains a closed public boundary", c do
    apply_binding(c, :dev)
    Application.delete_env(:arbor_shell, :agent_authorizer)
    assert {:error, :agent_execution_identity_unavailable} = Shell.agent_execution_identity()

    assert {:error, :agent_authorizer_unavailable} =
             Shell.authorize_and_execute("synthetic-unregistered", "cat input", cwd: c.root)
  end

  defp apply_binding(c, env) do
    config = Reader.read!(c.config_path, env: env, target: :host)
    # Apply only the actual returned binding; an absent key stays absent. Do not
    # apply dev/prod DB, background work, or other config to the test runtime.
    case Keyword.fetch(Keyword.get(config, :arbor_shell, []), :agent_authorizer) do
      {:ok, value} -> Application.put_env(:arbor_shell, :agent_authorizer, value)
      :error -> Application.delete_env(:arbor_shell, :agent_authorizer)
    end
  end

  defp principal!(c) do
    if Process.whereis(Store) == nil, do: start_supervised!(Store)

    if Process.whereis(Arbor.Trust.Manager) == nil do
      start_supervised!(
        {Arbor.Trust.Manager, circuit_breaker: false, decay: false, event_store: false}
      )
    end

    previous_guard = Application.fetch_env(:arbor_trust, :approval_guard_enabled)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    File.write!(Path.join(c.root, "input"), "synthetic boot binding")
    {:ok, identity} = Security.generate_identity(name: "synthetic boot authorizer")
    :ok = Security.register_identity(identity)
    {:ok, profile} = Profile.new(identity.agent_id)
    :ok = Store.store_profile(profile)
    {:ok, _} = Trust.set_rule(identity.agent_id, "arbor://shell/exec/cat", :auto)
    {:ok, _} = Trust.set_rule(identity.agent_id, "arbor://fs/read#{c.root}", :auto)
    {:ok, _} = Security.grant(principal: identity.agent_id, resource: "arbor://shell/exec/cat")

    on_exit(fn ->
      case previous_guard do
        {:ok, value} -> Application.put_env(:arbor_trust, :approval_guard_enabled, value)
        :error -> Application.delete_env(:arbor_trust, :approval_guard_enabled)
      end

      {:ok, caps} = Security.list_capabilities(identity.agent_id)
      for cap <- caps, do: Security.revoke(cap.id)
      Security.deregister_identity(identity.agent_id)
    end)

    identity
  end

  defp read(c, identity) do
    Shell.authorize_and_execute(identity.agent_id, "cat input",
      cwd: c.root,
      timeout: 5_000,
      approved_invocation: %{
        request_id: "irq_synthetic_boot_binding",
        principal_id: identity.agent_id,
        resource_uri: "arbor://shell/exec/cat",
        decision: :approved
      }
    )
  end

  defp restore_env({:ok, value}), do: Application.put_env(:arbor_shell, :agent_authorizer, value)
  defp restore_env(:error), do: Application.delete_env(:arbor_shell, :agent_authorizer)
end
