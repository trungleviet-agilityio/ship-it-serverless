---
paths:
  - "scripts/**"
  - "Makefile"
---

# Scripts and Makefile

Read `docs/reference/standards/tooling.md` before editing. Lab-specific points it builds on:

- Scripts run on macOS `/bin/bash` 3.2 and on CI bash 5: no bash 4 features (associative arrays, `${x,,}`,
  `mapfile`) and no brace tricks in parameter defaults such as `"${2:-{\}}"`.
- Every script has a self-test under `scripts/selftest/` that `make check` runs; a self-test must require the
  specific error, not any failure.
- Names derive from `project.env` through `scripts/lib.sh`; never spell the prefix.
- No `apply` or `destroy` target in the `Makefile`, ever.
