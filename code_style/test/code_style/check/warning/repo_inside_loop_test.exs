defmodule CodeStyle.Check.Warning.RepoInsideLoopTest do
  use Credo.Test.Case, async: false

  alias CodeStyle.Check.Warning.RepoInsideLoop

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports Repo calls inside Enum callbacks" do
    """
    defmodule Example do
      alias MyApp.Repo

      def load(users) do
        Enum.map(users, fn user ->
          Repo.get(User, user.id)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> assert_issue(%{
      line_no: 6,
      trigger: "Repo.get",
      message:
        "Repo call inside loop can create N+1 queries. Batch the query or preload before iterating."
    })
  end

  test "reports Repo preload inside for comprehensions" do
    """
    defmodule Example do
      def load(users) do
        for user <- users do
          MyApp.Repo.preload(user, :posts)
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> assert_issue(%{
      line_no: 4,
      trigger: "MyApp.Repo.preload"
    })
  end

  test "reports Repo calls inside Stream callbacks" do
    """
    defmodule Example do
      def load(users) do
        Stream.map(users, fn user ->
          MyApp.Repo.all(from p in Post, where: p.user_id == ^user.id)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> assert_issue(%{
      line_no: 4,
      trigger: "MyApp.Repo.all"
    })
  end

  test "reports Repo calls inside piped Enum callbacks" do
    """
    defmodule Example do
      alias MyApp.Repo

      def load(users) do
        users
        |> Enum.map(fn user ->
          Repo.get(User, user.id)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> assert_issue(%{
      line_no: 7,
      trigger: "Repo.get"
    })
  end

  test "does not report Repo calls before the loop body" do
    """
    defmodule Example do
      alias MyApp.Repo

      def names do
        Repo.all(User)
        |> Enum.map(fn user -> user.name end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> refute_issues()
  end

  test "does not report Repo calls used as the loop input" do
    """
    defmodule Example do
      alias MyApp.Repo

      def names do
        Enum.map(Repo.all(User), fn user -> user.name end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> refute_issues()
  end

  test "does not report non-Repo calls inside loop callbacks" do
    """
    defmodule Example do
      def load(users) do
        Enum.map(users, fn user ->
          Accounts.get_user(user.id)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RepoInsideLoop)
    |> refute_issues()
  end
end
