<p align="center">
  <img src="https://github.com/user-attachments/assets/ebb663d7-c47e-46bb-af4f-98281c64f89b" alt="Patterns" width="903" height="346" />
</p>

# Patterns

[![Hex Version](https://img.shields.io/hexpm/v/patterns.svg)](https://hex.pm/packages/patterns)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/patterns/)
[![CI Status](https://github.com/minnasoft/patterns/workflows/CI/badge.svg)](https://github.com/minnasoft/patterns/actions)
[![Coverage Status](https://coveralls.io/repos/github/minnasoft/patterns/badge.svg?branch=main)](https://coveralls.io/github/minnasoft/patterns?branch=main)

> Because sometimes you want a tiny \**sparkle*\* of magic.

Patterns is an anti-framework for shaping plain Elixir code into tidy little systems.

It gives you small, composable building blocks for the parts of an app that tend to get repetitive:

- [query DSLs](https://hexdocs.pm/patterns/Patterns.Queryable.html)
- [middleware](https://hexdocs.pm/patterns/Patterns.Middleware.html)
- [scoped context](https://hexdocs.pm/patterns/Patterns.Utils.html#with_ctx/2)
- [delegation helpers](https://hexdocs.pm/patterns/Patterns.Utils.html#defdelegate_all/1)
- tiny conventions you keep rewriting from project to project

Patterns is for the little bits of structure you keep rebuilding.

The query helpers, wrapper functions, scoped context, and tiny APIs that make a codebase feel like itself.

Just a few ~~cursed~~ cute tools that stay out of the way and make your own modules feel a little more intentional.

## Installation

```elixir
def deps do
  [
    {:patterns, "~> 0.0.1"}
  ]
end
```

## Why Patterns?

Because there is a sweet spot between “copy-paste this again” and “adopt an entire platform.”

Patterns is for codebases that want:

- plain modules with sprinkles of magic
- teeny tiny DSLs that get out of your way
- pretty patterns that still feel like your code
- APIs that feel nice without getting weird about it

Write the Elixir you want to write. Patterns just helps it stay pretty.

## What's Inside?

### Utilities

A couple of tiny tools for library-ish code:

- `defdelegate_all/1` for when yes, actually, you do want to delegate the whole public surface.
- `with_ctx/2` and `ctx/1` for scoped process-local context when a DSL needs to know where it is.

### Queryable

`Patterns.Queryable` gives Ecto schemas one tidy `query/2` entrypoint for contexts, resolvers, dataloaders, and tests.

Think of it like a more powerful `Repo.get_by/2` that works on any query, with good defaults for the boring stuff:

```elixir
Post.query(title: "Hello")
Post.query([published: true, order_by: [desc: :published_at]])
Post.query(comments: [author_id: user.id])
```

### Middleware

`Patterns.Middleware` wraps plain functions with explicit `@middleware` annotations.

Use it to extend existing functions and APIs: do a lil' auth check here, a lil' logging there.

```elixir
@middleware Blog.Middlewares.AuthorizeEditor
def edit_post(post, attrs) do
  Blog.Posts.update(post, attrs)
end

@middleware [Blog.Middlewares.AuthorizeEditor, Blog.Middlewares.RecordAuditLog]
def create_post(attrs) do
  Blog.Posts.create(attrs)
end
```

## Status

v0.0.1 is the first release. Tiny, useful, and still allowed to be a little cursed.

## Development

Patterns uses Nix for the project shell and CI tooling.

If you use direnv:

```sh
direnv allow
```

If you prefer entering the shell manually:

```sh
nix develop
```

Then run the usual checks:

```sh
mix local.hex --force
mix local.rebar --force
mix deps.get
mix test
mix lint
MIX_ENV=prod mix hex.build
```

CI runs the same checks through the Nix shell, with `nix flake check` covering repo-level hooks and formatting.

## License

MIT
