defmodule ArborTui.AgentsTest do
  @moduledoc """
  Tests for the `/agents` client-local command: the App's spawn-fetch + render
  path (the HTTP layer is stubbed via the `:agents_client` app-env seam, the same
  way the gateway tests stub their bridges) and the http-base derivation in
  ArborTui.AgentsClient.
  """
  use ExUnit.Case, async: false

  alias ArborTui.App
  alias ArborTui.AgentsClient

  # Stub HTTP client modules injected via :agents_client. fetch/2 returns a
  # canned result without touching the network.
  defmodule OkClient do
    def fetch(_identity, _url) do
      {:ok,
       [
         %{
           agent_id: "agent_aaaa1111",
           display_name: "Alice",
           template: "researcher",
           model: "gpt-4o",
           running: true
         },
         %{
           agent_id: "agent_bbbb2222",
           display_name: "Bob",
           template: "coder",
           model: "-",
           running: false
         }
       ]}
    end
  end

  defmodule EmptyClient do
    def fetch(_identity, _url), do: {:ok, []}
  end

  defmodule ErrorClient do
    def fetch(_identity, _url), do: {:error, :econnrefused}
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
      messages: [],
      streaming: nil,
      turn: :idle,
      pending_approvals: [],
      auto_approve: MapSet.new()
    }

    Map.merge(base, overrides)
  end

  defp up(msg, state), do: elem(App.update(msg, state), 0)

  # The spawned fetch casts {:message, :root, {:agents_result, …}} to `runtime`
  # (here, the test pid). Awaits + unwraps that gen_cast envelope.
  defp await_agents_result do
    receive do
      {:"$gen_cast", {:message, :root, {:agents_result, result}}} -> result
    after
      2_000 -> flunk("no :agents_result pushed to the runtime")
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:arbor_tui, :agents_client) end)
    :ok
  end

  describe "/agents command (spawn + async result)" do
    test "shows a fetching note immediately and pushes the result to the runtime" do
      Application.put_env(:arbor_tui, :agents_client, OkClient)

      s = up(:submit, model(%{input: "/agents"}))

      # Immediate feedback, input cleared, no blocking.
      assert s.input == ""
      assert List.last(s.messages).role == :system
      assert List.last(s.messages).text =~ "Fetching agents"

      # The spawned fetch delivered the canned result to the runtime (test pid).
      assert {:ok, [_, _]} = await_agents_result()
    end

    test "works while detached (no agent attached)" do
      Application.put_env(:arbor_tui, :agents_client, OkClient)

      s = up(:submit, model(%{input: "/agents", agent_id: nil, status: :idle}))
      assert List.last(s.messages).text =~ "Fetching agents"
      assert {:ok, _} = await_agents_result()
    end
  end

  describe "rendering the result" do
    test "renders a returned list with name, template and status, plus the attach hint" do
      result =
        {:ok,
         [
           %{
             agent_id: "agent_aaaa1111",
             display_name: "Alice",
             template: "researcher",
             model: "gpt-4o",
             running: true
           },
           %{
             agent_id: "agent_bbbb2222",
             display_name: "Bob",
             template: "coder",
             model: "-",
             running: false
           }
         ]}

      s = up({:agents_result, result}, model())
      text = s.messages |> Enum.map(& &1.text) |> Enum.join("\n")

      assert text =~ "Alice"
      assert text =~ "researcher"
      assert text =~ "[running]"
      assert text =~ "Bob"
      assert text =~ "coder"
      assert text =~ "[stopped]"
      assert text =~ "Use /agent <id> to attach."
    end

    test "renders the empty case" do
      s = up({:agents_result, {:ok, []}}, model())
      assert List.last(s.messages).text =~ "No agents you can chat with."
    end

    test "renders the error case clearly" do
      s = up({:agents_result, {:error, :econnrefused}}, model())
      assert List.last(s.messages).role == :system
      assert List.last(s.messages).text =~ "Couldn't list agents"
      assert List.last(s.messages).text =~ "econnrefused"
    end
  end

  describe "end-to-end via stubbed clients" do
    test "empty client → empty render" do
      Application.put_env(:arbor_tui, :agents_client, EmptyClient)
      up(:submit, model(%{input: "/agents"}))
      result = await_agents_result()
      s = up({:agents_result, result}, model())
      assert List.last(s.messages).text =~ "No agents"
    end

    test "error client → error render" do
      Application.put_env(:arbor_tui, :agents_client, ErrorClient)
      up(:submit, model(%{input: "/agents"}))
      result = await_agents_result()
      s = up({:agents_result, result}, model())
      assert List.last(s.messages).text =~ "Couldn't list agents"
    end
  end

  describe "AgentsClient.http_target/1 (ws→http derivation)" do
    test "ws → http, same host/port" do
      assert AgentsClient.http_target(URI.parse("ws://localhost:4000")) ==
               {:http, "localhost", 4000}
    end

    test "wss → https, same host/port" do
      assert AgentsClient.http_target(URI.parse("wss://gw.example.com:8443")) ==
               {:https, "gw.example.com", 8443}
    end

    test "defaults the port by scheme when absent" do
      assert AgentsClient.http_target(URI.parse("ws://host")) == {:http, "host", 80}
      assert AgentsClient.http_target(URI.parse("wss://host")) == {:https, "host", 443}
    end
  end
end
