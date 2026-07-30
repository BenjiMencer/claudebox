# Locked-down Claude Code in Docker (macOS)

Runs Claude Code in a container whose only permitted network destination is a
web-scanner service. All web access goes through a scanner skill; everything
else is blocked at the network layer. A fail-closed self-test refuses to start
the agent if the wall isn't holding.

This is meant to be cloned and run as-is — the only thing you need to bring is
a reachable scanner service and its token.

## Prerequisites

- Docker Desktop for Mac.
- A running web-scanner service reachable at a fixed IP (default assumed here:
  `100.123.181.11`, ports `8080` for the Anthropic-compatible API and `8099`
  for the scanner itself). If yours lives elsewhere, override `SCANNER_IP` /
  `ANTHROPIC_BASE_URL` / `SCANNER_BASE_URL` as shown below.
- A `SCANNER_TOKEN` issued by that service.

## Quick start

```bash
export SCANNER_TOKEN="<your token>"
./run.sh
```

`run.sh` builds the image on first run (and whenever the Dockerfile changes),
then starts the container with the current directory mounted read/write at
`/home/ccagent/work` inside the container — that's what Claude Code will see
and edit. Run it from the root of the project you want the agent to work on.

Pass extra arguments straight through to the `claude` CLI, e.g.:

```bash
./run.sh --resume
```

## Recommended: a shell function for daily use

The `claude-local` zsh function lives in `claude-local.zsh` in this repo. It
does everything `run.sh` does, plus:

- reads `SCANNER_TOKEN` from a `.env` file next to this repo instead of
  requiring you to `export` it every session,
- starts Docker Desktop automatically if it isn't running,
- auto-builds the image the first time you call it (`claude-local --rebuild`
  to force a rebuild later).

Setup — **source it from `~/.zshrc`, don't paste it in**:

```bash
cat add_to_zshrc.txt >> ~/.zshrc
echo 'SCANNER_TOKEN=<your token>' > ~/claudebox/.env
source ~/.zshrc
```

What that appends is a repo path and a `source` of `claude-local.zsh` (plus
some optional shell niceties you can trim):

```zsh
CLAUDEBOX_REPO="$HOME/claudebox"
[ -f "$CLAUDEBOX_REPO/claude-local.zsh" ] && source "$CLAUDEBOX_REPO/claude-local.zsh"
```

If you cloned somewhere else, `CLAUDEBOX_REPO` is the one line to change —
everything else derives from it. Leave it out entirely and the function falls
back to its own file location, which is also correct.

Source it rather than pasting the function body in. A pasted copy is invisible
to git: a pull updates the image and `claude-local.zsh`, while the launcher you
actually run stays frozen at whatever you copied. That divergence is silent —
`claude-local --rebuild` reports success, the image really does rebuild, and
the change still doesn't take effect.

Then, from any project directory:

```bash
claude-local
```

## Verify it yourself (do this — don't trust it blind)

The container is named `cc-agent-<directory>` (one per project directory, so
you can run several at once without name collisions — see "Running multiple
containers" below). Find the exact name with `docker ps`, then:

```bash
NAME=cc-agent-yourdir   # from `docker ps`
# internet should be blocked:
docker exec -it "$NAME" curl -s --max-time 5 http://1.1.1.1; echo "exit=$?"
# scanner should work:
docker exec -it "$NAME" curl -s --max-time 5 http://100.123.181.11:8099/health; echo
# agent user should NOT be able to flush the rules:
docker exec -it -u ccagent "$NAME" sudo iptables -F 2>&1 || echo "denied — good"
```

## Running multiple containers

Both `run.sh` and `claude-local` name the container after the current
directory's basename (e.g. `cc-agent-myproject`), so running the agent from
several project directories at once just works — each gets its own
container. Running it twice from the *same* directory still refuses to start
a second instance (see below), since two agents editing the same mounted
files at once isn't safe.

If a container with that name already exists — usually a stale one left
behind by a crashed terminal, a sleeping Mac, or a Docker Desktop restart
(since `--rm` only cleans up on a normal exit) — the script reclaims it
automatically if it's stopped, or tells you how to attach to or remove it if
it's still running.

## Sandbox roots — running without permission prompts

By default the agent asks before editing files or running commands. Launching
from a **sandbox root** skips those prompts instead. The container mounts your
current directory as its only writable surface, so scoping bypass by launch
location makes the blast radius exactly the thing you already called disposable.
The same signal also relaxes the [install policy](#installing-packages).

The default root is `~/claude-sandbox`, and it isn't created for you — until it
exists, nothing matches and every launch prompts. To use different ones, export
them from `~/.zshrc`, colon-separated:

    export CLAUDE_SANDBOX_ROOTS="$HOME/scratch:$HOME/throwaway"

`export` matters: `claudebox-install` is a separate process, so without it the
launcher and the installer read different lists and disagree about the same
directory — you get a session with no permission prompts but a strict install
policy. The directories have to exist, too; a root that isn't there matches
nothing and fails closed with no warning.

A matching launch says so before the container starts. Matching is on the
resolved path, so a symlink into a root counts as inside and one pointing out
counts as outside; a root matches only itself and paths beneath it, so
`/tmp/sandbox-evil` won't match a `/tmp/sandbox` root. Both launchers source the
gate from `sandbox-gate.sh` rather than each keeping a copy — two versions of a
security check drift, and a launcher that silently grants different permissions
than its twin is the bad kind of bug.

Two caveats:

- `CLAUDE_SANDBOX_ROOTS` is a convenience, not a security boundary. Anything
  that can set your environment can grant itself bypass. Keep the list narrow.
- **Never list this repo.** Bypass here would let the agent rewrite the
  launchers and widen its own allowlist.

Auto mode — which vets actions with a classifier rather than skipping checks —
isn't available here: the classifier needs a first-party Claude model, and this
container routes inference to a local one. Bypass is all-or-nothing, which is
why it's scoped by directory.

## Installing packages

Nothing installs from inside the container: egress is default-drop, there's no
DNS, and the agent can't `sudo`. Run this on the host instead, from the project
directory:

```bash
claudebox-install            # install what the manifests declare
claudebox-install pypdf      # add a package without touching the manifests
claudebox-install --lenient  # or --strict, to override this directory's policy
claudebox-install --clean    # discard this project's dependency volumes
```

**Two tiers.** `requirements.txt` and `package.json` are the *declared* set —
what the folder is meant to have. They're installed by a bare
`claudebox-install`, and reinstalled whenever the volumes are rebuilt, so they
survive `--clean` and move with the repo. Naming packages on the command line
adds them to the environment for the work in hand without recording them
anywhere: available immediately, gone after a `--clean`, absent on another
machine. Promote one by writing it into the manifest and installing again.

The agent is told to use the declared set only for dependencies worth keeping
across sessions, and to add anything exploratory on the fly.

A throwaway container fetches the packages into a Docker named volume, which the
launchers attach at `~/node_modules` and `~/venv` inside the container. It gets
no `SCANNER_TOKEN`, no API key, and no added capabilities, and exits when the
install finishes. The agent's own network posture is untouched, and because
volumes live in Docker Desktop's VM, package code never lands on your Mac.

**Policy follows the sandbox gate** — the same signal that decides permission
prompts:

| | lifecycle scripts | lockfile | project mount |
|---|---|---|---|
| under a sandbox root | run | written if missing | read-write |
| elsewhere | disabled | required | manifest only, read-only |

Leniency lands where the blast radius is already disposable; real projects keep
the guardrails. Disabling lifecycle scripts is the part that matters — it's what
stops `postinstall` being arbitrary code execution at install time.

**No preloading, no restart.** A volume attaches when a container *starts*, so
one created mid-session would be invisible to a running agent — it would install
successfully and then fail to import what it installed. Rather than making every
session guess in advance, `claudebox-install` streams the tree straight into the
running container when it isn't already mounted. The stream goes through a pipe,
so package code still never touches host disk, and the volume persists for the
next launch.

Three things to know:

- **Native modules work**, because the installer runs the same image as the
  agent. Installing on your Mac would build Darwin binaries that are visible
  inside this Linux container but won't load. Compiling them needs the image
  built with `CLAUDEBOX_BUILD_TOOLS=1` (off by default — it roughly doubles the
  image).
- **Nothing appears in your project.** Dependencies live at `~/node_modules` and
  `~/venv` inside the container, outside the mounted directory — Node resolves
  its own by walking up, and Python needs `~/venv/bin/python`. So no empty mount
  points on the Mac, but also no host-side autocomplete into `node_modules`.
- **This isolates install time, not run time.** The dependency code executes
  inside claudebox, which has your project mounted, so a malicious package can
  still reach your source when the agent runs it.

**System tools** go in the `Dockerfile`, then `claude-local --rebuild`. That
build runs on the host with ordinary network access.

### Letting the agent install for itself

Under a sandbox root, the launchers also start a watcher. The agent writes
`.claudebox-install-request`; the watcher runs `claudebox-install` in that
directory and puts the output in `.claudebox-install.log` for it to read back.
An empty request installs the declared set; a request naming packages adds just
those. No network for the agent, and no Docker socket.

What it controls is when this fires and which packages are named — not the
command, which is fixed here, and not the shell, since names are validated
against a plain-package-spec pattern first. `pypdf; touch /tmp/x` is rejected
rather than quoted around.

Choosing the packages is a confused-deputy hole by construction: an injected
page could talk the agent into installing something. That was already true when
the manifest was the only input, since the agent writes that too. The bound on
it is that this runs only under a sandbox root. `CLAUDEBOX_NO_WATCH=1` disables
it.

Installs that happen mid-session scroll past while the agent is talking, so the
launcher points at the log on exit. That log is your record of what got pulled
in without you watching.

## Files

- `Dockerfile` — builds the agent image (Claude Code + scanner skill + guidance).
- `entrypoint.sh` — runs as root at container start: sets the egress policy,
  runs `selftest.sh`, then drops privileges to the unprivileged `ccagent` user
  and execs `claude`.
- `selftest.sh` — fail-closed check that the internet is blocked and the
  scanner is reachable, before the agent is ever allowed to start.
- `run.sh` — build + run with the right flags, mounting the current directory.
- `claude-local.zsh` — the `claude-local` shell function used day to day. Source
  it from `~/.zshrc`; don't paste it in, or `git pull` stops reaching it.
- `add_to_zshrc.txt` — what to append to `~/.zshrc`: a `source` line for the
  above, plus optional shell niceties.
- `sandbox-gate.sh` — the shared directory check that decides whether a launch
  skips permission prompts. Sourced by both launchers so they can't disagree.
- `claudebox-install` — installs project dependencies into a Docker volume via
  a throwaway container, so the agent never needs network access.
- `deps-volumes.sh` — shared naming/detection for those volumes, so the
  installer and both launchers agree on where dependencies live.
- `claudebox-watch` — under a sandbox root, lets the agent trigger an install
  by writing a request file. Started and stopped by the launchers.
- `CLAUDE.md` — project instructions telling the agent to use only the scanner
  for web access and to treat scanned page content as untrusted data.
- `skills/web-scanner/` — the scanner skill (reads its token from
  `SCANNER_TOKEN`, never stores it).
- `settings.json` / `claude.json` — Claude Code config baked into the image
  (model, token limits, and a deny rule on the built-in `WebSearch`/`WebFetch`
  tools so the scanner skill is the only path to the web).

## Required container flags — don't drop these

`run.sh` and the `claude-local` function both run the container with:

```
--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=SETUID --cap-add=SETGID --security-opt no-new-privileges
```

All four matter:

- `NET_ADMIN` — needed once, at startup, for `entrypoint.sh` to install the
  `iptables` egress rules.
- `SETUID` / `SETGID` — needed once, at startup, for `gosu` to drop from root
  to the unprivileged `ccagent` user. Without these two, the kernel refuses
  the privilege drop even though the process is UID 0, because
  `--cap-drop=ALL` already stripped the capability that setuid/setgid checks
  for — the container would fail to start the agent at all.
- `no-new-privileges` — once we're running as `ccagent`, this stops the agent
  from escalating back to root to flush the egress rules or re-add
  capabilities.

If you're customizing the run command, keep all four, or the containment
either won't start (missing SETUID/SETGID) or won't hold (missing NET_ADMIN /
no-new-privileges).

## Honest limits — read this

This is the best containment Docker Desktop for **macOS** offers, and it is
**defense-in-depth, not an airtight guarantee**. Two structural reasons:

1. **The egress rules are set inside the container.** They're installed at
   startup and the agent then runs unprivileged with `no-new-privileges` and
   no `NET_ADMIN`, so the *agent* can't flush them. But the rules live in the
   container's own network namespace, not in a host kernel you administer. On
   a Mac, "the host" is Docker Desktop's hidden Linux VM, which you don't
   manage — so there is no layer *you control* beneath the container to catch
   a bypass. If the container image allows privilege escalation, root-in-
   container can remove the rules.

2. **The scanner IP is a permitted channel by design.** The firewall controls
   *where* traffic goes, not *what's in it*. The scanner's own injection
   screening and SSRF protection are load-bearing alongside this wall — keep
   them healthy, and keep the `CLAUDE.md` rule about honoring the
   `contains_suspected_injection` flag.

**If you need a real, kernel-enforced boundary**, run this on a Linux host
instead and place `nftables`/`iptables` rules in the host's `DOCKER-USER`
chain (matched on the container's bridge interface). There the rules sit below
the container in a kernel you own, and even root inside the container cannot
touch them.

The self-test in `selftest.sh` is what turns "I hope the wall holds" into "the
agent won't start unless it does." It is the most important piece here; don't
remove it.
