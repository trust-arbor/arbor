defmodule Arbor.Security.HomeCredentialReflexSecurityRegressionTest do
  @moduledoc """
  Security regression: a HOME-rooted file grant must not read or write
  credential files that shell containment already treats as protected.

  Exposure Check item AJ: `ssh_config`, `aws_credentials`, and other
  home credential paths used to warn, so `authorize/4` admitted the
  request after the warning. The public gate must deny (not warn) for
  `~`, `$HOME`, and symlink spellings.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Common.SafePath
  alias Arbor.Security
  alias Arbor.Security.FileGuard
  alias Arbor.Security.Reflex

  # Every home-relative credential path the shell protects and reflexes
  # must now block. Directory entries are authorized through a nested file
  # that a HOME-rooted grant would otherwise cover.
  @credential_targets [
    %{id: "aws_credentials", relative: ".aws/credentials", kind: :file},
    %{id: "aws_config", relative: ".aws/config", kind: :file},
    %{id: "ssh_config", relative: ".ssh/config", kind: :file},
    %{id: "azure_credentials", relative: ".azure/accessTokens.json", kind: :file},
    %{id: "gcloud_config", relative: ".config/gcloud/credentials.db", kind: :file},
    %{id: "kube_config", relative: ".kube/config", kind: :file},
    %{id: "docker_config", relative: ".docker/config.json", kind: :file},
    %{id: "netrc", relative: ".netrc", kind: :file},
    %{id: "npm_tokens", relative: ".npmrc", kind: :file},
    %{id: "pypirc", relative: ".pypirc", kind: :file},
    %{id: "gnupg", relative: ".gnupg/trustdb.gpg", kind: :file}
  ]

  setup do
    previous_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    previous_home = System.get_env("HOME")
    Application.put_env(:arbor_security, :reflex_checking_enabled, true)

    home_root =
      Path.join(
        System.tmp_dir!(),
        "arbor-home-cred-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir_p!(home_root)
    {:ok, home} = SafePath.resolve_real(home_root)
    System.put_env("HOME", home)

    for %{relative: relative} <- @credential_targets do
      path = Path.join(home, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "synthetic-credential\n")
    end

    symlink = Path.join(home, "looks_safe.txt")
    File.ln_s!(Path.join(home, ".aws/credentials"), symlink)

    agent_id = "agent_home_cred_#{System.unique_integer([:positive])}"

    {:ok, read_cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: FileGuard.resource_uri(:read, home <> "/**")
      )

    {:ok, write_cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: FileGuard.resource_uri(:write, home <> "/**")
      )

    on_exit(fn ->
      Security.revoke_fixture(read_cap.id)
      Security.revoke_fixture(write_cap.id)
      restore_env(:reflex_checking_enabled, previous_reflex)
      restore_home(previous_home)
      File.rm_rf!(home_root)
    end)

    %{agent_id: agent_id, home: home, symlink: symlink}
  end

  test "security regression: HOME-grant read of .aws/credentials is denied not warned", %{
    agent_id: agent_id,
    home: home,
    symlink: symlink
  } do
    credentials = Path.join(home, ".aws/credentials")

    for {label, opts} <- [
          {"absolute", [resource: FileGuard.resource_uri(:read, credentials)]},
          {"tilde", [resource: "arbor://fs/read", file_path: "~/.aws/credentials"]},
          {"home", [resource: "arbor://fs/read", file_path: "$HOME/.aws/credentials"]},
          {"symlink", [resource: FileGuard.resource_uri(:read, symlink)]}
        ] do
      result = authorize(agent_id, opts, :read)

      assert match?({:error, {:reflex_blocked, _id, _message}}, result),
             "#{label} spelling authorized or warned instead of blocking: #{inspect(result)}"

      {:error, {:reflex_blocked, id, message}} = result
      assert is_binary(id)
      assert message =~ "Blocked"
      refute message =~ "Warning"
    end
  end

  test "security regression: HOME-grant write of .aws/credentials is denied not warned", %{
    agent_id: agent_id,
    home: home
  } do
    credentials = Path.join(home, ".aws/credentials")

    result =
      authorize(
        agent_id,
        [resource: FileGuard.resource_uri(:write, credentials)],
        :write
      )

    assert {:error, {:reflex_blocked, _id, message}} = result
    assert message =~ "Blocked"
    refute message =~ "Warning"
  end

  test "security regression: every shell-protected credential path is blocked for read and write",
       %{agent_id: agent_id, home: home} do
    for %{id: expected_id, relative: relative} <- @credential_targets do
      path = Path.join(home, relative)

      for {operation, action} <- [read: :read, write: :write] do
        result =
          authorize(
            agent_id,
            [resource: FileGuard.resource_uri(operation, path)],
            action
          )

        assert {:error, {:reflex_blocked, id, message}} = result,
               "#{relative} #{operation} leaked through: #{inspect(result)}"

        assert id == expected_id
        assert message =~ "Blocked"
        refute message =~ "Warning"
      end
    end
  end

  test "security regression: ~ and $HOME spellings block every credential path", %{
    agent_id: agent_id
  } do
    for %{id: expected_id, relative: relative} <- @credential_targets do
      tilde = Path.join("~", relative)
      home_var = Path.join("$HOME", relative)

      for file_path <- [tilde, home_var] do
        result =
          authorize(
            agent_id,
            [resource: "arbor://fs/read", file_path: file_path],
            :read
          )

        assert {:error, {:reflex_blocked, ^expected_id, message}} = result,
               "#{file_path} leaked through: #{inspect(result)}"

        assert message =~ "Blocked"
      end
    end
  end

  test "security regression: direct reflex check blocks rather than warns", %{home: home} do
    path = Path.join(home, ".aws/credentials")
    aws = Enum.find(Reflex.list(), &(&1.id == "aws_credentials"))
    assert aws
    assert aws.response == :block
    assert aws.type == :custom

    for candidate <- ["~/.aws/credentials", "$HOME/.aws/credentials", path] do
      result = Reflex.check(%{path: candidate})

      assert {:blocked, reflex, message} = result,
             "check(#{inspect(candidate)}) => #{inspect(result)} HOME=#{inspect(System.get_env("HOME"))}"

      assert reflex.response == :block
      assert message =~ "Blocked"
    end
  end

  defp authorize(agent_id, opts, action) do
    resource = Keyword.fetch!(opts, :resource)

    Security.authorize(
      agent_id,
      resource,
      action,
      opts
      |> Keyword.delete(:resource)
      |> Keyword.put(:verify_identity, false)
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)

  defp restore_home(nil), do: System.delete_env("HOME")
  defp restore_home(value), do: System.put_env("HOME", value)
end
