#!/usr/bin/env bash
# ============================================================
#  GhostIntel — patch resolver tanpa aiodns (khusus Termux/Android)
#
#  Masalah:
#    core/engine.py memakai aiohttp.resolver.AsyncResolver, yang
#    mewajibkan paket aiodns -> mewajibkan pycares (ekstensi C).
#    pycares sering gagal dikompilasi di Android/clang Termux.
#
#  Solusi:
#    Pakai AsyncResolver bila tersedia; jika tidak, jatuh ke resolver
#    bawaan aiohttp. Perubahan dibatasi pada blok connector.
#
#  Jaminan:
#    - Idempoten: run kedua tidak mengubah apa pun, tidak menumpuk backup.
#    - Atomik: menulis ke file sementara lalu rename (tidak pernah
#      meninggalkan engine.py setengah jadi bila gagal di tengah).
#    - Backup sekali saja, dengan timestamp.
#    - Kode keluar: 0 = sudah/sukses, 1 = error, 2 = kode tidak cocok.
#
#  Pemakaian:
#    bash patch-no-aiodns.sh              # default: $HOME/GhostIntel
#    bash patch-no-aiodns.sh /path/ke/repo
# ============================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly DIR="${1:-${GHOSTINTEL_DIR:-$HOME/GhostIntel}}"
readonly F="$DIR/core/engine.py"

# ---------- keluaran ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  readonly C_RST=$'\033[0m' C_INF=$'\033[1;36m' C_OK=$'\033[1;32m'
  readonly C_WRN=$'\033[1;33m' C_ERR=$'\033[1;31m'
else
  readonly C_RST='' C_INF='' C_OK='' C_WRN='' C_ERR=''
fi

ok()   { printf '%s  ✓%s %s\n' "$C_OK" "$C_RST" "$*"; }
info() { printf '%s==>%s %s\n' "$C_INF" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WRN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }

# ---------- validasi ----------
info "GhostIntel no-aiodns patch v$SCRIPT_VERSION"

[ -d "$DIR" ] || { err "Direktori tidak ditemukan: $DIR"; exit 1; }
[ -f "$F" ]   || { err "File tidak ditemukan: $F"; exit 1; }

# Interpreter: utamakan venv repo, lalu python3, lalu python.
PY=""
for c in "$DIR/.venv/bin/python" python3 python; do
  if [ -x "$c" ]; then PY="$c"; break; fi
  if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
done
[ -n "$PY" ] || { err "Tidak ada interpreter Python yang bisa dipakai"; exit 1; }
ok "Python: $PY"

# ---------- deteksi sudah-dipatch ----------
if grep -q 'connector_kwargs' "$F"; then
  ok "Sudah dipatch sebelumnya. Tidak ada perubahan."
  exit 0
fi

# ---------- terapkan patch (atomik) ----------
# Path file diteruskan sebagai argv, BUKAN diinterpolasi ke dalam kode.
backup="$F.bak.$(date +%Y%m%d%H%M%S)"
# Backup TIDAK dibuat di sini: bila blok kode tidak cocok, kita berhenti tanpa
# meninggalkan file .bak yatim. Pembuatan backup dilakukan oleh blok Python
# di bawah, setelah validasi lolos dan tepat sebelum penulisan.

set +e
"$PY" - "$F" "$backup" <<'PYEOF'
import os
import shutil
import sys

path = sys.argv[1]
backup = sys.argv[2]
with open(path, encoding="utf-8") as fh:
    src = fh.read()

old_resolver = """        resolver = aiohttp.resolver.AsyncResolver(
            nameservers=['8.8.8.8', '1.1.1.1', '8.8.4.4']
        )
"""

new_resolver = '''        # Termux/Android: pycares (dependency aiodns) sering gagal build.
        # Pakai AsyncResolver bila tersedia; jika tidak, pakai resolver
        # bawaan aiohttp agar tool tetap berjalan.
        connector_kwargs = dict(ttl_dns_cache=300)
        try:
            import aiodns  # noqa: F401
            resolver = aiohttp.resolver.AsyncResolver(
                nameservers=['8.8.8.8', '1.1.1.1', '8.8.4.4']
            )
            connector_kwargs["resolver"] = resolver
        except Exception:
            pass
'''

if old_resolver not in src:
    print("NOMATCH resolver block")
    sys.exit(2)

src = src.replace(old_resolver, new_resolver, 1)

old_conn = """            resolver=resolver,  # <-- Ini kuncinya
            ttl_dns_cache=300
"""
new_conn = """            **connector_kwargs
"""

if old_conn in src:
    src = src.replace(old_conn, new_conn, 1)
else:
    print("NOMATCH connector block")
    sys.exit(2)

# Validasi lolos. Baru sekarang buat backup, lalu tulis secara atomik.
shutil.copy2(path, backup)

tmp = path + ".tmp.patch"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(src)
os.replace(tmp, path)
print("PATCHED")
PYEOF
patch_rc=$?
set -e

case "$patch_rc" in
  0) ok "Patch diterapkan" ;;
  2)
    err "Blok kode tidak cocok — versi GhostIntel berbeda. TIDAK ada yang diubah."
    err "Patch ini ditulis untuk v2.5.0. Periksa manual: $F"
    exit 2
    ;;
  *)
    err "Patch gagal (kode $patch_rc). TIDAK ada yang diubah."
    rm -f "$F.tmp.patch"
    exit 1
    ;;
esac

# ---------- verifikasi ----------
# Verifikasi sintaks memakai ast.parse, bukan py_compile. Keduanya tidak
# menulis file .pyc, tetapi ast.parse lebih ringan dan tidak memerlukan
# penulisan cache sama sekali.
# Catatan: core/__pycache__ tetap bisa muncul karena langkah berikutnya
# menjalankan ghostintel.py (perilaku normal Python), bukan karena skrip ini.
if "$PY" - "$F" <<'PYEOF'
import ast, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    ast.parse(fh.read(), filename=sys.argv[1])
PYEOF
then
  ok "Sintaks valid (AST parse)"
else
  err "Sintaks rusak setelah patch — memulihkan backup"
  if [ -f "$backup" ]; then
    mv -f "$backup" "$F"
    ok "Dikembalikan ke kondisi semula"
  else
    err "Backup tidak ditemukan: $backup"
  fi
  exit 1
fi

# ---------- uji jalan ----------
if ( cd "$DIR" && "$PY" ghostintel.py --version >/dev/null 2>&1 ); then
  ok "Tool berjalan (--version)"
else
  warn "--version gagal. Cek manual:"
  warn "  cd \"$DIR\" && \"$PY\" ghostintel.py -d example.com"
fi

echo
ok "Selesai. Backup: $backup"
