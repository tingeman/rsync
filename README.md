# RSYNC

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/tingeman/rsync/build.yml?logo=github) ![GitHub stars](https://img.shields.io/github/stars/tingeman/rsync?logo=github) ![Docker Stars](https://img.shields.io/docker/stars/tingeman/rsync?label=stars&logo=docker) ![Docker Pulls](https://img.shields.io/docker/pulls/tingeman/rsync?label=pulls&logo=docker)

![OpenSSH logo](https://raw.githubusercontent.com/atmoz/sftp/master/openssh.png "Powered by OpenSSH")

### Supported tags and respective `Dockerfile` links

- [`debian`, `latest` (*Dockerfile*)](https://github.com/atmoz/sftp/blob/master/Dockerfile) ![Docker Image Size (debian)](https://img.shields.io/docker/image-size/atmoz/sftp/debian?label=debian&logo=debian&style=plastic)
- [`alpine` (*Dockerfile*)](https://github.com/atmoz/sftp/blob/master/Dockerfile-alpine) ![Docker Image Size (alpine)](https://img.shields.io/docker/image-size/atmoz/sftp/alpine?label=alpine&logo=Alpine%20Linux&style=plastic)

# Securely synchronize/backup files

Easy to use [RSYNC](https://en.wikipedia.org/wiki/Rsync) server with [OpenSSH](https://en.wikipedia.org/wiki/OpenSSH), hosted in a docker image.

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
- Provide public ssh keys to be used for public-private key authentication (recommended).
  - Keys are restricted to perform rsync operations within the users home
    folder, only.
  - No shell access or other commands over ssh are permitted, when
    authenticated with an ssh key. 
  - By default, password authentication is disabled.
- Mount volumes
  - You can mount volumes in separate directories inside the user's home
    directory (`/home/user/mounted-directory`) or just mount the whole 
    `/home` directory.
    Just remember that the users can't create new files directly under their
    own home directory, so make sure there is at least one subdirectory if you
    want them to synchronize files to the server.
  - For consistent server fingerprint, mount your own host keys (i.e. `/etc/ssh/ssh_host_*`)

# Examples

<!-- ## Simplest docker run example

```
docker run -p 22:22 -d tingeman/rsync foo:pass:::upload
```

User "foo" with password "pass" can login with sftp and upload files to a folder called "upload". No mounted directories or custom UID/GID. Later you can inspect the files and use `--volumes-from` to mount them somewhere else (or see next example). -->

## Logging in with SSH keys

Mount public keys in the user's `.ssh/keys/` directory. All keys are automatically appended to `.ssh/authorized_keys` (you can't mount this file directly, because OpenSSH requires limited file permissions). In this example, we do not provide any password, so the user `foo` can only login with his SSH key. A folder called `upload` is created in the users home folder, with read and write permissions.

To start the container use:

```
docker run \
    -v <host-dir>/id_rsa.pub:/home/foo/.ssh/keys/id_rsa.pub:ro \
    -p 2222:22 -d tingeman/rsync \
    foo::::upload
```

Public keys should have unique names with the extension `*.pub`. The keys are restricted, so that they can only be used for rsync operations. This is done by prepending the key in `.ssh/authorized_keys` by a forced command:

```
command="/home/[user]/.ssh/validate-rsync.sh",no-port-forwarding,no-X11-forwarding,no-pty  [public key]
```

The script `validate-rsync.sh` checks the ssh command issued, and only allows it to be executed, if it is a call to `rsync --server`. It will terminate the ssh connection, if the command is anything else, or if there is indication of chained commands are being issued. The script will also check the destination path, and only allow the rsync operation, if the destination path is within the users home folder.

This solution was inspired by the following article: https://troy.jdmz.net/rsync/index.html.


## Sharing a directory from your computer

You may set the UID/GID for users manually, if you want them to make changes to your mounted volumes with permissions matching your host filesystem.

Let's mount a directory and set UID:

```
docker run \
    -v <host-dir>/id_rsa.pub:/home/foo/.ssh/keys/id_rsa.pub:ro \
    -v <host-dir>/upload:/home/foo/upload \
    -p 2222:22 -d tingeman/rsync \
    foo::1001
```

User `foo` (with no password) will have a folder from the host system mounted to `home/foo/upload`, and will be able to rsync to that folder using the `id_rsa` key.

### Using Docker Compose:

Identical example, implemented in a Docker Compose file:

```
rsync:
    image: tingeman/rsync
    volumes:
        - <host-dir>/id_rsa.pub:/home/foo/.ssh/keys/id_rsa.pub:ro
        - <host-dir>/upload:/home/foo/upload
    ports:
        - "2222:22"
    command: foo::1001
```

### Rsync operations

The OpenSSH server runs by default on port 22, and in this example, we are forwarding the container's port 22 to the host's port 2222. To perform an rsync operation, use something like:

```
rsync -avz -e "ssh -i ~/.ssh/id_rsa" ~/upload/ foo@[RSYNC-SERVER-IP]:./upload
```

- `-avz` are standard options passed to the rsync command:
    - `-a` (archive mode): This option enables recursion and preserves symbolic links, permissions, timestamps, and other attributes.
    - `-v` (verbose): This option increases the verbosity of the output, providing more details about the transfer process.
    - `-z` (compress): This option compresses the data during the transfer to reduce the amount of data sent over the network.

- `-e "ssh -i ~/.ssh/id_rsa"` specifies the use of `ssh` with a specific identity file (private key) located at `~/.ssh/id_rsa` for authentication.

- `~/upload/`: This is the source directory on the local machine that you want to synchronize. The ~ symbol represents the home directory of the current user.

- `foo@[RSYNC-SERVER-IP]:./upload`: This argument specifies the user `foo` on the remote server with IP address `[RSYNC-SERVER-IP]` and the destination path `./upload`. You may use a path relative to the users home directory (as here) or a fully qualified path, as long as the destination path points to a location within the users home folder (other locations are not permitted).

## A note about password authentication

Password authentication is dissabled by default, but may be enabled by modifying the file `./files/sshd_config`:

```
PasswordAuthentication no    # change to yes to allow password authentication
```

***NB: If password authentication is allowed, users will have full shell access to the server over ssh.*** The restriction to rsync operations is implemented for public-private key authorization only.

## Store users in config

When setting up multiple users, credentials and UID/GID etc. may be defined in a configuration file:

```
docker run \
    -v <host-dir>/id_rsa.pub:/home/foo/.ssh/keys/id_rsa.pub:ro \
    -v <host-dir>/users.conf:/etc/sftp/users.conf:ro \
    -p 2222:22 -d tingeman/rsync \
```

<host-dir>/users.conf:

```
foo::1001:100:upload
bar::1002:100:upload
baz::1003:100:upload
```

Here three users are defined without passwords (so they must have public keys defined to be able to log in), and with user ID and group ID manually specified.

Public keys can be mounted directly to the users `~/.ssh/keys` folder (as shown above for user `foo`).

Public keys may also be placed in a folder structure on the host which includes the username (e.g. `<host-dir>/ssh_keys/<username>/`), with one folder per user containing the relevant key(s) for that user. This folder may then be mounted to `/opt/rsync/resources/ssh_keys`, from where keys will be added to each users `authorized_keys` file during container initialization. See example below.

```
docker run \
    -v <host-dir>/ssh_keys:/opt/rsync/resources/ssh_keys:ro \
    -v <host-dir>/users.conf:/etc/sftp/users.conf:ro \
    -p 2222:22 -d tingeman/rsync \
```

with:

```
<host-dir>/ssh_keys/
├─ users.conf
├─ foo/
│  ├─ id_rsa_foo.pub
├─ bar/
│  ├─ id_rsa_bar.pub
├─ baz/
   ├─ id_rsa_baz.pub
```

## Encrypted password

Add `:e` behind password to mark it as encrypted. Read more about passwords and encryption at [atmoz/sftp](https://github.com/atmoz/sftp), if needed. The rsync server is intended for use with passwordless users, using instead ssh keys for authentication.


## Providing your own SSH host key (recommended)

This container will generate new SSH host keys at first run. To avoid that your users get a MITM warning when you recreate your container (and the host keys changes), you can mount your own host keys.

```
docker run \
    -v <host-dir>/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key \
    -v <host-dir>/ssh_host_rsa_key:/etc/ssh/ssh_host_rsa_key \
    -v <host-dir>/ssh_keys:/opt/rsync/resources/ssh_keys:ro \
    -p 2222:22 -d tingeman/rsync \
    foo::1001:upload
```

Tip: you can generate your keys with these commands:

```
ssh-keygen -t ed25519 -f ssh_host_ed25519_key < /dev/null
ssh-keygen -t rsa -b 4096 -f ssh_host_rsa_key < /dev/null
```

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

# What's the difference between Debian and Alpine?

The biggest differences are in size and OpenSSH version. [Alpine](https://hub.docker.com/_/alpine/) is 10 times smaller than [Debian](https://hub.docker.com/_/debian/). OpenSSH version can also differ, as it's two different teams maintaining the packages. Debian is generally considered more stable and only bugfixes and security fixes are added after each Debian release (about 2 years). Alpine has a faster release cycle (about 6 months) and therefore newer versions of OpenSSH. As I'm writing this, Debian has version 7.4 while Alpine has version 7.5. Recommended reading: [Comparing Debian vs Alpine for container & Docker apps](https://www.turnkeylinux.org/blog/alpine-vs-debian)

# What version of OpenSSH do I get?

It depends on which linux distro and version you choose (see available images at the top). You can see what version you get by checking the distro's packages online. I have provided direct links below for easy access.

- [List of `openssh` packages on Alpine releases](https://pkgs.alpinelinux.org/packages?name=openssh&branch=&repo=main&arch=x86_64)
- [List of `openssh-server` packages on Debian releases](https://packages.debian.org/search?keywords=openssh-server&searchon=names&exact=1&suite=all&section=main)

<!-- # Daily builds

Images are automatically built daily to get the newest version of OpenSSH provided by the package managers. -->
