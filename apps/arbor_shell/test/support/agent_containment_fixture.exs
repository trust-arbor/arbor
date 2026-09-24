defmodule Arbor.Shell.TestAgentContainment do
  @moduledoc false

  def authorize_command(agent, _command, opts),
    do:
      Arbor.Security.authorize(
        agent,
        "arbor://shell/exec/#{opts[:prepared_command].command_name}",
        :execute, verify_identity: false)

  def authorize_filesystem(agent, uri, operation, _capability_id, _opts),
    do: Arbor.Security.authorize(agent, uri, operation, verify_identity: false)

  # Fixture authority is real; only the lower-level app's Trust callback is
  # replaced. Production Trust behavior is covered by the owning Actions tests.
  def install! do
    :ok = Arbor.Security.TestBootstrap.start!()

    root =
      Path.join(
        System.tmp_dir!(),
        "shell_mechanics_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    :ok = File.mkdir(root)
    {:ok, cwd} = Arbor.Common.SafePath.resolve_real(root)
    {:ok, identity} = Arbor.Security.generate_identity(name: "synthetic shell mechanics")
    :ok = Arbor.Security.register_identity(identity)

    {:ok, _} =
      Arbor.Security.grant(principal: identity.agent_id, resource: "arbor://fs/read#{cwd}/**")

    previous = Application.get_env(:arbor_shell, :agent_authorizer)
    Application.put_env(:arbor_shell, :agent_authorizer, __MODULE__)
    Process.put(:agent_containment_fixture, %{cwd: cwd, agent: identity.agent_id})

    ExUnit.Callbacks.on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_shell, :agent_authorizer),
        else: Application.put_env(:arbor_shell, :agent_authorizer, previous)

      {:ok, caps} = Arbor.Security.list_capabilities(identity.agent_id)
      for cap <- caps, do: Arbor.Security.revoke(cap.id)
      Arbor.Security.deregister_identity(identity.agent_id)
      File.rm_rf!(cwd)
    end)

    identity.agent_id
  end

  def execute(agent, command, opts \\ []),
    do: Arbor.Shell.authorize_and_execute(agent, command, options(opts))

  def async(agent, command, opts \\ []),
    do: Arbor.Shell.authorize_and_execute_async(agent, command, options(opts))

  def streaming(agent, command, opts \\ []),
    do: Arbor.Shell.authorize_and_execute_streaming(agent, command, options(opts))

  def prepared(command, prepared, opts \\ []),
    do:
      Arbor.Shell.execute_prepared_authorized(
        Process.get(:agent_containment_fixture).agent,
        command,
        prepared,
        options(opts)
      )

  def options(opts), do: Keyword.put_new(opts, :cwd, Process.get(:agent_containment_fixture).cwd)
end
