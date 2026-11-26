# Alien Arena with game controllers

This is a fork of [Alien Arena](https://github.com/alienarena/alienarena) that
carries native game controller support until upstream merges it. The patches
are written as a stack of upstream pull requests, and a daily job keeps them on
top of upstream's latest code, builds and tests them, and tags release builds
for the snap.

This branch, `fork-tools`, holds only that job. The game is on the others.

## Branches and tags

| Ref | What it is |
|---|---|
| `master` | A copy of upstream's master. Never commit to it: the job moves it to match upstream every day. |
| `pad/1-keys`, `pad/2-linux`, ... | One branch per upstream pull request, each built on the one before it (the first on `master`). [stack.txt](stack.txt) lists them, in order. |
| `fork-tools` | This branch: the job, its scripts and stack.txt. It's the default branch, because GitHub only runs scheduled workflows from there. |
| `7.72.4`, ... | Upstream's release tags, copied. |
| `7.72.4-pad.1`, ... | Release builds: upstream's release with the whole stack on top, tested. The number goes up each time the stack changes. The snap builds the newest one. |

## What the job does

[Sync with upstream](.github/workflows/sync.yml) runs every day at 09:17 UTC,
whenever stack.txt changes, and when you run it from the Actions tab.

1. Moves `master` to upstream's master (fast forward only) and copies any new
   upstream tags. This happens even if the rest fails.
2. Replays each branch in stack.txt onto the one before it (the first onto
   `master`). Commits upstream already has are left out, and a branch whose
   whole change upstream already has is left alone and reported.
3. Remakes the generated files a branch needs (`configure`, `aclocal.m4`, the
   `Makefile.in` files, `config/config.h.in`, `CMD.html`, `CVAR.html`) with the
   tools upstream uses, autoconf 2.69 and automake 1.15.1 (in Docker), as one
   `Regenerate generated files` commit on top of the branch.
4. Replays the same stack onto upstream's latest release for a release build.
5. Builds `master`, every branch and the release build (each branch twice,
   with and without SDL2, once configure has `--with-sdl2`), and smoke tests
   each: the dedicated server loads dm-deathray, and the client starts under
   Xvfb, gets into the map and draws it. A client built with SDL2 also gets a
   virtual controller (SDL's virtual joystick, from `fork/vpad.c`), and has
   to see its Y button and move with its left stick. Screenshots and logs are
   kept with the run for 14 days.
6. If everything passed, pushes the branches that changed and the new
   `<release>-pad.N` tag in one go. If anything failed, it pushes nothing (but
   `master`) and opens an issue, **Fork sync stopped**, saying what and where.
   The issue gets a comment only when the problem changes, and is closed the
   next time the job runs clean.

A branch that didn't change keeps its commits, so on a quiet day nothing is
pushed and nothing is rebuilt.

## Setting up

Once, in the fork's settings:

1. **Actions**: on the Actions tab, switch workflows on (forks start with them off).
2. **Settings > Actions > General > Workflow permissions**: Read and write permissions.
3. **Settings > General > Default branch**: `fork-tools`.
4. **Settings > General > Features**: tick Issues, so the job can report.
5. Run **Actions > Sync with upstream > Run workflow** once, to see it pass.

Optional: if upstream ever changes a file in `.github/workflows`, GitHub won't
let the job's own token push `master`. Add a fine-grained personal access token
for this repository with read and write access to Contents and Workflows as the
secret `FORK_SYNC_TOKEN`, and the job uses it instead.

## Working on the patches

Clone the fork with upstream as a second remote:

```sh
git clone https://github.com/kenvandine/alienarena.git
cd alienarena
git remote add upstream https://github.com/alienarena/alienarena.git
git config rerere.enabled true      # remembers conflict fixes
```

### A new branch

Start the first branch from `master`, and each one after it from the one before:

```sh
git switch -c pad/1-keys origin/master
# ...commit...
git push -u origin pad/1-keys
git switch -c pad/2-linux pad/1-keys
```

Then add the branch to [stack.txt](stack.txt) on `fork-tools`. That push starts
the job. Leave a branch out of stack.txt while it doesn't build: the job tests
the whole stack and pushes nothing while any branch fails.

### Rules that keep the job working

- **Don't commit generated files.** Change `configure.ac`, the `Makefile.am`
  files, `CMD.md` and `CVAR.md`, and let the job add the `Regenerate generated
  files` commit. To build locally after changing them, run `autoreconf -fi`
  (or this branch's `fork/regen.sh .` for exactly upstream's autotools, with
  Docker), but don't commit what it makes. (If generated files do end up in a commit, the job
  settles conflicts in them by taking upstream's and making them again.)
- **Keep the branches straight.** No merge commits in them: rebase instead.
- **Keep CRLF files CRLF.** `source/client/keys.c`, `keys.h`, `menu.c` and
  `arena/default.cfg` have Windows line endings upstream, and a change that
  rewrites them all conflicts with every upstream change to the file.
- **Pick up the job's pushes before you change a branch.** The job rewrites
  the branches when upstream moves and adds the regenerate commit:

  ```sh
  git fetch origin
  git switch pad/2-linux && git reset --keep origin/pad/2-linux
  ```

### Changing a lower branch

Make the change on the top branch as a fixup of the commit it belongs to, then
rebase the stack so every branch moves together, and push them all:

```sh
git switch pad/3-menus                       # the top of the stack
git commit --fixup <commit in pad/1-keys>
git rebase -i --autosquash --update-refs origin/master
git push --force-with-lease origin pad/1-keys pad/2-linux pad/3-menus
```

Drop the `Regenerate generated files` commits from the todo list when you
rebase like this; the job makes them again.

## When the job stops

The **Fork sync stopped** issue says why. Usually it's one of these.

**A conflict with upstream.** Upstream changed lines one of the patches changes.
Rebase the stack onto upstream yourself, fix the conflicts, and push:

```sh
git fetch upstream && git fetch origin
git switch --detach origin/master
for b in pad/1-keys pad/2-linux pad/3-menus; do git branch -f "$b" "origin/$b"; done
git switch pad/3-menus
git rebase -i --update-refs upstream/master  # drop the Regenerate commits
# fix each conflict, git add, git rebase --continue
git push --force-with-lease origin pad/1-keys pad/2-linux pad/3-menus
```

Then run the job from the Actions tab (or wait for tomorrow).

**A build or smoke test failure.** The run's artifact has the configure and make
logs, the dedicated server's and client's logs, and the client's screenshot.
If `master` itself fails, upstream broke something (or the runner changed), and
the stack waits until it's fixed.

**The fork's master has its own commits.** Someone committed to `master`. Move
the commits to a branch and put `master` back:
`git push --force origin upstream/master:master`.

## When upstream merges a pull request

Nothing to do at first. While upstream's master has a branch's changes but its
latest release doesn't, the job leaves that branch alone, stacks the next
branch on `master`, and keeps putting the branch into release builds. Once a
release has it, the job opens an issue, **`pad/1-keys` is in upstream 7.72.5**:
then take the branch out of stack.txt and delete it.

Upstream pull requests come from these branches. The second one shows the first
one's commits too until the first is merged, so say in its description that it
builds on the first. When upstream's master moves, the job rebases the branches,
which updates any open pull request; that keeps them mergeable.

## Running it yourself

```sh
FORK_URL=https://github.com/kenvandine/alienarena.git DRY_RUN=1 TEST=always fork/sync.sh
```

`DRY_RUN=1` does and tests everything and pushes nothing; the report is
`work/summary.md` and the logs are in `work/out`. It needs Docker for the
autotools and the packages the workflow installs for the build and smoke test.
`fork/selftest.sh` checks the sync logic against a made-up upstream in a few
seconds, with no network, Docker or game data; the **Check the tools** workflow
runs it and shellcheck on every change to this branch.

## What isn't tested

The Windows build (Visual Studio), the Steam build, and real controllers: the
smoke test proves the game starts, loads a map, draws it, and takes a button
and a stick from a virtual controller, not that every pad's layout, hotplug or
the window's focus work. Try a release build with a real pad before pointing
players at it.
