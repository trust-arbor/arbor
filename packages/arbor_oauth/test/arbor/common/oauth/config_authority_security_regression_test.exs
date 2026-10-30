defmodule Arbor.Common.OAuth.ConfigAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.{Request, Response}

  @moduletag :fast

  defmodule PackageClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(%Request{}), do: {:ok, %Response{status: 200, body: "package"}}
  end

  defmodule LegacyClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(%Request{}) do
      Process.put(:legacy_oauth_dispatch, true)
      {:ok, %Response{status: 200, body: "legacy"}}
    end
  end

  setup do
    previous =
      for {app, key} <- [{:arbor_oauth, :http_client}, {:arbor_kernel, :common}] do
        {app, key, Application.fetch_env(app, key)}
      end

    Application.delete_env(:arbor_oauth, :http_client)
    Process.delete(:legacy_oauth_dispatch)

    on_exit(fn ->
      for {app, key, value} <- previous do
        case value do
          {:ok, prior} -> Application.put_env(app, key, prior)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    :ok
  end

  test "security regression: package transport configuration wins over legacy Common settings" do
    Application.put_env(:arbor_oauth, :http_client, PackageClient)
    Application.put_env(:arbor_kernel, :common, oauth_http_client: LegacyClient)

    assert {:ok, %Response{body: "package"}} = HttpClient.request(request())
    refute Process.get(:legacy_oauth_dispatch)
  end

  test "security regression: invalid explicit package providers never fall back to legacy transport" do
    Application.put_env(:arbor_kernel, :common, oauth_http_client: LegacyClient)

    for invalid <- [nil, false, self(), :missing_oauth_transport] do
      Application.put_env(:arbor_oauth, :http_client, invalid)

      assert {:error, {:invalid_request, :invalid_http_client}} = HttpClient.request(request())
      refute Process.get(:legacy_oauth_dispatch)
    end
  end

  test "legacy configured adapters retain their public behavior when no package override is present" do
    for config <- [[oauth_http_client: LegacyClient], %{oauth_http_client: LegacyClient}] do
      Application.put_env(:arbor_kernel, :common, config)
      assert {:ok, %Response{body: "legacy"}} = HttpClient.request(request())
    end
  end

  test "an explicit package setting is independent of an unrelated malformed Common namespace" do
    Application.put_env(:arbor_oauth, :http_client, PackageClient)
    Application.put_env(:arbor_kernel, :common, :malformed)
    assert {:ok, %Response{body: "package"}} = HttpClient.request(request())
  end

  test "per-call providers take precedence while nil resolves the configured package provider" do
    Application.put_env(:arbor_oauth, :http_client, PackageClient)
    Application.put_env(:arbor_kernel, :common, oauth_http_client: LegacyClient)

    assert {:ok, %Response{body: "legacy"}} =
             HttpClient.request(request(), http_client: LegacyClient)

    assert {:ok, %Response{body: "package"}} = HttpClient.request(request(), http_client: nil)
  end

  test "existing public protocol modules and struct identities belong to the passive package" do
    assert Application.load(:arbor_oauth) in [:ok, {:error, {:already_loaded, :arbor_oauth}}]
    assert {:ok, :arbor_oauth} = :application.get_application(HttpClient)
    assert {:ok, :arbor_oauth} = :application.get_application(Request)
    assert {:ok, :arbor_oauth} = :application.get_application(Response)
    assert Application.spec(:arbor_oauth, :mod) in [nil, []]
  end

  defp request do
    %Request{
      method: :get,
      url: "https://issuer.example/token",
      max_response_bytes: 1_024,
      timeout_ms: 1_000
    }
  end
end
