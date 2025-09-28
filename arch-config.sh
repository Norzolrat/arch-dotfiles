#!/usr/bin/env bash
# arch-config.sh — Install core desktop + wire your dotfiles from ./dots
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
ENABLE_NOCTALIA=${ENABLE_NOCTALIA:-true}     # <--- NEW: install and autostart Noctalia

### ======= Helpers =======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTS_DIR="${SCRIPT_DIR}/dots"

die() { echo "Error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }
pac() { pacman --noconfirm --needed -S "$@"; }
enable() { systemctl enable "$1"; systemctl start "$1" || true; }
as_user() { sudo -u "$USERNAME" bash -lc "$*"; }

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
    useradd -m -G wheel,audio,video,storage,input,kvm,libvirt "$USERNAME"
    echo "Set password for $USERNAME:"
    passwd "$USERNAME"
  fi
}

### ======= Packages / services =======
install_base() {
  pac -Syu --noconfirm
  pac base-devel git curl wget rsync unzip zip bash-completion linux-headers \
      networkmanager iwd openssh reflector dmidecode fish
  enable NetworkManager
  enable sshd
}

install_desktop() {
  pac hyprland xorg-xwayland \
      xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
      gdm \
      alacritty fuzzel wl-clipboard grim slurp \
      swayidle gtklock libnotify \
      network-manager-applet blueman \
      brightnessctl pamixer pavucontrol

  enable gdm

  # Audio
  pac pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack

  # Bluetooth
  pac bluez bluez-utils
  enable bluetooth

  # Firmware / power / graphics (generic)
  pac fwupd upower mesa vulkan-icd-loader
  enable fwupd
  enable upower

  # Fonts / icons / cursor
  pac noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation \
      gnome-themes-extra adwaita-qt papirus-icon-theme bibata-cursor-theme ttf-font-awesome
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
  usermod -aG docker "$USERNAME" || true
  enable docker
}

install_libvirt() {
  $ENABLE_LIBVIRT || return 0
  pac libvirt qemu-full edk2-ovmf dnsmasq iptables-nft bridge-utils virt-manager spice-gtk virt-viewer
  usermod -aG libvirt,kvm "$USERNAME" || true
  enable libvirtd
  cat >/etc/modprobe.d/kvm-intel.conf <<'EOF'
options kvm_intel nested=1
options kvm_intel emulate_invalid_guest_state=0
options kvm ignore_msrs=1
EOF
}

### ======= Noctalia (AUR) =======
install_noctalia() {
  $ENABLE_NOCTALIA || return 0
  # Install Noctalia (this pulls Quickshell and deps via AUR)
  as_user 'yay -S --noconfirm --needed noctalia-shell'
}

### ======= Dotfiles wiring (./dots layout) =======
link_into_home() {
  local src="$1" dest="$2"
  as_user "
    set -e
    mkdir -p \"\$(dirname \"$dest\")\"
    ln -sfn \"$src\" \"$dest\"
  "
}

copy_into_root() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$dest"
}

setup_dotfiles() {
  [[ -d "$DOTS_DIR" ]] || { echo "Skip dotfiles: $DOTS_DIR missing"; return 0; }
  local H="/home/$USERNAME"
  [[ -d "$H" ]] || die "Home directory $H not found."

  # Alacritty
  if [[ -d "$DOTS_DIR/alacritty" ]]; then
    link_into_home "$DOTS_DIR/alacritty" "$H/.config/alacritty"
  fi

  # gtklock
  if [[ -d "$DOTS_DIR/gtklock" ]]; then
    link_into_home "$DOTS_DIR/gtklock" "$H/.config/gtklock"
  fi

  # Hyprland configs & shaders
  local HYPRCFG="$DOTS_DIR/hypr"
  if [[ -d "$HYPRCFG" ]]; then
    as_user "mkdir -p \"$H/.config/hypr\" \"$H/.config/hypr/shaders\""
    if [[ -f "$HYPRCFG/hyprland.conf" ]]; then
      link_into_home "$HYPRCFG/hyprland.conf" "$H/.config/hypr/hyprland.conf"
    fi
    if [[ -d "$HYPRCFG/hyprland" ]]; then
      for f in "$HYPRCFG/hyprland"/*.conf; do
        [[ -e "$f" ]] || continue
        link_into_home "$f" "$H/.config/hypr/$(basename "$f")"
      done
      if [[ -d "$HYPRCFG/hyprland/scripts" ]]; then
        link_into_home "$HYPRCFG/hyprland/scripts" "$H/.config/hypr/scripts"
      fi
    fi
    if [[ -d "$HYPRCFG/shaders" ]]; then
      link_into_home "$HYPRCFG/shaders" "$H/.config/hypr/shaders"
    fi
  fi

  # Wallpapers -> ~/Pictures/wallpapers
  if [[ -d "$DOTS_DIR/wallpapers" ]]; then
    as_user "mkdir -p \"$H/Pictures\""
    link_into_home "$DOTS_DIR/wallpapers" "$H/Pictures/wallpapers"
  fi

  # Faces -> set GDM avatar (first image found)
  if [[ -d "$DOTS_DIR/faces" ]]; then
    local face
    face="$(find "$DOTS_DIR/faces" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | head -n1 || true)"
    if [[ -n "${face:-}" ]]; then
      local icond="/var/lib/AccountsService/icons"
      local usersd="/var/lib/AccountsService/users"
      mkdir -p "$icond" "$usersd"
      copy_into_root "$face" "$icond/$USERNAME"
      {
        echo "[User]"
        echo "Icon=$icond/$USERNAME"
      } > "$usersd/$USERNAME"
    fi
  fi

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

  setup_dotfiles

  # Install + autostart Noctalia
  install_noctalia

  echo
  echo "✅ Done."
  echo "- User: $USERNAME (default shell: fish)"
  echo "- KEYMAP (console): $KEYMAP ; XKB default: us"
  echo "- Display manager: GDM (Wayland). Session: Hyprland"
  echo "- Dotfiles linked from: $DOTS_DIR"
  $ENABLE_NOCTALIA && echo "- Noctalia installed and set to autostart (qs -c noctalia-shell)."
  $ENABLE_DOCKER && echo "- Docker enabled (relog for group membership)."
  $ENABLE_LIBVIRT && echo "- libvirtd enabled."
  echo "Reboot to start your Hyprland session."
}

main "$@"
