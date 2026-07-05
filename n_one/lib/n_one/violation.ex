defmodule NOne.Violation do
  @moduledoc """
  Raised when `NOne.watch/3` runs in `:raise` mode and finds repeated queries.
  """

  defexception [:message, :report]

  def exception(%NOne.Report{} = report) do
    %__MODULE__{message: NOne.Report.message(report), report: report}
  end
end
