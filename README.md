# mls — multi-level call-tree explorer for Ruby / Rails

A terminal UI for the "who calls this, and who calls *that*?" exercise. Start from a
method or class, walk **up** to callers (and callers of callers), walk **down** to what a
method calls, mark which same-named matches are real, add notes, and export the tree as
nested text. Your progress is saved automatically.

Ruby standard library only (Ruby 2.7+). Uses [ripgrep](https://github.com/BurntSushi/ripgrep)
when it is installed and falls back to a pure-Ruby search otherwise.

## Usage

```sh
bin/mls --root ~/code/my-rails-app            # open (or resume) the session for that app
bin/mls --root ~/code/my-rails-app total      # and search "total" right away
bin/mls --root ~/code/my-rails-app Billing::Order
```

Sessions live in `ROOT/.mls/session.json` (add `.mls/` to your global gitignore, or pass
`--session PATH`). Multiple named sessions are just multiple `--session` files.

### Choosing what gets searched

By default `vendor/`, `node_modules/`, `spec/`, `test/`, `features/`, `tmp/`, `log/`, `public/`,
`coverage/`, `db/schema.rb` and `db/structure.sql` are skipped. Add your own directories or globs
and they are remembered in the session:

```sh
bin/mls --root APP --exclude spec --exclude app/assets     # bare names mean spec/**, app/assets/**
bin/mls --root APP --no-default-excludes                   # also search vendor/, spec/, test/ … (remembered)
bin/mls --root APP --default-excludes                      # turn the defaults back on
```

Inside the TUI, `F` edits the exclude list and `T` toggles the default excludes. The header shows
how many globs are in effect. Changing the scope affects future searches only; nodes already in
the tree stay.

Non-interactive helpers:

```sh
bin/mls --root APP --definitions total              # where is `total` defined?
bin/mls --root APP --callers total                  # call-shaped references, with enclosing method
bin/mls --root APP --callees app/models/order.rb:12-20
bin/mls --root APP --export tree.md                 # export the saved session (add --include-dismissed)
bin/mls --root APP --tree total                     # climb all the way up from every `total` and print the tree
bin/mls --root APP --tree total --depth 3 --export total.md
bin/mls --root APP --exclude spec --callers total    # all of these honour the session's excludes
bin/mls --help
```

## Keys

| Key | Action |
| --- | --- |
| `j`/`k`, arrows | move · `h`/`l` collapse/expand · `Enter` toggle · `J`/`K` siblings · `g`/`G` top/bottom · `-`/`+` collapse/expand subtree |
| `/` | search a method name or `ClassName`; chosen definitions become new roots |
| `u` | **callers** of the selected node → pick call sites → children marked `↑ called by` |
| `U` | **auto-up**: climb callers of callers automatically; asks for a max depth (blank = unlimited), `Esc` stops, 500-node safety cap. Callers already in the tree become `↺ (see above)` leaves |
| `d` | **callees** of the selected node → pick calls → children marked `↓ calls` (asks which implementation when several exist) |
| `i` | **implementations**: other definitions of the same name; resolves `? name` placeholders |
| `y` / `n` / `space` | mark confirmed / dismissed / clear |
| `m` | edit the node's note |
| `x` | delete node + subtree (asks first) |
| `D` | toggle hiding dismissed nodes (also controls whether exports include them) |
| `F` / `T` | edit excluded dirs/globs · toggle the default excludes (vendor, spec, test, …) |
| `v` | view source; `]`/`[` jump between the definition and each call site; `o` opens `$EDITOR` |
| `o` | open the node's file at its line in `$EDITOR` |
| `e` | export all trees to a file (default `ROOT/.mls/export-<timestamp>.md`) |
| `w` / `q` / `?` | save / save and quit / help |

Inside a picker: `space` toggle, `a` all, `n` none, `/` filter, `v` peek at source, `.` show
noisy items (e.g. `each`, `present?`), `Enter` confirm, `Esc` cancel.

## What counts as a match

Ruby is dynamic, so this is textual search plus Ruby parsing, not type inference.

- **Definitions**: `def name`, `def self.name`, `define_method :name`, `attr_*`, `has_many`/`belongs_to`/…,
  `scope :name`, `delegate :name`, `alias`. Class names match `class`/`module` lines.
- **Callers**: `.name`, `&.name`, bare `name(`/`name`, `&:name`, `send(:name)`/`try(:name)`, `:name`
  symbols, and `"name"` strings (shown as noisy). Each hit is labelled with its kind. `def` lines,
  comments, `name?`/`name!`/`name=` variants and hash keys (`name:`) are excluded.
- **Enclosing method** of each hit comes from a Ripper parse of the file (with an indentation-based
  fallback for files that do not parse). Hits in a class body are attributed to `Klass (class body)`;
  hits in views are attributed to the file.
- **Callees** are the method calls and constant references inside the definition's line range.

Same-named methods on other classes will show up; that is what `y`/`n` are for.

## Climbing automatically

Select a node and press `U` (or run `--tree NAME` from the shell) to search callers, then callers of those
callers, and so on, breadth-first, until nothing new turns up. Every hit is attached without a picker, so
use `y`/`n` afterwards to judge same-named matches. A method that is already anywhere in the tree (a cycle,
or two paths converging on the same caller) is added as a `↺ (see above)` leaf and not expanded again.
Bare view sites stop the climb; calls in a class body continue via references to that class.

## Export format

```
# Billing::Order#total  — app/models/billing/order.rb:12
- ↑ called by Checkout#summary  — app/services/checkout.rb:6  [confirmed]
    app/services/checkout.rb:7: amount = @order.total
    note: main path
  - ↑ called by CheckoutsController#show  — app/controllers/checkouts_controller.rb:4
      app/controllers/checkouts_controller.rb:5: @summary = Checkout.new(@order).summary
- ↓ calls LineItem#price  — app/models/line_item.rb:7  [attr]
- ↑ called by Billing::Order#total?  — app/models/billing/order.rb:18
  - ↑ called by Checkout#summary  — app/services/checkout.rb:6  [see above]
```

## Development

```sh
rake test                      # or: ruby -w -Ilib -Itest test/run.rb
MLS_RG=/path/to/rg rake test   # also runs the ripgrep-vs-Ruby backend comparison
```

Layout: `lib/mls/search.rb` (patterns), `lib/mls/outline.rb` (Ripper scopes + callees),
`lib/mls/finder.rb` (ripgrep / Ruby grep), `lib/mls/model.rb` (tree + session JSON),
`lib/mls/export.rb`, `lib/mls/term.rb` (raw terminal), `lib/mls/ui/*` (tree view, picker, prompt, source view).
