defmodule EctoIsolator.Error do
  @moduledoc """
  Raised when an unsafe operation is detected and reporting mode is `:raise`.
  """

  defexception [:offense, :message]

  alias EctoIsolator.Offense

  @impl Exception
  def exception(%Offense{} = offense) do
    %__MODULE__{offense: offense, message: Offense.format(offense)}
  end
end
