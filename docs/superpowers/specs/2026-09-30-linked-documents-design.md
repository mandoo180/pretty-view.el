# pretty-view.el — Linked Documents Design

Date: 2026-09-30
Status: Approved for implementation planning
Supersedes, in part: `2026-09-11-pretty-view-design.md` §2 "Multi-file
site generation" (out of scope there; this document brings the linked
subset in). "An HTTP server" stays out of scope.

## 1. Purpose

Rendered output lives in a temporary directory (the Windows `TEMP` under
WSL), so every relative link in a rendered page resolves against that
directory and breaks. A README whose table links to 47
`menus/…/설명.md` files is the motivating case: none of the links open.

After this change, clicking a local link in a rendered page works:

- A link to another document (Markdown, Org, text) opens that document,
  rendered with the same theme, in the same tab.
- A link to any other local file (JSON, PDF, PNG, …) opens the original
  file in a new tab.
- An image too large to inline is shown on WSL too.

Success criteria: no setup, no server, works offline on every platform
the package supports, and Emacs never appears frozen while linked
documents are being rendered.

## 2. Scope

### In scope

- Rewriting local `<a href>` links in temp-directory output
- Rendering linked documents transitively, in the background
- Skipping writes of linked pages whose output did not change
- A browser-openable URL for any local file, including WSL paths
- Using that URL for the oversized-image fallback
- Org `file:` links to `.org` files

### Out of scope

- Lazy on-click rendering (needs an HTTP server or an OS protocol
  handler; both were considered and rejected — see §13)
- Rewriting links in `pretty-view-export` output
- Placeholder pages for links clicked before their page exists
- Cancelling a background run
- Single-quoted `href` attributes in raw HTML
- Absolute Windows drive-letter paths (`C:/…`) written as links

## 3. Behaviour overview

```
pretty-view (root buffer)
  └─ render root → rewrite links ──accept──→ run: visited, count
       │                                         │ enqueue new documents
       ↓                                         ↓
     write root, open browser            global FIFO queue
                                                 │ timer tick
                                                 ↓
                                  render linked doc (temp buffer)
                                  → rewrite links → accept/enqueue
                                  → write only if HTML changed
```

1. `pretty-view` renders the root document synchronously, rewriting its
   local links. Each accepted linked document is queued. The root is
   written and the browser opens, exactly as fast as today.
2. A timer drains the queue in the background. Each linked document is
   rendered in a temporary buffer; its links are rewritten under the
   same rules, which may queue more documents (breadth-first).
3. The echo area shows progress, and one summary line when the queue
   empties.

The same flow runs for `pretty-view-file`, `pretty-view-live-mode`
saves, and `pretty-view-select-theme`. `pretty-view-export` rewrites
nothing: its output is written where the user chose, often next to the
sources, where relative links already work.

## 4. Link classification and rewriting (`pretty-view-links.el`)

`pretty-view-links-rewrite` is a pure function of the HTML string, the
base directory, and an accept function. It runs on the complete document
from `pretty-view-html-document`, after body filters, TOC, and asset
inlining, and before the live script is added. Because it works on
rendered HTML, it treats Markdown, Org, and text the same way.

It matches `<a …href="…"…>` (double-quoted, as every renderer emits)
and classifies each `href`:

| `href` | Action |
|---|---|
| empty, `#…`, `//…`, or a scheme other than `file:` | untouched |
| base directory is remote (`file-remote-p`) | untouched |
| a path, or a `file:` URL, naming no regular file | untouched |
| a document that the run accepts | output file name + fragment, same tab |
| any other existing local file | file URL + fragment, new tab |

Decoding before resolution: HTML entities (`&amp;`, `&quot;`, `&#39;`,
`&lt;`, `&gt;`) are unescaped; the fragment (from the first `#`) and any
query (from the first `?`) are split off; the path is percent-decoded
as UTF-8. A `file:` URL loses its `file://` or `file:` prefix. The path
is expanded against the base directory, the source document's directory,
the same base used for images.

A **document** is a file whose extension, compared case-insensitively,
is in `pretty-view-follow-links-extensions`. A document is accepted
when `pretty-view-follow-links` is non-nil and the current run accepts
it (§7). A document that is not accepted, because the feature is off or
the run hit its limit, is treated as any other local file: its raw
source opens in a new tab.

Rewritten `href` values are escaped with `pretty-view-escape-attribute`.

- Document: the output file's name, percent-encoded, plus the original
  fragment. All output files share one directory, so the bare name is
  a correct relative link.
- Other file: `pretty-view-browser-file-url` of the file, plus the
  original fragment (so a PDF's `#page=3` survives). The tag gains
  `target="_blank" rel="noopener"` unless it already has a `target`.

Example, from a README in `…/company-setup-manual/`:

```
menus/01_ORGCOP00100_통합환경등록/설명.md#화면-구성
→ %EC%84%A4%EB%AA%85-<hash>.html#화면-구성
menus/01_ORGCOP00100_통합환경등록/structure.json
→ file://wsl.localhost/Ubuntu-24.04/home/…/structure.json  (new tab)
```

## 5. File URLs (`pretty-view-browser.el`)

`pretty-view-browser-file-url` returns a URL the configured browser can
open for an absolute local file. It sits with every other platform
decision.

| Platform | File | URL |
|---|---|---|
| WSL | `/mnt/<d>/rest` | `file:///<D>:/rest` |
| WSL | any other path | `file://<host>/<distro>/path` |
| Windows | `C:/rest` | `file:///C:/rest` |
| Linux, macOS | `/path` | `file:///path` |

On WSL, the `//<host>/<distro>` prefix comes from `wslpath -w /`
(`\\wsl.localhost\Ubuntu-24.04\` → `//wsl.localhost/Ubuntu-24.04`). It
is computed on first use and cached in a variable, like the Windows
temporary directory, so tests can rebind it. If `wslpath` fails, the
result is `file://` plus the Linux path, which is what the package
produces today.

Every path segment is percent-encoded; `/` and a drive's `C:` are kept.

Verified on 2026-09-30 in a Windows browser, from a page under
`file:///C:/Users/…/Temp/pretty-view/`: `file://wsl.localhost/…` links
to a JSON file, a PDF, and a PNG each opened in a new tab, and an
`<img src>` with such a URL displayed.

The oversized-image fallback in `pretty-view-html--inline-assets` now
uses this function instead of `(concat "file://" file)`, which fixes
large images on WSL for every output, `pretty-view-export` included.

## 6. Rendering a linked document (`pretty-view.el`)

`pretty-view--render-linked` renders one source file in a temporary
buffer that behaves as if it visited the file:

- The file's contents are inserted; `buffer-file-name` and
  `default-directory` are set from the file. Title, base directory for
  images and links, and output path are therefore identical to a
  `pretty-view-file` render of the same file: one document has one page,
  whichever way it was reached.
- The major mode comes from `set-auto-mode` inside `delay-mode-hooks`,
  so the user's `markdown-mode` or `gfm-mode` is used and dispatch
  through `pretty-view-source-functions` works unchanged, but mode hooks
  (LSP, linters, and so on) never run.
- The disk contents are used, even when a buffer visiting the file has
  unsaved changes.
- Before the buffer is killed it is marked unmodified and its file name
  cleared, so killing it can never prompt.

## 7. Background queue (`pretty-view-links.el`)

### 7.1 Runs

A **run** starts whenever a root document is rendered for temp output.
It holds the visited set (absolute source paths, including the root
when it is a file), the
count of accepted documents, whether the limit was hit, and counters
for the summary (written, unchanged, failed). While a document is being
rendered for a run, `pretty-view-links--run` is bound to that run; the
accept function reads it.

The accept function, given an absolute document path:

- already visited → accept (returns the output path; a back-link to the
  root or a cycle is rewritten but never re-queued)
- count below `pretty-view-follow-links-limit` → mark visited, count it,
  enqueue it unless the global queue already holds its output path,
  accept
- otherwise → note that the limit was hit, reject

### 7.2 Queue and scheduling

One global FIFO queue holds items of (source, output, run). A hash of
queued output paths removes duplicates across runs: a second run that
reaches a queued document links to it without queueing it again. Runs
never cancel each other.

The queue is drained by a timer. Each tick:

- if input is pending, reschedules itself for 0.2 s later and does
  nothing else;
- otherwise processes items until 50 ms have passed or input is
  pending, always at least one, then reschedules itself for 0.01 s
  later while items remain.

A tick therefore lasts at most 50 ms plus one document, and one
document costs about 6 ms of rendering plus, when the page changed,
about 90 ms of writing to `/mnt/c` (measured, §12). Timers run with
quitting inhibited, so a tick is not interruptible, and none needs to
be.

Processing an item binds its run, renders the document to a string
(following its links, §4), and then writes it unless §8 says it is
unchanged. When the last item of a run is done, the run's summary is
shown.

### 7.3 Pages owned by live mode

If a buffer visiting the source has `pretty-view-live-mode` on and the
output file exists, the item's links are still followed, but the file
is not written. That buffer's own saves maintain the page and its live
script, and a background write would silently drop the watcher.

### 7.4 Messages

- Progress, `pretty-view: rendering linked documents 12/55`, is shown
  with `message-log-max` bound to nil, so it does not flood
  `*Messages*`.
- The summary, `pretty-view: linked documents — 55 written, 0 unchanged,
  0 failed`, is logged. If the limit was hit, it is followed by
  `stopped after 200 linked documents; see
  pretty-view-follow-links-limit`.
- While the minibuffer is active, progress is not shown at all, and the
  summary and failure messages are logged to `*Messages*` with
  `inhibit-message` bound, so a prompt is never overwritten and nothing
  is lost.

## 8. Unchanged pages

Writing to `/mnt/c` costs about 90 ms a file; rendering costs about
6 ms. So every linked document is rendered on every run, and only the
write is skipped when nothing changed.

A session table maps an output path to the SHA-1 of the HTML last
written there. A linked page is written unless its output file exists
and the new HTML's hash equals the recorded one. Every write through
`pretty-view-render-buffer-to-file` for temp output records its hash,
including the root and pages written by live mode, except a render of a
buffer with unsaved changes, whose HTML does not reflect the file on
disk.

Consequences:

- Any change that alters the output is picked up: the source, a theme
  switch, a renderer, a head function, the TOC setting. No fingerprint
  or forcing command is needed.
- Links of unchanged documents are still followed, so a change two
  levels down is still picked up.
- The first run in an Emacs session writes every linked page (the table
  starts empty); later runs write only what changed. For the motivating
  README: first run about 5 s in the background; a live-mode save about
  0.3 s of rendering plus one `/mnt/c` stat per page.
- An existence check per page recovers from the temporary directory
  being cleaned.

## 9. Org (`pretty-view-org.el`)

`ox-html` rewrites `[[file:foo.org]]` to `href="foo.html"` because
`org-html-link-org-files-as-html` defaults to t. While rendering for
temp output, that variable is bound to nil, so the link keeps
`foo.org` and §4 rewrites it like any Markdown link. Export output keeps
Org's default.

Org links with a search option (`[[file:foo.org::*Heading]]`) are
rewritten to the document without a guaranteed fragment.

`ox` gives each headline a random id (`org-export-new-reference` calls
`random`), so exporting unchanged Org text twice gives different HTML,
and §8 would rewrite every Org page on every run. `pretty-view-org-body`
therefore seeds the generator with a fixed string before exporting and
reseeds it from the system (`(random t)`) afterwards. Ids stay unique
within a page and become stable across renders. As a side effect, a
live-mode save of unchanged Org text no longer reloads the tab.

## 10. Customization

| Variable | Default | Meaning |
|---|---|---|
| `pretty-view-follow-links` | `t` | Render linked documents. Nil: no run, no queue; document links open their raw source in a new tab like any other file |
| `pretty-view-follow-links-limit` | `200` | Most linked documents one run accepts |
| `pretty-view-follow-links-extensions` | `("md" "markdown" "org" "txt")` | Extensions treated as documents |

Converting non-document links to file URLs applies to all temp output
and has no switch: without it those links are always broken.

`pretty-view-render-buffer-to-file` gains an optional third argument,
LINKS. Non-nil rewrites links and, when following is on, starts a run.
`pretty-view`, `pretty-view--live-update`, and
`pretty-view-select-theme` pass it; `pretty-view-export` does not.

## 11. Error handling

- Each item is processed inside `condition-case`. A failure logs
  `pretty-view: could not render FILE (ERROR)`, counts toward the run's
  failures, and the queue moves on.
- A source deleted between queueing and processing is a failure like
  any other.
- The tick function wraps its own bookkeeping in `condition-case` as
  well. An error there (a bug, not a document failure) is logged, the
  queue and its duplicate table are cleared, and no further tick is
  scheduled, so the next run starts from a clean state instead of a
  half-updated one.
- No placeholder files are written, so an interrupted Emacs leaves
  nothing to clean up.

Stated limit: on the first render of a document set, a link clicked
before its page is written shows the browser's "file not found" page.
Documents are processed in document order, so the first links become
ready first. Later runs overwrite existing pages, so the window does not
recur.

## 12. Measurements (2026-09-30, WSL2, Emacs 32.0.50)

| Operation | Result |
|---|---|
| Render the 55 `설명.md` files (143 KB of Markdown) | 0.31 s, about 6 ms each |
| Write 55 small files to `/mnt/c` from Emacs | 4.5–6.8 s, about 90 ms each |
| Write 55 small files to `/mnt/c` from the shell | 2.4 s, about 43 ms each |
| Stat 55 files on `/mnt/c` | 0.93 s, about 17 ms each |

I/O on `/mnt/c`, not rendering, is the cost. Hence background
processing (§7) and skipping unchanged writes (§8). Placeholder pages
were rejected because each costs as much to write as the real page.

## 13. Alternatives considered

- **Custom URL protocol** (`pretty-view://` → `emacsclient`): truly lazy,
  but needs a running Emacs server, per-OS handler registration
  (`reg.exe` on WSL, xdg on Linux, an app bundle on macOS), and a
  browser confirmation on every click that `file://` origins do not
  remember.
- **Built-in HTTP server** (`make-network-process`): truly lazy, but
  reverses the no-server decision and brings port management, local
  security, server lifetime, and a dependence on WSL localhost
  forwarding.
- **Separate Emacs process for background rendering**: cannot carry the
  user's configuration (themes, renderer lambdas, major modes).
- **Lisp threads**: cooperative; a render never yields, so Emacs would
  still block.

## 14. Module changes

| File | Change |
|---|---|
| `pretty-view-links.el` (new) | Rewriting (§4), runs and queue (§7), unchanged-page table (§8), the three options (§10) |
| `pretty-view-browser.el` | `pretty-view-browser-file-url` and its WSL prefix cache (§5) |
| `pretty-view-html.el` | Oversized-image fallback uses the file URL (§5) |
| `pretty-view-org.el` | `org-html-link-org-files-as-html` binding and the seeded export (§9) |
| `pretty-view.el` | LINKS argument, `pretty-view--render-linked` (§6), wiring into commands and live mode |
| `README.md` | A "Linked documents" section and the new variables |
| `2026-09-11-pretty-view-design.md` | A note on the superseded out-of-scope item |

`pretty-view-links.el` does not require `pretty-view.el`. The render
function for linked documents is passed in, which keeps the dependency
one-way and lets tests drive the queue with a fake.

## 15. Testing

ERT, in temporary directories on the Linux file system. No real timers:
tests call the tick function directly.

- **Rewriting**: relative paths, fragments, percent-encoded and Korean
  paths, `&amp;`, untouched schemes and `#` links, missing files,
  directories, remote base directory, non-document files (URL plus
  `target`/`rel`, existing `target` kept), rejected documents falling
  back to file URLs, feature off.
- **File URLs**: WSL home path, WSL `/mnt/c` path, `wslpath` failure,
  Windows, Linux; segment encoding. WSL state is rebound through the
  cache variables, as in the existing WSL tests.
- **Queue**: breadth-first order, an A↔B cycle, a back-link to the root,
  duplicates across runs, the limit, an unchanged page not rewritten
  while its links are still followed, a deleted output rewritten, a
  failure isolated, a live-mode buffer's page not written, summary
  counts, pending input deferring work.
- **Org**: identical HTML for unchanged text, `random` reseeded after
  export; `[[file:foo.org]]` rewritten in temp output; export keeps
  `foo.html`.
- **Linked render**: title, output path, and base directory match a
  `pretty-view-file` render; mode hooks do not run; the temporary
  buffer is killed without prompting.
- **Integration**: `pretty-view` on a temporary tree writes the root
  immediately; draining the queue writes every linked page with correct
  links.
- **Gates**: `make all` (isolated compile and tests) and `make checkdoc`
  pass.
