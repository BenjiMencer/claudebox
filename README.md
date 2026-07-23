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

`add_to_zhrc.txt` has a `claude-local` zsh function you can paste into
`~/.zshrc`. Note it also includes a few unrelated shell niceties (`$EDITOR`,
`AUTO_CD`, history settings) at the top — trim those if you already set your
own, and only take the `claude-local` function itself. It does everything
`run.sh` does, plus:

- reads `SCANNER_TOKEN` from a `.env` file next to this repo instead of
  requiring you to `export` it every session,
- starts Docker Desktop automatically if it isn't running,
- auto-builds the image the first time you call it (`claude-local --rebuild`
  to force a rebuild later),
- works from *any* directory — it always mounts your current working
  directory, not this repo.

Setup — append `add_to_zhrc.txt`'s contents to `~/.zshrc` (or paste the
`claude-local` function in manually), then create a `.env` next to this repo:

```bash
cat add_to_zhrc.txt >> ~/.zshrc
echo 'SCANNER_TOKEN=<your token>' > ~/claude-docker/.env
source ~/.zshrc
```

By default the function expects this repo at `~/claude-docker` — edit the
`claude_docker_dir` line near the top of the function if you cloned it
somewhere else. Then, from any project directory:

```bash
claude-local
```

## Verify it yourself (do this — don't trust it blind)

With the container running:

```bash
# internet should be blocked:
docker exec -it cc-agent curl -s --max-time 5 http://1.1.1.1; echo "exit=$?"
# scanner should work:
docker exec -it cc-agent curl -s --max-time 5 http://100.123.181.11:8099/health; echo
# agent user should NOT be able to flush the rules:
docker exec -it -u ccagent cc-agent sudo iptables -F 2>&1 || echo "denied — good"
```

## Files

- `Dockerfile` — builds the agent image (Claude Code + scanner skill + guidance).
- `entrypoint.sh` — runs as root at container start: sets the egress policy,
  runs `selftest.sh`, then drops privileges to the unprivileged `ccagent` user
  and execs `claude`.
- `selftest.sh` — fail-closed check that the internet is blocked and the
  scanner is reachable, before the agent is ever allowed to start.
- `run.sh` — build + run with the right flags, mounting the current directory.
- `add_to_zhrc.txt` — optional `claude-local` shell function for day-to-day use
  from any project directory.
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
