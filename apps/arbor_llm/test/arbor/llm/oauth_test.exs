defmodule Arbor.LLM.OAuthTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.{Client, Message, OAuth, Request}
  alias Arbor.Contracts.LLM.OAuthHealth

  @env_keys [
    :oauth_store_dir,
    :oauth_refresh_fun,
    :oauth_cli_files,
    :oauth_source_files,
    :oauth_rename_fun,
    :oauth_fsync_dir_fun
  ]

  setup do
    prior =
      Map.new(@env_keys, fn key ->
        {key, Application.get_env(:arbor_llm, key, :__unset__)}
      end)

    store_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor-oauth-test-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.rm_rf!(store_dir)
    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)
    Application.delete_env(:arbor_llm, :oauth_refresh_fun)
    Application.delete_env(:arbor_llm, :oauth_cli_files)
    Application.delete_env(:arbor_llm, :oauth_source_files)
    Application.delete_env(:arbor_llm, :oauth_rename_fun)
    Application.delete_env(:arbor_llm, :oauth_fsync_dir_fun)

    on_exit(fn ->
      Enum.each(prior, fn
        {key, :__unset__} -> Application.delete_env(:arbor_llm, key)
        {key, value} -> Application.put_env(:arbor_llm, key, value)
      end)

      File.rm_rf(store_dir)
    end)

    {:ok, store_dir: store_dir}
  end

  describe "Anthropic guardrail (security regression — never wire a Claude subscription, ToS)" do
    test "refuses every anthropic/claude-family provider spelling BEFORE any token read" do
      for p <- [
            :anthropic,
            :claude,
            :"claude-code",
            :claude_code,
            "claude",
            "anthropic",
            "Claude",
            "CLAUDE-CODE",
            "anthropic/claude-opus-4"
          ] do
        assert {:error, :anthropic_oauth_forbidden} = OAuth.access_token(p),
               "expected #{inspect(p)} to be refused"

        assert OAuth.account_id(p) == nil
        refute OAuth.available?(p)
      end
    end

    test "security regression: Anthropic refusal runs before store/refresh seams are invoked",
         %{store_dir: store_dir} do
      parent = self()

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn key, _config, _rt ->
        send(parent, {:refresh_invoked, key})
        flunk("oauth_refresh_fun must not run for Anthropic")
      end)

      # Point CLI paths at a missing path under the hermetic store so a mistaken
      # file read cannot touch ~/.codex / ~/.grok / ~/.arbor.
      Application.put_env(:arbor_llm, :oauth_cli_files, %{
        openai: Path.join(store_dir, "must-not-read-openai.json"),
        xai: Path.join(store_dir, "must-not-read-xai.json")
      })

      assert {:error, :anthropic_oauth_forbidden} = OAuth.access_token(:anthropic)
      assert {:error, :anthropic_oauth_forbidden} = OAuth.access_token("claude-code")
      refute_received {:refresh_invoked, _}
      refute File.exists?(Path.join(store_dir, "must-not-read-openai.json"))
      refute File.exists?(Path.join(store_dir, "anthropic.json"))
    end
  end

  describe "provider resolution" do
    test "unknown providers error cleanly (no crash)" do
      # :mistral/:cohere aren't OAuth providers → resolve fails BEFORE any file read/refresh.
      assert {:error, {:no_oauth_provider, _}} = OAuth.access_token(:mistral)
      assert {:error, {:no_oauth_provider, _}} = OAuth.access_token("cohere")
    end

    # NOTE: we deliberately do NOT call access_token(:xai)/(:grok) against real credentials —
    # tests use hermetic store + refresh seams only and never touch ~/.codex, ~/.grok, or
    # ~/.arbor/oauth.
  end

  describe "OAuth route exactness and health contract (security regression)" do
    test "security regression: route accepts exact IDs and rejects aliases",
         %{store_dir: _store_dir} do
      assert {:ok, %{route: :openai_oauth, backend: :openai}} = OAuth.route(:openai_oauth)
      assert {:ok, %{route: :xai_oauth, backend: :xai}} = OAuth.route(:xai_oauth)
      assert {:ok, %{route: nil, backend: :openai}} = OAuth.route("openai")
      assert {:ok, %{route: nil, backend: :xai}} = OAuth.route("xai")
      assert {:error, {:unknown_oauth_route, "grok"}} = OAuth.route("grok")
      assert {:error, :anthropic_oauth_forbidden} = OAuth.route("anthropic")

      assert {:ok, %{route: :openai_oauth, backend: :openai}} = OAuth.route_only(:openai_oauth)
      assert {:ok, %{route: :xai_oauth, backend: :xai}} = OAuth.route_only(:xai_oauth)
      assert {:error, {:unknown_oauth_route, "xai"}} = OAuth.route_only("xai")
      assert {:error, {:unknown_oauth_route, "grok"}} = OAuth.route_only("grok")
      assert {:error, :anthropic_oauth_forbidden} = OAuth.route_only(:claude)
    end

    test "security regression: adapter rejects non-route aliases before credential or request I/O",
         %{
           store_dir: store_dir
         } do
      request = %Request{
        provider: "grok",
        model: "grok-4.5",
        messages: [Message.new(:user, "no-route")]
      }

      File.write!(Path.join(store_dir, "openai.json"), "{")
      File.write!(Path.join(store_dir, "xai.json"), "{")

      assert {:error, {:unknown_oauth_route, "grok"}} =
               Arbor.LLM.Adapter.OAuthResponses.complete(request, receive_timeout: 200)
    end

    test "security regression: oauth_health returns bounded local statuses for exact routes only",
         %{
           store_dir: store_dir
         } do
      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
        flunk("oauth_health must not refresh credentials")
      end)

      assert {:ok, %OAuthHealth{status: "login_required", owner: nil}} =
               OAuth.health(:openai_oauth)

      assert {:ok, %OAuthHealth{status: "login_required", owner: nil}} =
               Arbor.LLM.oauth_health(:openai_oauth)

      assert {:error, {:unknown_oauth_route, "openai"}} = OAuth.health(:openai)

      write_store!(
        store_dir,
        :openai,
        %{
          "access_token" => jwt_access(System.system_time(:second) + 3_600),
          "refresh_token" => "rt-openai",
          "account_id" => "acct_openai"
        }
      )

      assert {:ok,
              %OAuthHealth{route: "openai_oauth", backend: "openai", status: "ready"} = health} =
               OAuth.health(:openai_oauth)

      assert health.owner == "arbor_owned"
      assert health.source == "arbor_oauth_store"

      map = OAuthHealth.to_map(health)
      assert map["route"] == "openai_oauth"
      assert map["backend"] == "openai"
      refute Map.has_key?(map, "account_id")
      assert byte_size(inspect(map)) < 1_024

      root = store_dir
      source_path = Path.join(root, "codex-auth.json")
      write_codex_source!(source_path, "source-access", "source-refresh")
      write_envelope!(store_dir, :openai, source_envelope(:openai, "acct_source"))
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})

      assert {:ok,
              %OAuthHealth{route: "openai_oauth", status: "ready", owner: "source_owned"} =
                source_health} =
               OAuth.health(:openai_oauth)

      assert source_health.source == "codex_file"
      assert source_health.origin == "external_cli"
      assert source_health.owner == "source_owned"
      refute Map.has_key?(source_health, :account_id)
      refute inspect(source_health) =~ "source-access"

      expired_source_path = Path.join(root, "expired-codex-auth.json")

      write_codex_source!(
        expired_source_path,
        jwt_access(System.system_time(:second) - 10),
        "ignored"
      )

      write_envelope!(store_dir, :openai, source_envelope(:openai, "acct_source"))
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: expired_source_path})

      assert {:ok, %OAuthHealth{status: "expired", owner: "source_owned"}} =
               OAuth.health(:openai_oauth)

      write_envelope!(
        store_dir,
        :xai,
        source_envelope(:xai, nil)
      )

      assert {:ok,
              %OAuthHealth{
                route: "xai_oauth",
                status: "source_unsupported",
                owner: "source_owned"
              }} =
               OAuth.health(:xai_oauth)
    end
  end

  describe "credential ownership enforcement" do
    test "security regression: legacy ownerless store is refused and preserved byte-for-byte",
         %{store_dir: store_dir} do
      path = Path.join(store_dir, "openai.json")

      legacy_bytes =
        Jason.encode!(%{
          "access_token" => jwt_access(System.system_time(:second) + 3_600),
          "refresh_token" => "legacy-refresh-secret",
          "account_id" => "acct_legacy"
        })

      File.write!(path, legacy_bytes)

      assert {:error, :oauth_credential_migration_required} = OAuth.access_token(:openai)
      refute OAuth.configured?(:openai)
      assert File.read!(path) == legacy_bytes
    end

    test "security regression: explicit OpenAI source ownership reads through without modifying source",
         %{store_dir: store_dir} do
      source_path = Path.join(store_dir, "codex-auth.json")
      source_bytes = write_codex_source!(source_path, "source-access", "source-refresh-secret")
      write_envelope!(store_dir, :openai, source_envelope(:openai, "acct_source"))
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
        flunk("source-owned mode must not touch a refresh token")
      end)

      assert {:ok, receipt} = OAuth.credential_receipt(:openai)
      assert receipt.access_token == "source-access"
      assert receipt.account_id == "acct_source"
      assert receipt.owner == "source_owned"
      refute inspect(receipt) =~ "source-access"
      refute inspect(receipt) =~ "source-refresh-secret"
      assert {:ok, "source-access"} = OAuth.access_token(:openai)
      assert OAuth.configured?(:openai)

      client =
        Arbor.LLM.Client.from_env(
          adapters: %{"dummy" => Arbor.LLM.Adapter.OAuthResponses},
          discover_local: false,
          discover_acp: false,
          discover_oauth: true
        )

      assert Map.has_key?(client.adapters, "openai_oauth")
      assert File.read!(source_path) == source_bytes
    end

    test "security regression: xAI source ownership remains explicitly unsupported",
         %{store_dir: store_dir} do
      path = write_envelope!(store_dir, :xai, source_envelope(:xai, nil))
      before = File.read!(path)

      assert {:error, :oauth_source_owned_unsupported} = OAuth.credential_receipt(:xai)
      assert {:error, :oauth_source_owned_unsupported} = OAuth.access_token(:xai)
      assert {:error, :oauth_source_owned_unsupported} = OAuth.provenance(:xai)
      refute OAuth.configured?(:xai)
      assert File.read!(path) == before
    end

    test "security regression: unchanged source reread does not produce a retry receipt",
         %{store_dir: store_dir} do
      source_path = Path.join(store_dir, "codex-auth.json")
      write_codex_source!(source_path, "same-access", "never-forward-refresh")
      write_envelope!(store_dir, :openai, source_envelope(:openai, "acct_source"))
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})

      assert {:ok, used} = OAuth.credential_receipt(:openai)
      assert {:error, :oauth_source_token_unchanged} = OAuth.reread_source_credential(used)

      write_codex_source!(source_path, "changed-access", "changed-refresh-never-forward")
      assert {:ok, latest} = OAuth.reread_source_credential(used)
      assert latest.access_token == "changed-access"
      refute inspect(latest) =~ "changed-access"
      refute inspect(latest) =~ "changed-refresh-never-forward"
    end

    test "security regression: source provenance is bounded and contains no token material",
         %{store_dir: store_dir} do
      source_path = Path.join(store_dir, "codex-auth.json")
      write_codex_source!(source_path, "provenance-access", "provenance-refresh")
      write_envelope!(store_dir, :openai, source_envelope(:openai, "acct_source", 17))
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})

      assert {:ok, provenance} = OAuth.provenance(:openai)
      public = Arbor.Contracts.LLM.AuthProvenance.to_map(provenance)
      rendered = inspect(public)

      assert public["owner"] == "source_owned"
      assert public["origin"] == "external_cli"
      assert public["source"] == "codex_file"
      assert public["generation"] == 17
      assert is_integer(public["source_generation"])
      assert is_binary(public["source_observed_at"])
      assert byte_size(rendered) < 1_024
      refute rendered =~ "provenance-access"
      refute rendered =~ "provenance-refresh"
      refute rendered =~ "token_hash"
    end

    test "security regression: source reads reject symlink, malformed, oversized, and mismatched files",
         %{store_dir: store_dir} do
      source_path = Path.join(store_dir, "codex-auth.json")
      write_envelope!(store_dir, :openai, source_envelope(:openai, "acct_source"))
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})

      target = Path.join(store_dir, "codex-target.json")
      write_codex_source!(target, "target-access", "target-refresh")
      File.ln_s!(target, source_path)
      assert {:error, :oauth_source_file_symlink} = OAuth.credential_receipt(:openai)
      refute OAuth.configured?(:openai)

      File.rm!(source_path)
      File.write!(source_path, "{")
      assert {:error, :oauth_source_credential_invalid} = OAuth.credential_receipt(:openai)

      File.write!(source_path, String.duplicate("x", 1_048_577))
      assert {:error, :oauth_source_file_oversized} = OAuth.credential_receipt(:openai)

      write_codex_source!(source_path, "other-access", "other-refresh", "acct_other")
      assert {:error, :oauth_source_credential_invalid} = OAuth.credential_receipt(:openai)
    end

    test "security regression: OAuth routes preserve credential errors without accepting raw stores",
         %{store_dir: store_dir} do
      File.write!(
        Path.join(store_dir, "openai.json"),
        Jason.encode!(%{"access_token" => "legacy", "refresh_token" => "legacy-secret"})
      )

      File.write!(
        Path.join(store_dir, "xai.json"),
        Jason.encode!(%{"access_token" => "legacy-xai", "refresh_token" => "legacy-xai-secret"})
      )

      cli_path = Path.join(store_dir, "cli-openai.json")
      File.write!(cli_path, Jason.encode!(%{"tokens" => %{"refresh_token" => "cli-secret"}}))
      Application.put_env(:arbor_llm, :oauth_cli_files, %{openai: cli_path})

      source_path = Path.join(store_dir, "codex-auth.json")
      source_bytes = write_codex_source!(source_path, "source-access", "source-refresh")
      Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})

      client =
        Arbor.LLM.Client.from_env(
          adapters: %{"dummy" => Arbor.LLM.Adapter.OAuthResponses},
          discover_local: false,
          discover_acp: false,
          discover_oauth: true
        )

      assert client.adapters["openai_oauth"] == Arbor.LLM.Adapter.OAuthResponses
      assert client.adapters["xai_oauth"] == Arbor.LLM.Adapter.OAuthResponses

      for {provider, model} <- [
            {"openai_oauth", "gpt-5.6-sol"},
            {"xai_oauth", "grok-4.5"}
          ] do
        request = %Request{
          provider: provider,
          model: model,
          messages: [Message.new(:user, "credential routing regression")]
        }

        assert {:error, :oauth_credential_migration_required} =
                 Client.complete(client, request)
      end

      refute OAuth.configured?(:openai)
      refute OAuth.configured?(:xai)
      assert File.read!(source_path) == source_bytes
    end

    test "security regression: public provenance is bounded and never contains tokens", %{
      store_dir: store_dir
    } do
      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) + 3_600),
        "refresh_token" => "private-refresh-token",
        "account_id" => "acct_public"
      })

      assert {:ok, provenance} = OAuth.provenance(:openai)
      public = Arbor.Contracts.LLM.AuthProvenance.to_map(provenance)
      rendered = inspect(public)

      assert public["provider"] == "openai"
      assert public["owner"] == "arbor_owned"
      refute rendered =~ "private-refresh-token"
      refute rendered =~ "access_token"
      refute rendered =~ "refresh_token"
      refute rendered =~ "token_hash"
    end
  end

  test "security regression: xAI discovery requires the exact trusted origin" do
    assert {:ok, "https://auth.x.ai/oauth/token"} =
             OAuth.trusted_xai_token_endpoint(%{
               "token_endpoint" => "https://auth.x.ai/oauth/token"
             })

    for endpoint <- [
          "https://attacker-x.ai/oauth/token",
          "https://x.ai.attacker.example/oauth/token",
          "http://auth.x.ai/oauth/token",
          "https://auth.x.ai.attacker.example/oauth/token"
        ] do
      assert {:error, :untrusted_token_endpoint} =
               OAuth.trusted_xai_token_endpoint(%{"token_endpoint" => endpoint})
    end
  end

  describe "refresh single-flight (security regression — rotating refresh integrity)" do
    test "N simultaneous callers cause exactly one refresh and all receive the same access token",
         %{store_dir: store_dir} do
      counter = :atomics.new(1, signed: false)
      fresh_access = jwt_access(System.system_time(:second) + 3_600)
      rotated_refresh = "rotated-refresh-token-#{System.unique_integer([:positive])}"

      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) - 10),
        "refresh_token" => "stale-refresh-token",
        "account_id" => "acct_test"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai,
                                                             _config,
                                                             "stale-refresh-token" ->
        :atomics.add(counter, 1, 1)
        Process.sleep(150)

        {:ok,
         %{
           "access_token" => fresh_access,
           "refresh_token" => rotated_refresh
         }}
      end)

      n = 8

      results =
        1..n
        |> Enum.map(fn _ ->
          Task.async(fn -> OAuth.access_token(:openai) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.all?(results, &(&1 == {:ok, fresh_access}))
      assert :atomics.get(counter, 1) == 1

      # Durable store holds the full rotated set and advances the owned generation.
      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["access_token"] == fresh_access
      assert stored["refresh_token"] == rotated_refresh
      assert stored["account_id"] == "acct_test"
      assert stored["generation"] == 1
    end

    test "provider locks do not unnecessarily serialize different providers", %{
      store_dir: store_dir
    } do
      # Deterministic rendezvous: each provider waits for the other to enter
      # refresh before either returns. Serialized locks would deadlock until
      # wait_until fails; independent locks complete with both observed concurrent.
      entered = :atomics.new(2, signed: false)
      concurrent_observed = :atomics.new(1, signed: false)
      parent = self()

      openai_access = jwt_access(System.system_time(:second) + 3_600)
      xai_access = jwt_access(System.system_time(:second) + 7_200)

      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) - 10),
        "refresh_token" => "openai-rt"
      })

      write_store!(store_dir, :xai, %{
        "access_token" => jwt_access(System.system_time(:second) - 10),
        "refresh_token" => "xai-rt"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn key, _config, _rt ->
        idx =
          case key do
            :openai -> 1
            :xai -> 2
          end

        :atomics.put(entered, idx, 1)
        send(parent, {:refresh_entered, key})

        # Both providers must be inside refresh simultaneously. If locks serialized
        # providers, the second never enters while the first waits → timeout.
        wait_until(
          fn -> :atomics.get(entered, 1) == 1 and :atomics.get(entered, 2) == 1 end,
          2_000
        )

        :atomics.put(concurrent_observed, 1, 1)

        access =
          case key do
            :openai -> openai_access
            :xai -> xai_access
          end

        {:ok, %{"access_token" => access, "refresh_token" => "#{key}-rotated"}}
      end)

      t1 = Task.async(fn -> OAuth.access_token(:openai) end)
      t2 = Task.async(fn -> OAuth.access_token(:xai) end)

      assert_receive {:refresh_entered, :openai}, 2_000
      assert_receive {:refresh_entered, :xai}, 2_000

      assert {:ok, ^openai_access} = Task.await(t1, 5_000)
      assert {:ok, ^xai_access} = Task.await(t2, 5_000)
      assert :atomics.get(concurrent_observed, 1) == 1
    end

    test "security regression: failed store reread under lock never reuses the stale refresh token",
         %{store_dir: store_dir} do
      refresh_calls = :atomics.new(1, signed: false)

      store_path =
        write_store!(store_dir, :openai, %{
          "access_token" => jwt_access(System.system_time(:second) - 10),
          "refresh_token" => "stale-rotating-token"
        })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
        :atomics.add(refresh_calls, 1, 1)
        {:ok, %{"access_token" => jwt_access(System.system_time(:second) + 3_600)}}
      end)

      lock_id = {{OAuth, :refresh, :openai}, self()}
      lock_nodes = [node() | Node.list()]
      assert true = :global.set_lock(lock_id, lock_nodes, 0)

      task = Task.async(fn -> OAuth.access_token(:openai) end)

      try do
        # The caller has read the stale store and is now blocked on the exact provider lock.
        wait_until(fn -> waiting_on_global_lock?(task.pid) end, 2_000)
        File.write!(store_path, "{")
      after
        :global.del_lock(lock_id, lock_nodes)
      end

      assert {:error, {:oauth_token_store_reread_failed, {:token_file_unreadable, _}}} =
               Task.await(task, 5_000)

      assert :atomics.get(refresh_calls, 1) == 0
    end
  end

  describe "atomic token store publication (security regression — credential-store integrity)" do
    test "persisted file is valid complete JSON with mode 0600", %{store_dir: store_dir} do
      access = jwt_access(System.system_time(:second) + 3_600)

      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) - 5),
        "refresh_token" => "rt-1"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai, _config, "rt-1" ->
        {:ok,
         %{
           "access_token" => access,
           "refresh_token" => "rt-2",
           "account_id" => "acct_mode"
         }}
      end)

      assert {:ok, ^access} = OAuth.access_token(:openai)

      path = Path.join(store_dir, "openai.json")
      assert File.exists?(path)
      {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600

      body = File.read!(path)
      assert {:ok, decoded} = Jason.decode(body)
      assert decoded["tokens"]["access_token"] == access
      assert decoded["tokens"]["refresh_token"] == "rt-2"
      assert decoded["account_id"] == "acct_test"
      assert decoded["generation"] == 1
      # No leftover temp files from successful publication (temps are dot-prefixed).
      assert list_temp_files(store_dir) == []
    end

    test "security regression: malformed refreshed access token does not replace durable store",
         %{store_dir: store_dir} do
      stale_access = jwt_access(System.system_time(:second) - 5)

      write_store!(store_dir, :openai, %{
        "access_token" => stale_access,
        "refresh_token" => "rt-keep",
        "account_id" => "acct_keep"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai, _config, "rt-keep" ->
        # Oversized access token must be rejected before durable publication.
        {:ok,
         %{
           "access_token" => String.duplicate("a", 65_537),
           "refresh_token" => "rt-should-not-replace"
         }}
      end)

      assert {:error, {:invalid_refreshed_access_token, :oversized}} =
               OAuth.access_token(:openai)

      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["access_token"] == stale_access
      assert stored["refresh_token"] == "rt-keep"
      assert stored["account_id"] == "acct_keep"
      assert list_temp_files(store_dir) == []
    end

    test "security regression: refresh responses cannot overwrite ownership metadata",
         %{store_dir: store_dir} do
      fresh_access = jwt_access(System.system_time(:second) + 3_600)

      write_envelope!(
        store_dir,
        :openai,
        arbor_envelope(
          :openai,
          %{
            "access_token" => jwt_access(System.system_time(:second) - 5),
            "refresh_token" => "rt-owned"
          },
          account_id: "acct_owner",
          generation: 41
        )
      )

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai, _config, "rt-owned" ->
        {:ok,
         %{
           "access_token" => fresh_access,
           "refresh_token" => "rt-rotated",
           "provider" => "xai",
           "account_id" => "attacker-account",
           "origin" => "external_cli",
           "owner" => "source_owned",
           "source" => "grok_file",
           "generation" => 0,
           "tokens" => %{"refresh_token" => "nested-attacker-token"}
         }}
      end)

      assert {:ok, ^fresh_access} = OAuth.access_token(:openai)
      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["provider"] == "openai"
      assert stored["account_id"] == "acct_owner"
      assert stored["origin"] == "arbor_login"
      assert stored["owner"] == "arbor_owned"
      assert stored["source"] == "arbor_oauth_store"
      assert stored["generation"] == 42
      assert stored["refresh_token"] == "rt-rotated"
    end

    test "security regression: reused or invalidated refresh preserves the envelope and redacts errors",
         %{store_dir: store_dir} do
      for code <- ["refresh_token_reused", "refresh_token_invalidated"] do
        path =
          write_store!(store_dir, :openai, %{
            "access_token" => jwt_access(System.system_time(:second) - 5),
            "refresh_token" => "stored-refresh-secret"
          })

        before = File.read!(path)
        provider_secret = "provider-body-secret-#{code}"

        Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai,
                                                               _config,
                                                               "stored-refresh-secret" ->
          {:error,
           {:refresh_failed, 401, %{"error" => code, "error_description" => provider_secret}}}
        end)

        result = OAuth.access_token(:openai)
        assert result == {:error, :oauth_relogin_required}
        assert File.read!(path) == before
        refute inspect(result) =~ provider_secret
        refute inspect(result) =~ "stored-refresh-secret"
      end
    end

    test "security regression: unknown OAuth refresh errors are stable and secret-free",
         %{store_dir: store_dir} do
      path =
        write_store!(store_dir, :openai, %{
          "access_token" => jwt_access(System.system_time(:second) - 5),
          "refresh_token" => "stored-refresh-secret"
        })

      before = File.read!(path)
      leaked = "provider-response-access-token"

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
        {:error, {:refresh_failed, 500, %{"access_token" => leaked, "detail" => leaked}}}
      end)

      result = OAuth.access_token(:openai)
      assert result == {:error, :oauth_refresh_failed}
      assert File.read!(path) == before
      refute inspect(result) =~ leaked
    end

    test "security regression: malformed rotated refresh token is never published or returned",
         %{store_dir: store_dir} do
      stale_access = jwt_access(System.system_time(:second) - 5)
      fresh_access = jwt_access(System.system_time(:second) + 3_600)

      write_store!(store_dir, :openai, %{
        "access_token" => stale_access,
        "refresh_token" => "rt-keep"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai, _config, "rt-keep" ->
        {:ok, %{"access_token" => fresh_access, "refresh_token" => nil}}
      end)

      assert {:error, {:invalid_refreshed_refresh_token, :invalid}} =
               OAuth.access_token(:openai)

      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["access_token"] == stale_access
      assert stored["refresh_token"] == "rt-keep"
      refute stored["access_token"] == fresh_access
      assert list_temp_files(store_dir) == []
    end

    test "security regression: persistence failure does not return the fresh access token",
         %{store_dir: store_dir} do
      fresh = jwt_access(System.system_time(:second) + 3_600)

      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) - 5),
        "refresh_token" => "rt-persist-fail"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai,
                                                             _config,
                                                             "rt-persist-fail" ->
        # After refresh succeeds, point the store at a path whose parent is a regular
        # file so atomic publication cannot mkdir/write. (chmod 0500 is insufficient
        # because write_stored re-applies 0700 on an existing owner directory.)
        blocker = Path.join(store_dir, "not-a-directory")
        File.write!(blocker, "blocked")
        Application.put_env(:arbor_llm, :oauth_store_dir, Path.join(blocker, "oauth"))

        {:ok,
         %{
           "access_token" => fresh,
           "refresh_token" => "rt-should-not-leak"
         }}
      end)

      assert {:error, {:token_store_write_failed, _}} = OAuth.access_token(:openai)

      # Restore the hermetic store root so we can re-read prior durable content.
      Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)

      # Prior store content remains; the fresh access token was never published or returned.
      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["refresh_token"] == "rt-persist-fail"
      refute stored["access_token"] == fresh
      refute stored["refresh_token"] == "rt-should-not-leak"
    end

    test "security regression: an unreadable store never falls back to a CLI credential",
         %{store_dir: store_dir} do
      cli_path = Path.join(store_dir, "cli-openai.json")

      File.write!(
        cli_path,
        Jason.encode!(%{
          "tokens" => %{
            "access_token" => jwt_access(System.system_time(:second) + 3_600),
            "refresh_token" => "cli-rt",
            "account_id" => "acct_cli"
          }
        })
      )

      Application.put_env(:arbor_llm, :oauth_cli_files, %{openai: cli_path})

      # Parent of the store dir is a regular file → mkdir_p/publication fails closed.
      blocker = Path.join(store_dir, "import-blocker")
      File.write!(blocker, "blocked")
      locked = Path.join(blocker, "oauth")
      Application.put_env(:arbor_llm, :oauth_store_dir, locked)

      assert {:error, {:oauth_token_store_read_failed, {:token_file_unreadable, :enotdir}}} =
               OAuth.access_token(:openai)

      refute File.exists?(Path.join(locked, "openai.json"))
    end

    test "security regression: a missing store never imports or modifies a CLI credential",
         %{store_dir: store_dir} do
      codex_path = Path.join(store_dir, "cli-openai.json")
      grok_path = Path.join(store_dir, "cli-xai.json")

      codex_bytes =
        Jason.encode!(%{
          "tokens" => %{
            "access_token" => jwt_access(System.system_time(:second) + 3_600),
            "refresh_token" => "codex-family-refresh"
          }
        })

      grok_bytes =
        Jason.encode!(%{
          "https://auth.x.ai::account" => %{"refresh_token" => "grok-family-refresh"}
        })

      File.write!(codex_path, codex_bytes)
      File.write!(grok_path, grok_bytes)

      Application.put_env(:arbor_llm, :oauth_cli_files, %{
        openai: codex_path,
        xai: grok_path
      })

      assert {:error, :oauth_login_required} = OAuth.access_token(:openai)
      assert {:error, :oauth_login_required} = OAuth.access_token(:xai)
      assert File.read!(codex_path) == codex_bytes
      assert File.read!(grok_path) == grok_bytes
      refute File.exists?(Path.join(store_dir, "openai.json"))
      refute File.exists?(Path.join(store_dir, "xai.json"))
    end

    test "security regression: corrupt existing store never falls back to stale CLI credentials",
         %{store_dir: store_dir} do
      store_path = Path.join(store_dir, "openai.json")
      cli_path = Path.join(store_dir, "cli-openai.json")

      File.write!(store_path, "{")

      File.write!(
        cli_path,
        Jason.encode!(%{
          "tokens" => %{
            "access_token" => jwt_access(System.system_time(:second) + 3_600),
            "refresh_token" => "stale-cli-refresh"
          }
        })
      )

      Application.put_env(:arbor_llm, :oauth_cli_files, %{openai: cli_path})
      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ -> flunk("no refresh") end)

      assert {:error, {:oauth_token_store_read_failed, {:token_file_unreadable, _}}} =
               OAuth.access_token(:openai)

      assert File.read!(store_path) == "{"
    end
  end

  describe "AcquiredCredential.new/1 (single normalization seam)" do
    test "accepts a well-formed credential from a map or a keyword list" do
      assert {:ok, %OAuth.AcquiredCredential{provider: :openai, account_id: "acct_new"}} =
               OAuth.AcquiredCredential.new(%{
                 provider: :openai,
                 account_id: "acct_new",
                 access_token: jwt_access(System.system_time(:second) + 3_600),
                 refresh_token: "rt-fresh"
               })

      assert {:ok, %OAuth.AcquiredCredential{provider: :xai, account_id: nil}} =
               OAuth.AcquiredCredential.new(
                 provider: :xai,
                 access_token: "xai-access",
                 refresh_token: "xai-refresh"
               )
    end

    test "security regression: unknown fields / metadata injection are rejected" do
      # A keyword list (not a map) isolates unknown-key rejection from the separate map_size
      # bound below -- a 5-key map is rejected as :too_many_fields before any key is inspected,
      # so a keyword list is what actually exercises normalize_key/1's catch-all here.
      base = [
        provider: :openai,
        account_id: "acct_new",
        access_token: jwt_access(System.system_time(:second) + 3_600),
        refresh_token: "rt-fresh"
      ]

      for injected <- [:origin, :owner, :source, :version, :generation, :evil] do
        assert {:error, {:invalid_acquired_credential, :unknown_key}} =
                 OAuth.AcquiredCredential.new(base ++ [{injected, "attacker"}])
      end
    end

    test "security regression: an invalid or malformed provider is rejected" do
      base = %{account_id: "acct", access_token: "a", refresh_token: "r"}

      for bad <- [:anthropic, :claude, "openai", :openai_oauth, :grok, nil] do
        assert {:error, {:invalid_acquired_credential, :invalid_provider}} =
                 OAuth.AcquiredCredential.new(Map.put(base, :provider, bad))
      end
    end

    test "security regression: a missing required field is rejected" do
      assert {:error, {:invalid_acquired_credential, :missing_field}} =
               OAuth.AcquiredCredential.new(%{access_token: "a", refresh_token: "r"})
    end

    test "security regression: malformed or oversized access_token/refresh_token/account_id is rejected" do
      base = %{
        provider: :openai,
        account_id: "acct",
        access_token: jwt_access(System.system_time(:second) + 3_600),
        refresh_token: "rt"
      }

      assert {:error, {:invalid_acquired_credential, :invalid_token}} =
               OAuth.AcquiredCredential.new(%{base | access_token: ""})

      assert {:error, {:invalid_acquired_credential, :invalid_token}} =
               OAuth.AcquiredCredential.new(%{
                 base
                 | refresh_token: String.duplicate("a", 65_537)
               })

      assert {:error, {:invalid_acquired_credential, :invalid_account_id}} =
               OAuth.AcquiredCredential.new(%{base | account_id: nil})

      assert {:error, {:invalid_acquired_credential, :invalid_account_id}} =
               OAuth.AcquiredCredential.new(%{base | account_id: "bad\x00id"})
    end

    test "security regression: Inspect never renders access or refresh tokens" do
      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct_secret_holder",
          access_token: "super-secret-access-token",
          refresh_token: "super-secret-refresh-token"
        })

      rendered = inspect(credential)
      refute rendered =~ "super-secret-access-token"
      refute rendered =~ "super-secret-refresh-token"
      assert rendered =~ "acct_secret_holder"

      normalized =
        OAuth.normalize_acquired_credential(
          :openai,
          "acct_secret_holder",
          "super-secret-access-token",
          "super-secret-refresh-token"
        )

      refute inspect(normalized) =~ "super-secret-access-token"
      refute inspect(normalized) =~ "super-secret-refresh-token"
    end

    test "security regression: an oversized map is rejected by map_size before Map.to_list materializes it" do
      base = %{
        provider: :openai,
        account_id: "acct",
        access_token: jwt_access(System.system_time(:second) + 3_600),
        refresh_token: "rt"
      }

      oversized = Map.merge(base, %{extra1: "a", extra2: "b"})
      assert map_size(oversized) == 6

      assert {:error, {:invalid_acquired_credential, :too_many_fields}} =
               OAuth.AcquiredCredential.new(oversized)
    end
  end

  describe "publish_arbor_owned/2 (Arbor-owned OAuth credential publication boundary)" do
    test "successful publish: openai, complete fixed metadata, generation 0, mode 0600, no temp residue",
         %{store_dir: store_dir} do
      access = jwt_access(System.system_time(:second) + 3_600)

      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct_publish",
          access_token: access,
          refresh_token: "rt-publish"
        })

      assert :ok = OAuth.publish_arbor_owned(:openai_oauth, credential)

      path = Path.join(store_dir, "openai.json")
      {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600

      assert {:ok, stored} = Jason.decode(File.read!(path))
      assert stored["version"] == 1
      assert stored["provider"] == "openai"
      assert stored["account_id"] == "acct_publish"
      assert stored["origin"] == "arbor_login"
      assert stored["owner"] == "arbor_owned"
      assert stored["source"] == "arbor_oauth_store"
      assert stored["generation"] == 0
      assert stored["tokens"]["access_token"] == access
      assert stored["tokens"]["refresh_token"] == "rt-publish"
      assert list_temp_files(store_dir) == []

      assert {:ok, ^access} = OAuth.access_token(:openai)
    end

    test "successful publish: xai, nil account_id accepted, mode 0600, no temp residue",
         %{store_dir: store_dir} do
      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :xai,
          access_token: "xai-fresh-access",
          refresh_token: "xai-fresh-refresh"
        })

      assert :ok = OAuth.publish_arbor_owned(:xai_oauth, credential)

      path = Path.join(store_dir, "xai.json")
      {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
      assert {:ok, stored} = Jason.decode(File.read!(path))
      assert stored["account_id"] == nil
      assert stored["generation"] == 0
      assert list_temp_files(store_dir) == []
    end

    test "publish replaces an existing family and resets generation to 0 (not a continuation)",
         %{store_dir: store_dir} do
      write_envelope!(
        store_dir,
        :openai,
        arbor_envelope(:openai, %{"access_token" => "old-a", "refresh_token" => "old-r"},
          account_id: "acct_old",
          generation: 41
        )
      )

      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct_new",
          access_token: "new-a",
          refresh_token: "new-r"
        })

      assert :ok = OAuth.publish_arbor_owned(:openai_oauth, credential)

      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["generation"] == 0
      assert stored["account_id"] == "acct_new"
      assert stored["access_token"] == "new-a"
      assert stored["refresh_token"] == "new-r"
      assert list_temp_files(store_dir) == []
    end

    test "publish also works via the bare backend key, not only the exact route id",
         %{store_dir: store_dir} do
      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :xai,
          access_token: "xai-a",
          refresh_token: "xai-r"
        })

      assert :ok = OAuth.publish_arbor_owned(:xai, credential)
      assert {:ok, _stored} = read_store(store_dir, :xai)
    end

    test "security regression: unknown/malformed route is refused before any mutation",
         %{store_dir: store_dir} do
      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct",
          access_token: "a",
          refresh_token: "r"
        })

      for bad <- ["grok", "chatgpt", "codex", 123] do
        assert {:error, _} = OAuth.publish_arbor_owned(bad, credential)
      end

      refute File.exists?(Path.join(store_dir, "openai.json"))
      assert list_temp_files(store_dir) == []
    end

    test "security regression: Anthropic-family providers are refused before any mutation, regardless of credential shape",
         %{store_dir: store_dir} do
      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct",
          access_token: "a",
          refresh_token: "r"
        })

      for p <- [:anthropic, :claude, "claude-code", "Anthropic"] do
        assert {:error, :anthropic_oauth_forbidden} = OAuth.publish_arbor_owned(p, credential)
      end

      refute File.exists?(Path.join(store_dir, "openai.json"))
      refute File.exists?(Path.join(store_dir, "anthropic.json"))
      assert list_temp_files(store_dir) == []
    end

    test "security regression: provider mismatch between route and credential is refused before mutation",
         %{store_dir: store_dir} do
      write_envelope!(
        store_dir,
        :openai,
        arbor_envelope(:openai, %{"access_token" => "keep-a", "refresh_token" => "keep-r"},
          account_id: "acct_keep",
          generation: 7
        )
      )

      before = File.read!(Path.join(store_dir, "openai.json"))

      {:ok, xai_credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :xai,
          access_token: "xai-a",
          refresh_token: "xai-r"
        })

      assert {:error, :oauth_publish_provider_mismatch} =
               OAuth.publish_arbor_owned(:openai_oauth, xai_credential)

      assert File.read!(Path.join(store_dir, "openai.json")) == before
      assert list_temp_files(store_dir) == []
    end

    test "security regression: a manually constructed credential is revalidated before mutation",
         %{store_dir: store_dir} do
      path =
        write_store!(store_dir, :openai, %{
          "access_token" => "keep-a",
          "refresh_token" => "keep-r"
        })

      before = File.read!(path)

      forged = %OAuth.AcquiredCredential{
        provider: :openai,
        account_id: "acct",
        access_token: "bad\x00access",
        refresh_token: "refresh"
      }

      assert {:error, {:invalid_acquired_credential, :invalid_token}} =
               OAuth.publish_arbor_owned(:openai_oauth, forged)

      assert File.read!(path) == before
      assert list_temp_files(store_dir) == []
    end

    test "security regression: Inspect/errors never expose token values or token-derived material",
         %{store_dir: _store_dir} do
      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct",
          access_token: "leak-me-access",
          refresh_token: "leak-me-refresh"
        })

      result = OAuth.publish_arbor_owned(:anthropic, credential)
      refute inspect(result) =~ "leak-me-access"
      refute inspect(result) =~ "leak-me-refresh"

      {:ok, mismatch_credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :xai,
          access_token: "xai-a",
          refresh_token: "xai-r"
        })

      mismatch_result = OAuth.publish_arbor_owned(:openai_oauth, mismatch_credential)
      refute inspect(mismatch_result) =~ "xai-a"
      refute inspect(mismatch_result) =~ "xai-r"
    end

    test "security regression: publish_arbor_owned/2 is total -- a non-struct second argument returns a stable redacted error instead of raising",
         %{store_dir: store_dir} do
      for bad <- [%{provider: :openai}, "not-a-credential", nil, 123, %{}] do
        assert {:error, {:invalid_acquired_credential, :struct_required}} =
                 OAuth.publish_arbor_owned(:openai_oauth, bad)
      end

      refute File.exists?(Path.join(store_dir, "openai.json"))
      assert list_temp_files(store_dir) == []
    end

    test "security regression: an invalid provider is refused before the non-struct credential is even inspected" do
      for p <- [:anthropic, :claude, "grok", "chatgpt"] do
        result = OAuth.publish_arbor_owned(p, "garbage-not-a-credential")
        refute match?({:error, {:invalid_acquired_credential, _}}, result)
      end

      assert {:error, :anthropic_oauth_forbidden} =
               OAuth.publish_arbor_owned(:anthropic, "garbage-not-a-credential")
    end
  end

  describe "publish_arbor_owned/2 atomic write failure handling (security regression — honest commit point)" do
    test "security regression: a pre-rename write failure leaves the real target byte-for-byte unchanged with no temp residue",
         %{store_dir: store_dir} do
      path =
        write_store!(store_dir, :openai, %{
          "access_token" => "prior-a",
          "refresh_token" => "prior-r"
        })

      before = File.read!(path)

      Application.put_env(:arbor_llm, :oauth_rename_fun, fn _tmp, _path ->
        {:error, :simulated_rename_failure}
      end)

      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct_new",
          access_token: "new-a",
          refresh_token: "new-r"
        })

      assert {:error, {:token_store_write_failed, :simulated_rename_failure}} =
               OAuth.publish_arbor_owned(:openai_oauth, credential)

      assert File.read!(path) == before
      assert list_temp_files(store_dir) == []
    end

    test "security regression: a post-rename failure is reported as commit-uncertain, never falsely as unchanged",
         %{store_dir: store_dir} do
      Application.put_env(:arbor_llm, :oauth_fsync_dir_fun, fn _dir ->
        {:error, {:dir_fsync_failed, :simulated_fsync_failure}}
      end)

      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct_committed",
          access_token: "committed-a",
          refresh_token: "committed-r"
        })

      result = OAuth.publish_arbor_owned(:openai_oauth, credential)

      assert {:error,
              {:oauth_publish_commit_uncertain,
               {:token_store_write_failed, {:dir_fsync_failed, :simulated_fsync_failure}}}} =
               result

      refute inspect(result) =~ "committed-a"
      refute inspect(result) =~ "committed-r"

      path = Path.join(store_dir, "openai.json")
      assert {:ok, stored} = Jason.decode(File.read!(path))
      assert stored["tokens"]["access_token"] == "committed-a"
      assert stored["account_id"] == "acct_committed"
      assert list_temp_files(store_dir) == []
    end

    test "security regression: refresh's public error shape is preserved unchanged through the same post-rename tag",
         %{store_dir: store_dir} do
      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) - 5),
        "refresh_token" => "rt-refresh-remap"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai,
                                                             _config,
                                                             "rt-refresh-remap" ->
        {:ok,
         %{
           "access_token" => jwt_access(System.system_time(:second) + 3_600),
           "refresh_token" => "rt-refresh-remap-2"
         }}
      end)

      Application.put_env(:arbor_llm, :oauth_fsync_dir_fun, fn _dir ->
        {:error, {:dir_fsync_failed, :simulated_fsync_failure}}
      end)

      assert {:error, {:token_store_write_failed, {:dir_fsync_failed, :simulated_fsync_failure}}} =
               OAuth.access_token(:openai)
    end
  end

  describe "publish_arbor_owned/2 concurrency (security regression — shared provider lock)" do
    test "security regression: a forced refresh and a concurrent publication both block on the identical provider-scoped lock",
         %{store_dir: store_dir} do
      write_store!(store_dir, :openai, %{
        "access_token" => jwt_access(System.system_time(:second) - 5),
        "refresh_token" => "rt-shared-lock"
      })

      refreshed_access = jwt_access(System.system_time(:second) + 3_600)

      # Generic on refresh_token: :global.trans does not guarantee which of the two waiters below
      # acquires the resource first once released, so whichever one (publish or refresh) runs
      # second must see a store already mutated by the other. Pinning to one exact refresh_token
      # would make the test's outcome depend on that unspecified ordering.
      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai, _config, _refresh_token ->
        {:ok, %{"access_token" => refreshed_access, "refresh_token" => "rt-shared-lock-2"}}
      end)

      {:ok, credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :openai,
          account_id: "acct_locked",
          # Also expired, for the same reason: if publication commits first, the subsequent
          # refresh must still see a token that needs refreshing, regardless of ordering.
          access_token: jwt_access(System.system_time(:second) - 5),
          refresh_token: "locked-r"
        })

      lock_id = {{OAuth, :refresh, :openai}, self()}
      lock_nodes = [node() | Node.list()]
      assert true = :global.set_lock(lock_id, lock_nodes, 0)

      # Two independent processes, each contending the SAME resource: a forced refresh (the
      # stored token is already expired, so access_token/1 must take the refresh path) and a
      # concurrent publication. Both must be provably blocked on the externally-held lock before
      # it is released -- proving they share one resource, not merely that each respects locking
      # in isolation.
      refresh_task = Task.async(fn -> OAuth.access_token(:openai) end)
      publish_task = Task.async(fn -> OAuth.publish_arbor_owned(:openai_oauth, credential) end)

      try do
        wait_until(fn -> waiting_on_global_lock?(refresh_task.pid) end, 2_000)
        wait_until(fn -> waiting_on_global_lock?(publish_task.pid) end, 2_000)
      after
        :global.del_lock(lock_id, lock_nodes)
      end

      assert {:ok, ^refreshed_access} = Task.await(refresh_task, 5_000)
      assert :ok = Task.await(publish_task, 5_000)
    end

    test "security regression: different providers remain independently lockable during publication" do
      {:ok, xai_credential} =
        OAuth.AcquiredCredential.new(%{
          provider: :xai,
          access_token: "xai-independent-a",
          refresh_token: "xai-independent-r"
        })

      lock_id = {{OAuth, :refresh, :openai}, self()}
      lock_nodes = [node() | Node.list()]
      assert true = :global.set_lock(lock_id, lock_nodes, 0)

      try do
        publish_task =
          Task.async(fn -> OAuth.publish_arbor_owned(:xai_oauth, xai_credential) end)

        assert :ok = Task.await(publish_task, 2_000)
      after
        :global.del_lock(lock_id, lock_nodes)
      end
    end
  end

  describe "cached non-expiring tokens" do
    test "returns cached access token without invoking refresh", %{store_dir: store_dir} do
      access = jwt_access(System.system_time(:second) + 3_600)

      write_store!(store_dir, :openai, %{
        "access_token" => access,
        "refresh_token" => "unused-rt"
      })

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
        flunk("refresh must not run for a non-expiring cached token")
      end)

      assert {:ok, ^access} = OAuth.access_token(:openai)
    end
  end

  # ── hermetic helpers (never touch operator ~/.codex, ~/.grok, or ~/.arbor) ──

  defp write_store!(store_dir, provider, tokens) do
    account_id = Map.get(tokens, "account_id", if(provider == :openai, do: "acct_test"))
    token_payload = Map.take(tokens, ["access_token", "refresh_token"])

    write_envelope!(
      store_dir,
      provider,
      arbor_envelope(provider, token_payload, account_id: account_id)
    )
  end

  defp write_envelope!(store_dir, provider, envelope) do
    path = Path.join(store_dir, "#{provider}.json")
    File.write!(path, Jason.encode!(envelope))
    File.chmod!(path, 0o600)
    path
  end

  defp read_store(store_dir, provider) do
    path = Path.join(store_dir, "#{provider}.json")

    with {:ok, envelope} <- Jason.decode(File.read!(path)) do
      {:ok, Map.merge(envelope, envelope["tokens"] || %{})}
    end
  end

  defp arbor_envelope(provider, tokens, opts) do
    %{
      "version" => 1,
      "provider" => Atom.to_string(provider),
      "account_id" => Keyword.get(opts, :account_id),
      "origin" => "arbor_login",
      "owner" => "arbor_owned",
      "source" => "arbor_oauth_store",
      "generation" => Keyword.get(opts, :generation, 0),
      "tokens" => tokens
    }
  end

  defp source_envelope(provider, account_id, generation \\ 3) do
    {source, account_id} =
      case provider do
        :openai -> {"codex_file", account_id}
        :xai -> {"grok_file", account_id}
      end

    %{
      "version" => 1,
      "provider" => Atom.to_string(provider),
      "account_id" => account_id,
      "origin" => "external_cli",
      "owner" => "source_owned",
      "source" => source,
      "generation" => generation,
      "tokens" => %{}
    }
  end

  defp write_codex_source!(path, access_token, refresh_token, account_id \\ "acct_source") do
    bytes =
      Jason.encode!(%{
        "tokens" => %{
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "account_id" => account_id,
          "id_token" => "ignored-id-token"
        },
        "last_refresh" => "2026-07-22T00:00:00Z"
      })

    File.write!(path, bytes)
    bytes
  end

  # Temps are ".#{key}....tmp". Plain "*.tmp" skips leading-dot names; use ".*.tmp"
  # with match_dot so the cleanup assertion actually sees leftover publish temps.
  defp list_temp_files(store_dir) do
    store_dir
    |> Path.join(".*.tmp")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
  end

  defp jwt_access(exp) when is_integer(exp) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"exp" => exp}), padding: false)
    "#{header}.#{payload}.sig"
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before deadline")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end

  defp waiting_on_global_lock?(pid) when is_pid(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stacktrace} ->
        Enum.any?(stacktrace, fn
          {:global, function, _arity_or_args, _location}
          when function in [:set_lock, :trans, :random_sleep] ->
            true

          _ ->
            false
        end)

      _ ->
        false
    end
  end
end
