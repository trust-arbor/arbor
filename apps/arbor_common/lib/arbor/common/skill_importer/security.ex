defmodule Arbor.Common.SkillImporter.Security do
  @moduledoc """
  Consumer-owned port for imported-skill security validation.

  Library-specific to `arbor_common`. Implementations live above this
  library and are injected via `Arbor.Common.Config.skill_import_security_module/0`.

  Common-owned errors:

  - `:blocked` — the skill failed a security screen
  - `:invalid_skill` — the input is not a skill map
  - `:malformed_reflex_result` — the producer returned a non-admitted screen shape
  - `:reflex_unavailable` — the producer could not complete the screen
  """

  @type error_reason ::
          :blocked | :invalid_skill | :malformed_reflex_result | :reflex_unavailable

  @callback validate_imported_skill(map()) :: :ok | {:error, error_reason()}
end
