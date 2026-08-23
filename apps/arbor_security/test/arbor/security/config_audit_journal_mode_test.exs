defmodule Arbor.Security.ConfigAuditJournalModeTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile

  setup do
    originals = env_snapshot()
    Config.restore_authority_root()

    on_exit(fn ->
      Config.restore_authority_root()
      restore_env(originals)
    end)

    :ok
  end

  test "test default snapshot is ephemeral and does not freeze a journal root" do
    Application.delete_env(:arbor_security, :audit_journal_mode)
    Application.put_env(:arbor_security, :storage_backend, nil)
    put_kernel_runtime(start_profile: :full)

    assert {:ok, snapshot} = Config.startup_store_snapshot(:test_bootstrap)
    assert snapshot.journal_mode == :ephemeral
    assert snapshot.journal_reason == :none
    assert snapshot.root == nil
    assert Config.audit_journal_start_opts(snapshot) == [mode: :ephemeral]
  end

  test "activation_only forces disabled with activation_only reason and no journal root" do
    Application.put_env(:arbor_security, :audit_journal_mode, :durable)
    Application.put_env(:arbor_security, :storage_backend, JSONFile)
    Application.put_env(:arbor_security, :start_children, true)
    put_kernel_runtime(start_profile: :activation_only)

    assert {:ok, snapshot} = Config.startup_store_snapshot(:application)
    assert snapshot.journal_mode == :disabled
    assert snapshot.journal_reason == :activation_only
    assert snapshot.root == nil

    assert Config.audit_journal_start_opts(snapshot) == [
             mode: :disabled,
             reason: :activation_only
           ]
  end

  test "configured disabled is dormant without a journal root" do
    Application.put_env(:arbor_security, :audit_journal_mode, :disabled)
    Application.put_env(:arbor_security, :storage_backend, JSONFile)
    put_kernel_runtime(start_profile: :full)

    assert {:ok, snapshot} = Config.startup_store_snapshot(:test_bootstrap)
    assert snapshot.journal_mode == :disabled
    assert snapshot.journal_reason == :disabled
    assert snapshot.root == nil
    assert Config.audit_journal_start_opts(snapshot) == [mode: :disabled, reason: :disabled]
  end

  test "durable JSONFile freezes root into journal start opts" do
    root = unique_abs_root("journal-durable")
    Application.put_env(:arbor_security, :authority_state_root, root)
    Application.delete_env(:arbor_security, JSONFile)
    Application.put_env(:arbor_security, :storage_backend, JSONFile)
    Application.put_env(:arbor_security, :audit_journal_mode, :durable)
    put_kernel_runtime(start_profile: :full)

    assert {:ok, snapshot} = Config.startup_store_snapshot(:test_bootstrap)
    assert snapshot.journal_mode == :durable
    assert snapshot.root == Path.expand(root)
    assert Config.audit_journal_start_opts(snapshot) == [mode: :durable, root: Path.expand(root)]
  end

  test "attacker extras cannot inject path module callback backend or name" do
    refute function_exported?(Config, :audit_journal_start_opts, 2)
    assert function_exported?(Config, :audit_journal_start_opts, 1)

    snapshot = %{
      journal_mode: :ephemeral,
      journal_reason: :none,
      root: "/frozen/root",
      path: "/evil.log",
      file_module: :attacker,
      callback: fn -> :ok end,
      backend: :attacker,
      file: "/evil.log",
      destination: "/evil",
      store: :attacker,
      name: :attacker,
      mode: :durable,
      reason: :activation_only
    }

    opts = Config.audit_journal_start_opts(snapshot)
    assert opts == [mode: :ephemeral]
    refute Keyword.has_key?(opts, :path)
    refute Keyword.has_key?(opts, :root)

    durable = %{
      journal_mode: :durable,
      journal_reason: :none,
      root: "/frozen/root",
      path: "/evil.log",
      file_module: :attacker,
      backend: :memory
    }

    assert Config.audit_journal_start_opts(durable) == [mode: :durable, root: "/frozen/root"]
  end

  test "malformed snapshot mode fails closed instead of returning disabled opts" do
    assert_raise ArgumentError, "invalid audit journal snapshot", fn ->
      Config.audit_journal_start_opts(%{journal_mode: :memory, journal_reason: :none})
    end

    assert_raise ArgumentError, "invalid audit journal snapshot", fn ->
      Config.audit_journal_start_opts(%{journal_mode: :disabled, journal_reason: :attacker})
    end

    assert_raise ArgumentError, "invalid audit journal snapshot", fn ->
      Config.audit_journal_start_opts(%{journal_mode: :durable, journal_reason: :none, root: nil})
    end
  end

  test "invalid journal mode fails closed" do
    Application.put_env(:arbor_security, :audit_journal_mode, :memory)
    put_kernel_runtime(start_profile: :full)

    assert {:error, :audit_journal_mode_invalid} =
             Config.startup_store_snapshot(:test_bootstrap)
  end

  test "audit journal call timeout is bounded" do
    Application.delete_env(:arbor_security, :audit_journal_call_timeout_ms)
    assert Config.audit_journal_call_timeout_ms() == 5_000

    Application.put_env(:arbor_security, :audit_journal_call_timeout_ms, 60_000)
    assert Config.audit_journal_call_timeout_ms() == 30_000

    Application.put_env(:arbor_security, :audit_journal_call_timeout_ms, -1)
    assert Config.audit_journal_call_timeout_ms() == 5_000
  end

  defp unique_abs_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-p1c-b2b-cfg-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    expanded = Path.expand(path)
    on_exit(fn -> File.rm_rf!(expanded) end)
    expanded
  end

  defp put_kernel_runtime(updates) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)
    Application.put_env(:arbor_kernel, :kernel_runtime, value)
  end

  defp env_snapshot do
    %{
      authority_state_root: Application.fetch_env(:arbor_security, :authority_state_root),
      json_file: Application.fetch_env(:arbor_security, JSONFile),
      storage_backend: Application.fetch_env(:arbor_security, :storage_backend),
      start_children: Application.fetch_env(:arbor_security, :start_children),
      audit_journal_mode: Application.fetch_env(:arbor_security, :audit_journal_mode),
      timeout: Application.fetch_env(:arbor_security, :audit_journal_call_timeout_ms),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime)
    }
  end

  defp restore_env(originals) do
    restore_security_env(:authority_state_root, originals.authority_state_root)
    restore_json_file_env(originals.json_file)
    restore_security_env(:storage_backend, originals.storage_backend)
    restore_security_env(:start_children, originals.start_children)
    restore_security_env(:audit_journal_mode, originals.audit_journal_mode)
    restore_security_env(:audit_journal_call_timeout_ms, originals.timeout)

    case originals.kernel_runtime do
      {:ok, value} -> Application.put_env(:arbor_kernel, :kernel_runtime, value)
      :error -> Application.delete_env(:arbor_kernel, :kernel_runtime)
    end
  end

  defp restore_security_env(key, :error), do: Application.delete_env(:arbor_security, key)

  defp restore_security_env(key, {:ok, value}),
    do: Application.put_env(:arbor_security, key, value)

  defp restore_json_file_env(:error), do: Application.delete_env(:arbor_security, JSONFile)

  defp restore_json_file_env({:ok, value}),
    do: Application.put_env(:arbor_security, JSONFile, value)
end
