defmodule TrustStandaloneConsumer.Application do
  @moduledoc "Consumer-owned private PubSub and actor provisioner; canonical Trust and Capabilities keep their actual application trees."
  use Application
  alias Arbor.Common.SafePath

  def start(_type, _args) do
    root = System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT")
    paired = System.fetch_env!("PAIRED_STATE_ROOT")

    for directory <- [paired, root] do
      if Path.type(directory) != :absolute or Path.expand(directory) != directory,
        do: raise("state roots must be explicit canonical absolute paths")

      {:ok, %{type: :directory, mode: mode}} = File.lstat(directory)
      if Bitwise.band(mode, 0o077) != 0, do: raise("caller did not create private state root")
      {:ok, canonical} = SafePath.resolve_real(directory)
      if canonical != directory, do: raise("private state root has a symlink ancestor")
    end

    for directory <- [Path.join(root, "authority"), Path.join(root, "independent-revocations")] do
      case File.lstat(directory) do
        {:error, :enoent} -> File.mkdir!(directory)
        {:ok, %{type: :directory}} -> :ok
        _ -> raise "state child is not a directory"
      end

      {:ok, canonical} = SafePath.resolve_real(directory)
      if canonical != directory, do: raise("state child escaped private root")
      File.chmod!(directory, 0o700)
    end

    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: TrustStandaloneConsumer.PubSub},
          TrustStandaloneConsumer.Provisioner,
          ComposedTrustProof.approval_owner_child_spec()
        ],
        strategy: :one_for_one,
        name: TrustStandaloneConsumer.Supervisor
      )

    # Load canonical Trust metadata before Core admits its static role descriptors;
    # this does not start or reparent any Trust authority process.
    case Application.load(:arbor_trust) do
      :ok -> :ok
      {:error, {:already_loaded, :arbor_trust}} -> :ok
    end

    case Application.ensure_all_started(:arbor_capabilities) do
      {:ok, _} ->
        {:ok, supervisor}

      {:error, reason} ->
        Supervisor.stop(supervisor)
        {:error, reason}
    end
  end
end

defmodule TrustStandaloneConsumer.Catalog do
  @moduledoc "Explicit finite first-install catalog owned by this consumer."
  def capability_uri_prefixes,
    do: [
      "arbor://security",
      "arbor://standalone",
      "arbor://memory",
      "arbor://trust",
      "arbor://approval",
      "arbor://code",
      "arbor://agent",
      "arbor://consensus",
      "arbor://comms"
    ]
end

defmodule TrustStandaloneConsumer.Provisioner do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, nil}

  def handle_call(:verify, _from, state),
    do: {:reply, TrustStandaloneConsumer.verify_owned!(), state}
end

defmodule TrustStandaloneConsumer.DurableSink do
  @moduledoc "Leaf's real private fsynced invocation sink; composed consumer selects the real Historian SQL sink instead."
  def persist_security_invocation(event) do
    path = Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "invocations.jsonl")

    with {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      try do
        with :ok <- :file.write(file, Jason.encode!(event) <> "\n"),
             :ok <- :file.sync(file),
             do: {:ok, event["id"]}
      after
        :file.close(file)
      end
    end
  end
end
