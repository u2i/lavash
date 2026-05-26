defmodule Lavash.MixProject do
  use Mix.Project

  @version "0.4.0-rc.3"
  @source_url "https://github.com/u2i/lavash"

  def project do
    [
      app: :lavash,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit]
      ],

      # Hex
      name: "Lavash",
      description: "Declarative state management for Phoenix LiveView, built for Ash Framework",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Lavash.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:spark, "~> 2.0"},
      {:phoenix_live_view, "~> 1.2-rc"},
      {:ash, "~> 3.0"},
      {:ash_phoenix, "~> 2.0"},
      {:typeid_elixir, "~> 1.1"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5", only: :test},
      {:deno_rider, "~> 0.2", only: :test},
      # Browser-driven integration tests. Wallabidi is started manually in
      # test_helper.exs only for e2e runs because its Application.start raises
      # if Chrome isn't installed (we use Lightpanda, which gets configured
      # before Wallabidi starts).
      {:wallabidi, "0.4.0-rc.4", only: :test, runtime: false},
      {:lightpanda, "~> 0.3", only: :test, runtime: false},
      # Code quality
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sourceror, "~> 1.0", only: [:dev, :test], runtime: false},
      # Docs
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Tom Marrs"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/ARCHITECTURE.md",
        "docs/ACTION_LIFECYCLE.md",
        "docs/STREAMING.md"
      ],
      groups_for_modules: [
        Core: [
          Lavash.LiveView,
          Lavash.Component,
          Lavash.Dsl
        ],
        "State Management": [
          Lavash.Socket,
          Lavash.State,
          Lavash.Graph,
          Lavash.Assigns
        ],
        "Optimistic Updates": [
          Lavash.Optimistic
        ],
        Overlays: [
          Lavash.Overlay,
          Lavash.Overlay.Modal,
          Lavash.Overlay.Modal.Dsl,
          Lavash.Overlay.Modal.Helpers
        ],
        PubSub: [
          Lavash.PubSub,
          Lavash.Resource
        ],
        Types: [
          Lavash.Type
        ]
      ]
    ]
  end
end
