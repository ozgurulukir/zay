---
name: tci-query-tuning
description: Customize or tune tree-sitter AST queries for symbol extraction, callee resolution, local scope variables, and reference tracking. Execute when symbols are missed, caller/callee resolution fails, or custom language queries are needed.
---

# TCI Query Tuning & AST Inspection

Customize tree-sitter queries dynamically to improve symbol indexing, callee resolution, local scope extraction, or field/import search accuracy.

## Workflow

### 1. Inspect the S-Expression AST representation

Before writing any custom queries, inspect the AST node hierarchy of your source code file using the `ast` command:

```bash
code-tandem ast <file>
```

This returns the exact parenthesized tree-sitter AST structure of the file, allowing you to identify node names (e.g., `impl_item`, `function_definition`) and field names (e.g., `name:`, `body:`).

### 2. Create/Edit the Dynamic Query File

Create or modify the `.tsq` configuration file for your language in the project root:

```text
.code-tandem/queries/<language>.tsq
```

Where `<language>` is one of: `rust`, `python`, `typescript`, `javascript`, `go`, `java`, `scala`, `vue`, `crystal`, `c`, `cpp`.

### 3. Add Custom Query Sections

Add tree-sitter query patterns under the appropriate section header inside the `.tsq` file:

```ini
[symbols]
;; Override symbol extraction
(struct_item name: (type_identifier) @symbol.name) @symbol.def

[callers]
;; Override callers/callee call expression detection
(call_expression function: (identifier) @callee)

[variables]
;; Override lexical scope variable bindings
(let_declaration pattern: (identifier) @var.name)
```

**Supported headers:**

- `[symbols]`: Matches symbols, capturing `@symbol.name` and `@symbol.def`.
- `[callers]`: Matches callee call expressions, capturing `@callee`.
- `[id_refs]`: Matches identifier references for inverted indexing, capturing `@callee`.
- `[variables]`: Matches local variables for scope filtering, capturing `@var.name`.
- `[string]`: Matches string literals, capturing `@string_content`.
- `[template_string]`: Matches template string literals, capturing `@string_content`.
- `[imports]`: Matches imports/requires, capturing `@import.source` and `@import.def`.
- `[fields]`: Matches struct/class fields, capturing `@field.name` and `@field.type`.
- `[annotations]`: Matches annotations/decorators, capturing `@annotation.name`.

### 4. Verify & Hot-Reload

The server automatically detects updates to `.tsq` files using modification times (`mtime`) and hot-reloads them dynamically. Verify your new query instantly:

```bash
# Verify symbol indexing
code-tandem symbols --file <file>

# Verify call graph / callee extraction
code-tandem callers <symbol> --file <file>
```
