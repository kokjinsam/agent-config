defmodule EctoIsolator.Config do
  @moduledoc false

  def repos do
    Application.get_env(:ecto_isolator, :repos, [])
  end

  def mode do
    Process.get(:ecto_isolator_mode) || Application.get_env(:ecto_isolator, :mode, :raise)
  end

  def ignore_rules do
    Application.get_env(:ecto_isolator, :ignore, [])
  end
end
