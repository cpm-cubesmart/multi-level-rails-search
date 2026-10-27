# frozen_string_literal: true

module Mls
  module UI
    class Help < Modal
      TEXT = <<~TXT
        mls — multi-level call-tree explorer

        Navigation
          j/k ↑/↓        move          h/l ←/→   collapse / expand      Enter  toggle
          J/K            next/prev sibling          g/G   top / bottom      -/+    collapse/expand subtree

        Exploring
          /   search a method name or ClassName → pick definitions → new root(s)
          u   callers (up): who calls the selected node → pick sites → children "↑ called by"
          U   auto-up: climb callers of callers automatically (asks for a max depth, blank = unlimited;
              Esc stops; 500-node cap). Callers already in the tree become "↺ (see above)" leaves.
          d   callees (down): what the selected node calls → pick → children "↓ calls"
          i   implementations: other definitions of the same name (resolves "?" placeholders)

        Judging
          y   mark confirmed     n   mark dismissed     space  clear mark
          m   edit note          x   delete node + subtree      D   toggle hiding dismissed

        Viewing
          v   view source (]/[ jump between definition and call sites)      o   open in $EDITOR

        Search scope (remembered in the session)
          F   edit excluded dirs/globs ("spec app/assets" → spec/**, app/assets/**)
          T   toggle the default excludes (vendor, node_modules, spec, test, features, tmp, log, public …)

        Session
          e   export tree(s) to a file      w   save      q   save and quit      ?   this help

        Matches are textual (ripgrep + Ruby parsing); same-named methods on other classes show up too.
        Use y/n to record which ones are real. Dismissed nodes are left out of exports (unless D is off).
      TXT

      def render(rows, cols)
        lines = TEXT.lines.map(&:chomp)
        lines.fill("", lines.size, rows - 1 - lines.size) if lines.size < rows - 1
        lines = lines[0, rows - 1]
        lines << bar("any key: back", cols)
        lines
      end

      def handle(_key)
        [:done, nil]
      end
    end
  end
end
