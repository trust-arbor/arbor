defmodule Arbor.LLM.OAuthTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.OAuth

  @env_keys [
    :oauth_store_dir,
    :oauth_refresh_fun,
    :oauth_cli_files
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

      # Durable store holds the full rotated set.
      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["access_token"] == fresh_access
      assert stored["refresh_token"] == rotated_refresh
      assert stored["account_id"] == "acct_test"
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
      assert decoded["access_token"] == access
      assert decoded["refresh_token"] == "rt-2"
      assert decoded["account_id"] == "acct_mode"
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

      assert {:error, {:invalid_refreshed_refresh_token, :missing_or_not_binary}} =
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

    test "security regression: CLI import fails closed when the store path is invalid",
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

    test "first use imports CLI credentials only when the Arbor store is absent",
         %{store_dir: store_dir} do
      access = jwt_access(System.system_time(:second) + 3_600)
      cli_path = Path.join(store_dir, "cli-openai.json")

      File.write!(
        cli_path,
        Jason.encode!(%{
          "tokens" => %{
            "access_token" => access,
            "refresh_token" => "cli-first-use-refresh"
          }
        })
      )

      Application.put_env(:arbor_llm, :oauth_cli_files, %{openai: cli_path})

      assert {:ok, ^access} = OAuth.access_token(:openai)
      assert {:ok, stored} = read_store(store_dir, :openai)
      assert stored["access_token"] == access
      assert stored["refresh_token"] == "cli-first-use-refresh"
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
    path = Path.join(store_dir, "#{provider}.json")
    File.write!(path, Jason.encode!(tokens))
    File.chmod!(path, 0o600)
    path
  end

  defp read_store(store_dir, provider) do
    path = Path.join(store_dir, "#{provider}.json")
    Jason.decode(File.read!(path))
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
