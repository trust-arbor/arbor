# Used by "mix format"
# The root hook passes standalone/vendor files explicitly. Import Breeze's
# exported Elixir DSL options without loading its standalone HTML plugin here.
{breeze_formatter, _binding} =
  Code.eval_file(Path.join(__DIR__, "clients/arbor_breeze/vendor/breeze/.formatter.exs"))

breeze_locals =
  breeze_formatter
  |> Keyword.fetch!(:export)
  |> Keyword.fetch!(:locals_without_parens)

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: breeze_locals,
  subdirectories: ["apps/*"]
]
