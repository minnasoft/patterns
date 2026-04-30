<p align="center">
  <img src="https://github.com/user-attachments/assets/ebb663d7-c47e-46bb-af4f-98281c64f89b" alt="Patterns" width="903" height="346" />
</p>

# Patterns

> Because sometimes you want a tiny \**sparkle*\* of magic.

Patterns is an anti-framework for shaping plain Elixir code into tidy little systems.

It gives you small, composable building blocks for the parts of an app that tend to get repetitive:

- query DSLs
- middleware
- scoped context
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

## Status

Pre-release. Preparing v0.0.1.

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
