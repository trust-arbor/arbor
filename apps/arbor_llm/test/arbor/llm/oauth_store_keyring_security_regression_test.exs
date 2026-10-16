defmodule Arbor.LLM.OAuthStoreKeyringSecurityRegressionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.LLM.OAuth
  alias Arbor.LLM.OAuth.AcquiredCredential
  alias Arbor.LLM.OAuth.Keyring.Memory
  alias Arbor.LLM.OAuth.Keyring.SecretTool
  alias Arbor.LLM.OAuth.Keyring.Security
  alias Arbor.LLM.OAuth.Keyring.StdinCmd
  alias Arbor.LLM.OAuth.Storage.AesGcm

  @moduletag :fast
  @moduletag :security_regression

  @env_keys [
    :oauth_store_dir,
    :oauth_storage_backend,
    :oauth_keyring_adapter,
    :oauth_refresh_fun,
    :oauth_rename_fun,
    :oauth_fsync_dir_fun,
    :oauth_keyring_cmd_fun
  ]

  setup do
    prior =
      Map.new(@env_keys, fn key ->
        {key, Application.get_env(:arbor_llm, key, :__unset__)}
      end)

    store_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor-oauth-keyring-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.rm_rf!(store_dir)
    File.mkdir_p!(store_dir)

    {:ok, _pid} = start_supervised(Memory)
    Memory.reset()

    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)
    Application.put_env(:arbor_llm, :oauth_storage_backend, :keyring)
    Application.put_env(:arbor_llm, :oauth_keyring_adapter, Memory)
    Application.delete_env(:arbor_llm, :oauth_refresh_fun)
    Application.delete_env(:arbor_llm, :oauth_rename_fun)
    Application.delete_env(:arbor_llm, :oauth_fsync_dir_fun)
    Application.delete_env(:arbor_llm, :oauth_keyring_cmd_fun)

    on_exit(fn ->
      Enum.each(prior, fn
        {key, :__unset__} -> Application.delete_env(:arbor_llm, key)
        {key, value} -> Application.put_env(:arbor_llm, key, value)
      end)

      File.rm_rf(store_dir)
    end)

    {:ok, store_dir: store_dir}
  end

  test "security regression: keyring backend leaves no plaintext access_token or refresh_token on disk",
       %{store_dir: store_dir} do
    suffix = unique_suffix()
    access = "access-must-not-be-on-disk-#{suffix}"
    refresh = "refresh-must-not-be-on-disk-#{suffix}"

    {:ok, credential} =
      AcquiredCredential.new(%{
        provider: :openai,
        account_id: "acct_keyring",
        access_token: access,
        refresh_token: refresh
      })

    log =
      capture_log(fn ->
        assert :ok = OAuth.publish_arbor_owned(:openai, credential)
        assert {:ok, ^access} = OAuth.access_token(:openai)
      end)

    refute_plaintext_secrets(store_dir, [access, refresh])
    refute log =~ access
    refute log =~ refresh
    refute inspect(credential) =~ access
    refute inspect(credential) =~ refresh
  end

  test "security regression: enabling the keyring migrates a leftover plaintext file and deletes it",
       %{store_dir: store_dir} do
    suffix = unique_suffix()
    access = jwt_access(System.system_time(:second) + 3_600)
    refresh = "refresh-migrate-#{suffix}"
    path = Path.join(store_dir, "openai.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "provider" => "openai",
        "account_id" => "acct_migrate",
        "origin" => "arbor_login",
        "owner" => "arbor_owned",
        "source" => "arbor_oauth_store",
        "generation" => 4,
        "tokens" => %{"access_token" => access, "refresh_token" => refresh}
      })
    )

    File.chmod!(path, 0o600)
    assert File.exists?(path)

    assert {:ok, ^access} = OAuth.access_token(:openai)
    refute File.exists?(path)
    refute_plaintext_secrets(store_dir, [access, refresh])
    assert {:ok, ^access} = OAuth.access_token(:openai)
  end

  test "security regression: encrypted-file backend stores AES-GCM ciphertext and keeps the DEK in the keyring",
       %{store_dir: store_dir} do
    Application.put_env(:arbor_llm, :oauth_storage_backend, :encrypted_file)

    suffix = unique_suffix()
    access = "enc-access-#{suffix}"
    refresh = "enc-refresh-#{suffix}"

    {:ok, credential} =
      AcquiredCredential.new(%{
        provider: :xai,
        access_token: access,
        refresh_token: refresh
      })

    assert :ok = OAuth.publish_arbor_owned(:xai, credential)
    assert {:ok, ^access} = OAuth.access_token(:xai)

    enc_path = Path.join(store_dir, "xai.enc")
    assert File.exists?(enc_path)
    {:ok, %{mode: mode}} = File.stat(enc_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    envelope = enc_path |> File.read!() |> Jason.decode!()
    assert envelope["v"] == 1
    assert envelope["alg"] == "aes-256-gcm"
    assert envelope["provider"] == "xai"
    assert is_binary(envelope["iv"])
    assert is_binary(envelope["tag"])
    assert is_binary(envelope["ct"])
    refute File.exists?(Path.join(store_dir, "xai.json"))
    refute_plaintext_secrets(store_dir, [access, refresh])
  end

  test "security regression: a keyring write failure does not create a plaintext token file",
       %{store_dir: store_dir} do
    Application.put_env(:arbor_llm, :oauth_keyring_adapter, __MODULE__.UnavailableKeyring)

    {:ok, credential} =
      AcquiredCredential.new(%{
        provider: :openai,
        account_id: "acct_fail",
        access_token: "access-fail-closed",
        refresh_token: "refresh-fail-closed"
      })

    assert {:error, _} = OAuth.publish_arbor_owned(:openai, credential)
    refute File.exists?(Path.join(store_dir, "openai.json"))
    refute_plaintext_secrets(store_dir, ["access-fail-closed", "refresh-fail-closed"])
  end

  test "security regression: keyring refresh persists rotated tokens without a plaintext file",
       %{store_dir: store_dir} do
    expired = jwt_access(System.system_time(:second) - 30)
    suffix = unique_suffix()
    old_refresh = "refresh-old-#{suffix}"
    new_access = jwt_access(System.system_time(:second) + 3_600)
    new_refresh = "refresh-new-#{suffix}"

    {:ok, credential} =
      AcquiredCredential.new(%{
        provider: :openai,
        account_id: "acct_refresh",
        access_token: expired,
        refresh_token: old_refresh
      })

    assert :ok = OAuth.publish_arbor_owned(:openai, credential)

    Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :openai, _config, ^old_refresh ->
      {:ok, %{"access_token" => new_access, "refresh_token" => new_refresh}}
    end)

    assert {:ok, ^new_access} = OAuth.access_token(:openai)
    refute_plaintext_secrets(store_dir, [expired, old_refresh, new_access, new_refresh])
  end

  test "security regression: an unknown storage backend fails closed without writing tokens",
       %{store_dir: store_dir} do
    Application.put_env(:arbor_llm, :oauth_storage_backend, :s3)

    {:ok, credential} =
      AcquiredCredential.new(%{
        provider: :openai,
        account_id: "acct_invalid",
        access_token: "access-invalid-backend",
        refresh_token: "refresh-invalid-backend"
      })

    assert {:error, {:unsupported_oauth_storage_backend, :s3}} =
             OAuth.publish_arbor_owned(:openai, credential)

    refute File.exists?(Path.join(store_dir, "openai.json"))
    refute_plaintext_secrets(store_dir, ["access-invalid-backend", "refresh-invalid-backend"])
  end

  test "security regression: encrypted-file migrates leftover plaintext and deletes it",
       %{store_dir: store_dir} do
    Application.put_env(:arbor_llm, :oauth_storage_backend, :encrypted_file)
    suffix = unique_suffix()
    # Opaque (non-JWT) so xAI's 3600s skew cannot treat this as expiring and
    # force a refresh during the storage-migration assertion.
    access = "enc-migrate-access-#{suffix}"
    refresh = "enc-migrate-#{suffix}"
    path = Path.join(store_dir, "xai.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "provider" => "xai",
        "account_id" => nil,
        "origin" => "arbor_login",
        "owner" => "arbor_owned",
        "source" => "arbor_oauth_store",
        "generation" => 1,
        "tokens" => %{"access_token" => access, "refresh_token" => refresh}
      })
    )

    File.chmod!(path, 0o600)

    assert {:ok, ^access} = OAuth.access_token(:xai)
    refute File.exists?(path)
    assert File.exists?(Path.join(store_dir, "xai.enc"))
    refute_plaintext_secrets(store_dir, [access, refresh])
  end

  test "AES-GCM envelope round-trips and fails closed on tamper" do
    key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)
    plaintext = ~s({"tokens":{"access_token":"a","refresh_token":"r"}})

    assert {:ok, envelope} = AesGcm.wrap(plaintext, key, iv, "openai")
    assert {:ok, ^plaintext} = AesGcm.unwrap(envelope, key, "openai")
    refute inspect(envelope) =~ "access_token"

    tampered = Map.put(envelope, "ct", Base.encode64(:crypto.strong_rand_bytes(32)))

    assert {:error, :encrypted_oauth_decrypt_failed} =
             AesGcm.unwrap(tampered, key, "openai")

    assert {:error, :invalid_encrypted_envelope} =
             AesGcm.unwrap(envelope, key, "xai")
  end

  test "security regression: stdin cmd and OS adapters keep secrets off argv" do
    secret = "argv-must-not-contain-#{unique_suffix()}"
    parent = self()

    Application.put_env(:arbor_llm, :oauth_keyring_cmd_fun, fn exe, args, stdin, _opts ->
      send(parent, {:keyring_cmd, exe, args, stdin})
      {"", 0}
    end)

    assert :ok = SecretTool.put("arbor.oauth", "provider:openai", secret)
    assert_receive {:keyring_cmd, "secret-tool", args, stdin}
    refute_secret_in_argv(args, secret)
    assert stdin == secret

    assert :ok = Security.put("arbor.oauth", "provider:openai", secret)
    assert_receive {:keyring_cmd, "security", sec_args, sec_stdin}
    assert sec_args == ["-i"]
    refute_secret_in_argv(sec_args, secret)
    refute String.contains?(sec_stdin, secret)
    assert String.contains?(sec_stdin, Base.encode64(secret, padding: true))

    script = Path.join(System.tmp_dir!(), "arbor-stdin-cmd-#{unique_suffix()}")
    argv_log = script <> ".argv"
    stdin_log = script <> ".stdin"

    File.write!(script, """
    #!/bin/sh
    printf '%s\\n' "$0" "$@" > "#{argv_log}"
    cat > "#{stdin_log}"
    """)

    File.chmod!(script, 0o700)
    Application.delete_env(:arbor_llm, :oauth_keyring_cmd_fun)

    try do
      assert {:ok, _out} =
               StdinCmd.run(script, ["store", "arbor.oauth"], secret, timeout: 5_000)

      wait_for_file(argv_log)
      wait_for_file(stdin_log)
      recorded_argv = File.read!(argv_log)
      recorded_stdin = File.read!(stdin_log)
      refute String.contains?(recorded_argv, secret)
      assert recorded_stdin == secret
    after
      File.rm(script)
      File.rm(argv_log)
      File.rm(stdin_log)
    end
  end

  defmodule UnavailableKeyring do
    @moduledoc false
    @behaviour Arbor.LLM.OAuth.Keyring

    def get(_service, _account), do: {:error, :keyring_unavailable}
    def put(_service, _account, _secret), do: {:error, :keyring_unavailable}
    def delete(_service, _account), do: {:error, :keyring_unavailable}
  end

  defp refute_plaintext_secrets(store_dir, secrets) when is_list(secrets) do
    files =
      store_dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    Enum.each(files, fn path ->
      body = File.read!(path)

      Enum.each(secrets, fn secret ->
        refute String.contains?(body, secret),
               "plaintext secret leaked in #{Path.relative_to(path, store_dir)}"
      end)
    end)
  end

  defp unique_suffix do
    "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
  end

  defp jwt_access(exp) when is_integer(exp) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"exp" => exp}), padding: false)
    "#{header}.#{payload}.sig"
  end

  defp refute_secret_in_argv(args, secret) when is_list(args) do
    Enum.each(args, fn arg ->
      refute String.contains?(arg, secret), "secret leaked on argv"
    end)
  end

  defp wait_for_file(path) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    wait_for_file(path, deadline)
  end

  defp wait_for_file(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected #{path} to exist")
      else
        Process.sleep(5)
        wait_for_file(path, deadline)
      end
    end
  end
end
