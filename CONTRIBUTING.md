# Contributing

Port is a small project, and the contribution process matches.  Bug
reports, feature ideas, and patches are all welcome.

## Filing issues

Open a GitHub issue at
<https://github.com/clojure-emacs/port/issues>.  A reproducer (an
input form, a transcript, or a small Clojure project) helps a lot,
especially for things that depend on the JVM side.

## Running the tests

Port uses [Eldev](https://github.com/emacs-eldev/eldev) for
development:

```
eldev test       # run the test suite
eldev compile    # byte-compile every file
eldev lint       # run elisp-lint and relint
```

Tests use [Buttercup](https://github.com/jorgenschaefer/emacs-buttercup)
(`describe` / `it` / `expect`).  Eldev pulls it in automatically when
you first run `eldev test`.  The suite is fast (a few hundred
milliseconds) and doesn't require a live Clojure runtime — most tests
synthesise prepl messages and exercise the parser/dispatcher directly.

## Code style

- Follow the existing style.  Two-space indent, no tabs, lexical
  binding everywhere.
- Private helpers use a `--` separator (e.g. `port-repl--insert-prompt`);
  public-ish API uses a single dash.
- Docstrings on every interactive command and most internal helpers.
- Keep changes focused.  Don't refactor surrounding code in a feature
  PR; submit a separate cleanup commit if it's worth doing.
- New behaviour needs a test.  We don't merge feature changes without
  one.

## Commits and PRs

- One logical change per commit.  The subject line should explain
  the *why*, not just list files touched.
- Reference issues with `[Fix #N]` in the subject when applicable.
- For non-trivial changes, open a PR rather than pushing to `main`.
- After review, squash and force-push to keep history clean.

## Adding a new feature

If you're proposing a larger change, open an issue first to discuss
the design.  Port aims to stay small — we don't accept every feature,
even when they'd work.  The goalposts are in `doc/design.md` under
"Goals" and "Non-goals".

## Documentation

`README.md` is for users; `doc/design.md` is for contributors and
the curious.  When you add a feature, update whichever applies (or
both).  `CHANGELOG.md` gets an entry too — short, in the user's
voice, like the existing ones.
