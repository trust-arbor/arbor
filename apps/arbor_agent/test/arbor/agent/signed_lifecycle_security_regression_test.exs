defmodule Arbor.Agent.SignedLifecycleSecurityRegressionTest do
  @moduledoc """
  `mix arbor.agent start` / `resume` for a local operator whose key exists only
  in its key file (`mix arbor.user.init`, F-002).

  Regression for: every CLI start and resume failed with
  `:capability_mutation_unauthorized`, because `Lifecycle.create/2` and
  `start/2` require a caller-owned actor authority and none can cross RPC.
  The CLI now signs one lifecycle request with the key file; the server
  verifies it against the registered key and opens a one-use caller-held
  authority for exactly that operation.

  The operator is registered through the public caller-held registration
  facade. This suite shares one CapabilityStore whose wildcard grant-holders
  close genesis, so the operator's administrator capabilities come from
  fixtures here; `Mix.Tasks.Arbor.User.InitTest` covers genesis.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :security_regression
  @moduletag timeout: 120_000

  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.BranchSupervisor
  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Manager
  alias Arbor.Agent.TemplateStore
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  @operator_resources [
    "arbor://agent/lifecycle/create",
    "arbor://agent/lifecycle/start/*",
    "arbor://security/identity/register",
    "arbor://security/identity/endorse/*",
    "arbor://security/grant/*",
    "arbor://security/revoke/*",
    "arbor://security/identity/deregister/*",
    "arbor://security/identity/suspend/*",
    "arbor://security/identity/resume/*"
  ]
  @local_opts [start_session: false, start_heartbeat: false, recover_session: false]

  setup_all do
    if Process.whereis(:arbor_agent_profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
          id: :arbor_agent_profiles
        )
      )
    end

    {:ok, cleanup_principal} = Agents.open_lifecycle_actor_fixture()
    on_exit(fn -> Agents.close_lifecycle_actor_fixture(cleanup_principal) end)
    {:ok, cleanup_principal: cleanup_principal}
  end

  setup %{cleanup_principal: cleanup_principal} do
    previous_flag =
      Application.get_env(:arbor_capabilities, :allow_local_human_identity, :__absent__)

    previous_oidc = Application.get_env(:arbor_capabilities, :oidc, :__absent__)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)
    Application.delete_env(:arbor_capabilities, :oidc)

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    dir = private_dir!()
    template = "signed-lifecycle-#{System.unique_integer([:positive])}"
    TemplateStore.set_templates_dir(Path.join(dir, "templates"))

    assert :ok =
             Agents.put_template(template, %{
               "name" => template,
               "character" => %{"name" => "Signed lifecycle fixture"},
               "required_capabilities" => [],
               "tools" => []
             })

    before = agent_ids()

    on_exit(fn ->
      for agent_id <- MapSet.difference(agent_ids(), before) do
        Agents.destroy_agent_fixture(agent_id, cleanup_principal)
      end

      TemplateStore.clear_templates_dir_override()
      Mix.shell(previous_shell)
      restore_env(:allow_local_human_identity, previous_flag)
      restore_env(:oidc, previous_oidc)
      File.rm_rf!(dir)
    end)

    operator = operator!(dir, "operator")
    grant_all!(operator.principal, @operator_resources)

    {:ok, dir: dir, template: template, operator: operator}
  end

  test "security regression: a caller-held operator starts and resumes an agent through the CLI",
       %{template: template, operator: operator} do
    opts = cli_opts(operator, name: "River #{System.unique_integer([:positive])}")

    # No server-held key, and no authority could cross RPC: this used to fail
    # with :capability_mutation_unauthorized before anything was created.
    assert {:error, :no_signing_key} = Security.signing_key_status(operator.principal)

    assert {:ok, calls} = run_cli(:start_operator, [template, opts])
    assert infos() =~ "Started agent '#{opts[:name]}'"

    assert [
             {TemplateStore, :get},
             {Arbor.Agent, :submit_signed_lifecycle_request}
           ] = called(calls)

    refute_secret_crossed(calls, operator.private_key)

    assert [{_, :submit_signed_lifecycle_request, _args, {:ok, agent_id, _pid, :created}}] =
             Enum.filter(calls, &(elem(&1, 1) == :submit_signed_lifecycle_request))

    assert is_pid(BranchSupervisor.whereis(agent_id))

    # The operator owns the conversation, so `mix arbor.agent chat` can reach it.
    assert holds?(operator.principal, "arbor://chat/agent/#{agent_id}")

    # ...and the agent's Session can mint the one-turn disclosure capability
    # for the operator's own chat turn to an external route. Without this a
    # fresh install refused every chat as :turn_preparation_refused
    # (2026-11-13). The right is the narrow one, never a general self-grant.
    assert {:ok, disclose} = Security.disclosure_issue_right_uri(agent_id, operator.principal)
    assert holds?(agent_id, disclose)
    refute holds?(agent_id, "arbor://security/grant/#{agent_id}")
    # Still no server-held key for the operator.
    assert {:error, :no_signing_key} = Security.signing_key_status(operator.principal)

    # Stop, then resume by name with a fresh signed request.
    stop!(agent_id)

    assert {:ok, calls} = run_cli(:resume_operator, [opts[:name], opts])
    assert infos() =~ "Resumed agent '#{opts[:name]}' (#{agent_id})"
    refute_secret_crossed(calls, operator.private_key)
    assert is_pid(BranchSupervisor.whereis(agent_id))

    # `start` with an existing name resumes it rather than creating another.
    stop!(agent_id)
    assert {:ok, _calls} = run_cli(:start_operator, [template, opts])
    assert infos() =~ "Resumed agent '#{opts[:name]}' (#{agent_id})"
    assert [^agent_id] = ids_named(opts[:name])
  end

  test "security regression: a request signed for other arguments is refused before any effect",
       %{template: template, operator: operator} do
    request = start_request(template, "Bound name")
    before = agent_ids()

    for {field, value} <- [
          template: "other-template",
          display_name: "Other name",
          provider: "anthropic",
          model: "other-model"
        ] do
      signed = sign(operator, request)

      assert {:error, {:unauthorized, :payload_mismatch}} =
               submit(operator, %{request | field => value}, signed),
             "a proof for #{field}=#{request[field]} must not authorize #{inspect(value)}"
    end

    # Signed for resume of one agent, submitted as a start, and the reverse.
    resume = %{operation: :resume, agent_id: "agent_" <> String.duplicate("a", 64)}

    assert {:error, {:unauthorized, :payload_mismatch}} =
             submit(operator, request, sign(operator, resume))

    assert {:error, {:unauthorized, :payload_mismatch}} =
             submit(operator, resume, sign(operator, request))

    assert agent_ids() == before
  end

  test "security regression: a request signed for another purpose is refused",
       %{template: template, operator: operator} do
    request = start_request(template, "Purpose probe")
    before = agent_ids()

    {:ok, genesis} = Security.local_genesis_request_payload(operator.principal)

    {:ok, registration} =
      Security.local_human_registration_request_payload(operator.principal, operator.public_key)

    {:ok, message} = Agents.lifecycle_request_payload(operator.principal, request)
    legacy_http = "POST\n/api/chat/agents\n" <> Jason.encode!(%{template: template})

    for payload <- [genesis, registration, legacy_http, message <> "x", "start an agent"] do
      {:ok, signed} = SignedRequest.sign(payload, operator.principal, operator.private_key)
      assert {:error, {:unauthorized, :payload_mismatch}} = submit(operator, request, signed)
    end

    assert agent_ids() == before
  end

  test "security regression: a replayed, stale or foreign-key request is refused",
       %{template: template, operator: operator, dir: dir} do
    request = start_request(template, "Replay probe #{System.unique_integer([:positive])}")
    before = agent_ids()

    stale = resign(%{sign(operator, request) | timestamp: ago(3_600)}, operator.private_key)
    assert {:error, {:unauthorized, :expired_timestamp}} = submit(operator, request, stale)

    attacker = operator!(dir, "attacker")
    {:ok, payload} = Agents.lifecycle_request_payload(operator.principal, request)
    {:ok, forged} = SignedRequest.sign(payload, operator.principal, attacker.private_key)
    assert {:error, {:unauthorized, :invalid_signature}} = submit(operator, request, forged)

    # A different signer cannot act for the operator, even with its own valid
    # signature over a payload naming the operator.
    {:ok, other} = SignedRequest.sign(payload, attacker.principal, attacker.private_key)
    assert {:error, {:unauthorized, _}} = submit(operator, request, other)

    assert agent_ids() == before

    once = sign(operator, request)

    assert {:ok, agent_id, _pid, :created} =
             Agents.submit_signed_lifecycle_request(
               operator.principal,
               request,
               once,
               @local_opts
             )

    stop!(agent_id)

    # The accepted proof cannot start it again.
    assert {:error, {:unauthorized, :replayed_nonce}} = submit(operator, request, once)
    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: an unregistered principal or a closed local-human gate is refused",
       %{template: template, operator: operator, dir: dir} do
    request = start_request(template, "Gate probe")
    before = agent_ids()

    unregistered = operator!(dir, "unregistered", register: false)
    grant_all!(unregistered.principal, @operator_resources)

    assert {:error, {:unauthorized, :identity_not_found}} =
             submit(unregistered, request, sign(unregistered, request))

    # A local-issuer principal does not resolve while the gate is closed.
    signed = sign(operator, request)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, false)
    assert {:error, {:unauthorized, :identity_not_found}} = submit(operator, request, signed)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)

    assert agent_ids() == before
  end

  test "security regression: the operator still needs the lifecycle capability",
       %{template: template, dir: dir} do
    bare = operator!(dir, "no-caps")
    request = start_request(template, "Capability probe")
    before = agent_ids()

    assert {:error, {:unauthorized, _reason}} = submit(bare, request, sign(bare, request))
    assert agent_ids() == before
  end

  # -- CLI seam --------------------------------------------------------------

  # Each server call runs in its own process, as `:rpc` runs it, so the
  # lifecycle authority is owned by a process other than the CLI's.
  defp run_cli(function, args) do
    Process.put(:signed_lifecycle_calls, [])

    remote = fn module, fun, call_args ->
      call_args =
        if {module, fun} == {Arbor.Agent, :submit_signed_lifecycle_request},
          do: call_args ++ [@local_opts],
          else: call_args

      task = Task.async(fn -> apply(module, fun, call_args) end)
      result = Task.await(task, 60_000)

      Process.put(:signed_lifecycle_calls, [
        {module, fun, call_args, result} | Process.get(:signed_lifecycle_calls, [])
      ])

      result
    end

    result = apply(Mix.Tasks.Arbor.Agent, function, args ++ [remote])
    calls = Enum.reverse(Process.get(:signed_lifecycle_calls, []))
    if result == :ok, do: {:ok, calls}, else: {:error, calls}
  end

  defp cli_opts(operator, extra),
    do:
      [key_file: operator.key_path, provider: "openrouter", model: "sealed-no-provider"] ++ extra

  defp called(calls), do: Enum.map(calls, fn {m, f, _a, _r} -> {m, f} end)

  defp refute_secret_crossed(calls, private_key) do
    for {_m, f, args, result} <- calls do
      assert :binary.match(:erlang.term_to_binary({args, result}), private_key) == :nomatch,
             "private key material crossed the server boundary in #{f}"
    end
  end

  defp infos, do: drain(:info)

  defp drain(kind) do
    receive do
      {:mix_shell, ^kind, [message]} -> message <> "\n" <> drain(kind)
    after
      0 -> ""
    end
  end

  # -- requests --------------------------------------------------------------

  defp start_request(template, name) do
    %{
      operation: :start,
      template: template,
      display_name: name,
      provider: "openrouter",
      model: "sealed-no-provider"
    }
  end

  defp sign(operator, request) do
    {:ok, payload} = Agents.lifecycle_request_payload(operator.principal, request)
    {:ok, signed} = SignedRequest.sign(payload, operator.principal, operator.private_key)
    signed
  end

  defp submit(operator, request, signed),
    do: Agents.submit_signed_lifecycle_request(operator.principal, request, signed, @local_opts)

  defp resign(%SignedRequest{} = request, private_key) do
    message = SignedRequest.signing_payload(request)
    %{request | signature: :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

  # -- fixtures --------------------------------------------------------------

  # A local operator registered the way `mix arbor.user.init` registers it:
  # key generated here, key file written here, only the public key sent.
  defp operator!(dir, tag, opts \\ []) do
    claims = [user: "#{tag}-#{System.unique_integer([:positive])}", host: "signed-lifecycle.test"]
    principal = Security.local_human_principal_id(claims)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_path = Path.join(dir, "#{tag}-#{System.unique_integer([:positive])}.key")

    assert {:ok, ^key_path} =
             Security.write_key_file(key_path, %{agent_id: principal, private_key: private_key})

    if Keyword.get(opts, :register, true) do
      {:ok, payload} = Security.local_human_registration_request_payload(principal, public_key)
      {:ok, proof} = SignedRequest.sign(payload, principal, private_key)

      assert {:ok, _identity, :created} =
               Security.register_local_human_identity(public_key, proof, claims)
    end

    %{
      principal: principal,
      public_key: public_key,
      private_key: private_key,
      key_path: key_path
    }
  end

  defp grant_all!(principal, resources) do
    for resource <- resources do
      assert {:ok, capability} = Security.grant_fixture(principal: principal, resource: resource)
      on_exit(fn -> Security.revoke_fixture(capability.id) end)
    end
  end

  defp stop!(agent_id) do
    assert :ok = Manager.stop_agent(agent_id)
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait_stopped!(agent_id, deadline)
  end

  defp wait_stopped!(agent_id, deadline) do
    cond do
      BranchSupervisor.whereis(agent_id) == nil ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("agent #{agent_id} did not stop")

      true ->
        Process.sleep(20)
        wait_stopped!(agent_id, deadline)
    end
  end

  defp holds?(principal, resource) do
    {:ok, caps} = Security.list_capabilities(principal)
    Enum.any?(caps, &(&1.resource_uri == resource))
  end

  defp agent_ids, do: MapSet.new(Lifecycle.list_agents(), & &1.agent_id)

  defp ids_named(name),
    do: for(p <- Lifecycle.list_agents(), p.display_name == name, do: p.agent_id)

  defp private_dir! do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "signed-lifecycle-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(key, :__absent__), do: Application.delete_env(:arbor_capabilities, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_capabilities, key, value)
end
