# nsspell

An ispell/Aspell-compatible spell checker that uses the macOS system spell
checker (`NSSpellChecker`) as its backend.  It speaks the `ispell -a` pipe
protocol and identifies itself as Aspell 0.60, so Emacs's `ispell.el` and
`flyspell.el` use it unchanged, with UTF-8 and dictionary discovery.

## Build and install

    make
    make install            # PREFIX=/usr/local by default

`make install` also puts `nsspell.el` in `$(PREFIX)/share/emacs/site-lisp`.

## Emacs

```elisp
(setq ispell-program-name "/usr/local/bin/nsspell")
;; Optional: any macOS language code (en, en_GB, de, pt_BR, ...),
;; a traditional ispell name (english, british, deutsch, ...), or "auto".
(setq ispell-dictionary "en_GB")
```

## Usage

    nsspell [options] -a | -l | dicts | config KEY | -v

| Mode | Meaning |
|------|---------|
| `-a`, `pipe` | ispell pipe protocol |
| `-l`, `list` | print misspelled words read from standard input |
| `dicts` | list available dictionaries (macOS spelling languages) |
| `config KEY` | print `dict-dir`, `data-dir`, `lang` or `encoding` |
| `-v`, `-vv`, `--version` | print the version banner |

| Option | Meaning |
|--------|---------|
| `-d`, `--lang`, `--master NAME` | dictionary; default is the system's current spelling language |
| `-p`, `--personal FILE` | personal word list in Aspell `.pws` format |
| `--encoding ENC`, `-i ENC` | `utf-8` (default) or `iso-8859-1` |
| `-t`, `--mode=tex` | skip TeX control sequences and non-prose arguments |

Other Aspell/ispell options that Emacs may pass (`-m`, `-B`, `-C`,
`--sug-mode`, ...) are accepted and ignored.

Pipe commands: `^text` and plain lines are checked; `*word` and `&word` add to
the personal dictionary, `@word` accepts for the session, `#` saves, `!`/`%`
toggle terse mode, `+`/`-` toggle TeX mode, `$$cr KEY` reads a config value.

`config dict-dir` creates `~/Library/Caches/nsspell/aspell/<lang>.dat` stubs,
which Emacs reads when it discovers Aspell dictionaries.

## Grammar

The ispell protocol is word-by-word, so grammar checking is a separate
mode built on the macOS text checker's sentence-level analysis.

    nsspell grammar [-d NAME] [--quick] [--spelling] [-t] [FILE...]

prints `FILE:LINE:COL: MESSAGE [-> CORRECTION | ...]` for each issue (lines
and columns are 1-based, columns in characters), so it works with
`M-x compile`.  It exits 0 when there are no issues, 1 when there are, and
2 on errors.  Text is checked a paragraph at a time; paragraphs are
separated by blank lines.

| Option | Meaning |
|--------|---------|
| `--full` | wait for the full analysis (default) |
| `--quick` | report only results available at once |
| `--spelling` | also report misspelled words |
| `-t`, `--mode=tex` | skip TeX markup |
| `--server` | JSON-lines server used by `nsspell.el` |

The full analysis, which catches context-dependent errors such as
"Their going" or "datas", needs macOS 27 and takes a few seconds per
paragraph the first time it is seen.  macOS caches the analysis, so
rechecking unchanged text is instant, and `--quick` on text that was
never analysed usually reports nothing.

### Emacs

```elisp
(require 'nsspell)
(setq nsspell-program "/usr/local/bin/nsspell")
(add-hook 'text-mode-hook #'nsspell-grammar-mode)
```

`nsspell-grammar-mode` adds a Flymake backend; issues are underlined with
`nsspell-grammar-face` and appear in `flymake-show-buffer-diagnostics`.
In programming modes only comments and docstrings are checked.

| Key | Command |
|-----|---------|
| `C-c $` | `nsspell-grammar-correct`: pick a correction, or ignore the issue |

`nsspell-grammar-next` and `nsspell-grammar-previous` move between grammar
issues; they are unbound by default.

Customize `nsspell-grammar-full`, `nsspell-grammar-check-spelling` and
`nsspell-grammar-language` (defaults to `ispell-local-dictionary` or
`ispell-dictionary`).  One server process is shared by all buffers;
`M-x nsspell-kill-server` restarts it.

## Personal dictionaries

Without `-p`, words added with `*` go to the macOS user dictionary
(`~/Library/Spelling`), so they're shared with every other app on the Mac.
With `-p FILE`, words are kept in that file instead and are written out only
when a `#` command arrives, as with ispell.

## Limitations

- Grammar issues are not reported through the ispell protocol (which has
  nowhere to put them); use `nsspell grammar` or `nsspell.el`.
- `-d auto` picks the language for each line using NaturalLanguage.  It is
  unreliable for short text, including the single words flyspell sends,
  which fall back to the system language.
- There is no interactive (non-pipe) ispell mode.
