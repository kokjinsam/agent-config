defmodule CodeStyle.Check.Warning.RepoInsideLoop do
  @moduledoc false

  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check: """
      Avoid calling Repo from inside collection loops.

      Repo calls inside Enum, Stream, or for-comprehension bodies often create
      N+1 query behavior. Load or batch the data before iterating instead.
      """
    ]

  @enum_functions ~w(each filter flat_map map reduce)a
  @stream_functions ~w(each filter flat_map map)a

  @repo_functions ~w(
    aggregate all delete delete! exists? get get! get_by get_by! insert insert!
    one one! preload query query! stream transaction update update!
  )a

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&walk/2, {issue_meta, MapSet.new(), []})
    |> elem(2)
    |> Enum.reverse()
  end

  defp walk({:for, meta, args} = ast, {issue_meta, seen, issues}) when is_list(args) do
    body = block_body(args)
    {seen, issues} = issues_in_loop(body, issue_meta, seen, issues, meta)

    {ast, {issue_meta, seen, issues}}
  end

  defp walk({{:., _dot_meta, [module_ast, function_name]}, meta, args} = ast, acc)
       when is_list(args) and is_atom(function_name) do
    if loop_call?(module_ast, function_name) do
      {issue_meta, seen, issues} = acc

      args
      |> callback_args(module_ast, function_name)
      |> Enum.reduce({seen, issues}, fn callback_ast, {seen, issues} ->
        issues_in_loop(callback_ast, issue_meta, seen, issues, meta)
      end)
      |> then(fn {seen, issues} -> {ast, {issue_meta, seen, issues}} end)
    else
      {ast, acc}
    end
  end

  defp walk(ast, acc), do: {ast, acc}

  defp loop_call?(module_ast, function_name) do
    case alias_segments(module_ast) do
      [:Enum] -> function_name in @enum_functions
      [:Stream] -> function_name in @stream_functions
      _other -> false
    end
  end

  defp callback_args(args, module_ast, function_name) do
    case {alias_segments(module_ast), function_name, args} do
      {[:Enum], :reduce, [_enum, _acc, callback]} -> [callback]
      {[:Enum], :reduce, [_acc, callback]} -> [callback]
      {[:Enum], function, [_enum, callback]} when function in @enum_functions -> [callback]
      {[:Enum], function, [callback]} when function in @enum_functions -> [callback]
      {[:Stream], function, [_enum, callback]} when function in @stream_functions -> [callback]
      {[:Stream], function, [callback]} when function in @stream_functions -> [callback]
      _other -> []
    end
  end

  defp block_body(args) do
    Enum.find_value(args, fn
      {:do, body} -> body
      options when is_list(options) -> Keyword.get(options, :do)
      _other -> nil
    end)
  end

  defp issues_in_loop(nil, _issue_meta, seen, issues, _loop_meta), do: {seen, issues}

  defp issues_in_loop(loop_body, issue_meta, seen, issues, loop_meta) do
    loop_body
    |> Credo.Code.prewalk(&find_repo_call/2, {issue_meta, seen, issues, loop_meta})
    |> then(fn {_issue_meta, seen, issues, _loop_meta} -> {seen, issues} end)
  end

  defp find_repo_call(
         {{:., dot_meta, [module_ast, function_name]}, call_meta, args} = ast,
         {issue_meta, seen, issues, loop_meta}
       )
       when is_list(args) and function_name in @repo_functions do
    if repo_module?(module_ast) do
      location = issue_location(module_ast, call_meta, dot_meta, loop_meta)
      trigger = trigger_for(module_ast, function_name)
      key = {location[:line_no], location[:column], trigger}

      if MapSet.member?(seen, key) do
        {ast, {issue_meta, seen, issues, loop_meta}}
      else
        issue = issue_for(issue_meta, location, trigger)
        {ast, {issue_meta, MapSet.put(seen, key), [issue | issues], loop_meta}}
      end
    else
      {ast, {issue_meta, seen, issues, loop_meta}}
    end
  end

  defp find_repo_call(ast, acc), do: {ast, acc}

  defp issue_for(issue_meta, location, trigger) do
    format_issue(
      issue_meta,
      message:
        "Repo call inside loop can create N+1 queries. Batch the query or preload before iterating.",
      trigger: trigger,
      line_no: location[:line_no],
      column: location[:column]
    )
  end

  defp issue_location(module_ast, call_meta, dot_meta, loop_meta) do
    module_meta = alias_meta(module_ast)

    [
      line_no: module_meta[:line] || call_meta[:line] || dot_meta[:line] || loop_meta[:line],
      column:
        module_meta[:column] || dot_meta[:column] || call_meta[:column] || loop_meta[:column]
    ]
  end

  defp trigger_for(module_ast, function_name) do
    module_ast
    |> alias_segments()
    |> Enum.concat([function_name])
    |> Enum.map_join(".", &Atom.to_string/1)
  end

  defp repo_module?(module_ast) do
    case alias_segments(module_ast) do
      [] -> false
      segments -> List.last(segments) == :Repo
    end
  end

  defp alias_segments({:__aliases__, _meta, segments}), do: segments
  defp alias_segments(atom) when is_atom(atom), do: [atom]
  defp alias_segments(_other), do: []

  defp alias_meta({:__aliases__, meta, _segments}), do: meta
  defp alias_meta(_other), do: []
end
