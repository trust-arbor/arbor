defmodule Arbor.Security.Host.SkillSecurity do
  @moduledoc "Product implementation of Common's imported-skill security port."

  use Boundary, top_level?: true, deps: [Arbor.Security, Arbor.Common], exports: []

  @behaviour Arbor.Common.SkillImporter.Security

  @impl true
  defdelegate validate_imported_skill(skill), to: Arbor.Security
end
