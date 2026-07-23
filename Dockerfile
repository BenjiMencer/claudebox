FROM node:20-slim

# Tools needed for the egress policy and the startup self-test.
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables curl ca-certificates iproute2 gosu python3 \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code.
RUN npm install -g @anthropic-ai/claude-code

# Unprivileged user the agent actually runs as.
RUN useradd -m -s /bin/bash ccagent

# Skill + guidance live in the agent user's config.
COPY skills/ /home/ccagent/.claude/skills/
COPY CLAUDE.md /home/ccagent/.claude/CLAUDE.md
COPY settings.json /home/ccagent/.claude/settings.json
COPY claude.json /home/ccagent/.claude.json
RUN chown -R ccagent:ccagent /home/ccagent/.claude /home/ccagent/.claude.json

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY selftest.sh   /usr/local/bin/selftest.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/selftest.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
