defmodule Arbor.AI.Runtime.RouteConcurrencyDispatchTest do
  @moduledoc """
  Public-boundary Dispatch security regression for node-local route concurrency.

  Named path required by the work packet two-revision validator.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Runtime.Dispatch
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request

  # Resolved at runtime so this file can compile/run against a parent revision
  # that does not yet define Arbor.AI.RouteConcurrency.
  @rc_module Module.concat([Arbor, AI, RouteConcurrency])

  defmodule BlockingRuntime do
    @moduledoc false
    @behaviour Arbor.AI.Runtime

    alias Arbor.Contracts.AI.RuntimeProfile

    @impl true
    def prepare(request, _opts), do: {:ok, request}

    @impl true
    def execute(request, _cb, _opts) do
      test_pid = Application.fetch_env!(:arbor_ai, :_test_rc_dispatch_pid)
      send(test_pid, {:entered_execute, request.model, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok,
       %Arbor.LLM.Response{
         text: "blocked-ok",
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1},
         raw: %{model: request.model, runtime: request.runtime}
       }}
    end

    @impl true
    def profile do
      {:ok, p} =
        RuntimeProfile.new(%{
          runtime_id: :rc_blocking,
          display_name: "rc blocking",
          owns_model_loop: false,
          owns_thread_history: false,
          supports_jido_actions: false,
          supports_action_hooks: false,
          supports_native_tools: false,
          runs_context_engine: false,
          exposes_compaction_data: false,
          unsupported_features: []
        })

      p
    end
  end

  setup do
    original_registry = Application.get_env(:arbor_ai, :runtime_registry, %{})
    Application.put_env(:arbor_ai, :_test_rc_dispatch_pid, self())

    on_exit(fn ->
      Application.put_env(:arbor_ai, :runtime_registry, original_registry)
      Application.delete_env(:arbor_ai, :_test_rc_dispatch_pid)
    end)

    :ok
  end

  test "security regression: TOCTOU — limit 1 blocking first attempt blocks simultaneous second from runtime" do
    # Public-boundary proof via Dispatch.dispatch/2 only.
    # With exact-route limit 1, a blocking first attempt prevents a simultaneous
    # second attempt from entering runtime execute.
    # On the parent revision (no atomic acquire) both calls enter execute and
    # this assertion fails behaviorally.

    concurrency_name = :"toctou_rc_dispatch_#{System.unique_integer([:positive])}"
    rc = @rc_module
    candidate? = Code.ensure_loaded?(rc) and function_exported?(rc, :start_link, 1)

    # Candidate-only setup: start a node-local authority with limit 1.
    # Parent has no module / no admission — both Dispatch calls enter execute.
    if candidate? do
      start_supervised!({rc, name: concurrency_name, limits: %{provider_a: %{arbor: 1}}})
    end

    Application.put_env(:arbor_ai, :runtime_registry, %{
      arbor: BlockingRuntime,
      acp: BlockingRuntime
    })

    primary = route_model("primary", :provider_a, "wire-primary", :arbor)
    route_input = provider_route_input([primary])
    authorizer = fn _ -> :allow end

    dispatch_opts = [
      provider_route_input: route_input,
      route_authorizer: authorizer
    ]

    dispatch_opts =
      if candidate? do
        Keyword.put(dispatch_opts, :route_concurrency_server, concurrency_name)
      else
        dispatch_opts
      end

    task_a =
      Task.async(fn ->
        Dispatch.dispatch(build_request("ignored"), dispatch_opts)
      end)

    assert_receive {:entered_execute, "wire-primary", blocker_pid}, 1_000

    task_b =
      Task.async(fn ->
        Dispatch.dispatch(build_request("ignored"), dispatch_opts)
      end)

    # Candidate: second attempt rejected at admission before execute.
    # Parent: both enter execute → Task.await times out or second entered_execute,
    # so the at_capacity assertion fails behaviorally.
    b_result =
      case Task.yield(task_b, 1_000) || Task.shutdown(task_b, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :parent_both_entered_execute}
        {:exit, reason} -> {:error, {:task_exit, reason}}
      end

    assert {:error, {:route_concurrency, :at_capacity}} = b_result
    refute_received {:entered_execute, _, _}

    send(blocker_pid, :release)
    assert {:ok, _} = Task.await(task_a, 1_000)

    if candidate? do
      assert {:ok, snap} = apply(rc, :snapshot, [[route_concurrency_server: concurrency_name]])
      assert snap[{"provider_a", "arbor"}].concurrency_in_use == 0
    end
  end

  defp build_request(model) do
    %Request{
      provider: "anthropic",
      model: model,
      messages: [Message.new(:user, "hello")],
      tools: [],
      tool_choice: nil,
      max_tokens: 100,
      temperature: 0.7,
      reasoning_effort: nil,
      provider_options: %{}
    }
  end

  defp provider_route_input(catalog) do
    %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: catalog,
      scoreboard:
        Enum.map(catalog, fn model ->
          provider = hd(model.providers)

          %{
            model: model.canonical_id,
            provider: Atom.to_string(provider.id),
            runtime: provider.runtimes |> hd() |> Atom.to_string(),
            score: if(model.canonical_id == "primary", do: 1.0, else: 0.5)
          }
        end),
      observations: [],
      budgets: [],
      now: ~U[2026-07-22 22:00:00Z],
      policy: %{}
    }
  end

  defp route_model(canonical_id, provider, ref, runtime) do
    %ModelEntry{
      canonical_id: canonical_id,
      providers: [%ProviderEntry{id: provider, ref: ref, auth: :none, runtimes: [runtime]}],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end
end
