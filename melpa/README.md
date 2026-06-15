# MELPA recipe

This directory holds the [MELPA](https://melpa.org/) recipe for `kasas`. It is
*not* part of the package itself (MELPA's default `:files` spec only picks up
the root-level `*.el` files, so this directory is ignored by the build); it
lives here so the recipe is versioned alongside the code and ready to copy into
a `melpa/melpa` fork when submitting or updating the package.

The package name on MELPA is **`kasas`** (the feature the main file provides),
not `kasas.el`.

## Submitting to MELPA

MELPA builds packages from a one-line recipe in the
[`melpa/melpa`](https://github.com/melpa/melpa) repository; you don't upload
anything. The flow:

1. **Fork and clone** `melpa/melpa`.
2. **Copy the recipe** in this directory to `recipes/kasas` in your fork:

   ```sh
   cp melpa/kasas /path/to/melpa/recipes/kasas
   ```

   The recipe (no `:files` clause needed — the default spec grabs the
   root-level `*.el` and skips `test/`, which matches this repo's layout):

   ```elisp
   (kasas :fetcher github
          :repo "paulmeier/kasas.el")
   ```

3. **Build and smoke-test it locally**, from inside your `melpa` checkout:

   ```sh
   make recipes/kasas                        # build the package
   make sandbox INSTALL=kasas                # install it in a clean Emacs
   ```

4. **Open a PR** against `melpa/melpa`. Their template asks you to confirm you
   byte-compiled cleanly and ran `package-lint` and `checkdoc` — this repo's CI
   (`.github/workflows/ci.yml`) already does all three, plus the test suite, via
   `make compile`, `make lint`, `make checkdoc`, and `make test`. Check the
   "upstream author" box, since you maintain the package.

5. A maintainer reviews and merges. After merge the package is available from
   **MELPA** (unstable), built from the latest commit on the default branch.

## MELPA Stable

To also publish to **MELPA Stable**, push a git tag matching the `Version:`
header in `kasas.el` (currently `0.1.0`). Stable builds from the latest tag:

```sh
git tag -a 0.1.0 -m "kasas.el 0.1.0"
git push origin 0.1.0
```

## Notes

- `gptel` is an *optional* runtime dependency. `kasas-gptel.el` loads it with
  `(require 'gptel nil t)` and `declare-function`s the symbols it uses, so it is
  deliberately **not** listed in `Package-Requires` and `package-lint` does not
  flag it.
- The only hard requirement is `(emacs "27.1")`, declared in `kasas.el`.
