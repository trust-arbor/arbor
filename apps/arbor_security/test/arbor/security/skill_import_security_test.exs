defmodule Arbor.Security.SkillImportSecurityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security

  @metadata_url "http://169.254.169.254/latest/meta-data/"

  test "admits a clean imported skill" do
    assert :ok =
             Security.validate_imported_skill(%{
               name: "ok-skill",
               body: "Review this change carefully."
             })
  end

  test "admits a warned skill whose body mentions localhost" do
    assert :ok =
             Security.validate_imported_skill(%{
               name: "local-skill",
               body: "see http://localhost:8080/api"
             })
  end

  test "rejects a skill whose body contains the cloud-metadata URL" do
    assert {:error, :blocked} =
             Security.validate_imported_skill(%{
               name: "meta-skill",
               body: @metadata_url
             })
  end

  test "rejects a non-map skill" do
    assert {:error, :invalid_skill} = Security.validate_imported_skill("nope")
  end

  test "returns reflex_unavailable when Reflex.check cannot run" do
    child_id = Arbor.Security.Reflex.Registry

    on_exit(fn -> restore_registry(child_id) end)

    assert :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, child_id)

    assert {:error, :reflex_unavailable} =
             Security.validate_imported_skill(%{name: "ok-skill", body: "hello"})
  end

  defp restore_registry(child_id) do
    case Supervisor.restart_child(Arbor.Security.Supervisor, child_id) do
      {:ok, _pid} ->
        :ok

      {:error, :running} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      _other ->
        _ = Supervisor.start_child(Arbor.Security.Supervisor, {child_id, []})
        :ok
    end
  end
end
