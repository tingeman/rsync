FROM debian:bookworm
LABEL authors="Thomas Ingeman-Nielsen"

# Steps done in one RUN layer:
# - Install upgrades and new packages
# - OpenSSH needs /var/run/sshd to run
# - Remove generic host keys, entrypoint generates unique keys
RUN apt-get update && \
    apt-get upgrade -y && \
    DEBIAN_FRONTEND="noninteractive" apt-get -y install --no-install-recommends openssh-server rsync && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/run/sshd && \
    rm -f /etc/ssh/ssh_host_*key*

# Create the directory if it doesn't exist
RUN mkdir -p /opt/rsync/ssh_keys

COPY files/validate-rsync.sh /opt/rsync/validate-rsync.sh
COPY files/sshd_config /etc/ssh/sshd_config
COPY files/create-rsync-user /usr/local/bin/

# copy entrypoint script and set is executable
COPY files/entrypoint /entrypoint

# Set execution permissions
RUN chmod +x /entrypoint \
             /usr/local/bin/create-rsync-user \
             /opt/rsync/validate-rsync.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint"]
