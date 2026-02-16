defmodule Arbor.Actions.Judge.Rubrics do
  @moduledoc """
  Preset rubric factories for common evaluation domains.

  Provides ready-to-use rubrics for advisory council output, code generation,
  and custom domains. Each rubric defines weighted dimensions that guide
  the judge's evaluation.
  """

  alias Arbor.Contracts.Judge.Rubric

  @doc """
  Rubric for evaluating advisory council responses.

  Six dimensions balanced across analytical depth, relevance,
  actionability, accuracy, originality, and calibration.
  """
  @spec advisory() :: Rubric.t()
  def advisory do
    %Rubric{
      domain: "advisory",
      version: 1,
      dimensions: [
        %{name: :depth, weight: 0.20, description: "Analytical depth and rigor"},
        %{name: :perspective_relevance, weight: 0.20, description: "Stays on assigned perspective topic"},
        %{name: :actionability, weight: 0.20, description: "Concrete, implementable recommendations"},
        %{name: :accuracy, weight: 0.15, description: "Technical claims correct and well-grounded"},
        %{name: :originality, weight: 0.15, description: "Unique insights beyond obvious observations"},
        %{name: :calibration, weight: 0.10, description: "Confidence matches actual certainty"}
      ]
    }
  end

  @doc """
  Rubric for evaluating generated code quality.

  Six dimensions covering correctness, style, completeness,
  efficiency, safety, and documentation.
  """
  @spec code() :: Rubric.t()
  def code do
    %Rubric{
      domain: "code",
      version: 1,
      dimensions: [
        %{name: :correctness, weight: 0.30, description: "Code produces correct output and handles edge cases"},
        %{name: :style, weight: 0.15, description: "Follows language idioms and project conventions"},
        %{name: :completeness, weight: 0.20, description: "All requirements addressed, no missing pieces"},
        %{name: :efficiency, weight: 0.10, description: "Reasonable time/space complexity"},
        %{name: :safety, weight: 0.15, description: "No security vulnerabilities or unsafe patterns"},
        %{name: :documentation, weight: 0.10, description: "Clear comments and docstrings where needed"}
      ]
    }
  end

  @doc """
  Get a preset rubric by domain name.

  Returns `{:ok, rubric}` for known domains, `{:error, :unknown_domain}` otherwise.
  """
  @spec for_domain(String.t()) :: {:ok, Rubric.t()} | {:error, :unknown_domain}
  def for_domain("advisory"), do: {:ok, advisory()}
  def for_domain("code"), do: {:ok, code()}
  def for_domain(_), do: {:error, :unknown_domain}

  @doc """
  List all available preset domain names.
  """
  @spec available_domains() :: [String.t()]
  def available_domains, do: ["advisory", "code"]
end
