#!/usr/bin/env bash
# HRIS Hotel — bootstrap publik untuk repositori aplikasi privat.
#
# Jalankan pertama kali: skrip membuat SSH deploy key read-only, menunggu kunci
# ditambahkan ke GitHub, meng-clone it-avp-bali/hris-hotel, lalu menjalankan
# install.sh yang ada di dalam repositori aplikasi.
#
# Jalankan berikutnya: tarik commit terbaru dari branch yang dipakai, lalu
# ulangi install.sh (idempoten, APP_KEY lama dipertahankan).
#
# Tidak ada token GitHub yang disimpan di server. Deploy key bersifat read-only
# dan hanya berlaku untuk satu repositori.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -eq 0 ]]; then
  DEFAULT_REPO_DIR="/opt/hris-hotel"
else
  DEFAULT_REPO_DIR="${HOME}/hris-hotel"
fi

REPO_DIR="$DEFAULT_REPO_DIR"
REPO_URL="git@github-hris:it-avp-bali/hris-hotel.git"
BRANCH="uiux/phase-1.1"
SSH_ALIAS="github-hris"
KEY_PATH="${HOME}/.ssh/hris_deploy"
SSH_CONFIG="${HOME}/.ssh/config"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

ASSUME_YES=false
UPDATE_ONLY=false
CLONE_ONLY=false
KEEP_REMOTE=false
PRINT_KEY_ONLY=false
SKIP_BACKUP=false

usage() {
  cat <<'EOF'
Pemakaian: sudo bash deploy-server.sh [opsi]

Tanpa opsi: buat deploy key, tunggu kunci ditambahkan di GitHub, clone
repositori privat, lalu jalankan install.sh.

Opsi:
  --repo-dir=DIR        Direktori aplikasi (default: /opt/hris-hotel untuk root,
                        ~/hris-hotel untuk pengguna biasa)
  --repo-url=URL        Remote git (default: git@github-hris:it-avp-bali/hris-hotel.git)
  --branch=NAME         Branch yang dipasang (default: uiux/phase-1.1)
  --key=PATH            Lokasi deploy key (default: ~/.ssh/hris_deploy)
  --ssh-alias=NAME      Alias SSH (default: github-hris)
  --update              Wajib sudah ada clone; tarik update lalu jalankan install.sh
  --skip-backup         Jangan buat backup database sebelum update
  --clone-only          Hanya clone; jangan jalankan install.sh
  --print-key           Cetak public key lalu keluar
  --keep-remote         Jangan ubah origin yang sudah ada
  --yes, -y             Lewati konfirmasi deploy key
  -h, --help            Tampilkan bantuan ini

Contoh:
  sudo bash deploy-server.sh
  sudo bash /opt/hris-hotel/deploy-server.sh --update
  sudo DOMAIN=hris.example.com DB_PASSWORD='...' bash deploy-server.sh
EOF
}

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mPERINGATAN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mGAGAL:\033[0m %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --repo-dir=*) REPO_DIR="${arg#*=}" ;;
    --repo-url=*) REPO_URL="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --key=*) KEY_PATH="${arg#*=}" ;;
    --ssh-alias=*) SSH_ALIAS="${arg#*=}" ;;
    --update) UPDATE_ONLY=true ;;
    --skip-backup) SKIP_BACKUP=true ;;
    --clone-only) CLONE_ONLY=true ;;
    --keep-remote) KEEP_REMOTE=true ;;
    --print-key) PRINT_KEY_ONLY=true ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $arg (gunakan --help)" ;;
  esac
done

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo diperlukan bila tidak dijalankan sebagai root."
  SUDO=(sudo)
fi

run_root() { "${SUDO[@]}" "$@"; }

ensure_os() {
  if [[ ! -f /etc/debian_version ]]; then
    die "Skrip ini mendukung Ubuntu/Debian. Untuk distro lain ikuti README.md di aplikasi."
  fi
}

ensure_packages() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v ssh >/dev/null 2>&1 || missing+=(openssh-client)
  command -v ssh-keygen >/dev/null 2>&1 || missing+=(openssh-client)
  command -v ssh-keyscan >/dev/null 2>&1 || missing+=(openssh-client)

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || \
    die "Paket berikut belum ada: ${missing[*]}. Pasang git dan openssh-client lalu ulangi."

  log "Memasang paket: ${missing[*]}"
  run_root apt-get update -y
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

ensure_ssh_dir() {
  install -d -m 700 "${HOME}/.ssh"
  touch "$KNOWN_HOSTS" "$SSH_CONFIG"
  chmod 600 "$KNOWN_HOSTS" "$SSH_CONFIG"
}

ensure_key() {
  if [[ -f "$KEY_PATH" ]]; then
    log "Memakai deploy key yang sudah ada: $KEY_PATH"
  else
    log "Membuat deploy key read-only: $KEY_PATH"
    install -d -m 700 "$(dirname "$KEY_PATH")"
    ssh-keygen -t ed25519 -C "hris-deploy@$(hostname)" -f "$KEY_PATH" -N "" >/dev/null
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
  fi
}

print_key_instructions() {
  cat <<EOF

Tambahkan public key berikut di GitHub:

  Repositori privat -> Settings -> Deploy keys -> Add deploy key
  Title:     $(hostname) hris deploy
  Key:
$(cat "${KEY_PATH}.pub")

  Allow write access: OFF (read-only)

EOF
}

wait_for_key() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  [[ -t 0 ]] || die "Tidak ada terminal interaktif. Tambahkan kunci, lalu ulangi dengan --yes."
  read -r -p "Tekan Enter setelah deploy key disimpan di GitHub... " _
}

ensure_known_hosts() {
  if ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    return 0
  fi
  log "Menyimpan host key github.com"
  warn "Cocokkan fingerprint dengan https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints"
  local scanned
  scanned="$(ssh-keyscan -t ed25519,rsa github.com 2>/dev/null || true)"
  [[ -n "$scanned" ]] || die "Tidak dapat menghubungi github.com untuk membaca host key."
  printf '%s\n' "$scanned" >> "$KNOWN_HOSTS"
  sort -u "$KNOWN_HOSTS" -o "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
}

ensure_ssh_config() {
  if grep -qE "^[[:space:]]*Host[[:space:]]+${SSH_ALIAS}([[:space:]]|$)" "$SSH_CONFIG" 2>/dev/null; then
    log "Alias SSH '${SSH_ALIAS}' sudah ada di ${SSH_CONFIG}"
    return 0
  fi
  log "Menambahkan alias SSH '${SSH_ALIAS}' ke ${SSH_CONFIG}"
  cat >> "$SSH_CONFIG" <<EOF

Host ${SSH_ALIAS}
  HostName github.com
  User git
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CONFIG"
}

SSH_CHECK_OUTPUT=""

ssh_check() {
  local output rc
  set +e
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=15 -T "git@${SSH_ALIAS}" 2>&1)"
  rc=$?
  set -e

  if [[ "$output" == *"successfully authenticated"* ]]; then
    return 0
  fi

  SSH_CHECK_OUTPUT="$output (exit ${rc})"
  return 1
}

ensure_ssh_access() {
  log "Menguji deploy key ke GitHub"
  if ssh_check; then
    log "Deploy key diterima GitHub"
    return 0
  fi

  print_key_instructions
  wait_for_key

  if ssh_check; then
    log "Deploy key diterima GitHub"
    return 0
  fi

  printf '%s\n' "$SSH_CHECK_OUTPUT" >&2
  die "GitHub menolak deploy key. Tambahkan kunci ke repositori privat dengan akses baca, lalu ulangi."
}

require_clean_tree() {
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]]; then
    die "Ada perubahan lokal di ${REPO_DIR}. Commit atau stash dulu sebelum update."
  fi
}

ensure_remote() {
  local current
  current="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"

  if [[ -z "$current" ]]; then
    git -C "$REPO_DIR" remote add origin "$REPO_URL"
  elif [[ "$current" != "$REPO_URL" && "$KEEP_REMOTE" != "true" ]]; then
    warn "origin saat ini ${current}; diubah ke ${REPO_URL} agar deploy key dipakai"
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  fi
}

clone_repo() {
  if [[ -d "$REPO_DIR" && -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]]; then
    die "${REPO_DIR} sudah ada dan tidak kosong. Hapus atau pakai --repo-dir=DIR."
  fi

  log "Meng-clone ${REPO_URL} (${BRANCH}) ke ${REPO_DIR}"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$REPO_DIR"
}

pull_repo() {
  require_clean_tree
  ensure_remote
  local before after
  before="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo tidak-diketahui)"
  log "Menarik origin/${BRANCH}"
  git -C "$REPO_DIR" fetch --prune origin "$BRANCH"
  git -C "$REPO_DIR" checkout "$BRANCH" >/dev/null 2>&1 || \
    die "Tidak dapat checkout ${BRANCH} di ${REPO_DIR}."
  git -C "$REPO_DIR" merge --ff-only "origin/${BRANCH}"
  after="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo tidak-diketahui)"
  log "Repositori diperbarui: ${before} -> ${after}"
}

backup_before_update() {
  if [[ "$SKIP_BACKUP" == "true" ]]; then
    warn "Backup database sebelum update dilewati (--skip-backup)"
    return 0
  fi

  if [[ ! -f "$REPO_DIR/artisan" || ! -f "$REPO_DIR/.env" ]]; then
    warn "Aplikasi belum terpasang di ${REPO_DIR}; backup dilewati"
    return 0
  fi

  log "Membuat backup database sebelum update"
  if ! run_root php "$REPO_DIR/artisan" app:backup; then
    die "Backup gagal. Perbaiki dulu, atau ulangi dengan --skip-backup bila backup terbaru sudah ada."
  fi
}

run_install() {
  log "Menjalankan instalasi aplikasi (install.sh)"
  local env_args=()
  local var

  for var in DOMAIN APP_URL DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD SETUP_TOKEN NODE_MAJOR APP_USER; do
    if [[ -n "${!var:-}" ]]; then
      env_args+=("${var}=${!var}")
    fi
  done

  run_root env "${env_args[@]}" bash "$REPO_DIR/install.sh"
}

print_summary() {
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  cat <<EOF

Direktori aplikasi: ${REPO_DIR}
Repositori:         ${REPO_URL} (${BRANCH})
Deploy key:         ${KEY_PATH} (read-only, hanya untuk repositori ini)

Buka:    http://${host_ip:-<IP-server>}
Wizard:  buat Super Admin sekali pakai memakai SETUP_TOKEN dari .env

Update berikutnya:
  sudo bash ${SCRIPT_DIR}/deploy-server.sh --update

Simpan skrip ini di lokasi tetap, misalnya:
  sudo install -m 755 ${SCRIPT_DIR}/deploy-server.sh /usr/local/sbin/hris-bootstrap
  sudo /usr/local/sbin/hris-bootstrap --update
EOF
}

ensure_os
ensure_packages
ensure_ssh_dir
ensure_key

if [[ "$PRINT_KEY_ONLY" == "true" ]]; then
  cat "${KEY_PATH}.pub"
  exit 0
fi

ensure_known_hosts
ensure_ssh_config

if [[ "$UPDATE_ONLY" == "true" && ! -d "$REPO_DIR/.git" ]]; then
  die "--update membutuhkan clone yang sudah ada di ${REPO_DIR}."
fi

if [[ "$REPO_URL" == git@* ]]; then
  ensure_ssh_access
fi

if [[ -d "$REPO_DIR/.git" ]]; then
  if [[ "$UPDATE_ONLY" == "true" ]]; then
    backup_before_update
  fi
  pull_repo
else
  clone_repo
fi

if [[ "$CLONE_ONLY" == "true" ]]; then
  log "Clone selesai (instalasi dilewati karena --clone-only)"
  print_summary
  exit 0
fi

run_install
print_summary
