defmodule Mix.Tasks.Arbor.LoginTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.LLM.OAuthHealth
  alias Arbor.LLM.OAuth.Login.AuthorizationPrompt
  alias Arbor.LLM.OAuth.Login.DevicePrompt
  alias Arbor.LLM.OAuth.Login.LoopbackFlow
  alias Arbor.LLM.OAuth.Login.LoopbackPrompt
  alias Mix.Tasks.Arbor.Login

  @authorize_url "https://auth.openai.example/authorize?client_id=x&state=s"
  @device_url "https://accounts.x.ai/device"
  @device_code "WXYZ-1234"

  test "mix help arbor.login documents commands and flags" do
    assert {:docs_v1, _, :elixir, _, %{"en" => doc}, _, _} = Code.fetch_docs(Login)
    assert doc =~ "openai"
    assert doc =~ "xai"
    assert doc =~ "status"
    assert doc =~ "--manual"
    assert doc =~ "--no-browser"
    assert doc =~ "--timeout"
  end

  test "task source calls only the public Arbor.LLM facade" do
    src =
      File.read!(Path.expand("../../../../lib/mix/tasks/arbor.login.ex", __DIR__))

    refute src =~ "LoopbackOwner"
    refute src =~ "PendingStore"
    refute src =~ "Arbor.LLM.OAuth.Login.start"
    refute src =~ "Arbor.LLM.OAuth.Login.complete"
    refute src =~ "Arbor.LLM.OAuth.Login.await"
    assert src =~ "LLM.start_openai_loopback_login"
    assert src =~ "LLM.await_openai_loopback_login"
    assert function_exported?(Mix.Tasks.Arbor.Oauth.Login, :run, 1)
  end

  test "openai emits the authorize URL before the blocking await" do
    events = start_events()

    task =
      Task.async(fn ->
        Login.execute(
          ["openai"],
          output: record(events, :out),
          opener: fn url -> record_event(events, {:open, url}) end,
          start_openai_loopback: fn _opts ->
            record_event(events, :start)
            {:ok, loopback_prompt()}
          end,
          await_openai_loopback: held_await(events)
        )
      end)

    assert_receive {:held, pid}

    assert event_list(events) == [
             :start,
             {:out, openai_instructions()},
             {:open, @authorize_url},
             :await
           ]

    refute match?({:ok, _}, Task.yield(task, 30))
    send(pid, :release)
    assert {:ok, {:error, :timeout}} = Task.yield(task, 1_000)
  end

  test "openai --no-browser emits the authorize URL before await and does not open" do
    events = start_events()

    task =
      Task.async(fn ->
        Login.execute(
          ["openai", "--no-browser"],
          output: record(events, :out),
          opener: fn _url -> flunk("opener must not run for --no-browser") end,
          start_openai_loopback: fn _opts ->
            record_event(events, :start)
            {:ok, loopback_prompt()}
          end,
          await_openai_loopback: held_await(events)
        )
      end)

    assert_receive {:held, pid}
    assert event_list(events) == [:start, {:out, openai_instructions()}, :await]
    send(pid, :release)
    assert {:ok, {:error, :timeout}} = Task.yield(task, 1_000)
  end

  test "openai --manual emits the authorize URL before the callback prompt" do
    events = start_events()

    result =
      Login.execute(
        ["openai", "--manual", "--no-browser"],
        output: record(events, :out),
        opener: fn _url -> flunk("opener must not run for --no-browser") end,
        start_openai: fn _opts ->
          record_event(events, :start)
          {:ok, manual_prompt()}
        end,
        prompt: fn message ->
          record_event(events, {:prompt, message})
          "http://localhost:1455/auth/callback?code=pasted-code&state=pasted-state&x=1#frag"
        end,
        complete_openai: fn handle, code, state ->
          record_event(events, {:complete, handle, code, state})
          :ok
        end,
        oauth_health: fn route ->
          record_event(events, {:health, route})
          {:ok, health_fixture("openai_oauth")}
        end
      )

    assert result == :ok

    assert event_list(events) == [
             :start,
             {:out, openai_instructions()},
             {:prompt, "Paste the redirected callback URL: "},
             {:complete, "manual-handle", "pasted-code", "pasted-state"},
             {:health, :openai_oauth},
             {:out, Arbor.LLM.LoginCliCore.format_health(health_fixture("openai_oauth"))}
           ]
  end

  test "xai emits the device URL and code before the blocking complete" do
    events = start_events()

    task =
      Task.async(fn ->
        Login.execute(
          ["xai"],
          output: record(events, :out),
          start_xai: fn ->
            record_event(events, :start)
            {:ok, device_prompt()}
          end,
          complete_xai: held_complete(events),
          oauth_health: fn :xai_oauth -> {:ok, health_fixture("xai_oauth")} end
        )
      end)

    assert_receive {:held, pid}

    assert event_list(events) == [
             :start,
             {:out, "Open #{@device_url}?code=#{@device_code} and enter code: #{@device_code}"},
             :complete
           ]

    refute match?({:ok, _}, Task.yield(task, 30))
    send(pid, :release)
    assert {:ok, :ok} = Task.yield(task, 1_000)
  end

  test "an opener that raises or is absent does not abort the login" do
    for opener <- [
          fn _url -> raise "xdg-open missing" end,
          fn _url -> {:error, :opener_missing} end
        ] do
      events = start_events()
      logs = start_events()

      task =
        Task.async(fn ->
          Login.execute(
            ["openai"],
            output: record(events, :out),
            log: record(logs, :log),
            opener: opener,
            start_openai_loopback: fn _opts -> {:ok, loopback_prompt()} end,
            await_openai_loopback: held_await(events)
          )
        end)

      assert_receive {:held, pid}
      assert {:out, instructions} = Enum.at(event_list(events), 0)
      assert instructions =~ @authorize_url
      assert :await in event_list(events)
      assert [_log] = event_list(logs)
      send(pid, :release)
      assert {:ok, {:error, :timeout}} = Task.yield(task, 1_000)
    end
  end

  test "status emits every route's oauth_health" do
    events = start_events()

    assert :ok =
             Login.execute(
               ["status"],
               output: record(events, :out),
               oauth_health: fn
                 "openai_oauth" -> {:ok, health_fixture("openai_oauth")}
                 "xai_oauth" -> {:ok, health_fixture("xai_oauth")}
               end
             )

    output = events |> event_list() |> Enum.map_join("\n", fn {:out, line} -> line end)
    assert output =~ "openai_oauth status=ready"
    assert output =~ "xai_oauth status=ready"
  end

  defp start_events, do: Agent.start_link(fn -> [] end) |> elem(1)

  defp record(agent, tag) do
    fn value -> record_event(agent, {tag, value}) end
  end

  defp record_event(agent, event) do
    Agent.update(agent, &(&1 ++ [event]))
    event
  end

  defp event_list(agent), do: Agent.get(agent, & &1)

  defp held_await(events) do
    parent = self()

    fn _prompt, _opts ->
      record_event(events, :await)
      send(parent, {:held, self()})

      receive do
        :release -> {:error, :timeout}
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  defp held_complete(events) do
    parent = self()

    fn _handle ->
      record_event(events, :complete)
      send(parent, {:held, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp loopback_prompt do
    %LoopbackPrompt{
      authorize_url: @authorize_url,
      flow: LoopbackFlow.new(make_ref())
    }
  end

  defp manual_prompt do
    %AuthorizationPrompt{authorize_url: @authorize_url, handle: "manual-handle"}
  end

  defp device_prompt do
    %DevicePrompt{
      user_code: @device_code,
      verification_uri: @device_url,
      verification_uri_complete: "#{@device_url}?code=#{@device_code}",
      handle: "xai-handle"
    }
  end

  defp openai_instructions do
    Arbor.LLM.LoginCliCore.format_openai_instructions(@authorize_url)
  end

  defp health_fixture("openai_oauth") do
    {:ok, health} =
      OAuthHealth.new(%{
        route: "openai_oauth",
        backend: "openai",
        status: "ready",
        owner: "arbor_owned",
        origin: "arbor_login",
        source: "arbor_oauth_store"
      })

    health
  end

  defp health_fixture("xai_oauth") do
    {:ok, health} =
      OAuthHealth.new(%{
        route: "xai_oauth",
        backend: "xai",
        status: "ready",
        owner: "arbor_owned",
        origin: "arbor_login",
        source: "arbor_oauth_store"
      })

    health
  end
end
