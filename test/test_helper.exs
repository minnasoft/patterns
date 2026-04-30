alias Ecto.Adapters.SQL
alias Ecto.Adapters.SQL.Sandbox
alias Patterns.Test.Repo

ExUnit.start()

if Code.ensure_loaded?(Repo) do
  {:ok, _} = Repo.start_link()
  Sandbox.mode(Repo, {:shared, self()})

  SQL.query!(Repo, "DROP TABLE IF EXISTS patterns_comments")
  SQL.query!(Repo, "DROP TABLE IF EXISTS patterns_posts")

  SQL.query!(Repo, """
  CREATE TABLE IF NOT EXISTS patterns_posts (
    id INTEGER PRIMARY KEY,
    title TEXT,
    views INTEGER,
    published INTEGER DEFAULT 0,
    deleted_at TEXT
  )
  """)

  SQL.query!(Repo, """
  CREATE TABLE IF NOT EXISTS patterns_comments (
    id INTEGER PRIMARY KEY,
    body TEXT,
    likes INTEGER,
    post_id INTEGER
  )
  """)

  Sandbox.mode(Repo, :manual)
end
