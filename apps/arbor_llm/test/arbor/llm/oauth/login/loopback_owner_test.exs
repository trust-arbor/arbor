defmodule Arbor.LLM.OAuth.Login.LoopbackOwnerTest do
  use ExUnit.Case, async: false

  @moduletag :security_regression

  alias Arbor.Contracts.LLM.OAuthHealth
  alias Arbor.LLM.OAuth
  alias Arbor.LLM.OAuth.Login.LoopbackFlow
  alias Arbor.LLM.OAuth.Login.LoopbackOwner
  alias Arbor.LLM.OAuth.Login.LoopbackPrompt
  alias Arbor.LLM.OAuth.Login.PendingStore

  @port 1457

  setup do
    stop_all_flows()

    prior_store_dir = Application.get_env(:arbor_llm, :oauth_store_dir)

    store_dir =
      Path.join(System.tmp_dir!(), "arbor-loopback-owner-#{System.unique_integer([:positive])}")

    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)
    pending_snapshot = :sys.get_state(PendingStore)

    on_exit(fn ->
      stop_all_flows()
      restore_env(:arbor_llm, :oauth_store_dir, prior_store_dir)
      File.rm_rf(store_dir)
      :sys.replace_state(PendingStore, fn _ -> pending_snapshot end)
    end)

    :ok
  end

  test "denied callback after a successful start yields access_denied, not timeout" do
    assert {:ok, %LoopbackPrompt{} = prompt} =
             Arbor.LLM.start_openai_loopback_login(redirect_uri: :port_1457)

    flow_id = LoopbackFlow.id(LoopbackPrompt.flow(prompt))
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")

    assert :failure =
             LoopbackOwner.callback(flow_id, {:provider_error, :access_denied, state})

    assert {:error, {:access_denied, _reason}} =
             Arbor.LLM.await_openai_loopback_login(prompt, timeout_ms: 1_000)
  end

  test "unrelated route health becoming ready does not make await return success" do
    assert {:ok, prompt} = Arbor.LLM.start_openai_loopback_login(redirect_uri: :port_1457)

    access = jwt_access(System.system_time(:second) + 3_600)

    {:ok, credential} =
      OAuth.AcquiredCredential.new(%{
        provider: :openai,
        account_id: "acct_unrelated_ready",
        access_token: access,
        refresh_token: "rt-unrelated-ready"
      })

    assert :ok = OAuth.publish_arbor_owned(:openai_oauth, credential)
    assert {:ok, %OAuthHealth{status: "ready"}} = Arbor.LLM.oauth_health(:openai_oauth)

    assert {:error, :timeout} =
             Arbor.LLM.await_openai_loopback_login(prompt, timeout_ms: 300)
  end

  test "a second start while one is active returns loopback_busy with that flow's id" do
    assert {:ok, prompt} = Arbor.LLM.start_openai_loopback_login(redirect_uri: :port_1457)
    flow = LoopbackPrompt.flow(prompt)

    assert {:error, {:loopback_busy, ^flow}} =
             Arbor.LLM.start_openai_loopback_login(redirect_uri: :port_1457)

    assert inspect(flow) == "#Arbor.LLM.OAuth.Login.LoopbackFlow<redacted>"
  end

  test "await accepts the opaque flow handle as well as the prompt" do
    assert {:ok, prompt} = Arbor.LLM.start_openai_loopback_login(redirect_uri: :port_1457)
    flow = LoopbackPrompt.flow(prompt)
    flow_id = LoopbackFlow.id(flow)
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")

    assert :failure =
             LoopbackOwner.callback(flow_id, {:provider_error, :login_required, state})

    assert {:error, {:callback_failed, :login_required}} =
             Arbor.LLM.await_openai_loopback_login(flow, timeout_ms: 1_000)
  end

  defp query_value(url, key) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!(key)
  end

  defp jwt_access(exp) when is_integer(exp) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"exp" => exp}), padding: false)
    "#{header}.#{payload}.sig"
  end

  defp stop_all_flows do
    case Process.whereis(Arbor.LLM.OAuth.Login.LoopbackSupervisor) do
      nil ->
        :ok

      supervisor ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor) do
          DynamicSupervisor.terminate_child(supervisor, pid)
        end
    end

    wait_until(fn ->
      case :gen_tcp.listen(@port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
        {:ok, socket} ->
          :ok = :gen_tcp.close(socket)
          true

        {:error, _reason} ->
          false
      end
    end)
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp restore_env(_app, _key, nil), do: Application.delete_env(:arbor_llm, :oauth_store_dir)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
