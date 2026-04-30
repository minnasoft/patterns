if Mix.env() == :test do
  defmodule Patterns.Test.Post do
    @moduledoc false

    use Ecto.Schema

    schema "patterns_posts" do
      field :title, :string
      field :published, :boolean, default: false
      field :deleted_at, :utc_datetime

      has_many :comments, Patterns.Test.Comment
    end
  end
end
