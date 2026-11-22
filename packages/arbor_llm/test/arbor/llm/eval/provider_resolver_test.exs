defmodule Arbor.LLM.Eval.ProviderResolverTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM
  alias Arbor.LLM.Adapter.OAuthResponses

  setup do
    previous = Application.fetch_env(:arbor_llm, :oauth_store_dir)

    store_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor-eval-provider-resolver-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :oauth_store_dir, value)
        :error -> Application.delete_env(:arbor_llm, :oauth_store_dir)
      end

      File.rm_rf!(store_dir)
    end)

    {:ok, store_dir: store_dir}
  end

  test "resolves a ready exact OAuth route without the API-key catalog", %{
    store_dir: store_dir
  } do
    write_ready_credential!(store_dir, "openai")

    assert {:ok,
            %{
              provider: "openai_oauth",
              source: :oauth,
              adapter_module: OAuthResponses
            }} = LLM.resolve_eval_transport("openai_oauth")

    assert :ok = LLM.preflight_eval_provider("openai_oauth")
  end

  test "security regression: a non-ready OAuth route fails before eval transport" do
    expected =
      {:error, {:eval_provider_unavailable, "xai_oauth", {:oauth_status, "login_required"}}}

    assert LLM.resolve_eval_transport("xai_oauth") == expected
    assert LLM.preflight_eval_provider("xai_oauth") == expected
  end

  test "ordinary API providers still resolve through the provider catalog" do
    assert {:ok,
            %{
              provider: "anthropic",
              source: :catalog,
              adapter_module: Arbor.LLM.Adapter.ReqLLM
            }} = LLM.resolve_eval_transport("anthropic")
  end

  test "unknown providers include both catalog and exact OAuth route names" do
    assert {:error, {:unknown_eval_provider, "definitely_unknown", known}} =
             LLM.resolve_eval_transport("definitely_unknown")

    assert "openai_oauth" in known
    assert "xai_oauth" in known
  end

  test "preflight options are closed and typed" do
    assert LLM.preflight_eval_provider("openai_oauth", refresh: true) ==
             {:error, {:invalid_eval_provider_options, :unsupported}}

    assert LLM.preflight_eval_provider("openai_oauth", force_refresh: "yes") ==
             {:error, {:invalid_eval_provider_options, :boolean_required}}
  end

  defp write_ready_credential!(store_dir, provider) do
    account_id = if provider == "openai", do: "acct-eval-test", else: nil

    envelope = %{
      "version" => 1,
      "provider" => provider,
      "account_id" => account_id,
      "origin" => "arbor_login",
      "owner" => "arbor_owned",
      "source" => "arbor_oauth_store",
      "generation" => 0,
      "tokens" => %{
        "access_token" => jwt_access(System.system_time(:second) + 3_600),
        "refresh_token" => "refresh-eval-test"
      }
    }

    path = Path.join(store_dir, "#{provider}.json")
    File.write!(path, Jason.encode!(envelope))
    File.chmod!(path, 0o600)
  end

  defp jwt_access(exp) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"exp" => exp}), padding: false)
    "#{header}.#{payload}.sig"
  end
end
