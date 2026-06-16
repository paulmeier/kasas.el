# Contributing to kasas.el

Thanks for helping out! kasas.el is free, MIT-licensed software and intends to
stay that way. This guide covers local development, the checks CI enforces, and
the conventions we follow.

## Prerequisites

- **Emacs 27.1+** — the only hard requirement. The core depends on nothing but
  Emacs' built-in libraries (`url`, `json`, `tabulated-list`, `org`).
- **GNU Make** — drives every check via `emacs --batch`.
- **Optional, for exercising the integrations:**
  - [`gnuplot`](http://gnuplot.info) on `PATH` — for the `kasas-plot-*` commands.
  - A running [kasas](https://github.com/paulmeier/kasas) server — for manual,
    end-to-end testing (the automated tests do not need one).

`make help` lists every target.

## Getting started

```sh
git clone https://github.com/paulmeier/kasas.el
cd kasas.el
make            # byte-compile + run the test suite
```

To try it against a live server, start kasas locally (see its
[quick start](https://github.com/paulmeier/kasas#quick-start)) and then, from
this checkout:

```sh
emacs -Q -L . -l kasas.el --eval '(progn (setq kasas-base-url "http://localhost:8080") (kasas-accounts))'
```

## Project layout

| File | Responsibility |
| --- | --- |
| `kasas.el` | Core: HTTP client, auth, JSON, typed endpoint wrappers, formatting. **Everything else requires this.** |
| `kasas-accounts.el` | The accounts `tabulated-list` browser. |
| `kasas-transactions.el` | The transactions browser + search + label drill-down. |
| `kasas-events.el` | The live event-stream tail (polling, like the kasas dashboard). |
| `kasas-plot.el` | Realtime charts via `org-plot`. |
| `test/` | ERT tests and the batch runners for `checkdoc` / `package-lint`. |

It is a **multi-file package**: only `kasas.el` carries the `Version` and
`Package-Requires` headers; the others declare themselves part of the same
package (and `test/package-lint-batch.el` sets `package-lint-main-file`
accordingly).

## The checks (what CI runs)

CI runs the same `make` targets you can run locally; all must pass on every PR.

```sh
make compile    # byte-compile all sources; warnings are treated as errors
make test       # run the ERT suite (no live server required)
make checkdoc   # docstring conventions
make lint       # package-lint (installs it from MELPA on demand)
```

- **`compile`** runs with `byte-compile-error-on-warn` — a warning fails the
  build, so keep the byte-compiler quiet (use `declare-function` for optional
  dependencies, and `defvar` for special variables).
- **`test`** runs against the pure, server-independent helpers. Add a test for
  any new aggregation, parser, or formatter.
- The CI matrix exercises Emacs **27.2, 28.2, 29.4, and snapshot**, so avoid
  APIs newer than the declared `(emacs "27.1")` floor.

[Eldev](https://emacs-eldev.github.io/eldev/) users can instead run
`eldev compile`, `eldev test`, and `eldev lint`; the `Makefile` is the canonical
entry point and needs nothing but Emacs.

## Conventions

- **Naming.** Public symbols are prefixed `kasas-`; internal ones `kasas--`.
  Feature modules may use their own prefix (`kasas-plot-`).
- **No hard dependencies in the core.** Optional integrations (e.g. `gnuplot`)
  must degrade gracefully — soft-`require`, `declare-function`, and a clear
  `user-error` when the dependency is missing.
- **Money is never a float.** kasas returns exact decimal strings; keep them as
  strings for display (`kasas-format-amount`) and only parse to a number
  (`kasas-parse-amount`) for charts and aggregation.
- **Lexical binding** is on in every file (the `-*- lexical-binding: t; -*-`
  cookie). Keep it.
- **Docstrings** for every interactive command and public function; `make
  checkdoc` enforces the house style.

## Commits & pull requests

- Keep PRs focused; explain the *why* in the description.
- Run `make` (compile + test) before pushing, and ideally `make checkdoc lint`
  too.
- New user-facing behaviour deserves a note in the README and, where it makes
  sense, a test.

## License & contributions

kasas.el is distributed under the [MIT License](LICENSE). By contributing, you
agree that your contributions are licensed under the same MIT terms — there is
no CLA, and the project will always remain free and MIT-licensed.
