defmodule Arbor.LLM.DeadlineOwnerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM
  alias Arbor.LLM.Client
  alias Arbor.LLM.Plugs.{Dispatch, ResponseLimit}

  @moduletag :fast

  defmodule BlockingProvider do
    def complete(_request, opts) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, {:provider_started, self()})

      receive do
        :release ->
          send(observer, {:provider_effect, self()})
          {:error, :fixture_finished}
      end
    end

    def stream(_request, opts) do
      observer = Keyword.fetch!(opts, :observer)
      resource = spawn_link(fn -> stream_resource() end)
      send(observer, {:stream_resource, resource})

      {:ok,
       Stream.resource(
         fn -> false end,
         fn
           false ->
             send(resource, {:next, self()})

             receive do
               :resource_ready ->
                 {[%Arbor.LLM.StreamEvent{type: :delta, data: %{text: "kept alive"}}], true}
             end

           true ->
             {:halt, true}
         end,
         fn _ -> send(resource, :stop) end
       )}
    end

    defp stream_resource do
      receive do
        {:next, consumer} ->
          send(consumer, :resource_ready)
          stream_resource()

        :stop ->
          :ok
      end
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.fetch_env(:arbor_llm, :pipeline)
    Application.put_env(:arbor_llm, :pipeline, [ResponseLimit, Dispatch])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :pipeline, value)
        :error -> Application.delete_env(:arbor_llm, :pipeline)
      end
    end)

    :ok
  end

  test "security regression: public generate caller death reaps the actual provider before a later effect" do
    observer = self()
    caller = spawn(fn -> generate(observer) end)
    assert_receive {:provider_started, worker}, 2_000
    assert_caller_loss_reaps(caller, worker)
  end

  test "security regression: public embed caller death reaps the actual HTTP operation" do
    observer = self()
    stub_embedding(observer)
    caller = spawn(fn -> embed() end)
    assert_receive {:provider_started, worker}, 2_000
    assert_caller_loss_reaps(caller, worker)
  end

  test "public generate completion still returns the provider error after its operation exits" do
    observer = self()
    caller = spawn(fn -> send(observer, {:result, generate(observer)}) end)
    caller_monitor = Process.monitor(caller)
    assert_receive {:provider_started, worker}, 2_000
    worker_monitor = Process.monitor(worker)
    send(worker, :release)
    assert_receive {:provider_effect, ^worker}
    assert_receive {:result, {:error, :fixture_finished}}, 2_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
  end

  test "public embed completion retains exact indexed response association" do
    observer = self()
    stub_embedding(observer)
    spawn(fn -> send(observer, {:result, embed()}) end)
    assert_receive {:provider_started, worker}, 2_000
    send(worker, :release)
    assert_receive {:provider_effect, ^worker}
    assert_receive {:result, {:ok, result}}, 2_000
    assert result.association_version == 1
    assert result.indexed_embeddings == [%{index: 0, embedding: [1.0, 0.0]}]
    assert result.provider == "lm_studio"
  end

  test "public generate timeout reaps the provider and keeps the existing typed timeout" do
    observer = self()
    spawn(fn -> send(observer, {:result, generate(observer, 100)}) end)
    assert_receive {:provider_started, worker}, 2_000
    worker_monitor = Process.monitor(worker)
    assert_receive {:result, {:error, %Arbor.LLM.RequestTimeoutError{}}}, 2_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    send(worker, :release)
    refute_receive {:provider_effect, ^worker}, 20
  end

  test "public stream consumes a transferred linked resource after normal operation completion" do
    client = Client.new(adapters: %{"deadline_owner_fixture" => BlockingProvider})

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "deadline_owner_fixture",
               model: "fixture",
               prompt: "fixture",
               timeout_ms: 2_000,
               client_opts: [observer: self()]
             )

    assert_receive {:stream_resource, resource}
    monitor = Process.monitor(resource)
    on_exit(fn -> if Process.alive?(resource), do: Process.exit(resource, :kill) end)
    assert Process.alive?(resource)

    assert [%Arbor.LLM.StreamEvent{type: :delta, data: %{text: "kept alive"}}] =
             Enum.to_list(stream)

    assert_receive {:DOWN, ^monitor, :process, ^resource, :normal}
  end

  test "nested public generate retains the inherited shorter deadline" do
    observer = self()

    spawn(fn ->
      result = LLM.run_with_deadline(fn -> generate(observer, 10_000) end, 100, :outer_timeout)
      send(observer, {:result, result})
    end)

    assert_receive {:provider_started, worker}, 2_000
    monitor = Process.monitor(worker)
    assert_receive {:result, {:error, :outer_timeout}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    send(worker, :release)
    refute_receive {:provider_effect, ^worker}, 20
  end

  defp assert_caller_loss_reaps(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    send(worker, :release)
    refute_receive {:provider_effect, ^worker}, 20
  end

  defp generate(observer, timeout \\ 10_000) do
    client = Client.new(adapters: %{"deadline_owner_fixture" => BlockingProvider})

    LLM.generate(
      client: client,
      provider: "deadline_owner_fixture",
      model: "fixture",
      prompt: "fixture",
      timeout_ms: timeout,
      client_opts: [observer: observer]
    )
  end

  defp embed do
    LLM.embed_batch("lm_studio", "deadline-owner-fixture", ["private fixture"],
      timeout_ms: 10_000,
      req_http_options: [plug: {Req.Test, __MODULE__}, retry: false, redirect: false]
    )
  end

  defp stub_embedding(observer) do
    Req.Test.stub(__MODULE__, fn conn ->
      send(observer, {:provider_started, self()})

      receive do
        :release ->
          send(observer, {:provider_effect, self()})

          Req.Test.json(conn, %{
            "model" => "deadline-owner-fixture",
            "data" => [%{"index" => 0, "embedding" => [1.0, 0.0]}],
            "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
          })
      end
    end)
  end
end
