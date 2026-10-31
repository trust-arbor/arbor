defmodule Arbor.Historian.HostAdoptionTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  test "product host is passive and canonical Historian owns the authority application" do
    assert Application.spec(:arbor_historian_host, :mod) in [nil, []]
    assert Application.spec(:arbor_historian_host, :registered) in [nil, []]
    applications = Application.spec(:arbor_historian_host, :applications)
    assert :arbor_kernel_runtime in applications
    assert :arbor_historian in applications

    assert Enum.find_index(applications, &(&1 == :arbor_kernel_runtime)) <
             Enum.find_index(applications, &(&1 == :arbor_historian))

    for module <- [
          Arbor.Historian,
          Arbor.Historian.Application,
          Arbor.Historian.AuthorityAuditPuller
        ] do
      assert Application.get_application(module) == :arbor_historian
      refute module in (Application.spec(:arbor_historian_host, :modules) || [])
    end

    assert Application.get_application(Arbor.Historian.Adapters.SecurityEventLog) ==
             :arbor_historian_host

    assert Application.spec(:arbor_historian, :mod) == {Arbor.Historian.Application, []}

    for omitted <- [
          :arbor_capabilities,
          :arbor_security,
          :arbor_kernel_runtime,
          :arbor_signals,
          :arbor_persistence_host,
          :arbor_persistence_sql,
          :ecto_sql
        ] do
      for key <- [:applications, :optional_applications, :included_applications] do
        refute omitted in (Application.spec(:arbor_historian, key) || [])
      end
    end
  end
end
