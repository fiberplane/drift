; Symbol declarations in Go
[
  (function_declaration
    name: (identifier) @name) @definition
  (method_declaration
    name: (field_identifier) @name) @definition
  (type_declaration
    (type_spec
      name: (type_identifier) @name)) @definition
  (const_declaration
    (const_spec
      name: (identifier) @name)) @definition
  (var_declaration
    (var_spec
      name: (identifier) @name)) @definition
]
