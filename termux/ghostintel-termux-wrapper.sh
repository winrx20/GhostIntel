#!/usr/bin/env bash
# shellcheck disable=SC2016
#   SC2016 di file ini adalah FALSE POSITIVE: blok yang membangun runner
#   sengaja memakai single-quote agar '$rc' dan '${PIPESTATUS[0]}' tidak
#   diekspansi sekarang, melainkan ditulis apa adanya ke skrip hasil-generate.
# ============================================================
#  GhostIntel — wrapper Termux (tmux + wake-lock + arsip hasil)
#
#  Kenapa perlu:
#    Android membekukan Termux saat aplikasi di-background atau layar
#    terkunci. Scan 120+ platform bisa >1 menit dan akan terputus.
#    Wrapper ini menjalankan scan di dalam tmux + wake-lock agar tetap
#    hidup, mencatat log, dan mengarsipkan HANYA hasil run ini.
#
#  Pemakaian:
#    bash ghostintel-termux-wrapper.sh -d example.com --report --format json
#    bash ghostintel-termux-wrapper.sh -u nama_user
#
#  Variabel lingkungan:
#    GHOSTINTEL_DIR      direktori repo    (default: $HOME/GhostIntel)
#    GHOSTINTEL_SESSION  prefiks sesi tmux (default: ghostintel)
#    GHOSTINTEL_LOGDIR   direktori arsip    (default: $HOME/ghostintel-logs)
#
#  Kode keluar:
#    0       scan sukses
#    lainnya kode keluar GhostIntel diteruskan apa adanya
#    127     prasyarat tidak terpenuhi
# ============================================================
set -euo pipefail

readonly DIR="${GHOSTINTEL_DIR:-$HOME/GhostIntel}"
readonly SESS_PREFIX="${GHOSTINTEL_SESSION:-ghostintel}"
readonly LOG_DIR="${GHOSTINTEL_LOGDIR:-$HOME/ghostintel-logs}"

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

usage() {
  cat <<EOF
ghostintel-termux-wrapper 1.2.0

Pemakaian: bash $(basename -- "$0") [opsi GhostIntel...]

Contoh:
  bash $(basename -- "$0") -d example.com --report --format json
  bash $(basename -- "$0") -u nama_user

Variabel: GHOSTINTEL_DIR, GHOSTINTEL_SESSION, GHOSTINTEL_LOGDIR
EOF
}

# ---------- validasi ----------
if [ "$#" -eq 0 ]; then usage; exit 127; fi
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

[ -d "$DIR" ]             || { err "Repo tidak ada di: $DIR"; err "Jalankan setup-ghostintel-termux.sh dulu, atau set GHOSTINTEL_DIR."; exit 127; }
[ -f "$DIR/ghostintel.py" ] || { err "ghostintel.py tidak ada di $DIR"; exit 127; }

PY="$DIR/.venv/bin/python"
if [ ! -x "$PY" ]; then
  PY="$(command -v python3 || command -v python || true)"
  [ -n "$PY" ] || { err "Python tidak ditemukan"; exit 127; }
  warn "venv repo tidak ada — memakai Python sistem: $PY"
fi

mkdir -p "$LOG_DIR"

# Direktori arsip harus UNIK. Dua run yang mulai pada detik yang sama akan
# mendapat timestamp identik, sehingga tanpa pembeda keduanya akan menulis ke
# direktori yang sama dan saling menimpa. mkdir bersifat atomik: bila sudah
# ada, tambah sufiks sampai berhasil.
TS="$(date +%Y%m%d_%H%M%S)"
readonly TS
OUT=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$i" -eq 1 ]; then
    candidate="$LOG_DIR/run_$TS"
  else
    candidate="$LOG_DIR/run_${TS}_$i"
  fi
  if mkdir "$candidate" 2>/dev/null; then
    OUT="$candidate"
    break
  fi
done
[ -n "$OUT" ] || { err "Tidak bisa membuat direktori arsip di $LOG_DIR"; exit 127; }
readonly OUT

# ---------- tentukan direktori output ----------
# Bila pengguna TIDAK memberi --output-dir, GhostIntel menulis ke $DIR/output
# yang dipakai bersama. Dua run bersamaan lalu akan saling melihat report
# satu sama lain dan mengarsipkannya (kontaminasi silang). Karena itu tiap
# run diberi direktori output privat di dalam arsipnya sendiri.
has_outdir=0
for a in "$@"; do
  case "$a" in
    --output-dir|--output-dir=*) has_outdir=1 ;;
  esac
done

ARGS=("$@")
if [ "$has_outdir" -eq 0 ]; then
  ARGS+=(--output-dir "$OUT")
fi

# ---------- snapshot hasil SEBELUM run ----------
# GhostIntel menulis ke output/ (dan kadang reports/). Snapshot agar
# pengarsipan hanya menyalin file yang BARU muncul, bukan report lama.
snapshot() {
  find "$DIR/output" "$DIR/reports" -maxdepth 1 -type f -name 'ghostintel_*' 2>/dev/null | sort
}

BEFORE="$(mktemp)"
AFTER="$(mktemp)"
RUNNER="$(mktemp)"
trap 'rm -f "$BEFORE" "$AFTER" "$RUNNER"' EXIT

snapshot > "$BEFORE"

wake_lock()   { command -v termux-wake-lock   >/dev/null 2>&1 && { termux-wake-lock   || true; } || true; }
wake_unlock() { command -v termux-wake-unlock >/dev/null 2>&1 && { termux-wake-unlock || true; } || true; }

# ---------- bangun runner ----------
# printf %q meng-quote tiap argumen, jadi argumen dengan spasi, kutip, atau
# metakarakter tidak dipecah maupun dieksekusi sebagai perintah.
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -o pipefail\n'
  printf 'cd %q || exit 127\n' "$DIR"
  printf 'termux-wake-lock 2>/dev/null || true\n'
  printf '%q ' "$PY" ghostintel.py
  for a in "${ARGS[@]}"; do printf '%q ' "$a"; done
  printf '2>&1 | tee %q\n' "$OUT/output.log"
  printf 'rc="${PIPESTATUS[0]}"\n'
  printf 'termux-wake-unlock 2>/dev/null || true\n'
  printf 'printf "%%s" "$rc" > %q\n' "$OUT/.exitcode"
  printf 'exit "$rc"\n'
} > "$RUNNER"
chmod 700 "$RUNNER"

run_rc=0

if command -v tmux >/dev/null 2>&1; then
  # Nama sesi HARUS diturunkan dari $OUT yang sudah unik, bukan dari $TS.
  # Dua run pada detik yang sama akan mendapat $TS identik; bila nama sesi
  # hanya memakai $TS, run kedua akan menabrak sesi pertama
  # ("duplicate session") atau bahkan membunuhnya.
  RUN_SESS="${SESS_PREFIX}_$(basename -- "$OUT")"
  readonly RUN_SESS
  info "Menjalankan di tmux (sesi: $RUN_SESS)"

  # Tidak ada kill-session di sini: nama sudah unik per run, sehingga
  # membunuh sesi tidak pernah diperlukan dan justru berbahaya bila ada
  # run lain yang kebetulan memakai nama sama.
  if tmux has-session -t "$RUN_SESS" 2>/dev/null; then
    err "Sesi tmux '$RUN_SESS' sudah ada — tidak menimpanya."
    exit 127
  fi
  tmux new-session -d -s "$RUN_SESS" "bash $(printf %q "$RUNNER")"

  if [ -t 0 ] && [ -t 1 ]; then
    tmux attach -t "$RUN_SESS" || true
  else
    info "Tanpa TTY — menunggu sesi selesai..."
    while tmux has-session -t "$RUN_SESS" 2>/dev/null; do sleep 1; done
  fi

  if [ -s "$OUT/.exitcode" ]; then
    run_rc="$(cat "$OUT/.exitcode")"
  else
    warn "File exit-code tidak terbentuk — sesi tmux mungkin terbunuh."
    run_rc=1
  fi
else
  warn "tmux tidak ada — menjalankan langsung (scan panjang bisa terputus saat layar kunci)."
  warn "Disarankan: pkg install tmux termux-api"

  wake_lock
  set +e
  bash "$RUNNER"
  run_rc=$?
  set -e
  wake_unlock
fi

# ---------- arsipkan hasil baru ----------
snapshot > "$AFTER"
copied=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if cp -- "$f" "$OUT/" 2>/dev/null; then
    copied=$((copied + 1))
  else
    warn "gagal menyalin: $f"
  fi
done < <(comm -13 "$BEFORE" "$AFTER")

rm -f "$OUT/.exitcode"

# ---------- ringkasan ----------
echo
if [ "$run_rc" -eq 0 ]; then
  ok "Selesai (exit 0). Arsip: $OUT"
else
  err "GhostIntel keluar dengan kode $run_rc. Lihat log: $OUT/output.log"
fi

# Hitung report yang benar-benar ada di arsip. Dengan output-dir privat,
# file sudah langsung berada di $OUT sehingga tidak perlu disalin.
nrep=$(find "$OUT" -maxdepth 1 -type f -name 'ghostintel_*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$nrep" -gt 0 ]; then
  info "Report diarsipkan: $nrep"
elif [ "$copied" -gt 0 ]; then
  info "Report diarsipkan (disalin): $copied"
else
  warn "Tidak ada report (tambahkan --report untuk menghasilkan report)."
fi
ls -1 "$OUT" 2>/dev/null || true

exit "$run_rc"
