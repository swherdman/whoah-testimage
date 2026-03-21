FROM alpine:latest

RUN apk add --no-cache \
    alpine-conf \
    apk-tools \
    dosfstools \
    e2fsprogs \
    grub \
    grub-efi \
    kpartx \
    mkinitfs \
    parted \
    util-linux \
    wget

WORKDIR /build
