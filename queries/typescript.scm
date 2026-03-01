; Symbol declarations in TypeScript/JavaScript
[
  (function_declaration
    name: (identifier) @name) @definition
  (class_declaration
    name: (type_identifier) @name) @definition
  (type_alias_declaration
    name: (type_identifier) @name) @definition
  (interface_declaration
    name: (type_identifier) @name) @definition
  (enum_declaration
    name: (identifier) @name) @definition
  (lexical_declaration
    (variable_declarator
      name: (identifier) @name)) @definition
]
