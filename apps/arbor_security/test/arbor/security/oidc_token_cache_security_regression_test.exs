defmodule Arbor.Security.OIDCTokenCacheSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-008"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Security.OIDC
  alias Arbor.Security.OIDC.TokenCacheOwner
  alias Arbor.Security.SupervisedOwner

  setup do
    previous_oidc = Application.get_env(:arbor_security, :oidc)
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    cache_path = Path.join(system_tmp, "arbor-retired-oidc-cache-#{token}.enc")

    Application.put_env(:arbor_security, :oidc, token_cache_path: cache_path)

    on_exit(fn ->
      File.rm(cache_path)

      if previous_oidc,
        do: Application.put_env(:arbor_security, :oidc, previous_oidc),
        else: Application.delete_env(:arbor_security, :oidc)
    end)

    {:ok, cache_path: cache_path}
  end

  @tag spec: "SSEC-008"
  test "security regression: public token-cache APIs neither persist nor disclose bearer tokens",
       %{cache_path: cache_path} do
    token_response = %{
      "id_token" => "secret-id-token",
      "access_token" => "secret-access-token",
      "refresh_token" => "secret-refresh-token"
    }

    claims = %{"sub" => "operator", "exp" => System.os_time(:second) + 3_600}

    assert {:error, :oidc_token_cache_unauthorized} =
             OIDC.cache_token(token_response, claims)

    refute File.exists?(cache_path)

    assert {:error, :oidc_token_cache_unauthorized} = OIDC.load_cached_token()
  end

  test "security regression: raw gen_call cannot read or replace the OIDC token cache",
       %{cache_path: cache_path} do
    owner =
      SupervisedOwner.registered_child(
        TokenCacheOwner,
        :arbor_security,
        [TokenCacheOwner]
      )

    assert is_pid(owner)

    assert {:error, :oidc_token_cache_unauthorized} =
             forged_call(owner, :load)

    assert {:error, :oidc_token_cache_unauthorized} =
             forged_call(
               owner,
               {:store,
                %{
                  "id_token" => "attacker-id-token",
                  "access_token" => "attacker-access-token",
                  "refresh_token" => "attacker-refresh-token"
                }, %{"sub" => "attacker"}}
             )

    refute File.exists?(cache_path)
  end

  defp forged_call(owner, request) do
    reply_alias = :erlang.alias()
    tag = [:alias | reply_alias]
    send(owner, {:"$gen_call", {self(), tag}, request})

    try do
      receive do
        {^tag, reply} -> reply
      after
        2_000 -> flunk("forged token-cache call did not settle")
      end
    after
      :erlang.unalias(reply_alias)
    end
  end
end
