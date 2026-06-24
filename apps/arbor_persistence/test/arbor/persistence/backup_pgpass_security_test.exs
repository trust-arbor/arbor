defmodule Arbor.Persistence.BackupPgpassSecurityTest do
  # Mutates PATH + application env to install stub pg binaries; not async.
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Backup

  @moduletag :fast

  # M6 security regression (SECURITY_REVIEW 2026-02-16):
  # "Database password passed via PGPASSWORD environment variable" — visible in
  # /proc/*/environ and process listings. The fix routes credentials through
  # `with_pgpass/2`, which writes a temporary `.pgpass` file (chmod 0600) and
  # passes only `PGPASSFILE` to pg_dump / pg_restore — never `PGPASSWORD`.
  #
  # These tests stub `pg_dump` / `pg_restore` (and `age`) on PATH with scripts
  # that record the environment + the PGPASSFILE mode, then drive the public
  # `Backup.backup/1` / `Backup.restore/2`. They assert the security invariant:
  # NO `PGPASSWORD` and NO cleartext password in the child env; a `PGPASSFILE`
  # pointing at a 0600 file is present.
  #
  # Red-proof: revert `with_pgpass/2` to set `PGPASSWORD` (the pre-fix behavior)
  # and the `refute PGPASSWORD` / `refute cleartext password` assertions fail.

  @password "super-secret-pw-#{System.unique_integer([:positive])}"

  describe "M6 security regression — pg credentials use PGPASSFILE, not PGPASSWORD" do
    test "pg_dump (via Backup.backup/1) receives PGPASSFILE 0600 and no PGPASSWORD" do
      %{tmp: tmp, bin: bin, backup_dir: backup_dir, age_key: age_key, env_dump: env_dump} =
        setup_stub_env(["pg_dump"])

      with_patched_env(bin, fn ->
        assert {:ok, _path} =
                 Backup.backup(backup_dir: backup_dir, age_key_file: age_key, skip_cleanup: true)

        assert_pgpass_invariant(env_dump)
      end)

      File.rm_rf!(tmp)
    end

    test "pg_restore (via Backup.restore/2) receives PGPASSFILE 0600 and no PGPASSWORD" do
      %{tmp: tmp, bin: bin, backup_dir: backup_dir, age_key: age_key, env_dump: env_dump} =
        setup_stub_env(["pg_restore"])

      # restore decrypts a backup file via the stubbed `age`, so a file must exist.
      backup_name = "arbor-2026-01-30-100000.sql.age"
      File.write!(Path.join(backup_dir, backup_name), "ciphertext")

      with_patched_env(bin, fn ->
        assert :ok =
                 Backup.restore(backup_name,
                   backup_dir: backup_dir,
                   age_key_file: age_key,
                   private_key: age_key
                 )

        assert_pgpass_invariant(env_dump)
      end)

      File.rm_rf!(tmp)
    end
  end

  # --- assertions -----------------------------------------------------------

  defp assert_pgpass_invariant(env_dump) do
    recorded = File.read!(env_dump)

    # The fix's invariant: no PGPASSWORD, no cleartext password in the child env.
    refute String.contains?(recorded, "PGPASSWORD"),
           "pg command was given PGPASSWORD env var (M6 regression):\n#{recorded}"

    refute String.contains?(recorded, @password),
           "database password leaked into pg command env (M6 regression)"

    # And it DOES pass a PGPASSFILE pointing at a 0600 file.
    assert String.contains?(recorded, "PGPASSFILE="),
           "pg command did not receive PGPASSFILE:\n#{recorded}"

    # macOS `stat -f %Lp` reports just the perm bits ("600"); GNU `stat -c %a`
    # likewise. Either way the trailing permission bits must be 600 (0600).
    assert recorded =~ ~r/PGPASS_MODE=0?0?600\b/,
           "PGPASSFILE was not chmod 0600:\n#{recorded}"
  end

  # --- stub environment -----------------------------------------------------

  defp setup_stub_env(pg_commands) do
    tmp = Path.join(System.tmp_dir!(), "m6_pgpass_#{:erlang.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    backup_dir = Path.join(tmp, "backups")
    File.mkdir_p!(bin)
    File.mkdir_p!(backup_dir)

    env_dump = Path.join(tmp, "pg_env.txt")

    # Stub each pg command: record its env + the mode of the PGPASSFILE it was
    # handed, create any --file= target so the surrounding pipeline proceeds,
    # then succeed.
    for cmd <- pg_commands do
      write_executable(Path.join(bin, cmd), """
      #!/bin/sh
      env > "#{env_dump}"
      if [ -n "$PGPASSFILE" ] && [ -f "$PGPASSFILE" ]; then
        # %Lp = octal file mode incl. type bits, e.g. 100600
        mode=$(stat -f '%Lp' "$PGPASSFILE" 2>/dev/null || stat -c '%a' "$PGPASSFILE" 2>/dev/null)
        echo "PGPASS_MODE=$mode" >> "#{env_dump}"
      fi
      for a in "$@"; do
        case "$a" in
          --file=*) touch "${a#--file=}" ;;
        esac
      done
      exit 0
      """)
    end

    # Stub `age`: copy last positional arg (input) to the `-o OUT` path so both
    # encrypt (backup) and decrypt (restore) "succeed".
    write_executable(Path.join(bin, "age"), """
    #!/bin/sh
    out=""
    prev=""
    last=""
    for a in "$@"; do
      if [ "$prev" = "-o" ]; then out="$a"; fi
      prev="$a"
      last="$a"
    done
    cp "$last" "$out" 2>/dev/null || touch "$out"
    exit 0
    """)

    age_key = Path.join(tmp, "key.txt")
    File.write!(age_key, "fake-age-recipient")

    %{tmp: tmp, bin: bin, backup_dir: backup_dir, age_key: age_key, env_dump: env_dump}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp with_patched_env(bin, fun) do
    orig_path = System.get_env("PATH")
    orig_repo = Application.get_env(:arbor_persistence, Arbor.Persistence.Repo)

    System.put_env("PATH", bin <> ":" <> orig_path)

    Application.put_env(:arbor_persistence, Arbor.Persistence.Repo,
      database: "arbor_test_db",
      hostname: "localhost",
      port: 5432,
      username: "postgres",
      password: @password
    )

    try do
      fun.()
    after
      System.put_env("PATH", orig_path)

      if orig_repo do
        Application.put_env(:arbor_persistence, Arbor.Persistence.Repo, orig_repo)
      else
        Application.delete_env(:arbor_persistence, Arbor.Persistence.Repo)
      end
    end
  end
end
