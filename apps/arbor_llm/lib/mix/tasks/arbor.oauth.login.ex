defmodule Mix.Tasks.Arbor.Oauth.Login do
  @shortdoc "Alias for mix arbor.login"
  @moduledoc false

  use Mix.Task

  @impl true
  def run(args), do: Mix.Tasks.Arbor.Login.run(args)
end
