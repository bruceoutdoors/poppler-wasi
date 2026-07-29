# Patches

Patches applied to the Poppler submodule at build time by `scripts/apply-patches.sh`.

They live here, outside `third_party/poppler`, so the submodule stays a pristine checkout of
an upstream tag. Bumping Poppler is then a one-line pin change rather than rebasing a fork.

## Rules

- **Prefer build configuration over patching.** Nearly everything Poppler needs for WASI is
  reachable through CMake options — `FONT_CONFIGURATION=generic`, the `ENABLE_*` switches,
  and wasi-libc's opt-in flags. Reach for a patch only when configuration genuinely cannot
  express the change.
- **Keep each patch minimal and single-purpose**, and start the file with a comment block
  explaining what breaks without it, why the fix is correct, and whether it is upstreamable.
  `git apply` ignores text before the first `diff --git`, so the rationale costs nothing.
- **Prefer upstreamable fixes.** Both current patches are plain bugs that happen to surface
  on WASI first, not WASI-specific hacks; they should be sent upstream so this directory can
  shrink back to empty.
- Generate with `git -C third_party/poppler diff -- <path>` and name them `NNNN-summary.patch`;
  they are applied in sorted order.

`scripts/apply-patches.sh` is idempotent (it skips patches already applied) and
`make unpatch` restores a clean checkout.

Because patches are applied to the submodule worktree at build time, the submodule is
normally dirty after a build. `.gitmodules` sets `ignore = dirty` for it so this does not
show up as a spurious change in `git status`; the pinned commit is still tracked as usual.
