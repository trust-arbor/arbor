defmodule Arbor.Scheduler.IdentityAuthorityExportSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-013"

  alias Arbor.Scheduler.Identity

  @moduletag :fast
  @moduletag :security_regression

  defmodule HandlerHarness do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Identity)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(request, from, state), do: Identity.handle_call(request, from, state)
  end

  @tag spec: "SSEC-002,SSEC-013"
  test "security regression: raw callers cannot retrieve the scheduler signing authority" do
    authority = make_ref()
    start_supervised!({HandlerHarness, %{signing_authority: authority}})

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)
  end
end
