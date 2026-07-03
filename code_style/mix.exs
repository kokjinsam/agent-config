defmodule CodeStyle.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_style,
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
      {:credo, "1.7.18", runtime: false}
    ]
  end
end
