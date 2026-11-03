FROM node:24-slim

# Use a stable Debian mirror — deb.debian.org/Fastly intermittently returns
# HTTP 400 for certain packages; the German mirror reliably carries `aggregate`.
RUN printf 'deb http://ftp.de.debian.org/debian bookworm main\ndeb http://ftp.de.debian.org/debian bookworm-updates main\ndeb http://security.debian.org/debian-security bookworm-security main\n' \
    > /etc/apt/sources.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    ripgrep \
    jq \
    python3 \
    python3-pip \
    build-essential \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    sudo \
  && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally and run its post-install initialiser.
# The smoke-test (claude --version) catches broken installs at build time.
RUN npm install -g --include=optional @anthropic-ai/claude-code \
  && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
  && claude --version

# Create the non-root dev user.
# node:24-slim ships a `node` user at UID/GID 1000; delete it first so
# groupadd/useradd succeed regardless of which UID/GID is requested.
ARG UID=1000
ARG GID=1000
RUN userdel -r node 2>/dev/null || true \
  && groupadd -g "${GID}" dev \
  && useradd -m -u "${UID}" -g dev -s /bin/bash dev \
  && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Copy runtime scripts into the image.
COPY entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY init-firewall.sh  /usr/local/bin/init-firewall.sh
COPY extra-allows.sh   /usr/local/bin/extra-allows.sh
COPY refresh-allows.sh /usr/local/bin/refresh-allows.sh
RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/init-firewall.sh \
    /usr/local/bin/extra-allows.sh \
    /usr/local/bin/refresh-allows.sh

# Document the OAuth callback port (informational only — actual publishing
# happens at `docker run -p`).
EXPOSE 8976

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
