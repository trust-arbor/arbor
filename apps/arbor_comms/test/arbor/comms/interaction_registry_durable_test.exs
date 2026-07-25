defmodule Arbor.Comms.InteractionRegistryDurableTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRegistry.Authority
  alias Arbor.Comms.InteractionRegistry.DurableLifecycleCore
  alias Arbor.Comms.InteractionRegistry.DurableStore
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Contracts.Comms.Interaction
  alias Arbor.Contracts.Persistence.Record
  alias __MODULE__.Backend
  alias __MODULE__.ProcessLifetimeBackend

  @moduletag :fast

  setup do
    path =
      Path.join(System.tmp_dir!(), "arbor-comms-durable-#{System.unique_integer([:positive])}")

    Backend.start_link(path)
    original = Application.get_env(:arbor_comms, :durable_interaction_store)

    Application.put_env(
      :arbor_comms,
      :durable_interaction_store,
      backend: Backend,
      namespace: :durable_interaction_integration_test,
      opts: [path: path],
      max_data_bytes: 65_536,
      max_items: 32
    )

    restart_authority()
    InteractionRegistry.reset()

    on_exit(fn ->
      restore_config(original)
      restart_authority()
      Backend.stop()
      File.rm(path)
    end)

    :ok
  end

  test "the facade exposes durable readiness and rejects unsupported durability" do
    assert {:ok, %{durability: :node_restart}} = Arbor.Comms.durable_readiness()
    assert Arbor.Comms.durable_ready?()

    assert {:ok, "irq_facade_durable"} =
             Arbor.Comms.request_interaction(
               interaction_attrs("facade", request_id: "irq_facade_durable"),
               durability: :node_restart
             )

    assert {:error, :unsupported_durability} =
             InteractionRouter.request(
               interaction_attrs("unsupported", request_id: "irq_unsupported"),
               durability: :process_lifetime
             )

    assert {:error, :unsupported_durability} =
             InteractionRegistry.put(
               build_interaction(
                 interaction_attrs("unsupported direct", request_id: "irq_direct")
               ),
               durability: :process_lifetime
             )
  end

  test "durable admission is idempotent and rejects a different interaction" do
    attrs = interaction_attrs("duplicate", request_id: "irq_durable_duplicate")

    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)
    assert {:ok, ^request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:error, :already_tracked} =
             InteractionRouter.request(%{attrs | description: "different"},
               durability: :node_restart
             )
  end

  test "durable pending state survives authority restart and claims a fresh epoch" do
    attrs = interaction_attrs("restart", request_id: "irq_durable_restart")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, first_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 5_000)

    {:ok, before_restart} = DurableStore.get(request_id)
    {:ok, before_data} = DurableLifecycleCore.decode(before_restart.data)
    old_authority = Process.whereis(Authority)
    restart_authority()

    assert old_authority != Process.whereis(Authority)
    assert {:ok, _interaction} = InteractionRegistry.get(request_id)

    assert {:ok, second_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 10_000)

    assert second_capture.operation_id == first_capture.operation_id
    refute second_capture.authority_epoch == first_capture.authority_epoch

    {:ok, after_restart} = DurableStore.get(request_id)
    {:ok, after_data} = DurableLifecycleCore.decode(after_restart.data)
    assert after_data["operation_id"] == before_data["operation_id"]
    assert after_data["owner_deadline_unix_ms"] == before_data["owner_deadline_unix_ms"]

    assert {:error, :authority_unavailable} =
             InteractionRegistry.finalize_timeout(first_capture, request_id)

    assert {:ok, %{status: :abandoned}} =
             InteractionRegistry.finalize_timeout(second_capture, request_id)
  end

  test "the earliest deadline remains in force across repeated arms and restart" do
    attrs = interaction_attrs("deadline", request_id: "irq_durable_deadline")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, first_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 2_000)

    {:ok, first_record} = DurableStore.get(request_id)
    {:ok, first_data} = DurableLifecycleCore.decode(first_record.data)

    assert {:ok, _second_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 60_000)

    {:ok, second_record} = DurableStore.get(request_id)
    {:ok, second_data} = DurableLifecycleCore.decode(second_record.data)
    assert second_data["owner_deadline_unix_ms"] == first_data["owner_deadline_unix_ms"]

    restart_authority()

    assert {:ok, _third_capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 60_000)

    {:ok, third_record} = DurableStore.get(request_id)
    {:ok, third_data} = DurableLifecycleCore.decode(third_record.data)
    assert third_data["owner_deadline_unix_ms"] == first_data["owner_deadline_unix_ms"]
    assert is_binary(first_capture.authority_epoch)
  end

  test "response and timeout have one durable terminal winner" do
    attrs = interaction_attrs("race", request_id: "irq_durable_race")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, capture, :armed} =
             InteractionRegistry.capture_timeout_authority(request_id, 60_000)

    parent = self()

    responder =
      Task.async(fn ->
        send(parent, :response_ready)

        receive do
          :go ->
            InteractionRegistry.resolve(request_id,
              response: :approved,
              metadata: %{"decision" => "approve"}
            )
        end
      end)

    timer =
      Task.async(fn ->
        send(parent, :timeout_ready)

        receive do
          :go -> InteractionRegistry.finalize_timeout(capture, request_id)
        end
      end)

    assert_receive :response_ready
    assert_receive :timeout_ready
    send(responder.pid, :go)
    send(timer.pid, :go)
    results = [Task.await(responder), Task.await(timer)]
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, terminal} = InteractionRegistry.get_terminal(request_id)
    assert terminal.status in [:responded, :abandoned]
  end

  test "durable abandonment is reduced and fenced before publication" do
    attrs = interaction_attrs("abandon", request_id: "irq_durable_abandon")
    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)

    assert {:ok, %Interaction{request_id: ^request_id}} =
             InteractionRegistry.abandon(request_id, :await_timeout)

    assert {:ok, %{status: :abandoned, reason: :await_timeout}} =
             InteractionRegistry.get_terminal(request_id)

    assert {:ok, record} = DurableStore.get(request_id)
    assert {:ok, %{"status" => "abandoned"}} = DurableLifecycleCore.decode(record.data)
  end

  test "durable expiry is reduced through the real store CAS" do
    attrs =
      interaction_attrs("already expired",
        request_id: "irq_durable_expired",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      )

    assert {:ok, request_id} = InteractionRouter.request(attrs, durability: :node_restart)
    assert :not_found = InteractionRegistry.get(request_id)

    assert {:ok, %{status: :expired, reason: :expires_at_elapsed}} =
             InteractionRegistry.get_terminal(request_id)

    assert {:ok, record} = DurableStore.get(request_id)
    assert {:ok, %{"status" => "expired"}} = DurableLifecycleCore.decode(record.data)
  end

  test "approval and text terminal responses round-trip through restart" do
    assert {:ok, approval_id} =
             InteractionRouter.request(
               interaction_attrs("approval", request_id: "irq_durable_approval"),
               durability: :node_restart
             )

    assert :ok = InteractionRouter.respond(approval_id, :approved, %{"decision" => "approve"})
    restart_authority()
    assert {:ok, approval_terminal} = InteractionRegistry.get_terminal(approval_id)
    assert approval_terminal.status == :responded
    assert approval_terminal.response == :approved
    assert approval_terminal.authority_node == node()

    text_attrs = interaction_attrs("text", kind: :clarification, request_id: "irq_durable_text")

    assert {:ok, text_id} =
             InteractionRouter.request(
               text_attrs,
               durability: :node_restart
             )

    assert :ok =
             InteractionRouter.respond(text_id, {:text, "hello"}, %{"source" => "operator"})

    assert {:ok, text_terminal} = InteractionRegistry.get_terminal(text_id)
    assert text_terminal.response == {:text, "hello"}
    assert text_terminal.metadata == %{"source" => "operator"}
  end

  test "disabled and degraded durable storage fail closed while volatile remains available" do
    Application.delete_env(:arbor_comms, :durable_interaction_store)
    restart_authority()
    assert {:error, :disabled} = InteractionRegistry.durable_readiness()

    assert {:ok, _volatile_id} =
             InteractionRouter.request(interaction_attrs("volatile", request_id: "irq_volatile"))

    assert {:error, :durable_unavailable} =
             InteractionRouter.request(interaction_attrs("disabled", request_id: "irq_disabled"),
               durability: :node_restart
             )

    Application.put_env(
      :arbor_comms,
      :durable_interaction_store,
      backend: ProcessLifetimeBackend,
      namespace: :durable_interaction_integration_test,
      opts: [],
      max_data_bytes: 65_536,
      max_items: 32
    )

    restart_authority()
    assert {:error, :unsupported} = InteractionRegistry.durable_readiness()

    assert {:ok, _volatile_id} =
             InteractionRouter.request(
               interaction_attrs("volatile again", request_id: "irq_volatile_2")
             )

    assert {:error, :durable_unavailable} =
             InteractionRouter.request(interaction_attrs("degraded", request_id: "irq_degraded"),
               durability: :node_restart
             )
  end

  test "hydration never claims a record owned by another node" do
    interaction = build_interaction(interaction_attrs("foreign", request_id: "irq_foreign"))

    {:ok, data} =
      DurableLifecycleCore.new(interaction, "op_foreign", "other@node", "epoch_foreign", now_ms())

    assert {:ok, _record} = DurableStore.insert_once(interaction.request_id, data)

    restart_authority()
    assert :not_found = InteractionRegistry.get(interaction.request_id)
    assert {:ok, record} = DurableStore.get(interaction.request_id)
    assert {:ok, decoded} = DurableLifecycleCore.decode(record.data)
    assert decoded["authority_node"] == "other@node"
    assert decoded["authority_epoch"] == "epoch_foreign"
  end

  defp interaction_attrs(description, overrides) do
    Map.merge(
      %{
        request_id: "irq_#{System.unique_integer([:positive])}",
        kind: :approval,
        agent_id: "agent_durable",
        user_id: "user_durable",
        description: description,
        submitted_at: ~U[2026-01-01 00:00:00Z]
      },
      Map.new(overrides)
    )
  end

  defp build_interaction(attrs) do
    {:ok, interaction} = Interaction.new(attrs)
    interaction
  end

  defp restart_authority do
    case Process.whereis(Authority) do
      pid when is_pid(pid) ->
        Process.exit(pid, :kill)

        unless wait_for_new_authority(pid, 100) do
          raise "authority did not restart"
        end

      nil ->
        {:ok, _} = start_supervised(Arbor.Comms.InteractionRegistry)
    end
  end

  defp wait_for_new_authority(_old_pid, 0), do: is_pid(Process.whereis(Authority))

  defp wait_for_new_authority(old_pid, attempts) do
    case Process.whereis(Authority) do
      new_pid when is_pid(new_pid) and new_pid != old_pid ->
        true

      _ ->
        Process.sleep(10)
        wait_for_new_authority(old_pid, attempts - 1)
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp restore_config(nil), do: Application.delete_env(:arbor_comms, :durable_interaction_store)

  defp restore_config(value),
    do: Application.put_env(:arbor_comms, :durable_interaction_store, value)

  defmodule Backend do
    alias Arbor.Contracts.Persistence.Record

    def start_link(path) do
      case Process.whereis(__MODULE__) do
        nil -> Agent.start_link(fn -> load(path) end, name: __MODULE__)
        _pid -> {:ok, __MODULE__}
      end
    end

    def stop do
      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
      :ok
    catch
      :exit, _ -> :ok
    end

    def durability_class(_opts), do: :node_restart

    def get(key, _opts) do
      Agent.get(__MODULE__, fn state ->
        case Map.fetch(state, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end)
    end

    def list(_opts), do: Agent.get(__MODULE__, fn state -> {:ok, Map.keys(state)} end)

    def compare_and_swap(key, :not_found, %Record{} = replacement, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key) do
          nil ->
            stored = %{replacement | generation: 1, revision: 1}
            next = Map.put(state, key, stored)
            persist(opts, next)
            {{:ok, stored}, next}

          _ ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def compare_and_swap(key, {:value, %Record{} = expected}, %Record{} = replacement, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key) do
          %Record{generation: generation, revision: revision} = current
          when generation == expected.generation and revision == expected.revision ->
            stored = %{
              replacement
              | id: current.id,
                key: current.key,
                generation: current.generation,
                revision: current.revision + 1,
                inserted_at: current.inserted_at
            }

            next = Map.put(state, key, stored)
            persist(opts, next)
            {{:ok, stored}, next}

          _ ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}

    defp persist(opts, state),
      do: File.write!(Keyword.fetch!(opts, :path), :erlang.term_to_binary(state))

    defp load(path) do
      case File.read(path) do
        {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
        {:error, :enoent} -> %{}
      end
    end
  end

  defmodule ProcessLifetimeBackend do
    def durability_class(_opts), do: :process_lifetime
    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}
  end
end
