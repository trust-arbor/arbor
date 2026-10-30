defmodule SignalsStandaloneConsumer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: SignalsStandaloneConsumer.Supervisor)
  end
end

defmodule SignalsStandaloneConsumer do
  @moduledoc "Independent public-API canary, executable in a release without Mix."

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Signals
  alias Arbor.Signals.Taint, as: SignalsTaint

  @golden_payload %{"a" => [1, true, nil], "z" => "π"}
  @golden_payload_json ~s({"a":[1,true,null],"z":"π"})
  @golden_payload_sha256 "71bd17f72b7094e9b88e72ce13a3ecb59c9cdeeb99d4d2c174ad027d8b55f45e"
  @golden_envelope_json ~s({"payload_encoding":"canonical_json_v1","payload_sha256":"71bd17f72b7094e9b88e72ce13a3ecb59c9cdeeb99d4d2c174ad027d8b55f45e","taint":{"chain":["source_b"],"confidence":"plausible","level":"untrusted","sanitizations":1,"sensitivity":"restricted","source":"source_a"},"version":1})

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false), do: false = Code.ensure_loaded?(Mix)

    {:ok, _started} = Application.ensure_all_started(:signals_standalone_consumer)
    assert_independent_closure!()
    assert_canonical_taint!()
    original_bus = Process.whereis(Arbor.Signals.Bus)
    true = is_pid(original_bus)
    owner = self()

    {:ok, subscription} =
      Signals.subscribe("standalone.*", fn signal ->
        send(owner, {:standalone_signal, signal})
        :ok
      end)

    :ok = Signals.emit(:standalone, :ready, %{value: 42}, async: false)

    receive do
      {:standalone_signal, %{category: :standalone, type: :ready, data: %{value: 42}}} -> :ok
    after
      2_000 -> raise "Standalone signal delivery was not observed"
    end

    {:ok, signals} = Signals.recent(category: :standalone, limit: 10)
    true = Enum.any?(signals, &(&1.type == :ready and &1.data == %{value: 42}))

    {:error, :unauthorized} =
      Signals.subscribe("security.*", fn _signal -> :ok end,
        principal_id: "standalone_principal",
        session_token: "standalone-proof"
      )

    Application.put_env(:arbor_signals, :security_module, SignalsStandaloneConsumer.Authorization)

    {:error, :unauthorized} =
      Signals.subscribe("security.*", fn _signal -> :ok end,
        principal_id: "other_principal",
        session_token: "standalone-proof"
      )

    {:ok, protected_subscription} =
      Signals.subscribe("security.*", fn _signal -> :ok end,
        principal_id: "standalone_principal",
        session_token: "standalone-proof"
      )

    :ok = Signals.unsubscribe(protected_subscription)
    Application.delete_env(:arbor_signals, :security_module)
    :ok = Signals.unsubscribe(subscription)

    :ok = Application.stop(:signals_standalone_consumer)
    :ok = Application.stop(:arbor_signals)
    nil = Process.whereis(Arbor.Signals.Supervisor)
    nil = Process.whereis(Arbor.Signals.Bus)
    false = Process.alive?(original_bus)

    {:ok, _restarted} = Application.ensure_all_started(:signals_standalone_consumer)
    restarted_bus = Process.whereis(Arbor.Signals.Bus)
    true = is_pid(restarted_bus)
    true = restarted_bus != original_bus
    assert_independent_closure!()
    assert_canonical_taint!()

    IO.puts(
      "Standalone Signals verified: canonical taint, v1 bytes, delivery, history, authorization, closure and restart"
    )

    %{
      arbor_applications: ["arbor_kernel", "arbor_signals"],
      kernel_passive: true,
      mix_available: Code.ensure_loaded?(Mix),
      canonical_payload_sha256: @golden_payload_sha256,
      code_paths:
        Map.new([Taint, TaintEnvelope, SignalsTaint, Signals], fn module ->
          {Atom.to_string(module), module |> :code.which() |> List.to_string()}
        end)
    }
  end

  defp assert_independent_closure! do
    loaded = for {app, _description, _version} <- Application.loaded_applications(), do: app
    started = for {app, _description, _version} <- Application.started_applications(), do: app

    compiled =
      :code.get_path()
      |> Enum.flat_map(fn path -> Path.wildcard(Path.join(List.to_string(path), "*.app")) end)
      |> Enum.map(fn path ->
        {:ok, [{:application, app, _properties}]} = :file.consult(String.to_charlist(path))
        app
      end)

    for {kind, applications} <- [loaded: loaded, started: started, compiled: compiled] do
      actual =
        applications
        |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "arbor_"))
        |> Enum.uniq()
        |> Enum.sort()

      if actual != [:arbor_kernel, :arbor_signals] do
        raise "Standalone consumer has unexpected #{kind} Arbor closure: #{inspect(actual)}"
      end
    end

    true = Application.spec(:arbor_kernel, :mod) in [nil, []]
    false = Code.ensure_loaded?(Arbor.Common)
    false = Code.ensure_loaded?(Arbor.Security)
    false = Code.ensure_loaded?(Arbor.Agent)
    :ok
  end

  defp assert_canonical_taint! do
    :error = Application.fetch_env(:arbor_signals, :taint_module)
    :error = Application.fetch_env(:arbor_signals, :taint_envelope_module)
    {:ok, :arbor_kernel} = :application.get_application(Taint)
    {:ok, :arbor_kernel} = :application.get_application(TaintEnvelope)
    %Taint{level: :untrusted} = SignalsTaint.from_level(:untrusted)

    {:ok, left} =
      Taint.new(%{
        level: :derived,
        sensitivity: :confidential,
        sanitizations: 3,
        confidence: :verified,
        source: "source_a",
        chain: []
      })

    {:ok, right} =
      Taint.new(%{
        level: :untrusted,
        sensitivity: :restricted,
        sanitizations: 1,
        confidence: :plausible,
        source: "source_b",
        chain: []
      })

    {:ok, joined} = Taint.join(left, right)
    ^joined = SignalsTaint.propagate_taint([left, right])

    %Taint{
      level: :untrusted,
      sensitivity: :restricted,
      sanitizations: 1,
      confidence: :plausible,
      source: "source_a",
      chain: ["source_b"]
    } = joined

    invalid = Taint.invalid_durable_provenance()
    ^invalid = SignalsTaint.propagate_taint([joined, invalid])
    ^invalid = SignalsTaint.propagate_taint([invalid, joined])

    expected = %{
      "version" => 1,
      "payload_encoding" => "canonical_json_v1",
      "payload_sha256" => @golden_payload_sha256,
      "taint" => %{
        "level" => "untrusted",
        "sensitivity" => "restricted",
        "sanitizations" => 1,
        "confidence" => "plausible",
        "source" => "source_a",
        "chain" => ["source_b"]
      }
    }

    {:ok, ^expected} = SignalsTaint.bind_durable_provenance(@golden_payload, joined)
    {:ok, payload_json} = TaintEnvelope.canonical_json(@golden_payload)
    true = payload_json == @golden_payload_json
    {:ok, envelope_json} = TaintEnvelope.canonical_json(expected)
    true = envelope_json == @golden_envelope_json

    {:ok, %TaintEnvelope{taint: ^joined}} =
      SignalsTaint.verify_durable_provenance(expected, @golden_payload)

    {:ok, %TaintEnvelope{taint: ^joined}} = TaintEnvelope.verify(expected, @golden_payload)

    {:error, :payload_mismatch} =
      SignalsTaint.verify_durable_provenance(expected, %{"tampered" => true})

    {:ok, ^invalid, :invalid_durable_provenance} =
      SignalsTaint.resolve_durable_provenance(expected, %{"tampered" => true})

    :ok
  end
end

defmodule SignalsStandaloneConsumer.Authorization do
  @moduledoc "Exact fixture authorization; it is not a production identity provider."
  @behaviour Arbor.Signals.Contracts.Authorization

  @impl true
  def authorize("standalone_principal", "arbor://signals/subscribe/security", :subscribe,
        session_token: "standalone-proof"
      ),
      do: {:ok, :authorized}

  def authorize(_principal, _resource, _operation, _opts), do: {:error, :no_capability}
end
