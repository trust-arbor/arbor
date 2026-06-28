defmodule ArborTui.LifecycleTest do
  @moduledoc """
  Tests the agent-lifecycle client commands (/new, /start, /stop): command
  parsing, the async spawn-and-push, success rendering + AUTO-ATTACH, and clear
  error rendering. The HTTP layer is stubbed via the `:lifecycle_client` app-env
  seam (same pattern as agents_test.exs stubs `:agents_client`), so no network is
  touched.
  """
  use ExUnit.Case, async: false

  alias ArborTui.App

  # Stub lifecycle clients injected via :lifecycle_client. They record their
  # args to the test pid (so we can assert command parsing) and return canned
  # results.
  defmodule OkClient do
    def create(_id, _url, template, name) do
      send(test_pid(), {:create, template, name})

      {:ok,
       %{"agent_id" => "agent_new999", "display_name" => name || template, "running" => true}}
    end

    def start(_id, _url, agent_id) do
      send(test_pid(), {:start, agent_id})
      {:ok, %{"agent_id" => agent_id, "running" => true}}
    end

    def stop(_id, _url, agent_id) do
      send(test_pid(), {:stop, agent_id})
      {:ok, %{"agent_id" => agent_id, "running" => false}}
    end

    defp test_pid, do: Application.get_env(:arbor_tui, :lifecycle_test_pid, self())
  end

  defmodule ErrorClient do
    def create(_id, _url, _template, _name),
      do: {:error, {:http_error, 403, "unauthorized: nope"}}

    def start(_id, _url, _agent_id), do: {:error, {:http_status, 404}}
    def stop(_id, _url, _agent_id), do: {:error, :econnrefused}
  end

  defp model(overrides \\ %{}) do
    base = %{
      ws: nil,
      runtime: self(),
      identity: %{agent_id: "agent_me", private_key: <<0::256>>},
      identity_id: "agent_me",
      agent_id: nil,
      gateway_url: "ws://localhost:4000",
      status: :idle,
      status_detail: nil,
      engagement_id: nil,
      input: "",
      history: [],
      hist_pos: nil,
      draft: "",
      messages: [],
      streaming: nil,
      turn: :idle,
      pending_approvals: [],
      auto_approve: MapSet.new()
    }

    Map.merge(base, overrides)
  end

  defp up(msg, state), do: elem(App.update(msg, state), 0)

  # The spawned POST casts {:message, :root, {:lifecycle_result, op, result}} to
  # `runtime` (the test pid). Awaits + unwraps it.
  defp await_lifecycle_result do
    receive do
      {:"$gen_cast", {:message, :root, {:lifecycle_result, op, result}}} -> {op, result}
    after
      2_000 -> flunk("no :lifecycle_result pushed to the runtime")
    end
  end

  setup do
    # The stub runs inside the spawned task (a different process), so it can't
    # use its own self() to reach the test — pin the test pid via app env.
    Application.put_env(:arbor_tui, :lifecycle_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:arbor_tui, :lifecycle_client)
      Application.delete_env(:arbor_tui, :lifecycle_test_pid)
    end)

    :ok
  end

  # ── /new ────────────────────────────────────────────────────────────────

  describe "/new command" do
    test "parses <template> [name], shows a note, and pushes a create result" do
      Application.put_env(:arbor_tui, :lifecycle_client, OkClient)

      s = up(:submit, model(%{input: "/new researcher Rita"}))

      assert s.input == ""
      assert List.last(s.messages).text =~ "Creating agent from 'researcher'"

      assert_receive {:create, "researcher", "Rita"}
      assert {:new, {:ok, _}} = await_lifecycle_result()
    end

    test "parses a template with no name" do
      Application.put_env(:arbor_tui, :lifecycle_client, OkClient)

      up(:submit, model(%{input: "/new coder"}))
      assert_receive {:create, "coder", nil}
    end

    test "usage when no template given" do
      s = up(:submit, model(%{input: "/new"}))
      assert List.last(s.messages).text =~ "usage: /new"
    end
  end

  describe "/new result rendering" do
    test "success renders 'Created' and AUTO-ATTACHES (resets transcript, connecting)" do
      result = {:ok, %{"agent_id" => "agent_new999", "display_name" => "Rita", "running" => true}}
      s = up({:lifecycle_result, :new, result}, model())

      assert s.agent_id == "agent_new999"
      assert s.status == :connecting
      # Transcript reset to a single attach note.
      assert length(s.messages) == 1
      assert List.first(s.messages).text =~ "Created Rita"
      assert List.first(s.messages).text =~ "Attaching"
    end

    test "error renders clearly" do
      result = {:error, {:http_error, 403, "unauthorized: nope"}}
      s = up({:lifecycle_result, :new, result}, model())

      assert List.last(s.messages).role == :system
      assert List.last(s.messages).text =~ "Create failed"
      assert List.last(s.messages).text =~ "unauthorized: nope"
      # No attach on failure.
      assert s.agent_id == nil
    end
  end

  # ── /start ──────────────────────────────────────────────────────────────

  describe "/start command" do
    test "parses <id>, shows a note, and pushes a start result" do
      Application.put_env(:arbor_tui, :lifecycle_client, OkClient)

      s = up(:submit, model(%{input: "/start agent_abc"}))
      assert List.last(s.messages).text =~ "Starting agent_abc"

      assert_receive {:start, "agent_abc"}
      assert {{:start, "agent_abc"}, {:ok, _}} = await_lifecycle_result()
    end

    test "usage when no id given" do
      s = up(:submit, model(%{input: "/start"}))
      assert List.last(s.messages).text =~ "usage: /start"
    end

    test "success AUTO-ATTACHES to the started agent" do
      result = {:ok, %{"agent_id" => "agent_abc", "running" => true}}
      s = up({:lifecycle_result, {:start, "agent_abc"}, result}, model())

      assert s.agent_id == "agent_abc"
      assert s.status == :connecting
      assert List.first(s.messages).text =~ "Started"
    end

    test "error renders clearly without attaching" do
      result = {:error, {:http_status, 404}}
      s = up({:lifecycle_result, {:start, "agent_abc"}, result}, model())

      assert List.last(s.messages).text =~ "Start failed"
      assert List.last(s.messages).text =~ "HTTP 404"
      assert s.agent_id == nil
    end
  end

  # ── /stop ───────────────────────────────────────────────────────────────

  describe "/stop command" do
    test "parses <id>, shows a note, and pushes a stop result" do
      Application.put_env(:arbor_tui, :lifecycle_client, OkClient)

      s = up(:submit, model(%{input: "/stop agent_xyz"}))
      assert List.last(s.messages).text =~ "Stopping agent_xyz"

      assert_receive {:stop, "agent_xyz"}
      assert {{:stop, "agent_xyz"}, {:ok, _}} = await_lifecycle_result()
    end

    test "usage when no id given" do
      s = up(:submit, model(%{input: "/stop"}))
      assert List.last(s.messages).text =~ "usage: /stop"
    end

    test "success confirms and DETACHES when the stopped agent is the attached one" do
      result = {:ok, %{"agent_id" => "agent_attached", "running" => false}}

      s =
        up(
          {:lifecycle_result, {:stop, "agent_attached"}, result},
          model(%{agent_id: "agent_attached", status: :connected})
        )

      assert s.agent_id == nil
      assert s.status == :detached
      text = s.messages |> Enum.map(& &1.text) |> Enum.join("\n")
      assert text =~ "Stopped"
      assert text =~ "Detached"
    end

    test "success confirms but stays attached when stopping a DIFFERENT agent" do
      result = {:ok, %{"agent_id" => "agent_other", "running" => false}}

      s =
        up(
          {:lifecycle_result, {:stop, "agent_other"}, result},
          model(%{agent_id: "agent_attached", status: :connected})
        )

      assert s.agent_id == "agent_attached"
      assert s.status == :connected
      assert List.last(s.messages).text =~ "Stopped"
    end

    test "error renders clearly" do
      result = {:error, :econnrefused}
      s = up({:lifecycle_result, {:stop, "agent_xyz"}, result}, model())

      assert List.last(s.messages).text =~ "Stop failed"
      assert List.last(s.messages).text =~ "econnrefused"
    end
  end

  # ── works detached + help ─────────────────────────────────────────────────

  describe "available while detached, and listed in /help" do
    test "/new works while detached (no agent attached)" do
      Application.put_env(:arbor_tui, :lifecycle_client, OkClient)
      s = up(:submit, model(%{input: "/new researcher", agent_id: nil, status: :idle}))
      assert List.last(s.messages).text =~ "Creating agent"
      assert_receive {:create, "researcher", nil}
    end

    test "/help lists /new, /start, /stop" do
      s = up(:submit, model(%{input: "/help"}))
      text = s.messages |> Enum.map(& &1.text) |> Enum.join("\n")
      assert text =~ "/new"
      assert text =~ "/start"
      assert text =~ "/stop"
    end
  end
end
