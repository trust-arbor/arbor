defmodule Arbor.Gateway.PromptClassifier do
  @moduledoc """
  Pre-processes prompts by classifying sensitive data and recommending routing.

  Thin wrapper around `Arbor.Common.SensitiveData` that maps scan findings
  to taint tags, sensitivity levels, and routing recommendations. This is
  Phase 1 of the Prompt Pre-Processor pipeline.

  ## Usage

      result = Arbor.Gateway.PromptClassifier.classify("deploy the app to staging")
      result.overall_sensitivity   #=> :public
      result.routing_recommendation #=> :any

  When sensitive data is detected, findings are returned with redacted text
  and appropriate routing/taint recommendations.

  """

  alias Arbor.Common.SensitiveData

  @type sensitivity :: :public | :internal | :confidential | :restricted
  @type routing :: :any | :local_preferred | :local_only

  @type classification :: %{
          findings: [{String.t(), String.t()}],
          sanitized_prompt: String.t(),
          overall_sensitivity: sensitivity(),
          routing_recommendation: routing(),
          taint_tags: %{pii: boolean(), credentials: boolean(), code: boolean(), internal: boolean()},
          element_count: non_neg_integer()
        }

  @restricted_labels MapSet.new([
    "Private Key",
    "AWS Secret Key",
    "Database Connection String",
    "US Social Security Number",
    "Credit Card Number"
  ])

  @confidential_labels MapSet.new([
    "Password in Config",
    "AWS Access Key",
    "Anthropic API Key",
    "OpenAI API Key",
    "Stripe Key",
    "GitHub Token",
    "GitHub Fine-Grained PAT",
    "GitLab PAT",
    "Slack Token",
    "JWT Token",
    "High-Entropy Base64"
  ])

  @pii_labels MapSet.new([
    "Email Address",
    "Phone Number",
    "Credit Card Number",
    "US Social Security Number",
    "IP Address",
    "Hardcoded User Path"
  ])

  @credential_labels MapSet.new([
    "AWS Access Key",
    "AWS Secret Key",
    "Anthropic API Key",
    "OpenAI API Key",
    "GitHub Token",
    "GitHub Fine-Grained PAT",
    "GitLab PAT",
    "Slack Token",
    "Google API Key",
    "Stripe Key",
    "Private Key",
    "JWT Token",
    "Database Connection String",
    "Bearer Token",
    "Password in Config",
    "API Key/Token",
    "High-Entropy Base64"
  ])

  @doc """
  Classify a prompt for sensitive data, returning findings, sanitized text,
  sensitivity level, routing recommendation, and taint tags.
  """
  @spec classify(String.t(), keyword()) :: classification()
  def classify(prompt, opts \\ []) when is_binary(prompt) do
    findings = SensitiveData.scan_all(prompt, opts)
    sanitized = if findings == [], do: prompt, else: SensitiveData.redact(prompt)
    sensitivity = max_sensitivity(findings)

    %{
      findings: findings,
      sanitized_prompt: sanitized,
      overall_sensitivity: sensitivity,
      routing_recommendation: route_for(sensitivity),
      taint_tags: findings_to_taint(findings),
      element_count: length(findings)
    }
  end

  @doc """
  Quick check — does this prompt contain any sensitive data?
  """
  @spec sensitive?(String.t()) :: boolean()
  def sensitive?(prompt) when is_binary(prompt) do
    SensitiveData.scan_all(prompt) != []
  end

  @doc """
  Return just the routing recommendation without full classification.
  """
  @spec routing_for(String.t()) :: routing()
  def routing_for(prompt) when is_binary(prompt) do
    findings = SensitiveData.scan_all(prompt)
    findings |> max_sensitivity() |> route_for()
  end

  # -- Sensitivity ranking --

  defp max_sensitivity([]), do: :public

  defp max_sensitivity(findings) do
    findings
    |> Enum.map(fn {label, _match} -> label_to_sensitivity(label) end)
    |> Enum.max_by(&sensitivity_rank/1)
  end

  defp label_to_sensitivity(label) do
    cond do
      MapSet.member?(@restricted_labels, label) -> :restricted
      MapSet.member?(@confidential_labels, label) -> :confidential
      true -> :internal
    end
  end

  defp sensitivity_rank(:restricted), do: 3
  defp sensitivity_rank(:confidential), do: 2
  defp sensitivity_rank(:internal), do: 1
  defp sensitivity_rank(:public), do: 0

  # -- Routing --

  defp route_for(:restricted), do: :local_only
  defp route_for(:confidential), do: :local_preferred
  defp route_for(_), do: :any

  # -- Taint tag mapping --

  defp findings_to_taint([]) do
    %{pii: false, credentials: false, code: false, internal: false}
  end

  defp findings_to_taint(findings) do
    labels = findings |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    %{
      pii: Enum.any?(labels, &MapSet.member?(@pii_labels, &1)),
      credentials: Enum.any?(labels, &MapSet.member?(@credential_labels, &1)),
      code: false,
      internal: MapSet.size(labels) > 0
    }
  end
end
