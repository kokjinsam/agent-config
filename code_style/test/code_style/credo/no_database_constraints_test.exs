defmodule CodeStyle.Credo.NoDatabaseConstraintsTest do
  use Credo.Test.Case, async: false

  alias CodeStyle.Credo.NoDatabaseConstraints

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports forbidden column options inside migration table blocks" do
    """
    defmodule Remark.Repo.Migrations.CreateProducts do
      use Ecto.Migration

      def change do
        create table(:products) do
          add :price, :decimal, null: false, precision: 10, scale: 2, default: 0
        end
      end
    end
    """
    |> to_source_file("priv/repo/migrations/20260624000000_create_products.exs")
    |> run_check(NoDatabaseConstraints)
    |> assert_issue(%{
      line_no: 6,
      trigger: "add",
      message:
        "Column option(s) `null`, `precision`, `scale`, `default` should not be set in migrations. Enforce at the application layer."
    })
  end

  test "does not report structural primary key options" do
    """
    defmodule Remark.Repo.Migrations.CreateWidgets do
      use Ecto.Migration

      def change do
        create table(:widgets, primary_key: false) do
          add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
        end
      end
    end
    """
    |> to_source_file("priv/repo/migrations/20260624000000_create_widgets.exs")
    |> run_check(NoDatabaseConstraints)
    |> refute_issues()
  end

  test "reports modify options inside alter table blocks" do
    """
    defmodule Remark.Repo.Migrations.AlterUsers do
      use Ecto.Migration

      def change do
        alter table(:users) do
          modify :name, :string, from: :text, null: false, default: ""
        end
      end
    end
    """
    |> to_source_file("priv/repo/migrations/20260624000000_alter_users.exs")
    |> run_check(NoDatabaseConstraints)
    |> assert_issue(%{
      line_no: 6,
      trigger: "modify",
      message:
        "Column option(s) `null`, `default` should not be set in migrations. Enforce at the application layer."
    })
  end
end
