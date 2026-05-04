# Scoping a Concourse Git Resource to a Monorepo Subdirectory

## The Problem

When every commit to `main` triggers all 5 pipelines regardless of which service changed, your workers spend most of their time rebuilding services that weren't touched. With 20 commits/day, that multiplies quickly.

## The Fix

Concourse's git resource supports two filtering parameters that work together:

- **`paths`** — only trigger if at least one changed file matches these glob patterns
- **`ignore_paths`** — suppress triggers for files that match, even if they'd otherwise qualify via `paths`

Here is the corrected resource for the `orders` service pipeline:

```yaml
resources:
  - name: src
    type: git
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/orders/**
        - libs/shared/**
      ignore_paths:
        - services/orders/**/*.md
        - services/orders/**/ADR*.md
        - libs/shared/**/*.md
```

## How It Works

| Parameter | What It Does |
|---|---|
| `paths` | Concourse only triggers a new build if **at least one** file in the push matches one of these globs. A commit that only modifies `services/payments/` will not match, so this pipeline stays idle. |
| `ignore_paths` | Even if a file matches `paths`, if it **also** matches `ignore_paths` it is excluded from consideration. A commit that only adds a README inside `services/orders/` will not trigger. If the commit contains both a `.go` file and a `.md` file, the `.go` file still matches `paths` and does not match `ignore_paths`, so the build fires correctly. |

## Notes

- Both `paths` and `ignore_paths` accept standard glob patterns. The `**` wildcard matches across directory separators (recursive).
- Filtering is evaluated by the `check` step on the git resource. Concourse re-checks after each push; a version is only emitted when the diff contains at least one qualifying file.
- If your markdown files live in a dedicated `docs/` root directory rather than alongside source code, you can simplify `ignore_paths` to just `- docs/**`.
- Each of your 5 pipelines should have its own `paths` list scoped to that service's directory plus any shared libraries it depends on (e.g., `libs/shared/`, `libs/auth/`). Do not share a single git resource definition across pipelines if the path scopes differ.
- The `tests/` subdirectory under `services/orders/` is already covered by `services/orders/**`, so no additional entry is needed for it.

## Result

Only commits that touch `services/orders/` or `libs/shared/` (excluding markdown files) will trigger this pipeline. The other 4 pipelines remain unaffected unless their own paths match.
