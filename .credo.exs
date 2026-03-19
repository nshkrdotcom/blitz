%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: ["deps/", "_build/"]
      },
      strict: true,
      requires: [],
      checks: [
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Readability.ModuleDoc, false}
      ]
    }
  ]
}
