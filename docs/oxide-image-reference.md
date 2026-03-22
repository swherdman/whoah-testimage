# Oxide VM Image Reference

A reference for building custom Linux VM images that boot on Oxide's Propolis hypervisor. This assumes familiarity with building Linux images for other platforms (AWS, GCP, etc.) and focuses on what's different about Oxide.

## Virtual hardware

Propolis is bhyve-based. Guests see:

| Device | Type | PCI ID | Notes |
|---|---|---|---|
| Boot disk | Oxide NVMe | `01de:0000` | Class `0x010802`. NOT virtio-blk. |
| Metadata drive | virtio-blk | `1af4:1001` | ~21KB, NoCloud datasource. Appears as `/dev/vda`. |
| NIC | virtio-net | `1af4:1000` | Standard virtio. `eth0` on most distros. |
| Firmware | UEFI (OVMF) | — | TianoCore EDK2. No persistent NVRAM. |
| Console | Serial | — | `ttyS0`, 115200 8N1. No VGA/framebuffer. |

### The NVMe boot disk

This is the most important difference from other cloud platforms. The boot disk is an Oxide NVMe controller, not virtio-blk or virtio-scsi. Your kernel and initramfs **must** include the NVMe driver.

On Alpine (`linux-virt`), NVMe is a module, not built-in. The initramfs must explicitly include it:

```
features="base ext4 virtio nvme"
```

On Ubuntu/Debian, the NVMe driver (`nvme-core`, `nvme`) is typically included in the default initramfs. Verify with:

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep nvme
```

**Symptom if missing:** The kernel boots (UEFI loads it from the ESP) but drops to an initramfs emergency shell with `mount: mounting UUID=... on /sysroot failed: No such file or directory`. The only block device visible is `/dev/vda` (the 21KB metadata drive). Run `dmesg | grep nvme` from the emergency shell to confirm.

### The metadata drive

Oxide presents a NoCloud-compatible metadata drive at `/dev/vda` (~21KB, virtio-blk). If you use cloud-init, it will pick this up automatically. If you're building a pre-baked image without cloud-init, ignore it.

**Common mistake:** Assuming `/dev/vda` is your boot disk. It isn't — it's the metadata drive. Your boot disk is `/dev/nvme0n1`.

### Console

There is no VGA output. All console access is via serial (`ttyS0` at 115200 baud). Your bootloader, kernel, and init system must all be configured for serial output, or the system will appear to hang despite booting normally.

## Disk image format

Oxide accepts raw disk images via `oxide disk import`:

| Requirement | Value |
|---|---|
| Format | Raw (not qcow2, vmdk, or vhd) |
| Partition table | GPT |
| Boot partition | EFI System Partition (FAT32) |
| Block size | 512 (pass `--disk-block-size 512`) |
| Minimum disk | 1 GiB (Oxide enforces this regardless of image size) |

Sparse raw files upload correctly.

### EFI System Partition sizing

The ESP only needs to hold the UEFI bootloader (~2MB for GRUB EFI). Practical minimums:

| Size | Notes |
|---|---|
| 33 MB | Absolute FAT32 minimum (65,525 clusters). |
| 64 MB | Safe minimum for appliance images. |
| 128 MB | Conservative default. |

OVMF supports FAT12, FAT16, and FAT32. FAT32 is the most tested path.

## Bootloader

GRUB EFI is the standard choice. Key flags:

```bash
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --boot-directory=/boot \
    --removable \
    --no-nvram
```

- `--removable` installs to `/EFI/BOOT/BOOTX64.EFI` — the UEFI fallback path that OVMF uses when no boot entry exists in NVRAM.
- `--no-nvram` is required because Oxide's OVMF has no persistent NVRAM.

### Serial console in GRUB

Without serial terminal configuration, GRUB sends output to VGA (which doesn't exist) and boot appears to hang:

```
serial --speed=115200
terminal_input serial
terminal_output serial

set timeout=0
set default=0

menuentry "Linux" {
    linux /boot/vmlinuz root=UUID=<uuid> rootfstype=ext4 console=ttyS0,115200n8 quiet
    initrd /boot/initramfs
}
```

`console=ttyS0,115200n8` in the kernel command line is critical.

## Networking

### DHCP

Oxide VPC instances get their IP via DHCP from the OPTE virtual networking layer. The NIC appears as a standard virtio-net device. Configure your image for DHCP on the primary interface.

Alpine (`/etc/network/interfaces`):
```
auto eth0
iface eth0 inet dhcp
```

Ubuntu/Debian (netplan):
```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
```

### DNS

The DHCP-provided DNS servers may only resolve Oxide internal names (`*.oxide.internal`). For external name resolution, bake a public DNS fallback into the image:

```bash
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

On systems with `systemd-resolved`, this may be overridden by DHCP. Configure DNS directly in netplan or the network manager instead.

### Firewall

Oxide VPC firewalls default to **allow-all outbound, deny-all inbound** (except ICMP, intra-VPC, and SSH on port 22). To expose additional ports, update the VPC firewall rules via the Oxide CLI or web console.

### External IP

Instances get a SNAT IP for outbound traffic automatically. For inbound access, attach an ephemeral IP:

```bash
oxide instance external-ip attach-ephemeral \
    --project <project> \
    --instance <instance>
```

## Uploading and deploying

```bash
# Upload raw image as a disk
oxide disk import \
    --project <project> \
    --description "my image" \
    --path image.raw \
    --disk my-boot-disk \
    --disk-block-size 512

# Create instance (1 GiB RAM minimum)
oxide instance create --project <project> --json-body instance.json

# Connect via serial console
oxide instance serial console --project <project> --instance <instance>
```

To create a reusable image (snapshot + image), add these flags to `disk import`:
```
    --snapshot my-snapshot \
    --image my-image \
    --image-description "my image" \
    --image-os linux \
    --image-version "1.0"
```

The upload may time out on the Nexus API but still succeed. Check `oxide disk view` — if the state is `detached`, it completed.

## Verifying images locally

Mount a raw image in Docker to inspect contents without deploying:

```bash
docker run --rm --privileged -v "$(pwd):/work" alpine:latest sh -c "
apk add -q util-linux kpartx
LOOP=\$(losetup -f --show /work/image.raw)
kpartx -av \$LOOP >/dev/null 2>&1; sleep 1
mkdir -p /mnt/root
mount /dev/mapper/\$(basename \$LOOP)p2 /mnt/root

ls /mnt/root/
cat /mnt/root/etc/hostname

umount /mnt/root
kpartx -d \$LOOP; losetup -d \$LOOP
"
```

## Troubleshooting

### Drops to initramfs emergency shell
`mount: mounting UUID=... on /sysroot failed: No such file or directory`

Missing NVMe driver. From the emergency shell:
```bash
ls /dev/nvme*     # Should show /dev/nvme0n1, /dev/nvme0n1p1, etc.
dmesg | grep nvme # Check if driver loaded
lsmod | grep nvme # Check if module is present
```

### Boot appears to hang
GRUB or the kernel is sending output to VGA. Check your GRUB config for `terminal_input serial` / `terminal_output serial` and kernel command line for `console=ttyS0,115200n8`.

### `/dev/vda` is only 21KB
That's the NoCloud metadata drive, not your boot disk. The boot disk is at `/dev/nvme0n1`.

### `oxide disk import` times out
Check `oxide disk view` — the upload usually succeeded. The Nexus API on single-sled deployments is frequently slow.

### Network interface doesn't come up
Verify the `virtio_net` driver is present. On Alpine, check `/lib/modules/*/kernel/drivers/net/virtio_net.ko*` exists. DHCP clients (udhcpc) also require `AF_PACKET` support in the kernel — ensure the relevant network modules are not stripped from the image.

### SSH rejects users that resolve via custom lookup
OpenSSH checks `/etc/shadow` in addition to `getpwnam()`. Users without a shadow entry may be rejected even if the username resolves. With `UsePAM yes`, the shadow check is bypassed and PAM handles authentication instead.
