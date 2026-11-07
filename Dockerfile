# Base image pinned by digest (multi-arch index of debian:bookworm, taken 2026-11-07).
# apt-get upgrade below still pulls the current security updates at build time.
FROM debian:bookworm@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8
LABEL authors="Thomas Ingeman-Nielsen"

# Steps done in one RUN layer:
# - Install upgrades and new packages
#   (python3: /usr/bin/rrsync from the rsync package is a Python script)
# - OpenSSH needs /var/run/sshd to run
# - Remove generic host keys, entrypoint generates unique keys
RUN apt-get update && \
    apt-get upgrade -y && \
    DEBIAN_FRONTEND="noninteractive" apt-get -y install --no-install-recommends openssh-server rsync python3 && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/run/sshd && \
    rm -f /etc/ssh/ssh_host_*key*

# Create the directory if it doesn't exist
RUN mkdir -p /opt/rsync/ssh_keys

COPY files/sshd_config /etc/ssh/sshd_config
COPY files/create-rsync-user /usr/local/bin/
# Forced command for every session (ForceCommand in sshd_config)
COPY files/rsync-only /usr/local/bin/rsync-only

# copy entrypoint script and set is executable
COPY files/entrypoint /entrypoint

# Set ownership and execution permissions
RUN chown root:root /usr/local/bin/rsync-only && \
    chmod 0755 /usr/local/bin/rsync-only && \
    chmod +x /entrypoint \
             /usr/local/bin/create-rsync-user

EXPOSE 22

# Healthy when sshd accepts TCP connections on port 22
HEALTHCHECK --interval=1m --timeout=10s --start-period=30s --retries=3 \
    CMD bash -c '</dev/tcp/127.0.0.1/22' || exit 1

ENTRYPOINT ["/entrypoint"]
