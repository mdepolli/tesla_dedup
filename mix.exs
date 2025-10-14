defmodule TeslaDedup.MixProject do
  use Mix.Project

  @name "TeslaDedup"
  @version "0.1.0"
  @source_url "https://github.com/mdepolli/tesla_dedup"

  def project do
    [
      app: :tesla_dedup,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: @name,
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {TeslaDedup.Application, []}
    ]
  end

  defp deps do
    [
      {:tesla, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # Dev/Test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:hackney, "~> 1.18", only: :test}
    ]
  end

  defp description do
    """
    Tesla middleware for request deduplication - Prevents concurrent identical HTTP requests from causing
    unexpected side effects such as double charges, duplicate orders, or race conditions.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Marcelo De Polli"]
    ]
  end

  defp docs do
    [
      main: @name,
      extras: ["README.md", "CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
