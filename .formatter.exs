[
  import_deps: [:ecto],
  locals_without_parens: [defdelegate_all: 1],
  plugins: [Styler],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
