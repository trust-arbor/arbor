defmodule CapabilitiesStandaloneConsumer.Application do
  @moduledoc "Starts the fixture-owned provisioner and the standalone Capabilities authority."
  use Application

  alias Arbor.Common.SafePath

  def start(_type, _args) do
    root = System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT")

    for directory <- [
          root,
          Path.join(root, "authority"),
          Path.join(root, "independent-revocations")
        ] do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
    end

    {:ok, canonical} = SafePath.resolve_real(root)
    if canonical != root, do: raise("qualification state root must be canonical")

    {:ok, supervisor} =
      Supervisor.start_link([CapabilitiesStandaloneConsumer.Provisioner],
        strategy: :one_for_one,
        name: CapabilitiesStandaloneConsumer.Supervisor
      )

    case Application.ensure_all_started(:arbor_capabilities) do
      {:ok, _} ->
        {:ok, supervisor}

      {:error, reason} ->
        Supervisor.stop(supervisor)
        {:error, reason}
    end
  end
end

defmodule CapabilitiesStandaloneConsumer.Catalog do
  @moduledoc "Fixed URI catalog for the standalone qualification host."
  def capability_uri_prefixes, do: ["arbor://security", "arbor://standalone"]
end

defmodule CapabilitiesStandaloneConsumer.DurableSink do
  @moduledoc "Private fsynced invocation sink for the standalone qualification host."
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

defmodule CapabilitiesStandaloneConsumer.Provisioner do
  @moduledoc "Supervised caller that owns the fixture's explicitly admitted signing role."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: {:ok, nil}

  def handle_call({:phase, phase}, _from, state)
      when phase in [:write, :recover, :refused, :peers] do
    {:reply, CapabilitiesStandaloneConsumer.Proof.run_owned!(phase), state}
  end
end
