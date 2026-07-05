defmodule NOne.ExUnit do
  @moduledoc """
  ExUnit helpers for asserting that an operation did not repeat query fingerprints.
  """

  defmacro assert_no_repeated_queries(operation, opts) do
    {block, opts} = Keyword.pop(opts, :do)
    build_assertion(operation, opts, block)
  end

  defmacro assert_no_repeated_queries(operation, opts, do: block) do
    build_assertion(operation, opts, block)
  end

  defp build_assertion(operation, opts, block) do
    quote do
      {result, report} =
        NOne.collect(unquote(operation), unquote(opts), fn ->
          unquote(block)
        end)

      if NOne.Report.violation?(report) do
        ExUnit.Assertions.flunk(NOne.Report.message(report))
      end

      result
    end
  end
end
