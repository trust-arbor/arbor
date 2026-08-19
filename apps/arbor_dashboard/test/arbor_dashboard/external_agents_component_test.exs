defmodule Arbor.Dashboard.Components.ExternalAgentsComponentTest do
  use ExUnit.Case, async: false

  alias Arbor.Dashboard.Components.ExternalAgentsComponent
  alias Phoenix.LiveView.Socket

  @moduletag :fast

  describe "register without principal" do
    test "fails closed when the socket has no authenticated principal" do
      socket =
        %Socket{}
        |> Phoenix.Component.assign(:current_agent_id, nil)
        |> Phoenix.Component.assign(:tenant_context, nil)
        |> Phoenix.Component.assign(:external_agents_error, nil)
        |> Phoenix.Component.assign(:just_registered, nil)
        |> Phoenix.Component.assign(:show_register_form, false)
        |> Phoenix.Component.assign(:agent_types, [])
        |> Phoenix.Component.assign(:editing_agent_id, nil)
        |> Phoenix.Component.assign(:external_agents_state, %{owner_agent_id: nil, rows: []})

      updated =
        ExternalAgentsComponent.update_external_agents(socket, "submit_registration", %{
          "display_name" => "Should Fail",
          "agent_type" => "external"
        })

      assert updated.assigns.just_registered == nil
      assert updated.assigns.external_agents_error =~ "Sign in"
    end
  end

  describe "save_key_file/2" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "arbor-ext-keys-#{System.unique_integer([:positive])}"
        )

      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "writes ~/.arbor/keys-style path at mode 0600", %{dir: dir} do
      view = %{
        display_name: "Claude On Phone",
        agent_id: "agent_abcdef123456",
        private_key_b64: "cHJpdmF0ZQ=="
      }

      assert {:ok, path} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true
               )

      assert Path.basename(path) == "claude_on_phone_abcdef12.arbor.key"
      assert File.read!(path) =~ "agent_id=agent_abcdef123456"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "does not overwrite on collision", %{dir: dir} do
      view = %{
        display_name: "Claude On Phone",
        agent_id: "agent_abcdef123456",
        private_key_b64: "first"
      }

      assert {:ok, path} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true
               )

      File.write!(path, "do-not-clobber\n")

      assert {:error, :collision} =
               ExternalAgentsComponent.save_key_file(
                 %{view | private_key_b64: "second"},
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true
               )

      assert File.read!(path) == "do-not-clobber\n"
    end

    test "does not save when auto-save is disabled or outside local-dev", %{dir: dir} do
      view = %{
        display_name: "Claude",
        agent_id: "agent_abcdef12",
        private_key_b64: "QQ=="
      }

      assert {:error, :disabled} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: false
               )

      assert {:error, :disabled} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: false,
                 enabled: true
               )

      assert File.ls!(dir) == []
    end

    test "returns {:error, _} when the keys dir cannot be created", %{dir: dir} do
      blocker = Path.join(dir, "not-a-directory")
      File.write!(blocker, "file")

      view = %{
        display_name: "Claude",
        agent_id: "agent_abcdef12",
        private_key_b64: "QQ=="
      }

      assert {:error, reason} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: Path.join(blocker, "keys"),
                 local_dev: true,
                 enabled: true
               )

      assert reason not in [:disabled, :collision]
    end

    test "returns {:error, _} when chmod fails and does not leave the key file", %{dir: dir} do
      view = %{
        display_name: "Claude",
        agent_id: "agent_abcdef12",
        private_key_b64: "QQ=="
      }

      assert {:error, :eperm} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true,
                 chmod: fn _path, _mode -> {:error, :eperm} end
               )

      assert File.ls!(dir) == []
    end

    test "returns {:error, _} when mkdir_p fails without raising", %{dir: dir} do
      view = %{
        display_name: "Claude",
        agent_id: "agent_abcdef12",
        private_key_b64: "QQ=="
      }

      assert {:error, :enotdir} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true,
                 mkdir_p: fn _path -> {:error, :enotdir} end
               )

      assert File.ls!(dir) == []
    end

    test "returns {:error, _} when mkdir_p raises instead of crashing", %{dir: dir} do
      view = %{
        display_name: "Claude",
        agent_id: "agent_abcdef12",
        private_key_b64: "QQ=="
      }

      assert {:error, %RuntimeError{message: "mkdir boom"}} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true,
                 mkdir_p: fn _path -> raise "mkdir boom" end
               )

      assert File.ls!(dir) == []
    end

    test "returns {:error, _} when mkdir_p throws instead of crashing", %{dir: dir} do
      view = %{
        display_name: "Claude",
        agent_id: "agent_abcdef12",
        private_key_b64: "QQ=="
      }

      assert {:error, {:throw, :mkdir_boom}} =
               ExternalAgentsComponent.save_key_file(view,
                 keys_dir: dir,
                 local_dev: true,
                 enabled: true,
                 mkdir_p: fn _path -> throw(:mkdir_boom) end
               )

      assert File.ls!(dir) == []
    end
  end
end
