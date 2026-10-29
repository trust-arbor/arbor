defmodule Arbor.Agent.XaiVoiceAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "KSEC-004,SSEC-004"

  @moduletag :fast

  alias Arbor.Agent.Prototypes.XaiVoiceOrchestrator

  @tag spec: "KSEC-004,SSEC-004"
  test "security regression: prototype rejects missing actor authority before file or network effects" do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    missing = Path.join(system_tmp, "xai-voice-missing-#{token}.pcm")

    refute File.exists?(missing)

    assert {:error, :capability_mutation_unauthorized} =
             XaiVoiceOrchestrator.converse_audio_file(missing)
  end

  test "security regression: mic capture is not a fixed shared /tmp path" do
    beam =
      case :code.get_object_code(XaiVoiceOrchestrator) do
        {:module, _mod, bin, _filename} ->
          bin

        :error ->
          File.read!(:code.which(XaiVoiceOrchestrator))
      end

    assert :binary.match(beam, "/tmp/arbor_mic_in.pcm") == :nomatch
  end
end
