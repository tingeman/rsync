# RSYNC

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/tingeman/rsync/build.yml?logo=github) ![GitHub stars](https://img.shields.io/github/stars/tingeman/rsync?logo=github) ![Docker Stars](https://img.shields.io/docker/stars/tingeman/rsync?label=stars&logo=docker) ![Docker Pulls](https://img.shields.io/docker/pulls/tingeman/rsync?label=pulls&logo=docker)

![OpenSSH logo](https://raw.githubusercontent.com/atmoz/sftp/master/openssh.png "Powered by OpenSSH")

### Supported tags and respective `Dockerfile` links

- [`debian` (*Dockerfile*)](https://github.com/tingeman/rsync/blob/main/Dockerfile): Debian bookworm, base image pinned by digest.

The Alpine variant was dropped in release 2026.1.

**Build the image from source.** The image `tingeman/rsync:debian` on Docker Hub is outdated: it was built in 2024 with the old forced-command script (`validate-rsync.sh`), not with the rrsync confinement described below. Build it yourself:

```
git clone https://github.com/tingeman/rsync.git
cd rsync
docker build -t rsync:local .
bash tests/run.sh rsync:local
```

The examples below use the image name `rsync:local`.

# Securely synchronize/backup files

Easy to use [RSYNC](https://en.wikipedia.org/wiki/Rsync) server with [OpenSSH](https://en.wikipedia.org/wiki/OpenSSH), hosted in a docker image. Users log in with an SSH key and can only run rsync, confined to their own home folder.

## Acknowledgement

This repository is heavily inspired by the excellent project [atmoz/sftp](https://github.com/atmoz/sftp). Well, actually, everything is mostly copied from that project, and minor modifications implemented to turn it into an rsync server, rather than an sftp server.

# Usage

- Define users in (1) command arguments, (2) `RSYNC_USERS` environment variable
  or (3) in file mounted as `/etc/rsync/users.conf` (syntax:
  `user:pass[:e][:uid[:gid[:dir1[,dir2]...]]] ...`, see below for examples)
  - Set UID/GID manually for your users if you want them to make changes to
    your mounted volumes with permissions matching your host filesystem.
  - Directory names at the end will be created under user's home directory with
    write permission, if they aren't already present.
- Provide public ssh keys to be used for public-private key authentication.
  - Every session can only run rsync, rooted at the user's home folder (see
    [How sessions are confined](#how-sessions-are-confined)).
  - By default, password authentication is disabled.
- Mount volumes
  - You can mount volumes in separate directories inside the user's home
    directory (`/home/user/mounted-directory`) or just mount the whole
    `/home` directory.
    Just remember that the users can't create new files directly under their
    own home directory, so make sure there is at least one subdirectory if you
    want them to synchronize files to the server.
  - For consistent server fingerprint, mount your own host keys (i.e. `/etc/ssh/ssh_host_*`)

# How sessions are confined

Every SSH session runs [`rrsync`](https://manpages.debian.org/bookworm/rsync/rrsync.1.en.html), the restricted-rsync helper that ships with rsync:

- `sshd_config` sets `ForceCommand /usr/local/bin/rsync-only`, which runs `rrsync -munge "$HOME"`. sshd applies it to every session, whatever command the client asks for and whatever `authorized_keys` says.
- rrsync reads the client's command, parses the rsync server arguments itself (no shell is involved), roots every path at the user's home folder `/home/<user>`, including the paths of options such as `--log-file` and `--temp-dir`, and refuses options it does not allow. `-munge` turns on rsync's `--munge-links`, so uploaded symlinks can't be used to reach files outside the home folder.
- Each key in `authorized_keys` gets the option `restrict` (no port, agent or X11 forwarding, no pty, no `~/.ssh/rc`). `sshd_config` also turns off forwarding, tunnels, ttys, user rc files and user environment files.
- The home folder `/home/<user>`, `.ssh/`, `.ssh/keys/` and `.ssh/authorized_keys` are owned by root and not writable by the user, so users can't change the files that restrict them. The user can write only in the folders created for them (e.g. `upload`) or mounted into the home folder.

## Client usage: paths are relative to the home folder

The root of each user's rsync is their home folder. Use paths relative to it:

```
rsync -a data/ foo@<server>:upload/          # upload
rsync -a foo@<server>:upload/ data/          # download
rsync foo@<server>:upload/                   # listing
rsync -a --delete data/ foo@<server>:upload/ # mirror, deleting files no longer in data/
```

An absolute path is rooted at the home folder too: `foo@<server>:/upload/` is the same as `foo@<server>:upload/`.

**Breaking change compared with the old image:** absolute paths such as `foo@<server>:/home/foo/upload/` no longer work. They now point to `/home/foo/home/foo/upload/`, which doesn't exist. Use `upload/`.

## What is refused and what is confined

Refused (the session ends with an error):

- any command that is not an rsync server run, e.g. `ssh foo@<server> id`; shell commands appended to an rsync command are not run;
- an interactive login or a pty (`ssh -t`);
- `..` in a path or in an option path, e.g. `foo@<server>:../bar/`, `--temp-dir=../x`;
- options rrsync does not allow, e.g. `-s` (`--secluded-args`), `--copy-links`, `--keep-dirlinks`, `--no-munge-links`;
- port forwarding (`ssh -L`, `ssh -R`) and agent forwarding;
- writing into the home folder itself or into `.ssh/` (e.g. overwriting `.ssh/authorized_keys`, also with `--inplace`);
- a second session of the same user while one is running (see below).

Confined (accepted, but rooted at the home folder, so nothing outside it is reached):

- absolute paths: `foo@<server>:/etc/passwd` means `/home/foo/etc/passwd`, and `/home/bar/upload/` means `/home/foo/home/bar/upload/`;
- every source argument, e.g. a second source `:/etc/hostname`;
- option paths, e.g. `--log-file=/tmp/x` means `/home/foo/tmp/x`, `--temp-dir=/` means `/home/foo/`;
- `--files-from` lists and paths;
- symlinks: an uploaded link to `/etc` is stored munged, and reads through it are refused.

## One session per user at a time

rrsync locks the user's home folder for each session, so each user runs one rsync session at a time. A second session of the same user, started while the first one runs, is refused with `Another instance of rrsync is already accessing this directory.` Retry it when the first one has ended. Sessions of different users run in parallel.

# Examples

## Logging in with SSH keys

Public keys can be given in two ways; both end up in `.ssh/authorized_keys`, each line with `restrict`. You can't mount `authorized_keys` directly; it is written by the container at start. Public keys should have unique names with the extension `*.pub`.

1. Mount the keys into the user's `.ssh/keys/` directory:

   ```
   docker run \
       -v <host-dir>/id_ed25519.pub:/home/foo/.ssh/keys/id_ed25519.pub:ro \
       -p 2222:22 -d rsync:local \
       foo::::upload
   ```

2. Mount a folder with one subfolder per user at `/opt/rsync/ssh_keys` (see [Store users in config](#store-users-in-config)). The keys are copied into each user's `.ssh/keys/` at start.

In this example, we do not provide any password, so the user `foo` can only log in with the SSH key. A folder called `upload` is created in the user's home folder, with read and write permissions.

## Sharing a directory from your computer

You may set the UID/GID for users manually, if you want them to make changes to your mounted volumes with permissions matching your host filesystem.

Let's mount a directory and set UID:

```
docker run \
    -v <host-dir>/id_ed25519.pub:/home/foo/.ssh/keys/id_ed25519.pub:ro \
    -v <host-dir>/upload:/home/foo/upload \
    -p 2222:22 -d rsync:local \
    foo::1001
```

User `foo` (with no password) will have a folder from the host system mounted to `/home/foo/upload`, and will be able to rsync to that folder using the `id_ed25519` key.

### Using Docker Compose:

Identical example, implemented in a Docker Compose file:

```
rsync:
    image: rsync:local
    volumes:
        - <host-dir>/id_ed25519.pub:/home/foo/.ssh/keys/id_ed25519.pub:ro
        - <host-dir>/upload:/home/foo/upload
    ports:
        - "2222:22"
    command: foo::1001
```

### Rsync operations

The OpenSSH server runs on port 22 in the container, and in this example, we are forwarding the container's port 22 to the host's port 2222. To perform an rsync operation, use something like:

```
rsync -avz -e "ssh -p 2222 -i ~/.ssh/id_ed25519" ~/upload/ foo@<server>:upload/
```

- `-avz` are standard options passed to the rsync command:
    - `-a` (archive mode): This option enables recursion and preserves symbolic links, permissions, timestamps, and other attributes.
    - `-v` (verbose): This option increases the verbosity of the output, providing more details about the transfer process.
    - `-z` (compress): This option compresses the data during the transfer to reduce the amount of data sent over the network.

- `-e "ssh -p 2222 -i ~/.ssh/id_ed25519"` specifies the use of `ssh` on port 2222 with a specific identity file (private key) located at `~/.ssh/id_ed25519` for authentication.

- `~/upload/`: This is the source directory on the local machine that you want to synchronize. The ~ symbol represents the home directory of the current user.

- `foo@<server>:upload/`: the user `foo` on the server and the destination path `upload/`, relative to the user's home folder (see [Client usage](#client-usage-paths-are-relative-to-the-home-folder)).

## A note about password authentication

Password authentication is disabled by default, but may be enabled by modifying the file `./files/sshd_config`:

```
PasswordAuthentication no    # change to yes to allow password authentication
```

The `ForceCommand` applies to password logins too, so they are also limited to rsync in the home folder. Keys are still recommended.

## Store users in config

When setting up multiple users, credentials and UID/GID etc. may be defined in a configuration file:

```
docker run \
    -v <host-dir>/ssh_keys:/opt/rsync/ssh_keys:ro \
    -v <host-dir>/users.conf:/etc/rsync/users.conf:ro \
    -p 2222:22 -d rsync:local
```

<host-dir>/users.conf:

```
foo::1001:100:upload
bar::1002:100:upload
baz::1003:100:upload
```

Here three users are defined without passwords (so they must have public keys defined to be able to log in), and with user ID and group ID manually specified.

The keys are in a folder structure on the host with one folder per user, containing the key(s) for that user. It is mounted read-only to `/opt/rsync/ssh_keys`, from where the keys are added to each user's `authorized_keys` file during container initialization:

```
<host-dir>/ssh_keys/
├─ foo/
│  ├─ id_ed25519_foo.pub
├─ bar/
│  ├─ id_ed25519_bar.pub
├─ baz/
   ├─ id_ed25519_baz.pub
```

## Encrypted password

Add `:e` behind password to mark it as encrypted. Read more about passwords and encryption at [atmoz/sftp](https://github.com/atmoz/sftp), if needed. The rsync server is intended for use with passwordless users, using instead ssh keys for authentication.


## Providing your own SSH host key (recommended)

This container will generate new SSH host keys at first run. To avoid that your users get a MITM warning when you recreate your container (and the host keys changes), you can mount your own host keys.

```
docker run \
    -v <host-dir>/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key \
    -v <host-dir>/ssh_host_rsa_key:/etc/ssh/ssh_host_rsa_key \
    -v <host-dir>/ssh_keys:/opt/rsync/ssh_keys:ro \
    -p 2222:22 -d rsync:local \
    foo::1001::upload
```

Tip: you can generate your keys with these commands:

```
ssh-keygen -t ed25519 -f ssh_host_ed25519_key < /dev/null
ssh-keygen -t rsa -b 4096 -f ssh_host_rsa_key < /dev/null
```

## Healthcheck

The image defines a Docker `HEALTHCHECK`: the container is healthy when sshd accepts TCP connections on port 22 (a bash `/dev/tcp/127.0.0.1/22` connect; interval 1m, timeout 10s, 3 retries, start period 30s). `docker compose up --wait` waits for it.

## Execute custom scripts or applications

Put your programs in `/etc/rsync.d/` and it will automatically run when the container starts.
See next section for an example.

## Bindmount dirs from another location

If you are using `--volumes-from` or just want to make a custom directory available in user's home directory, you can add a script to `/etc/rsync.d/` that bindmounts after container starts.

```
#!/bin/bash
# File mounted as: /etc/rsync.d/bindmount.sh
# Just an example (make your own)

function bindmount() {
    if [ -d "$1" ]; then
        mkdir -p "$2"
    fi
    mount --bind $3 "$1" "$2"
}

# Remember permissions, you may have to fix them:
# chown -R :users /data/common

bindmount /data/admin-tools /home/admin/tools
bindmount /data/common /home/dave/common
bindmount /data/common /home/peter/common
bindmount /data/docs /home/peter/docs --read-only
```

**NOTE:** Using `mount` requires that your container runs with the `CAP_SYS_ADMIN` capability turned on. [See this answer for more information](https://github.com/atmoz/sftp/issues/60#issuecomment-332909232).

# Tests

`tests/run.sh` runs behaviour tests against a built image, with the docker CLI only (Linux, WSL, or Git Bash on Windows):

```
docker build -t rsync:local .
bash tests/run.sh rsync:local
TEST_FILTER='refused|confined' bash tests/run.sh rsync:local   # only the matching tests
```

It starts one server and one client container from the image on a private docker network, with throwaway ed25519 keys and two users whose names share a prefix (`alice`, `alice2`). It checks the healthcheck, the ownership of `.ssh` and `authorized_keys`, that upload, download, listing and `--delete` work, and every refused and confined case listed above. Each test prints `PASS:` or `FAIL:`; the last line is `ALL <n> TESTS PASSED` (exit 0) or `<m> OF <n> TESTS FAILED` (exit 1). Everything the tests create is removed at the end, also when a test fails.

# What version of OpenSSH do I get?

The one in Debian bookworm at build time (the build runs `apt-get upgrade`). See the [list of `openssh-server` packages on Debian releases](https://packages.debian.org/search?keywords=openssh-server&searchon=names&exact=1&suite=all&section=main).
