defmodule Arbor.Persistence.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag :isolated_repo

  @root Path.expand("../../../../..", __DIR__)

  test "production SQLite configuration starts the persistence Repo and executes a query" do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_prod_repo_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)
    security_state = Path.join(temp_dir, "security-state")
    revocation_ledger = Path.join(temp_dir, "revocations/capability_revocations.v1.json")
    File.mkdir_p!(security_state)
    File.mkdir_p!(Path.dirname(revocation_ledger))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    database = Path.join(temp_dir, "arbor_prod.sqlite3")
    deps_path = System.get_env("MIX_DEPS_PATH") || Path.join(@root, "deps")
    build_path = Path.join(@root, "_build/prod-repo-proof")

    fixture_dir =
      Path.join([@root, "apps", "arbor_kernel", "test", "fixtures", "extension_envelopes", "v1"])

    # Prod has no installer sys.config. The fixture is the dev/test stage-zero,
    # valid through 2027-08-17, so the prod clock can bind it.
    boot_profile = [
      manifest_bytes: File.read!(Path.join(fixture_dir, "boot_profile_manifest.json")),
      signature_bytes: File.read!(Path.join(fixture_dir, "boot_profile_signature.json")),
      trusted_signers: [
        %{
          "signer_id" => "installer.arbor",
          "key_id" => "37eb0623867f14c690e51a9e24c55fd98ae4b353a00cd3a37ec953330ddda395",
          "public_key" => "347f4f2c0221027fb01086e2d5b8ee0264ae43ddb99aea3dacf04ce0331f89b8"
        }
      ],
      expected_release_id: "arbor.platform.release.1",
      expected_profile_id: "safe_recovery",
      expected_revocation_input_id: "revocation.platform.1",
      expected_payload_digests: [
        %{
          "id" => "payload.kernel",
          "sha256" => "1111111111111111111111111111111111111111111111111111111111111111"
        },
        %{
          "id" => "payload.kernel_runtime",
          "sha256" => "2222222222222222222222222222222222222222222222222222222222222222"
        }
      ],
      min_boot_epoch: 1,
      revoked_signer_key_ids: [],
      revoked_platform_key_ids: []
    ]

    probe = """
    repo_config =
      Application.fetch_env!(:arbor_persistence, Arbor.Persistence.Repo)

    required = [:database, :pool_size, :busy_timeout, :journal_mode]

    unless Enum.all?(required, &Keyword.has_key?(repo_config, &1)) do
      raise "production Repo configuration is incomplete"
    end

    unless repo_config[:database] == #{inspect(database)} do
      raise "production SQLite path was not runtime-resolved"
    end

    unless Application.fetch_env!(:arbor_persistence, :start_repo) do
      raise "production Repo supervision is disabled"
    end

    unless Arbor.Persistence.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      raise "production Repo compiled with the wrong adapter"
    end

    runtime = Application.get_env(:arbor_kernel, :kernel_runtime, [])

    Application.put_env(
      :arbor_kernel,
      :kernel_runtime,
      Keyword.put(runtime, :boot_profile, #{inspect(boot_profile)})
    )

    # This app's prod code path lists Mix deps only. os_mon is an OTP provider
    # the full kernel profile starts, and it is not one of those deps.
    [os_mon_ebin] =
      Path.wildcard(Path.join(List.to_string(:code.root_dir()), "lib/os_mon-*/ebin"))

    true = Code.append_path(os_mon_ebin)

    {:ok, _started} = Application.ensure_all_started(:arbor_persistence)
    true = is_pid(Process.whereis(Arbor.Persistence.Repo))
    {:ok, %{rows: [[1]]}} = Arbor.Persistence.Repo.query("SELECT 1")
    true = File.exists?(#{inspect(database)})
    IO.puts("PROD_REPO_PROBE_OK")
    """

    env = [
      {"MIX_ENV", "prod"},
      {"ARBOR_DB", "sqlite"},
      {"ARBOR_DATA_DIR", temp_dir},
      # Home is unset in this child, so runtime.exs would load ~/.arbor and
      # call Arbor.Shell before that app is compiled.
      {"ARBOR_HOME", temp_dir},
      {"ARBOR_SQLITE_PATH", nil},
      {"ARBOR_ENV_PATH", Path.join(temp_dir, "missing.env")},
      {"SECRET_KEY_BASE", String.duplicate("p", 64)},
      {"ARBOR_SESSION_TOKEN_SECRET", String.duplicate("s", 32)},
      {"ARBOR_SECURITY_STATE_DIR", security_state},
      {"ARBOR_SECURITY_REVOCATION_LEDGER_PATH", revocation_ledger},
      {"MIX_DEPS_PATH", deps_path},
      {"MIX_BUILD_PATH", build_path}
    ]

    assert {output, 0} =
             System.cmd(
               Path.join(@root, "bin/mix"),
               ["run", "--no-start", "-e", probe],
               cd: Path.join(@root, "apps/arbor_persistence"),
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "PROD_REPO_PROBE_OK"
  end
end
