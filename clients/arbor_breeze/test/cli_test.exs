defmodule ArborBreeze.CLITest do
  use ExUnit.Case, async: true
  alias ArborBreeze.CLI

  test "device login is the default and an explicit key mode stays opt in" do
    assert {:ok, options} = CLI.parse(["--agent", "agent_fixture"])
    assert options[:url] == "http://127.0.0.1:4000"
    refute Keyword.has_key?(options, :key)
    assert {:ok, options} = CLI.parse(["--agent", "agent_fixture", "--key", "/private/key"])
    assert options[:key] == "/private/key"
    assert {:ok, detached} = CLI.parse([])
    refute Keyword.has_key?(detached, :agent)

    assert {:error, :invalid_options} =
             CLI.parse(["--agent", "agent_fixture", "--secret", "value"])
  end

  test "no-agent CLI starts detached without login, resolution or implicit attachment" do
    for {argv, mode} <- [{[], :human}, {["--key", "/private/key"], :signed}] do
      {:ok, options} = CLI.parse(argv)

      assert :ok =
               CLI.run(options, ArborBreeze.CLITest.ClientProbe, fn controller ->
                 ref = Process.monitor(controller)
                 {:ok, snapshot} = ArborBreeze.Controller.subscribe(controller)
                 assert snapshot.navigation.mode == mode
                 assert snapshot.navigation.target == nil
                 assert snapshot.navigation.directory
                 refute snapshot.connected
                 assert snapshot.projection["messages"] == []
                 refute inspect(snapshot) =~ "/private/key"
                 send(self(), {:detached_owner, controller, ref})
                 :ok
               end)

      assert_receive {:detached_owner, controller, ref}
      assert_receive {:DOWN, ^ref, :process, ^controller, :normal}
      refute_receive {:operator_request, _, _}, 30
    end

    assert_receive {:operator_load_key, "/private/key"}
  end
end

defmodule ArborBreeze.CLITest.ClientProbe do
  def load_key(path) do
    send(self(), {:operator_load_key, path})
    {:ok, %{agent_id: "agent_operator", private_key: :binary.copy(<<1>>, 32)}}
  end

  for {function, arity} <- [
        list_agents: 2,
        resolve_agent: 3,
        list_aliases: 2,
        set_alias: 4,
        remove_alias: 3,
        create_agent: 3,
        start_agent: 3,
        stop_agent: 3
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(function)(unquote_splicing(args)) do
      send(self(), {:operator_request, unquote(function), unquote(args)})
      Process.get(:operator_reply, {:error, :not_found})
    end
  end

  def start_login(_, _), do: raise("operator mode must never use human login")
end

defmodule ArborBreeze.CLIOperatorTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias ArborBreeze.CLI
  alias ArborBreeze.CLITest.ClientProbe

  test "explicit signed commands have a closed bounded syntax and human chat remains exact target" do
    for argv <- [["agents"], ["stop", "agent_fixture"], ["new", "test"]],
        do: assert({:error, :signed_key_required} == CLI.parse(argv))

    assert {:error, :agent_required} = CLI.parse(["--agent", "cedar"])
    assert {:ok, opts} = CLI.parse(["--agent", "cedar", "--key", "/private/key"])
    assert opts[:operation] == :chat

    for argv <- [
          nil,
          [<<255>>],
          [String.duplicate("x", 2_049)],
          ["agents", "--key", "k", "--agent", "agent_fixture"],
          ["stop", "agent_fixture", "--key", "k", "--model", "sealed"],
          ["agents", "--key", "k", "--key", "other"],
          ["--agent", "agent_fixture", "--session-token", "secret"],
          ["destroy", "agent_fixture", "--key", "k"]
        ] do
      assert {:error, :invalid_options} = CLI.parse(argv)
    end
  end

  test "operator commands call only the explicit SDK API and never open a conversation" do
    cases = [
      {["agents"], :list_agents, %{agents: [], truncated: false}},
      {["resolve", "cedar"], :resolve_agent, "agent_fixture"},
      {["aliases"], :list_aliases, %{aliases: [], truncated: false}},
      {["alias", "cedar", "Cedar"], :set_alias, %{name: "cedar", agent_id: "agent_fixture"}},
      {["unalias", "cedar"], :remove_alias, %{name: "cedar", removed: true}},
      {["new", "test", "--name", "Cedar", "--model", "sealed"], :create_agent,
       %{display_name: "Cedar", agent_id: "agent_new", running: true}},
      {["start", "cedar"], :start_agent, %{agent_id: "agent_fixture", running: true}},
      {["stop", "cedar"], :stop_agent, %{agent_id: "agent_fixture", running: false}}
    ]

    for {argv, function, reply} <- cases do
      assert {:ok, opts} =
               CLI.parse(argv ++ ["--key", "/private/key", "--url", "http://127.0.0.1:4321"])

      Process.put(:operator_reply, {:ok, reply})

      output =
        capture_io(fn ->
          assert :ok =
                   CLI.run(opts, ClientProbe, fn _ -> flunk("operator command auto-attached") end)
        end)

      assert_received {:operator_load_key, "/private/key"}

      assert_received {:operator_request, ^function,
                       [%{agent_id: "agent_operator"}, "http://127.0.0.1:4321" | args]}

      case function do
        :create_agent ->
          assert args == [%{template: "test", name: "Cedar", model: "sealed"}]
          assert output =~ "No conversation was attached."

        op when op in [:start_agent, :stop_agent] ->
          assert output =~ "No conversation was attached."

        _ ->
          :ok
      end

      refute_received {:operator_request, _, _}
    end
  end

  test "literal catalog output neutralizes OSC and CSI without corrupting Unicode or hiding truncation" do
    assert {:ok, opts} = CLI.parse(["agents", "--key", "/private/key"])

    Process.put(
      :operator_reply,
      {:ok,
       %{
         agents: [
           %{
             agent_id: "agent_fixture",
             display_name: "雪\e]52;c;secret\a\e[2J",
             running: false,
             template: "test",
             model: "sealed"
           }
         ],
         truncated: true
       }}
    )

    output = capture_io(fn -> assert :ok = CLI.run(opts, ClientProbe) end)
    assert output =~ "雪\\u001B]52;c;secret\\u0007\\u001B[2J"
    refute output =~ "\e"
    assert output =~ "Listing truncated"
    refute output =~ "private/key"
  end

  test "uncertain and approval-required effects are returned once without automatic retry or attachment" do
    assert {:ok, opts} = CLI.parse(["new", "test", "--key", "/private/key"])

    for result <- [:management_unconfirmed, :approval_required, :unauthorized] do
      Process.put(:operator_reply, {:error, result})

      assert capture_io(fn ->
               assert {:error, ^result} =
                        CLI.run(opts, ClientProbe, fn _ -> flunk("attached") end)
             end) == ""

      assert_received {:operator_load_key, _}
      assert_received {:operator_request, :create_agent, _}
      refute_received {:operator_request, _, _}
    end

    assert CLI.error_message(:management_unconfirmed) =~ "No retry was sent."
    assert CLI.error_message(:approval_required) =~ "authenticated Console"
  end

  test "signed startup resolves the selected token before any private binding and refuses ambiguity" do
    assert {:ok, opts} = CLI.parse(["--agent", "cedar", "--key", "/private/key"])
    Process.put(:operator_reply, {:error, :ambiguous})

    assert {:error, :ambiguous} =
             CLI.run(opts, ClientProbe, fn _ -> flunk("opened before exact resolution") end)

    assert_received {:operator_load_key, _}
    assert_received {:operator_request, :resolve_agent, [_, "http://127.0.0.1:4000", "cedar"]}
    refute_received {:operator_request, _, _}

    assert {:error, :invalid_options} =
             CLI.run(Keyword.put(opts, :session_token, "secret"), ClientProbe)
  end
end
