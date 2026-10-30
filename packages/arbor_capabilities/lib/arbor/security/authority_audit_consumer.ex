defmodule Arbor.Security.AuthorityAuditConsumer do
  @moduledoc false

  alias Arbor.Security.Config
  alias Arbor.Security.SupervisedOwner

  @spec authorized?(pid()) :: boolean()
  def authorized?(caller) when is_pid(caller) do
    name = Config.authority_audit_consumer_name()
    application = Config.authority_audit_consumer_application()

    is_atom(name) and not is_nil(name) and Process.whereis(name) == caller and
      authorized_provenance?(caller, application, name)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def authorized?(_caller), do: false

  if Mix.env() == :test do
    defp authorized_provenance?(_caller, :test, _name), do: true
  end

  defp authorized_provenance?(caller, application, child_id) when is_atom(application) do
    SupervisedOwner.authorized?(caller, application, [child_id])
  end

  defp authorized_provenance?(_caller, _application, _child_id), do: false
end
