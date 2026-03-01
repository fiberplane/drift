; Symbol declarations in Rust
[
  (function_item
    name: (identifier) @name) @definition
  (struct_item
    name: (type_identifier) @name) @definition
  (enum_item
    name: (type_identifier) @name) @definition
  (trait_item
    name: (type_identifier) @name) @definition
  (type_item
    name: (type_identifier) @name) @definition
  (impl_item
    type: (type_identifier) @name) @definition
  (const_item
    name: (identifier) @name) @definition
  (static_item
    name: (identifier) @name) @definition
]
