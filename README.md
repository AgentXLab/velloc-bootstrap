# Velloc Agent Bootstrap

This repository bootstraps the Velloc Agent workspace. It owns the
`.gclient` configuration plus the bootstrap and build scripts used to sync and
compile the `src/` checkout.

## Repository URL (updated)

```bash
git clone git@github.com:AgentXLab/velloc-bootstrap.git
```

## Workspace layout

```
velloc-bootstrap/
├─ .gclient
├─ args/
├─ bootstrap.sh
├─ build.bat
├─ build.sh
├─ depot_tools/      (not tracked; required)
├─ scripts/
│  ├─ bootstrap_cli.py
│  └─ custom_browser_tag.py
├─ release_manifest.json  (generated)
└─ src/              (Chromium checkout)
```

`gclient` always creates `src/` directly under the folder that contains
`.gclient`. There is no extra `chromium/` layer unless you change the config.

The default `src` remote configured in `.gclient` is:

```bash
git@github.com:AgentXLab/velloc-chromium.git
```

After `src/` is cloned, the bootstrap flow also ensures
`src/custom_browser` is cloned from:

```bash
git@github.com:AgentXLab/velloc-core.git
```

## Prerequisites

- Git and Python 3
- Bash for `build.sh` (Git Bash or WSL on Windows)
- Sufficient disk space and a stable network connection for Chromium syncs

## Fresh setup (first run)

1) Clone the repo:

```bash
git clone git@github.com:AgentXLab/velloc-bootstrap.git
cd velloc-bootstrap
```

2) Install depot_tools:

```bash
./bootstrap.sh
```

Choose option **1) Install depot_tools**.

3) Sync Chromium:

Run `./bootstrap.sh` again and choose **3) Bootstrap & Sync (clone src + custom_browser + gclient sync)**.

4) Build:

```bash
./build.sh
```

Pick a build config (defaults to `Debug`) and wait for the build to finish.

On Windows PowerShell, you can use:

```powershell
.\build.bat
```

## Bootstrap (sync Chromium)

Run:

```bash
./bootstrap.sh
```

Select one of the menu options:

1) **Install depot_tools**
   Clones `depot_tools` into `./depot_tools` if it does not already exist.
2) **Fast sync (shallow fetch custom/main + gclient sync)**
   Shallow-fetches `custom/main` for `src/` and the default branch for
   `src/custom_browser`, then runs a shallow `gclient sync`.
   This minimizes data but does not pull full history.
3) **Bootstrap & Sync (clone src + custom_browser + gclient sync)**
   Clones `src/` (Chromium) and `src/custom_browser` (velloc-core) if missing,
   ensures the origin remotes match, resolves branches, then runs a shallow,
   forced `gclient sync`.
4) **Bootstrap (force) & Sync (force, shallow)**
   Deletes `src/` and re-clones before syncing. Use this to reset a workspace.
5) **Restore release snapshot**
   Checks out each repo listed in `release_manifest.json` to its recorded commit.

If you do not have `depot_tools` yet, run option 1 first.

The script reads the `src` URL from `.gclient` and runs:

```
gclient sync --force --no-history --shallow --revision "src@<revision>"
```

Note: **Fast sync** always checks out the configured `SRC_BRANCH` (default
`custom/main`) with a shallow fetch. It is the smallest download but does not
pull full history. Use **Bootstrap & Sync** or the `sync` subcommand if you
need full branch resolution or specific revisions.

### Bootstrap overrides

You can override the defaults via environment variables:

- `SRC_URL` to override the `.gclient` URL
- `SRC_BRANCH` to choose a branch (default: `custom/main`)
- `SRC_REVISION` to pin an exact ref (default: `refs/heads/<branch>`)
- `CUSTOM_BROWSER_URL` to override the velloc-core URL
- `CUSTOM_BROWSER_BRANCH` to choose a branch (default: `main`)
- `CUSTOM_BROWSER_REVISION` to pin an exact ref (default: `refs/heads/<branch>`)

If the requested branch is missing, the script falls back to the remote default
branch (or `main`/`master`).

### CLI usage (non-interactive)

```bash
python scripts/bootstrap_cli.py install-tools
python scripts/bootstrap_cli.py fast-sync
python scripts/bootstrap_cli.py bootstrap
python scripts/bootstrap_cli.py sync
python scripts/bootstrap_cli.py rebootstrap --yes
python scripts/bootstrap_cli.py restore
```

Custom browser overrides:

```bash
python scripts/bootstrap_cli.py bootstrap --custom-browser-url git@github.com:AgentXLab/velloc-core.git
python scripts/bootstrap_cli.py bootstrap --custom-browser-branch main
python scripts/bootstrap_cli.py bootstrap --custom-browser-revision refs/heads/main
```

Restore options:

```bash
python scripts/bootstrap_cli.py restore --manifest release_manifest.json
python scripts/bootstrap_cli.py restore --force
python scripts/bootstrap_cli.py restore --no-fetch
```

## Build (chrome or mini_installer)

Run:

```bash
./build.sh
```

What it does:

- Lists `args/*.gn` files and prompts for a build config (defaults to `Debug`)
- Copies the selected args file to `src/out/<name>/args.gn`
- Runs `gn gen` if `build.ninja` is missing
- Builds `chrome` with `autoninja -C src/out/<name> chrome`

The **mini_installer** option:

- Prompts for an args file
- Uses `src/out/Release`
- Builds `mini_installer`

### Adding a new build config

Create another `*.gn` file in `args/`. The filename becomes the menu option.

### Notes

- If `gn` is missing, `build.sh` runs `gclient runhooks` to fetch it.
- To force a clean generate, delete `src/out/<name>/build.ninja` (or the entire
  `src/out/<name>` directory) and rerun `./build.sh`.

## Release snapshots

The release workflow writes a `release_manifest.json` at the workspace root.
Use the **Restore release snapshot** option in `./bootstrap.sh` (or the
`restore` subcommand) to check out all tracked repos to that snapshot.

## License

MIT for the bootstrap tooling in this repo. Chromium and third-party code in
`src/` are licensed under their own terms.
