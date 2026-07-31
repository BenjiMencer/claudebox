FROM node:20-slim

# Tools needed for the egress policy and the startup self-test.
# python3-venv carries ensurepip, without which `python3 -m venv` produces an
# environment with no pip in it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables curl ca-certificates iproute2 gosu python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Compilers for packages with native components (node-gyp addons, C extensions).
# Off by default because it roughly doubles the image, and lifecycle scripts are
# disabled under the strict install policy anyway. Turn on with:
#   CLAUDEBOX_BUILD_TOOLS=1 claude-local --rebuild
ARG WITH_BUILD_TOOLS=0
RUN if [ "$WITH_BUILD_TOOLS" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        build-essential python3-dev \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Install Claude Code.
RUN npm install -g @anthropic-ai/claude-code

# Unprivileged user the agent actually runs as. The dependency directories are
# created here so they exist and are owned by ccagent before anything mounts
# over them: a fresh named volume inherits the image directory's ownership, and
# root inside the running container cannot fix it later (--cap-drop=ALL).
RUN useradd -m -s /bin/bash ccagent \
 && mkdir -p /home/ccagent/node_modules /home/ccagent/venv \
 && chown -R ccagent:ccagent /home/ccagent

# Skill + guidance live in the agent user's config.
COPY skills/ /home/ccagent/.claude/skills/
COPY CLAUDE.md /home/ccagent/.claude/CLAUDE.md
COPY settings.json /home/ccagent/.claude/settings.json
COPY claude.json /home/ccagent/.claude.json
RUN chown -R ccagent:ccagent /home/ccagent/.claude /home/ccagent/.claude.json

# Shims for the package managers, plus the PreToolUse hook that catches the
# same commands one step earlier. Installed after the apt/npm work above so the
# build itself is unaffected. npm is renamed rather than replaced: the shim
# redirects only its install verbs and execs the real one otherwise.
# Staged first, then installed: copying the npm shim straight to
# /usr/local/bin would clobber the real npm before it could be moved aside.
COPY shims/ /usr/local/lib/claudebox/shims/
RUN set -eux \
 && mv /usr/local/bin/npm /usr/local/bin/npm.real \
 && cp /usr/local/lib/claudebox/shims/claudebox-guidance /usr/local/lib/claudebox/guidance \
 && for f in pip apt-get npm claudebox-install-hook claudebox-web-hook; do \
      cp "/usr/local/lib/claudebox/shims/$f" /usr/local/bin/$f; \
      chmod +x /usr/local/bin/$f; \
    done \
 && ln -sf /usr/local/bin/pip /usr/local/bin/pip3 \
 && ln -sf /usr/local/bin/pip /usr/local/bin/easy_install \
 && ln -sf /usr/local/bin/apt-get /usr/local/bin/apt \
 && rm -rf /usr/local/lib/claudebox/shims

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY selftest.sh   /usr/local/bin/selftest.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/selftest.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
