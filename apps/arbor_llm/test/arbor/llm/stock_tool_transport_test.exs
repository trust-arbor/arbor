defmodule Arbor.LLM.StockToolTransportTest do
  use ExUnit.Case, async: false
  alias Arbor.LLM
  alias Arbor.LLM.{Client, Plugs}
  @moduletag :fast

  # Only identity-contract tests use this stub. Agent journey tests use real Ecto.
  defmodule DurableIdentityFixture do
    def durability_class(_), do: :node_restart
  end

  setup do
    env = [
      {:arbor_llm, :tool_invocation_auditor},
      {:arbor_llm, :pipeline},
      {:arbor_llm, :rate_limit_backoff_dispatch_fn},
      {:arbor_llm, Plugs.RateLimitBackoff},
      {:arbor_security, :invocation_audit_mode},
      {:arbor_security, :invocation_audit_sink},
      {:arbor_historian, :durable_event_log_target},
      {:arbor_orchestrator, :lm_studio}
    ]

    prior = Map.new(env, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)
    old_client = Client.default_client()
    Application.put_env(:arbor_llm, :tool_invocation_auditor, Arbor.Security)
    Application.delete_env(:arbor_llm, :pipeline)
    Application.delete_env(:arbor_llm, :rate_limit_backoff_dispatch_fn)
    Application.delete_env(:arbor_llm, Plugs.RateLimitBackoff)
    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_security, :invocation_audit_sink, Arbor.Historian)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: :identity_fixture,
      backend: DurableIdentityFixture,
      opts: []
    })

    Application.put_env(:arbor_orchestrator, :lm_studio, base_url: "http://127.0.0.1:1234/v1")
    Client.set_default_client(Client.new(adapters: %{"lm_studio" => LLM.Adapter.ReqLLM}))

    on_exit(fn ->
      Client.set_default_client(old_client)

      Enum.each(prior, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "stock identity binds actual pipeline, auditor and options without disclosing URL secrets" do
    assert {:ok, first} = LLM.stock_tool_transport_identity("lmstudio")
    assert first["local_endpoint"]
    assert first["auditor"] == "Elixir.Arbor.Security"
    assert first["audit_mode"] == "required"
    assert Enum.all?(first["implementation"], &(byte_size(&1["loaded_md5"]) == 32))
    Application.put_env(:arbor_llm, Plugs.RateLimitBackoff, max_retries: 1)
    assert {:ok, changed} = LLM.stock_tool_transport_identity("lmstudio")
    refute changed["runtime_options_digest"] == first["runtime_options_digest"]

    Application.put_env(:arbor_orchestrator, :lm_studio,
      base_url: "http://user:secret@127.0.0.1:1234/v1?key=secret"
    )

    assert {:ok, redacted} = LLM.stock_tool_transport_identity("lmstudio")
    refute redacted["local_endpoint"]
    refute Jason.encode!(redacted) =~ "secret"
  end

  test "custom adapter, middleware and reordered pipeline cannot qualify as stock" do
    Client.set_default_client(Client.new(adapters: %{"lm_studio" => __MODULE__}))
    assert {:error, _} = LLM.stock_tool_transport_identity("lmstudio")
    Client.set_default_client(Client.new(middleware: [fn _, _ -> {:ok, :fake} end]))
    assert {:error, _} = LLM.stock_tool_transport_identity("lmstudio")
    Client.set_default_client(Client.new(adapters: %{"lm_studio" => LLM.Adapter.ReqLLM}))
    Application.put_env(:arbor_llm, :pipeline, [Plugs.Dispatch, Plugs.ResponseLimit])
    assert {:error, _} = LLM.stock_tool_transport_identity("lmstudio")
  end

  test "disabled or substituted auditor and executable retry callback fail closed" do
    for auditor <- [:disabled, __MODULE__] do
      Application.put_env(:arbor_llm, :tool_invocation_auditor, auditor)
      assert {:error, _} = LLM.stock_tool_transport_identity("lmstudio")
    end

    Application.put_env(:arbor_llm, :tool_invocation_auditor, Arbor.Security)
    Application.put_env(:arbor_security, :invocation_audit_mode, :disabled)
    assert {:error, _} = LLM.stock_tool_transport_identity("lmstudio")
    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_llm, :rate_limit_backoff_dispatch_fn, fn call -> call end)
    assert {:error, _} = LLM.stock_tool_transport_identity("lmstudio")
  end
end
