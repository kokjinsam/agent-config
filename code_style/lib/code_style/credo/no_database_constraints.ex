defmodule CodeStyle.Credo.NoDatabaseConstraints do
  @moduledoc false

  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Avoid setting business-logic column constraints in Ecto migrations.

      Application-level validations should enforce nullability, defaults, and sizing
      rules instead of pushing those concerns into `add/3` and `modify/3`.
      """
    ]

  @forbidden_options ~w(null default size precision scale)a
  @targeted_functions %{create: MapSet.new([:add]), alter: MapSet.new([:add, :modify])}

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if migration_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&walk/2, {issue_meta, []})
      |> elem(1)
    else
      []
    end
  end

  defp walk({operation, _meta, [table_call, block_options]} = ast, {issue_meta, issues})
       when operation in [:create, :alter] and is_list(block_options) do
    with true <- table_call?(table_call),
         {:ok, body} <- Keyword.fetch(block_options, :do),
         {:ok, targeted_functions} <- Map.fetch(@targeted_functions, operation) do
      {ast, {issue_meta, issues ++ issues_in_block(body, targeted_functions, issue_meta)}}
    else
      _fallback -> {ast, {issue_meta, issues}}
    end
  end

  defp walk(ast, acc), do: {ast, acc}

  defp issues_in_block(block_ast, targeted_functions, issue_meta) do
    block_ast
    |> Credo.Code.prewalk(&find_issues/2, {targeted_functions, issue_meta, []})
    |> elem(2)
    |> Enum.reverse()
  end

  defp find_issues({function_name, meta, args} = ast, {targeted_functions, issue_meta, issues})
       when is_list(args) do
    if MapSet.member?(targeted_functions, function_name) do
      case forbidden_options(args) do
        [] ->
          {ast, {targeted_functions, issue_meta, issues}}

        options ->
          issue = issue_for(issue_meta, function_name, meta, options)
          {ast, {targeted_functions, issue_meta, [issue | issues]}}
      end
    else
      {ast, {targeted_functions, issue_meta, issues}}
    end
  end

  defp find_issues(ast, acc), do: {ast, acc}

  defp forbidden_options(args) do
    with [_first_arg, _second_arg | _remaining_args] <- args,
         opts when is_list(opts) <- List.last(args),
         true <- Keyword.keyword?(opts),
         false <- primary_key_column?(opts) do
      opts
      |> Keyword.keys()
      |> Enum.filter(&(&1 in @forbidden_options))
      |> Enum.uniq()
    else
      _fallback -> []
    end
  end

  defp primary_key_column?(opts), do: Keyword.get(opts, :primary_key) == true

  defp issue_for(issue_meta, function_name, meta, options) do
    option_list = Enum.map_join(options, ", ", &"`#{&1}`")

    format_issue(
      issue_meta,
      message:
        "Column option(s) #{option_list} should not be set in migrations. Enforce at the application layer.",
      trigger: Atom.to_string(function_name),
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp migration_file?(source_file) do
    Credo.Code.prewalk(source_file, &find_migration_use/2, false)
  end

  defp find_migration_use(
         {:use, _use_meta, [{:__aliases__, _aliases_meta, [:Ecto, :Migration]} | _remaining_args]} =
           ast,
         _found?
       ) do
    {ast, true}
  end

  defp find_migration_use(ast, found?), do: {ast, found?}

  defp table_call?({:table, _meta, _args}), do: true
  defp table_call?(_other), do: false
end
