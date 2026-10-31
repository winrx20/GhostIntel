#!/usr/bin/env bash
# ============================================================
#  GhostIntel — Termux bootstrap & runner
#
#  Memasang GhostIntel di Termux (Android, tanpa root) secara
#  idempoten: aman dijalankan berulang tanpa efek samping ganda.
#
#  Pemakaian:
#    bash setup-ghostintel-termux.sh              # instal penuh
#    WITH_LXML=0 bash setup-ghostintel-termux.sh  # tanpa lxml (lebih cepat)
#    GH_REPO=... GHOSTINTEL_DIR=... bash setup-ghostintel-termux.sh
#
#  Variabel lingkungan:
#    GH_REPO          URL repo (default: github.com/winrx20/GhostIntel)
#    GHOSTINTEL_DIR   direktori tujuan (default: $HOME/GhostIntel)
#    WITH_LXML        1 = pasang lxml best-effort, 0 = lewati (default 1)
#    NO_COLOR         set untuk mematikan warna
# ============================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly GH_REPO="${GH_REPO:-https://github.com/winrx20/GhostIntel.git}"
readonly GH_DIR="${GHOSTINTEL_DIR:-$HOME/GhostIntel}"
readonly VENV="$GH_DIR/.venv"
readonly WITH_LXML="${WITH_LXML:-1}"
readonly TOTAL_STEPS=6

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Paket inti yang benar-benar dipakai GhostIntel (diverifikasi dari source).
readonly -a CORE_PKGS=(
  aiohttp aiodns aiofiles beautifulsoup4 rich
  dnspython phonenumbers jinja2 flask flask-cors
)

# Paket sistem Termux. clang/make/binutils/pkg-config dibutuhkan bila
# pycares (dependency C dari aiodns) harus dikompilasi dari source.
readonly -a SYS_PKGS=(
  python git clang make binutils pkg-config
  libffi openssl libxml2 libxslt nano
)

# ---------- keluaran ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  readonly C_RST=$'\033[0m' C_INF=$'\033[1;36m' C_OK=$'\033[1;32m'
  readonly C_WRN=$'\033[1;33m' C_ERR=$'\033[1;31m'
else
  readonly C_RST='' C_INF='' C_OK='' C_WRN='' C_ERR=''
fi

step_no=0
info() { printf '%s==>%s %s\n' "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WRN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

step()  { step_no=$((step_no + 1)); info "$step_no/$TOTAL_STEPS  $*"; }
skip()  { step_no=$((step_no + 1)); info "$step_no/$TOTAL_STEPS  $* (dilewati)"; }

cleanup() { [ -n "${PIPLOG:-}" ] && rm -f "$PIPLOG" || true; }
trap cleanup EXIT

# ---------- pra-syarat ----------
info "GhostIntel Termux installer v$SCRIPT_VERSION"

IS_TERMUX=0
command -v pkg >/dev/null 2>&1 && IS_TERMUX=1

if [ "$IS_TERMUX" -eq 0 ]; then
  case "${PREFIX:-}" in
    *com.termux*) IS_TERMUX=1 ;;
  esac
fi

if [ "$IS_TERMUX" -eq 0 ]; then
  warn "Terdeteksi bukan Termux (perintah 'pkg' tidak ada)."
  warn "Langkah paket sistem akan dilewati; lanjut dengan Python yang ada."
fi

# ---------- 1/6 ----------
if [ "$IS_TERMUX" -eq 1 ]; then
  step "Memperbarui indeks paket Termux"
  if ! pkg update -y; then
    err "'pkg update' gagal."
    err "Coba pilih mirror lain: termux-change-repo"
    exit 1
  fi
  ok "Indeks paket diperbarui"
else
  skip "Memperbarui indeks paket Termux"
fi

# ---------- 2/6 ----------
if [ "$IS_TERMUX" -eq 1 ]; then
  step "Memasang dependensi sistem"
  if ! pkg install -y "${SYS_PKGS[@]}"; then
    err "Instalasi paket sistem gagal"
    exit 1
  fi
  ok "Dependensi sistem siap"
else
  skip "Memasang dependensi sistem"
fi

# ---------- 3/6 ----------
step "Menyiapkan source GhostIntel"
if [ -d "$GH_DIR/.git" ]; then
  if git -C "$GH_DIR" pull --ff-only >/dev/null 2>&1; then
    ok "Repo diperbarui (git pull)"
  else
    warn "git pull gagal — memakai kode yang ada"
  fi
elif [ -d "$GH_DIR" ]; then
  warn "$GH_DIR sudah ada tetapi bukan repo git — dipakai apa adanya"
else
  command -v git >/dev/null 2>&1 || die "git tidak ditemukan"
  git clone --depth 1 "$GH_REPO" "$GH_DIR" \
    || die "git clone gagal: $GH_REPO"
  ok "Repo di-clone ke $GH_DIR"
fi

[ -f "$GH_DIR/ghostintel.py" ] \
  || die "ghostintel.py tidak ditemukan di $GH_DIR — repo tidak valid?"

# ---------- 4/6 ----------
step "Menyiapkan virtualenv"
if [ -x "$VENV/bin/python" ]; then
  ok "Virtualenv sudah ada: $VENV"
else
  PYBOOT="$(command -v python3 || command -v python || true)"
  [ -n "$PYBOOT" ] || die "Python tidak ditemukan. Pasang: pkg install python"
  "$PYBOOT" -m venv "$VENV" || die "Gagal membuat virtualenv di $VENV"
  ok "Virtualenv dibuat: $VENV"
fi

"$VENV/bin/python" -m pip install --disable-pip-version-check \
  --quiet --upgrade pip setuptools wheel >/dev/null 2>&1 \
  || warn "Pembaruan pip dilewati (tidak fatal)"

# ---------- 5/6 ----------
step "Memasang dependensi Python"
PIPLOG="$(mktemp)"

if "$VENV/bin/python" -m pip install --disable-pip-version-check \
     "${CORE_PKGS[@]}" >"$PIPLOG" 2>&1; then
  ok "Semua paket inti terpasang"
else
  warn "Instalasi serentak gagal — mencoba satu per satu"
  failed=()
  for p in "${CORE_PKGS[@]}"; do
    if "$VENV/bin/python" -m pip install --disable-pip-version-check \
         "$p" >>"$PIPLOG" 2>&1; then
      ok "$p"
    else
      warn "gagal: $p"
      failed+=("$p")
    fi
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    warn "Paket gagal dipasang: ${failed[*]}"
    warn "Log pip: $PIPLOG (disalin ke /tmp/ghostintel-pip.log)"
    cp "$PIPLOG" /tmp/ghostintel-pip.log 2>/dev/null || true
  fi
fi

# aiodns opsional: bila pycares gagal dikompilasi, GhostIntel tetap bisa
# dijalankan setelah patch resolver (lihat patch-no-aiodns.sh).
if "$VENV/bin/python" -c 'import aiodns' >/dev/null 2>&1; then
  ok "aiodns tersedia (resolver DNS native)"
else
  warn "aiodns/pycares tidak tersedia."
  warn "GhostIntel akan gagal start sampai resolver dipatch:"
  warn "  bash \"$SCRIPT_DIR/patch-no-aiodns.sh\" \"$GH_DIR\""
fi

# lxml: TIDAK dipakai GhostIntel, murni opsional -> kegagalan tidak fatal.
if [ "$WITH_LXML" = "1" ]; then
  if "$VENV/bin/python" -c 'import lxml' >/dev/null 2>&1; then
    ok "lxml sudah terpasang (opsional)"
  elif "$VENV/bin/python" -m pip install --disable-pip-version-check \
         --no-cache-dir --quiet lxml >>"$PIPLOG" 2>&1; then
    ok "lxml terpasang (opsional)"
  else
    warn "lxml gagal dipasang — AMAN, GhostIntel tidak memakainya"
    warn "Coba manual: pkg install libxml2 libxslt && pip install lxml"
    warn "Atau lewati:  WITH_LXML=0 bash \"$0\""
  fi
else
  info "  lxml dilewati (WITH_LXML=0)"
fi

# ---------- 6/6 ----------
step "Verifikasi"
if ! imp_out=$("$VENV/bin/python" - <<'PY'
import importlib, sys

required = {
    "aiohttp": "aiohttp",
    "aiofiles": "aiofiles",
    "bs4": "beautifulsoup4",
    "rich": "rich",
    "dns": "dnspython",
    "phonenumbers": "phonenumbers",
    "jinja2": "jinja2",
    "flask": "flask",
    "flask_cors": "flask-cors",
}
missing = []
for module, package in required.items():
    try:
        importlib.import_module(module)
    except Exception:
        missing.append(package)
if missing:
    print("MISSING " + " ".join(missing))
    sys.exit(1)
print("OK")
PY
); then
  err "Dependensi inti tidak lengkap: $imp_out"
  err "Coba ulang, atau cek log: /tmp/ghostintel-pip.log"
  exit 1
fi
ok "Semua modul inti dapat diimpor"

cd "$GH_DIR"

# JANGAN pakai '| head -1' di sini: di bawah 'set -euo pipefail', bila Python
# menulis lebih dari satu baris, head menutup pipe lebih awal sehingga Python
# menerima SIGPIPE. pipefail membuat pipeline itu gagal dan 'set -e' langsung
# menghentikan skrip tanpa pesan. Tangkap output penuh, lalu ambil barisnya.
if ! version_out="$("$VENV/bin/python" ghostintel.py --version 2>&1)"; then
  err "ghostintel.py --version gagal dijalankan"
  err "Output: $version_out"
  exit 1
fi
# Output --version DIAWALI baris kosong, jadi 'baris pertama' sering kosong.
# Ambil baris pertama yang benar-benar berisi, tanpa pipe (hindari SIGPIPE).
version=""
while IFS= read -r line; do
  trimmed="${line//[[:space:]]/}"
  if [ -n "$trimmed" ]; then
    version="$line"
    break
  fi
done <<< "$version_out"

[ -n "$version" ] || die "ghostintel.py --version tidak menghasilkan output yang bisa dibaca"
ok "$version"

# ---------- ringkasan ----------
cat <<EOF

${C_OK}Instalasi selesai.${C_RST}

  Direktori : $GH_DIR
  Python    : $VENV/bin/python

Cara pakai (dari dalam Termux):

  cd "$GH_DIR"
  . .venv/bin/activate

  python ghostintel.py -u nama_user
  python ghostintel.py -e email@domain.com
  python ghostintel.py -p +628123456789
  python ghostintel.py -d example.com
  python ghostintel.py -i 8.8.8.8
  python ghostintel.py -d example.com --report --format all
  python ghostintel.py --batch targets.txt

Scan panjang (tahan background/layar kunci):

  bash "$SCRIPT_DIR/ghostintel-termux-wrapper.sh" -d example.com --report

Peringatan: 'python ghostintel.py -web' mengikat ke 0.0.0.0 tanpa
autentikasi. Di jaringan bersama, batasi ke loopback (lihat README).
EOF
