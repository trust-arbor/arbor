defmodule PairedStandaloneConsumer.Application do
  @moduledoc "Owns the private Repo, PubSub and admitted provisioner; canonical OTP apps own authority trees."
  use Application

  def start(_type, _args) do
    root = System.fetch_env!("PAIRED_STATE_ROOT")

    for path <- [root, Path.join(root, "authority"), Path.join(root, "independent-revocations")] do
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end

    {:ok, ^root} = Arbor.Common.SafePath.resolve_real(root)
    {:ok, _} = Application.ensure_all_started(:arbor_persistence_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    with {:ok, supervisor} <-
           Supervisor.start_link(
             [
               Arbor.Persistence.SQL.Repo,
               {Phoenix.PubSub, name: PairedStandaloneConsumer.PubSub},
               PairedStandaloneConsumer.Provisioner,
               ComposedTrustProof.approval_owner_child_spec()
             ],
             strategy: :one_for_one,
             name: PairedStandaloneConsumer.Supervisor
           ) do
      if System.fetch_env!("PAIRED_PHASE") == "install" do
        {:ok, supervisor}
      else
        try do
          # Reopening has no schema-install fallback. The explicit prior stage owns DDL.
          %{rows: [[11]]} =
            Ecto.Adapters.SQL.query!(
              Arbor.Persistence.SQL.Repo,
              "SELECT COUNT(*) FROM schema_migrations",
              []
            )

          :ok = PairedStandaloneConsumer.Proof.start_canonical!()
          {:ok, supervisor}
        rescue
          error ->
            Supervisor.stop(supervisor)
            reraise error, __STACKTRACE__
        end
      end
    end
  end
end

defmodule PairedStandaloneConsumer.Provisioner do
  @moduledoc "Real supervised scheduler-role caller. Opaque signing handles never leave this process."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: {:ok, nil}

  def handle_call({:phase, phase}, _from, state)
      when phase in [
             :install,
             :write,
             :recover,
             :namespace_seed,
             :retirement,
             :refused,
             :conflict,
             :namespace_rollback_attack
           ] do
    {:reply, PairedStandaloneConsumer.Proof.run_owned!(phase), state}
  end
end

defmodule PairedStandaloneConsumer.Catalog do
  @moduledoc false
  def capability_uri_prefixes,
    do: [
      "arbor://security",
      "arbor://standalone",
      "arbor://fs",
      "arbor://memory",
      "arbor://trust",
      "arbor://approval",
      "arbor://code",
      "arbor://agent",
      "arbor://consensus",
      "arbor://comms"
    ]
end

defmodule PairedStandaloneConsumer.Authorizer do
  @moduledoc "Trusted fixed adapter; synchronous public authority calls preserve caller identity."
  @behaviour Arbor.Historian.Contracts.Authorizer
  def authorize(principal, resource, action, opts),
    do: Arbor.Security.authorize(principal, resource, action, opts)

  def authorize_self_scoped(principal, resource, owner, prefix, action, opts),
    do: Arbor.Security.authorize_self_scoped(principal, resource, owner, prefix, action, opts)
end

defmodule PairedStandaloneConsumer.InvocationSink do
  @moduledoc "Actual durable Historian sink plus a private synced proof transcript; either failure denies."
  def persist_security_invocation(event) do
    with {:ok, id} <- Arbor.Historian.persist_security_invocation(event) do
      path = Path.join(System.fetch_env!("PAIRED_STATE_ROOT"), "invocations.jsonl")

      with {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
        try do
          with :ok <- :file.write(file, Jason.encode!(event) <> "\n"),
               :ok <- :file.sync(file),
               do: {:ok, id}
        after
          :file.close(file)
        end
      end
    end
  end
end
