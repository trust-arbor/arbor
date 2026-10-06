defmodule Arbor.Orchestrator.TestFixtures.ProvenanceIngress do
  @moduledoc false
  use Jido.Action,
    name: "bound_provenance_ingress",
    description: "Ingress whose descriptor can drift after its effect",
    schema: []

  def effect_class, do: :read

  def execution_idempotency,
    do: Application.get_env(:arbor_orchestrator, :provenance_probe_idempotency, :idempotent)

  def output_taint(%{"failure" => "raise"}), do: raise("provenance unavailable")
  def output_taint(%{"failure" => "exit"}), do: exit(:provenance_unavailable)
  def output_taint(%{"failure" => "throw"}), do: throw(:provenance_unavailable)
  def output_taint(%{"failure" => "malformed"}), do: {:ok, :untrusted}

  def output_taint(_) do
    send(Application.fetch_env!(:arbor_orchestrator, :provenance_probe_owner), :provenance_read)
    :untrusted
  end

  @impl true
  def run(_, _) do
    send(Application.fetch_env!(:arbor_orchestrator, :provenance_probe_owner), :ingress_effect)

    if Application.get_env(:arbor_orchestrator, :provenance_probe_drift, false) do
      Application.put_env(:arbor_orchestrator, :provenance_probe_idempotency, :read_only)
    end

    {:ok, %{payload: "external instruction"}}
  end
end

defmodule Arbor.Orchestrator.TestFixtures.ProvenanceSink do
  @moduledoc false
  use Jido.Action,
    name: "bound_provenance_sink",
    description: "Observable control sink at the actual action taint gate",
    schema: [payload: [type: :string, required: true]]

  def taint_roles, do: %{payload: :control}
  def effect_class, do: :read
  def execution_idempotency, do: :idempotent

  @impl true
  def run(_, _) do
    send(Application.fetch_env!(:arbor_orchestrator, :provenance_probe_owner), :control_effect)
    {:ok, %{executed: true}}
  end
end
