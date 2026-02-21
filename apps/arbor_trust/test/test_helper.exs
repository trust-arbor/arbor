# Trust tests manage their own processes via start_supervised!/start_link
# No global processes needed here.
ExUnit.start(exclude: [:llm, :llm_local])
