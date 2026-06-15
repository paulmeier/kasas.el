<h1 align="center">kasas.el</h1>

<p align="center">
  <strong>An Emacs interface to the <a href="https://github.com/paulmeier/kasas">kasas</a> financial ledger.</strong>
</p>

<p align="center">
  <a href="https://github.com/paulmeier/kasas.el/actions/workflows/ci.yml"><img src="https://github.com/paulmeier/kasas.el/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Emacs-27.1%2B-7F5AB6?logo=gnuemacs&logoColor=white" alt="Emacs 27.1+">
</p>

---

kasas.el browses your [kasas](https://github.com/paulmeier/kasas) ledger from
inside Emacs — accounts, transactions, search, labels, and a live event tail —
over the kasas REST API. On top of the basics it adds two things Emacs is
uniquely good at:

- 🤖 **[gptel](https://github.com/karthink/gptel) tools** — expose your ledger to
  an LLM as read-only, callable tools, so you can ask *"how much did I spend on
  groceries last month?"* and the model fetches the **real numbers** instead of
  hallucinating them.
- 📈 **Realtime [org-plot](https://orgmode.org/manual/Org-Plot.html) charts** —
  render spending and balance charts as live Org documents that refresh
  themselves as your ledger changes.

> **Free forever, MIT licensed.** kasas.el is and always will be free software
> under the [MIT License](LICENSE).

## Requirements

- **Emacs 27.1+** (no hard third-party dependencies — the core uses only
  built-in `url`, `json`, and `tabulated-list`).
- A reachable **kasas** server (`docker compose up`, or a binary — see the
  [kasas quick start](https://github.com/paulmeier/kasas#quick-start)).
- **Optional:** [`gptel`](https://github.com/karthink/gptel) for the LLM
  integration, and a **`gnuplot`** binary on `PATH` for the plotting commands.

## Installation

kasas.el is a multi-file package; load the entry point and the features you
want. From source with `use-package` and `:vc` (Emacs 30+):

```elisp
(use-package kasas
  :vc (:url "https://github.com/paulmeier/kasas.el")
  :custom
  (kasas-base-url "http://localhost:8080")
  ;; Prefer auth-source for the token (see below); or set it directly:
  ;; (kasas-token "kasas_...")
  :commands (kasas kasas-accounts kasas-transactions kasas-events-follow))
```

Or clone and add to your `load-path`:

```sh
git clone https://github.com/paulmeier/kasas.el ~/.emacs.d/site-lisp/kasas.el
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/kasas.el")
(require 'kasas)
```

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `kasas-base-url` | `http://localhost:8080` | Base URL of the kasas server (no trailing slash). |
| `kasas-token` | `nil` | Bearer token — the dashboard token or a scoped API key. |
| `kasas-use-auth-source` | `t` | Fall back to `auth-source` to resolve the token. |
| `kasas-default-limit` | `100` | Default page size for list endpoints. |
| `kasas-currency-symbol` | `$` | Symbol used when formatting amounts for display. |

A kasas server with **no token configured** accepts unauthenticated requests, so
for a local instance you may not need a token at all. When the server *is*
secured, the recommended way to supply the token is `auth-source` — add to
`~/.authinfo.gpg`:

```
machine localhost:8080 login kasas password kasas_XXXXXXXXXXXX
```

`kasas-token`, when set, always takes precedence.

## Usage

| Command | What it does |
| --- | --- |
| `M-x kasas` | The main entry point — browse all transactions. |
| `M-x kasas-accounts` | List accounts with balances; `RET` opens an account's transactions. |
| `M-x kasas-transactions` | Browse transactions; `s` to search, `l` to drill by label. |
| `M-x kasas-events-follow` | Follow the live event stream. |
| `M-x kasas-plot-spending-by-label` | Bar chart of spending grouped by a label. |
| `M-x kasas-plot-account-balance` | Cumulative net-flow chart for an account. |
| `M-x kasas-gptel-ask` | Ask a natural-language question about your finances. |

### Browsing & searching

In a transactions buffer:

| Key | Action |
| --- | --- |
| `RET` | Show full transaction details |
| `s` | Search with the [kasas query language](https://github.com/paulmeier/kasas/blob/main/docs/features/search.md) |
| `l` | Drill down by label key/value (completing-read over the vocabulary) |
| `p` | Plot the transactions currently shown |
| `g` | Refresh |

The search box speaks the full kasas grammar, e.g.:

```
coffee amount:<0 date:2024 -label:reimbursed
```

### Realtime plots

```elisp
M-x kasas-plot-spending-by-label  ; pick a label key, e.g. "category"
```

This builds an Org table annotated with a `#+PLOT:` directive and renders it
with gnuplot. To make it *live*, enable the buffer-local refresh mode in the
plot buffer:

```elisp
M-x kasas-plot-auto-refresh-mode
```

It re-fetches and re-renders every `kasas-plot-refresh-interval` seconds, and —
if you are following the event stream with `kasas-events-follow` — also the
instant a relevant change lands.

### Asking your ledger with gptel

```elisp
(require 'kasas-gptel)
(kasas-gptel-setup)   ; register the kasas tools with gptel
```

Then enable tool use in your gptel session, or just:

```elisp
M-x kasas-gptel-ask RET how much did I spend on groceries last month? RET
```

The model can call these **read-only** tools: `kasas_search_transactions`,
`kasas_list_accounts`, `kasas_account_transactions`, `kasas_list_labels`, and
`kasas_sync_status`. It can inspect your finances but never mutate them.

## Library API

Every REST endpoint has a thin, signalling wrapper you can call from your own
Elisp (see `kasas.el`): `kasas-accounts-list`, `kasas-account-transactions`,
`kasas-transactions-list`, `kasas-search`, `kasas-labels`, `kasas-events`,
`kasas-sync-status`, and more. They return decoded JSON (plists / vectors) and
signal `kasas-http-error` (or `kasas-auth-error`) on failure.

```elisp
(kasas-get (aref (kasas-accounts-list) 0) :name)   ;; => "Checking"
(kasas-get (kasas-search "amount:>1000") :total)   ;; => 3
```

## Contributing

Contributions are welcome! See **[CONTRIBUTING.md](CONTRIBUTING.md)** for local
setup, the `make` targets CI runs (byte-compile, ERT, checkdoc, package-lint),
and the conventions we follow. CI must be green on every PR.

## License

[MIT](LICENSE) © Paul Meier. Free forever.
