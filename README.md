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
echo 'SCANNER_TOKEN=<your token>' > ~/claude-docker/.env
source ~/.zshrc
```

`add_to_zshrc.txt` is a one-line `source` of `claude-local.zsh` (plus some
optional shell niceties you can trim). Sourcing matters: a pasted copy of the
function silently ignores every future `git pull`, so you end up rebuilding the
image from new code while the launcher wrapping it stays whatever you pasted
months ago. That failure is quiet and confusing — `claude-local --rebuild`
appears to work, and the change still doesn't take effect.

The function finds this repo from its own location, so there is nothing to
hand-edit if you cloned somewhere other than `~/claude-docker` — just point the
`source` line in `~/.zshrc` at wherever it is. Then, from any project
directory:

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

By default the agent asks before editing files or running commands. You can
skip those prompts, but only from directories you have explicitly designated
as disposable. Both launchers source the same gate from `sandbox-gate.sh`,
compare the launch directory against a list of sandbox roots, and pass
`--permission-mode bypassPermissions` only when it matches:

    CLAUDEBOX_DEFAULT_SANDBOX_ROOT="$HOME/claude-sandbox"

The gate is shared rather than duplicated in each launcher on purpose: two
copies of a security-relevant check drift, and a launcher that quietly grants
different permissions than its twin is the bad kind of bug.

The default root is `~/claude-sandbox`, which is not created for you — until it
exists, nothing matches and every launch prompts normally. Override the list
per-call with a colon-separated `CLAUDE_SANDBOX_ROOTS`:

    CLAUDE_SANDBOX_ROOTS="$HOME/scratch:$HOME/throwaway" claude-local

A launch that matches prints two lines saying so before the container starts.
Matching is on the resolved path — a symlink into a sandbox root counts as
inside, and one pointing out of it counts as outside — and a root only matches
that directory and things beneath it, so `/tmp/sandbox-evil` does not match a
`/tmp/sandbox` root.

Why tie it to the directory: the container mounts your current directory as its
only writable surface. Scoping bypass by launch location makes the blast radius
exactly the thing you already decided was disposable.

Two caveats worth stating plainly:

- `CLAUDE_SANDBOX_ROOTS` is a convenience, not a security boundary. Anything
  that can set your environment can grant itself bypass. Keep the default
  narrow, and don't export it globally in your shell profile.
- **Do not add this repo to the list.** Bypass here would let the agent rewrite
  `run.sh` and widen its own allowlist.

Auto mode (`--permission-mode auto`), which reviews actions with a classifier
instead of skipping checks, is *not* available in this setup: the classifier
requires a first-party Claude model, and this container routes inference to a
local model. Bypass is all-or-nothing, which is why it is scoped by directory.

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
