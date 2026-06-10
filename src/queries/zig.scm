; Symbol declarations in Zig (tree-sitter-grammars/tree-sitter-zig node names)
[
  (function_declaration
    name: (identifier) @name) @definition
  (variable_declaration
    . (identifier) @name) @definition
]
