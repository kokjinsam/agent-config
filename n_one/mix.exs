defmodule NOne.MixProject do
  use Mix.Project

  def project do
    [
      app: :n_one,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:telemetry, "1.3.0"},
      {:plug, "1.16.1", optional: true}
    ]
  end
end
