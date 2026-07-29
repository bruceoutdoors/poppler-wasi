# poppler-wasi

Upstream [Poppler](https://poppler.freedesktop.org/) command-line utilities as standalone
`wasm32-wasip1` **WASI command modules**, for Wasmtime and other WASI runtimes.

No JavaScript glue, no bindings, no custom API: each `.wasm` is the upstream utility with its
original CLI, over stdin/stdout and WASI preopens.

## Why

- **Sandbox untrusted PDFs.** A big C++ parser with a CVE history, run with only the capabilities
  you grant it — no filesystem, no network, capped memory. That limits the impact of a parser
  vulnerability, assuming the WASI runtime's isolation boundary holds.
- **Embed without native binaries.** No native Poppler installation required; run the modules
  through a WASI runtime, either embedded in your application or as a separate command.
- **One artifact everywhere.** Same module on Linux, macOS and Windows, x86-64 and arm64.
- **Pinned build inputs.** Poppler, toolchain and dependency versions recorded per release.

Not a browser project — Emscripten ports cover that:
[antimatter15/pdftotext-wasm](https://github.com/antimatter15/pdftotext-wasm) and
[discere-os/poppler.wasm](https://github.com/discere-os/poppler.wasm). Both need JS glue and fork or
pin old Poppler; this targets WASI directly and tracks upstream unforked.

## Install

Grab the module you need from the
[latest release](https://github.com/bruceoutdoors/poppler-wasi/releases/latest):

```sh
BASE=https://github.com/bruceoutdoors/poppler-wasi/releases/latest/download
curl -LO $BASE/pdftotext.wasm
curl -LO $BASE/pdftotext.wasm.sha256
shasum -a 256 -c pdftotext.wasm.sha256   # or sha256sum -c
```

## Usage

```sh
# text extraction: stdin/stdout only, no host directories preopened
wasmtime run pdftotext.wasm -layout - - < input.pdf > output.txt

# utilities that read or write files need an explicit preopened directory
wasmtime run --dir=. pdfinfo.wasm input.pdf
wasmtime run --dir=. pdfseparate.wasm input.pdf page-%d.pdf
```

Modules:

1. `pdftotext` — extract text
2. `pdfinfo` — document metadata
3. `pdffonts` — list fonts
4. `pdfimages` — extract images
5. `pdftops` — convert to PostScript
6. `pdftohtml` — convert to HTML
7. `pdfseparate` — split into single pages
8. `pdfunite` — merge documents
9. `pdfattach` — add an embedded file
10. `pdfdetach` — list or extract embedded files
11. `pdftoppm` — rasterise to PPM/PGM/PBM

`pdftocairo` (needs cairo) and `pdfsig` (needs a signature backend) are skipped by upstream's own
build guards.

### Precompiling (AOT)

Wasmtime JIT-compiles on every run. In the benchmark below that cost about 15 ms and most of the
peak memory; precompiling removed nearly all of both. Worth it if you invoke these often.

```sh
wasmtime compile pdftotext.wasm -o pdftotext.cwasm
wasmtime run --allow-precompiled pdftotext.cwasm -layout - - < input.pdf > output.txt
```
A `.cwasm` is native code tied to the exact Wasmtime version that produced it, so compile your own
and regenerate after upgrading. Further reading:
[pre-compiling](https://docs.wasmtime.dev/examples-pre-compiling-wasm.html).

## Performance

One run of `make bench` on an Apple M4 Pro: `pdftotext -layout` over a 1000-page, 466 KiB PDF
against native Poppler 26.07.0, best of 10, output byte-identical across all three. These figures
describe that machine and that document — reproduce with `make bench` before relying on them.

| metric | native | wasm (JIT) | wasm (AOT) | wasm/native | aot/native |
| --- | --- | --- | --- | --- | --- |
| wall clock | 311 ms | 403 ms | 389 ms | 1.30× | 1.25× |
| startup floor | 51 ms | 67 ms | 53 ms | 1.31× | 1.04× |
| work (wall − startup) | 260 ms | 336 ms | 336 ms | 1.29× | 1.29× |
| CPU (user+sys) | 0.25 s | 0.35 s | 0.34 s | 1.40× | 1.36× |
| peak RSS | 14.2 MiB | 33.4 MiB | 16.8 MiB | 2.35× | 1.18× |

Extraction ran ~1.29× slower than native, and that is the row that scales with document size; AOT
does not change it, since precompilation affects startup, not steady state. Memory was the largest
gap and mostly the JIT: 2.35× under `wasmtime run` but 1.18× precompiled.

## Limitations

Consequences of the minimal dependency set (FreeType and zlib only), all deliberate:

- **No system fonts.** Rasterising a PDF that relies on non-embedded fonts logs `Config Error: No
  display font for ...`. Basic text extraction generally does not need system fonts, since it uses
  embedded font encodings, though unusual PDFs may behave differently.
- **No JPEG or JPEG 2000 decoding.** Poppler dropped its built-in DCT and JPX decoders in 26.07,
  so these need libjpeg and openjpeg. The obvious next step if `pdfimages`/`pdftoppm` matter.
- **`pdftoppm`/`pdfimages` emit only PPM/PGM/PBM** — PNG, JPEG and TIFF need libpng, libjpeg,
  libtiff.
- **Single-threaded.** Each invocation is single-threaded, matching the upstream CLI
  implementations. Run multiple instances for request-level parallelism.
- **No signing.** `pdfsig` is not built.

## Building

Only needed to develop or to build an unreleased version. Needs `cmake` (≥ 3.28), `ninja`, `git`,
`curl`, optionally `ccache`; the WASI toolchain is downloaded automatically and no system Poppler
or FreeType is used.

```sh
make build    # fetch toolchain + deps, cross-compile, stage dist/
make test     # golden and smoke tests under wasmtime
make help     # all targets
```

Idempotent and incremental — a clean build is about a minute, a no-op rebuild about a second.
Poppler is a submodule, pinned by commit and never vendored; FreeType and zlib come from
sha256-pinned tarballs. Two one-line patches are needed, both plain upstream bugs rather than WASI
workarounds — see [patches/poppler/](patches/poppler/README.md). `scripts/build.sh` documents the
non-obvious parts of the configuration.

Modules are stripped when staged into `dist/`, which removes about two thirds of each one — almost
all of it DWARF from wasi-sdk's prebuilt `libc`/`libc++`, not from Poppler. The binaries under
`build/poppler/utils/` keep their debug info, so debug against those.

Tests compare `pdftotext` output byte-for-byte against checked-in regression outputs, originally
generated by a *native* Poppler, so they assert the wasm build matches native rather than merely
agreeing with itself. The comparison is always against the checked-in files: when they came from an
older Poppler than the submodule, the run only prints a note. A diff therefore needs manual review
before `make goldens` regenerates them, which needs a matching native `pdftotext`.

## Versioning and releases

The Poppler version lives in exactly two places: the submodule pin (a commit SHA in the git index,
which is what CI builds) and `scripts/check-upstream.sh`, which discovers the newest stable tag
from upstream at runtime. It is in no script, workflow or config file. `make check-upstream` prints
what the release workflow would build.

FreeType and zlib are pinned by exact version and sha256 in `scripts/versions.env`. Poppler only
declares a FreeType *minimum* and no zlib constraint, so newer is always allowed — but a floating
dependency cannot be checksummed and would make releases unreproducible. The pins move
automatically instead: the scheduled workflow resolves newest stable, builds, tests and commits the
bump. `make update-deps` does the same locally. The release job additionally runs
`scripts/update-deps.sh --if-needed`, which repins FreeType only when Poppler's floor has risen
above the pin, so an unattended release is never blocked.

The workflow runs every six days and builds **only the single newest upstream tag — it does not
backfill**, so if two releases land between runs the older is skipped permanently. Trigger it
manually with a `tag` input (`26.06.0` or `poppler-26.06.0`) to build a specific version, and
`force` to replace an existing release's assets. Otherwise it is idempotent: an existing release
for the target tag means it does nothing.

Both jobs commit straight to `main` and only after building and testing, so `main` only receives
green commits — but `ci.yml` is `pull_request` only and does not re-run on them, so that testing is
the workflow's own. Releases are tagged to match upstream and target the commit that was built.

## Licence

GPL-2.0-or-later, matching upstream Poppler — see [LICENSE](LICENSE). These binaries statically
link Poppler and are distributed under GPL-2.0-or-later. FreeType (FTL or GPLv2) and zlib are
compatible.

Each release records its corresponding source in `BUILD-INFO.txt`: the Poppler repository and exact
commit, the FreeType and zlib tarball URLs with their sha256s, and a pointer to the only
modifications, [patches/poppler/](patches/poppler/README.md).
