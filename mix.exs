defmodule Blitz.MixProject do
  use Mix.Project

  def project do
    [
      app: :blitz,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      preferred_cli_env: preferred_cli_env(),
      dialyzer: dialyzer(),
      deps: deps(),
      description: "Parallel command runner and Mix workspace orchestrator for Elixir tooling",
      package: package(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/blitz"},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/blitz.svg",
      homepage_url: "https://github.com/nshkrdotcom/blitz",
      source_url: "https://github.com/nshkrdotcom/blitz",
      assets: %{"assets" => "assets"},
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        "Project Documents": ~r/README.md|CHANGELOG.md|LICENSE/
      ]
    ]
  end

  defp preferred_cli_env do
    [
      credo: :test,
      dialyzer: :dev
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_local_path: "priv/plts",
      flags: [:error_handling, :missing_return, :underspecs, :unknown]
    ]
  end
end
