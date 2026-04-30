if Mix.env() == :test do
  defmodule Patterns.Test.Comment do
    @moduledoc false

    use Ecto.Schema

    schema "patterns_comments" do
      field :body, :string
      belongs_to :post, Patterns.Test.Post
    end
  end
end
