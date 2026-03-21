#!/bin/sh
set -e

IMAGE="/output/whoah-testimage.raw"
IMAGE_SIZE="512M"
ROOTFS="/mnt/root"
GAME_URL="https://eblong.com/infocom/gamefiles/zork1-r119-s880429.z3"
USERNAME="whoah-testimage-user"

echo "=== Creating disk image ==="
truncate -s "$IMAGE_SIZE" "$IMAGE"

echo "=== Partitioning (GPT + ESP + root) ==="
parted -s "$IMAGE" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 129MiB \
    set 1 esp on \
    mkpart root ext4 129MiB 100%

echo "=== Setting up loop device ==="
LOOP=$(losetup -f --show "$IMAGE")
echo "Loop device: $LOOP"
kpartx -av "$LOOP"

# Get partition device names
LOOP_BASE=$(basename "$LOOP")
ESP_DEV="/dev/mapper/${LOOP_BASE}p1"
ROOT_DEV="/dev/mapper/${LOOP_BASE}p2"

# Wait for devices
sleep 1

echo "=== Formatting partitions ==="
mkfs.fat -F32 -n EFI "$ESP_DEV"
mkfs.ext4 -L root -q "$ROOT_DEV"

echo "=== Mounting ==="
mkdir -p "$ROOTFS"
mount "$ROOT_DEV" "$ROOTFS"
mkdir -p "$ROOTFS/boot/efi"
mount "$ESP_DEV" "$ROOTFS/boot/efi"

echo "=== Bootstrapping Alpine rootfs ==="
apk -X https://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
    -X https://dl-cdn.alpinelinux.org/alpine/latest-stable/community \
    -U --allow-untrusted \
    --root "$ROOTFS" --initdb --arch x86_64 \
    add \
    alpine-base \
    linux-virt \
    frotz \
    openssh-server-pam \
    grub \
    grub-efi \
    e2fsprogs \
    mkinitfs

echo "=== Compiling nscd-any ==="
mkdir -p "$ROOTFS/usr/local/sbin"
gcc -static -O2 -Wall -o "$ROOTFS/usr/local/sbin/nscd-any" /src/nscd-any.c
chmod 755 "$ROOTFS/usr/local/sbin/nscd-any"

echo "=== Copying overlay files ==="
cp -a /rootfs/* "$ROOTFS/"

echo "=== Downloading game data ==="
mkdir -p "$ROOTFS/opt/game"
wget -q "$GAME_URL" -O "$ROOTFS/opt/game/zork1.z3"

echo "=== Configuring rootfs ==="

# Hostname
echo "whoah-testimage" > "$ROOTFS/etc/hostname"

# fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV")
cat > "$ROOTFS/etc/fstab" << EOF
UUID=$ROOT_UUID  /          ext4  defaults,noatime  0  1
UUID=$ESP_UUID   /boot/efi  vfat  defaults          0  0
EOF

# Create user (unlock account — replace ! with * in shadow)
chroot "$ROOTFS" adduser -D -s /bin/sh "$USERNAME"
sed -i "s/^${USERNAME}:!:/${USERNAME}:*:/" "$ROOTFS/etc/shadow"

# Auto-login script
cat > "$ROOTFS/usr/local/bin/autologin" << EOF
#!/bin/sh
exec login -f $USERNAME
EOF
chmod +x "$ROOTFS/usr/local/bin/autologin"

# inittab — serial console only, auto-login
sed -i 's|^tty1|#tty1|' "$ROOTFS/etc/inittab"
sed -i 's|^tty2|#tty2|' "$ROOTFS/etc/inittab"
sed -i 's|^tty3|#tty3|' "$ROOTFS/etc/inittab"
sed -i 's|^tty4|#tty4|' "$ROOTFS/etc/inittab"
sed -i 's|^tty5|#tty5|' "$ROOTFS/etc/inittab"
sed -i 's|^tty6|#tty6|' "$ROOTFS/etc/inittab"
echo "ttyS0::respawn:/sbin/getty -L -n -l /usr/local/bin/autologin 115200 ttyS0 vt100" >> "$ROOTFS/etc/inittab"

# DNS fallback
echo "nameserver 8.8.8.8" > "$ROOTFS/etc/resolv.conf"

# OpenRC services
chroot "$ROOTFS" rc-update add devfs sysinit
chroot "$ROOTFS" rc-update add dmesg sysinit
chroot "$ROOTFS" rc-update add mdev sysinit
chroot "$ROOTFS" rc-update add hwclock boot
chroot "$ROOTFS" rc-update add modules boot
chroot "$ROOTFS" rc-update add networking boot
chroot "$ROOTFS" rc-update add hostname boot
chroot "$ROOTFS" rc-update add nscd-any default
chroot "$ROOTFS" rc-update add sshd default
chroot "$ROOTFS" rc-update add killprocs shutdown
chroot "$ROOTFS" rc-update add mount-ro shutdown
chroot "$ROOTFS" rc-update add savecache shutdown

echo "=== Generating initramfs ==="
mkdir -p "$ROOTFS/etc/mkinitfs"
echo 'features="base ext4 virtio nvme"' > "$ROOTFS/etc/mkinitfs/mkinitfs.conf"

# Bind mounts for chroot
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"

# Generate initramfs
KERNEL_VERSION=$(ls "$ROOTFS/lib/modules/" | head -1)
chroot "$ROOTFS" mkinitfs -b / -k "$KERNEL_VERSION"

echo "=== Installing GRUB ==="
mkdir -p "$ROOTFS/boot/grub"
cat > "$ROOTFS/boot/grub/grub.cfg" << GRUBEOF
serial --speed=115200
terminal_input serial
terminal_output serial

set timeout=0
set default=0

menuentry "Alpine Linux" {
    linux /boot/vmlinuz-virt root=UUID=$ROOT_UUID rootfstype=ext4 console=ttyS0,115200n8 quiet
    initrd /boot/initramfs-virt
}
GRUBEOF

chroot "$ROOTFS" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --boot-directory=/boot \
    --removable \
    --no-nvram

echo "=== Cleanup ==="
umount "$ROOTFS/proc" || true
umount "$ROOTFS/sys" || true
umount "$ROOTFS/dev" || true
umount "$ROOTFS/boot/efi"
umount "$ROOTFS"
kpartx -d "$LOOP"
losetup -d "$LOOP"

echo "=== Done ==="
echo "Image: $IMAGE"
ls -lh "$IMAGE"
