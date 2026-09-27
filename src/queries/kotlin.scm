; Symbol declarations in fwcd/tree-sitter-kotlin.
; class_declaration includes classes, interfaces, data classes and enum classes.
[
  (class_declaration
    (type_identifier) @name) @definition
  (object_declaration
    (type_identifier) @name) @definition
  (companion_object
    (type_identifier) @name) @definition
  (function_declaration
    (simple_identifier) @name) @definition
  (property_declaration
    (variable_declaration
      (simple_identifier) @name)) @definition
  (enum_entry
    (simple_identifier) @name) @definition
  (type_alias
    (type_identifier) @name) @definition
]
