#!/usr/bin/env bash
# arch-config.sh — Arch setup + dotfiles (COPY mode, no symlinks)
# Run as root from the repo root (the folder that contains ./dots).

set -euo pipefail

### ======= EDITABLE DEFAULTS =======
USERNAME="${USERNAME:-normi}"
HOSTNAME="${HOSTNAME:-veronica}"
TIMEZONE="${TIMEZONE:-Europe/Paris}"
KEYMAP="${KEYMAP:-us}"
LOCALES=("en_US.UTF-8 UTF-8" "fr_FR.UTF-8 UTF-8")
LANG_DEFAULT="${LANG_DEFAULT:-en_US.UTF-8}"

ENABLE_DOCKER=${ENABLE_DOCKER:-true}
ENABLE_LIBVIRT=${ENABLE_LIBVIRT:-true}
CREATE_USER=${CREATE_USER:-true}
ENABLE_NOCTALIA=${ENABLE_NOCTALIA:-true}   # install + autostart noctalia-shell

### ======= Paths & helpers =======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTS_DIR="${SCRIPT_DIR}/dots"

die() { echo "Error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }
pac() { pacman --noconfirm --needed -S "$@"; }
enable() { systemctl enable "$1"; systemctl start "$1" || true; }
as_user() { sudo -u "$USERNAME" bash -lc "$*"; }

# Copy tree into destination (preserve perms, delete stale files)
sync_dir_to_user() { # src dest_dir
  local src="$1" dest="$2"
  mkdir -p "$dest"
  # run as root, set owner on the fly
  rsync -a --delete --chown="$USERNAME:$USERNAME" "$src"/ "$dest"/
}


### ======= System prep =======
tune_pacman() {
  sed -i 's/^#Color/Color/' /etc/pacman.conf || true
  sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf || true
  grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
  if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    cat >>/etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
  fi
}

set_locale() {
  for l in "${LOCALES[@]}"; do
    sed -i "s/^#\s*${l}/${l}/" /etc/locale.gen || true
    grep -q "^${l}$" /etc/locale.gen || echo "${l}" >> /etc/locale.gen
  done
  locale-gen
  printf "LANG=%s\n" "$LANG_DEFAULT" > /etc/locale.conf
  printf "KEYMAP=%s\n" "$KEYMAP" > /etc/vconsole.conf
  localectl set-x11-keymap us || true
}

set_time_host() {
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  hwclock --systohc
  echo "${HOSTNAME}" > /etc/hostname
  grep -q "$HOSTNAME" /etc/hosts || echo -e "\n127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts
}

sudo_wheel() {
  mkdir -p /etc/sudoers.d
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
  chmod 0440 /etc/sudoers.d/10-wheel
}

maybe_create_user() {
  if $CREATE_USER && ! id -u "$USERNAME" &>/dev/null; then
    useradd -m -G wheel,audio,video,storage,input "$USERNAME"
    echo "Set password for $USERNAME:"
    passwd "$USERNAME"
  fi
}

### ======= Packages / services =======
install_base() {
  pacman -Syu --noconfirm
  pac base-devel git curl wget rsync unzip zip bash-completion linux-headers \
      networkmanager iwd openssh reflector dmidecode fish
  enable NetworkManager
  enable sshd
}

install_desktop() {
  pac hyprland xorg-xwayland \
      xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
      alacritty fuzzel wl-clipboard grim slurp \
      swayidle gtklock libnotify \
      network-manager-applet blueman \
      brightnessctl pamixer pavucontrol

  # Audio
  pac pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack

  # Bluetooth
  pac bluez bluez-utils
  enable bluetooth

  # Firmware / power / graphics (generic)
  pac fwupd upower mesa vulkan-icd-loader
  enable fwupd
  enable upower

  # Fonts / icons
  pac noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-font-awesome
}

install_yay() {
  if ! command -v yay &>/dev/null; then
    pac base-devel git
    as_user '
      set -e
      cd ~
      rm -rf yay
      git clone https://aur.archlinux.org/yay.git
      cd yay
      makepkg -si --noconfirm
    '
  fi
}

install_aur_goodies() {
  as_user 'yay -S --noconfirm --needed \
    ttf-jetbrains-mono-nerd nerd-fonts-symbols-only ttf-material-design-icons'
}

install_docker() {
  $ENABLE_DOCKER || return 0
  pac docker docker-compose
  groupadd -f docker
  usermod -aG docker "$USERNAME" || true
  enable docker
}


install_libvirt() {
  $ENABLE_LIBVIRT || return 0
  pac libvirt qemu-full edk2-ovmf dnsmasq bridge-utils virt-manager spice-gtk virt-viewer
  enable libvirtd

  # make sure groups exist, then add the user
  groupadd -f libvirt
  groupadd -f kvm
  usermod -aG libvirt,kvm "$USERNAME" || true

  cat >/etc/modprobe.d/kvm-intel.conf <<'EOF'
options kvm_intel nested=1
options kvm_intel emulate_invalid_guest_state=0
options kvm ignore_msrs=1
EOF
}


install_noctalia() {
  $ENABLE_NOCTALIA || return 0
  as_user 'yay -S --noconfirm --needed noctalia-shell'
}

### ======= Dotfiles (COPY EVERYTHING under ./dots into ~/.config) =======
copy_all_dots_into_config() {
  [[ -d "$DOTS_DIR" ]] || { echo "Skip dotfiles copy: $DOTS_DIR missing"; return 0; }
  local H="/home/$USERNAME"
  [[ -d "$H" ]] || die "Home directory $H not found."

  # 1) Copy every subfolder/file from ./dots into ~/.config (one flat rule)
  sync_dir_to_user "$DOTS_DIR" "$H/.config"

  # 2) Optional quality-of-life: if wallpapers landed in ~/.config/wallpapers, mirror them to ~/Pictures/wallpapers
  if as_user "[ -d \"$H/.config/wallpapers\" ]"; then
    as_user "mkdir -p \"$H/Pictures/wallpapers\" && rsync -a --delete \"$H/.config/wallpapers/\" \"$H/Pictures/wallpapers/\""
  fi

  # 3) Optional: if quickshell config is under ~/.config/quickshell/noctalia-shell, good; nothing else needed

  # 4) Ensure ownership
  chown -R "$USERNAME:$USERNAME" "$H/.config" "$H/Pictures" 2>/dev/null || true
}

### ======= Main =======
main() {
  need_root
  tune_pacman
  set_locale
  set_time_host
  install_base
  sudo_wheel
  maybe_create_user

  # Default shell -> fish
  if command -v fish &>/dev/null; then
    chsh -s /usr/bin/fish "$USERNAME" || true
  fi

  install_desktop
  install_yay
  install_aur_goodies
  install_docker
  install_libvirt
  install_noctalia

  copy_all_dots_into_config
  ensure_noctalia_autostart

  echo
  echo "✅ Done."
  echo "- User: $USERNAME (default shell: fish)"
  echo "- KEYMAP (console): $KEYMAP ; XKB default: us"
  echo "- Dotfiles copied from: $DOTS_DIR -> ~/.config (rsync --delete)"
  $ENABLE_NOCTALIA && echo "- Noctalia installed and set to autostart (qs -c noctalia-shell)."
  $ENABLE_DOCKER && echo "- Docker enabled (relog for group membership)."
  $ENABLE_LIBVIRT && echo "- libvirtd enabled."
  echo "Reboot to start your Hyprland session."
}

main "$@"
