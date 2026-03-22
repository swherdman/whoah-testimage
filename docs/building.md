# Building the Image

## Prerequisites

- Docker with `--privileged` support (Docker Desktop, Docker Engine, or Podman)
- ~2GB free disk space for the build

No other tools or dependencies are required. The entire build runs inside a Docker container.

## Build

```bash
git clone https://github.com/swherdman/whoah-testimage.git
cd whoah-testimage
./build.sh
```

The build takes approximately 60-90 seconds and produces `output/whoah-testimage.raw` (384MB).

### What the build does

1. Creates a Docker container with Alpine build tools (parted, grub, gcc, etc.)
2. Creates a raw GPT disk image with an EFI System Partition and ext4 root
3. Bootstraps an Alpine Linux rootfs using `apk --root`
4. Compiles `nscd-any` (a ~150 line C program) as a static binary
5. Copies overlay configuration files into the rootfs
6. Downloads application data
7. Configures OpenRC services, serial console, networking
8. Generates the initramfs and installs GRUB for UEFI boot
9. Removes build-only files (System.map, GRUB CLI tools, mkinitfs, apk cache)

### Build output

| File | Size | Description |
|---|---|---|
| `output/whoah-testimage.raw` | 384 MB | Raw disk image, ready for `oxide disk import` |

To create a compressed release artifact:

```bash
gzip -9 -c output/whoah-testimage.raw > output/whoah-testimage.raw.gz
```

## Project structure

```
whoah-testimage/
├── build.sh                    # Host entry point — runs Docker
├── Dockerfile.builder          # Alpine container with build tools
├── deploy.sh                   # Upload to Oxide and create instance
├── Makefile                    # build, deploy, clean targets
├── scripts/
│   └── build-image.sh          # Runs inside Docker: partition, bootstrap, configure
├── src/
│   └── nscd-any.c              # musl nscd responder for any-username SSH
└── rootfs/                     # Overlay files baked into the image
    ├── etc/
    │   ├── init.d/
    │   │   ├── nscd-any        # OpenRC service: nscd responder
    │   │   ├── tls-cert        # OpenRC service: TLS cert generation
    │   │   ├── ttyd-http       # OpenRC service: web terminal (HTTP)
    │   │   └── ttyd-https      # OpenRC service: web terminal (HTTPS)
    │   ├── network/
    │   │   └── interfaces      # DHCP on eth0
    │   ├── pam.d/
    │   │   └── sshd            # PAM config for passwordless SSH
    │   └── ssh/
    │       └── sshd_config     # SSH config: any user, no auth, ForceCommand
    └── home/
        └── whoah-testimage-user/
            └── .profile        # Auto-login shell profile
```

## Customisation

### Changing the application

The image runs a specific application via three entry points:

| Entry point | File | How it launches |
|---|---|---|
| Serial console | `rootfs/home/whoah-testimage-user/.profile` | `exec <command>` on auto-login |
| SSH | `rootfs/etc/ssh/sshd_config` | `ForceCommand <command>` |
| HTTP/HTTPS | `rootfs/etc/init.d/ttyd-http`, `ttyd-https` | `ttyd -W <command>` |

To change what the image runs, update the command in all three files and rebuild.

### Changing the hostname

Edit the `echo "whoah-testimage"` line in `scripts/build-image.sh`.

### Image size

The image size is set by `IMAGE_SIZE` in `scripts/build-image.sh` (default: 384MB). The ESP is 64MB and the root partition uses the remainder. Actual disk usage is approximately 105MB.

## Technical notes

### NVMe boot disk

Oxide's Propolis hypervisor presents the boot disk as an NVMe device (`01de:0000`), not virtio-blk. The initramfs must include the `nvme` feature for the kernel to mount the root filesystem.

### Any-username SSH

OpenSSH requires `getpwnam()` to succeed for the connecting username. On Alpine (musl libc), `getpwnam()` falls back to querying `/var/run/nscd/socket` when a user isn't in `/etc/passwd`. The `nscd-any` daemon responds to every query, mapping all usernames to a single system user. Combined with PAM (`pam_permit.so`), this allows any username to connect without authentication.

### Serial console

Alpine uses `/etc/inittab` for getty management. The image configures a serial getty on `ttyS0` at 115200 baud with auto-login via a helper script at `/usr/local/bin/autologin`.
