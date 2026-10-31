# GhostIntel di Termux (Android)

Panduan lengkap memasang dan menjalankan **GhostIntel v2.5.0** di Termux,
tanpa root, beserta skrip pendukung yang sudah diuji.

---

## Daftar isi

1. [Ringkasan](#1-ringkasan)
2. [Instalasi cepat](#2-instalasi-cepat)
3. [Instalasi manual](#3-instalasi-manual)
4. [Menjalankan scan](#4-menjalankan-scan)
5. [Akses dari perangkat lain](#5-akses-dari-perangkat-lain)
6. [Troubleshooting](#6-troubleshooting)
7. [Referensi teknis](#7-referensi-teknis)
8. [Status verifikasi](#8-status-verifikasi)

---

## 1. Ringkasan

GhostIntel adalah alat OSINT yang memeriksa username, email, nomor telepon,
domain, dan IP. Di Android ada tiga hambatan nyata:

| Hambatan | Penjelasan | Penanganan |
|---|---|---|
| Android membekukan Termux | Saat layar terkunci atau app di-background, proses dihentikan dan scan 100+ platform terputus | `ghostintel-termux-wrapper.sh` (tmux + wake-lock) |
| `pycares` sulit dikompilasi | `aiodns` bergantung pada `pycares` (ekstensi C); build clang sering gagal di Android | `patch-no-aiodns.sh` — tool jalan tanpa `aiodns` |
| Instalasi berat | Kompilasi C memakan waktu lama dan banyak gagal | Set dependensi dikecilkan ke 10 paket inti |

### Berkas dalam paket ini

| Berkas | Fungsi |
|---|---|
| `setup-ghostintel-termux.sh` | Installer otomatis, idempoten |
| `patch-no-aiodns.sh` | Membuat resolver DNS bekerja tanpa `aiodns` |
| `ghostintel-termux-wrapper.sh` | Menjalankan scan tahan background + arsip hasil |

---

## 2. Instalasi cepat

```bash
# 1. Ambil paket skrip (asumsikan repo sudah di-clone)
cd ~/GhostIntel

# 2. Jalankan installer
bash termux/setup-ghostintel-termux.sh

# 3. Bila aiodns gagal dikompilasi, patch resolver
bash termux/patch-no-aiodns.sh ~/GhostIntel
```

Selesai. Installer melakukan semuanya: paket sistem, clone, venv,
dependensi, dan verifikasi.

### Opsi installer

```bash
# Tanpa lxml (lebih cepat, tidak perlu libxml2/libxslt)
WITH_LXML=0 bash termux/setup-ghostintel-termux.sh

# Repo lain / fork
GH_REPO=https://github.com/owner/fork.git bash termux/setup-ghostintel-termux.sh

# Lokasi lain
GHOSTINTEL_DIR=~/tools/GhostIntel bash termux/setup-ghostintel-termux.sh

# Tanpa warna (untuk log)
NO_COLOR=1 bash termux/setup-ghostintel-termux.sh
```

---

## 3. Instalasi manual

Gunakan bagian ini bila installer gagal atau Anda ingin kendali penuh.

### 3.1 Pasang Termux dari sumber resmi

**Jangan** dari Google Play — versi itu sudah ditinggalkan dan banyak paket
gagal dipasang. Gunakan salah satu:

- F-Droid: <https://f-droid.org/packages/com.termux/>
- GitHub: <https://github.com/termux/termux-app/releases>

### 3.2 Paket sistem

```bash
pkg update -y && pkg upgrade -y
pkg install -y python git clang make binutils pkg-config \
               libffi openssl libxml2 libxslt nano tmux termux-api
```

> Termux **tidak memiliki** paket `python-dev`. Header pengembangan sudah
> termasuk di paket `python`. Panduan yang menyuruh `pkg install python-dev`
> akan gagal dengan `has no installation candidate`.

### 3.3 Source dan virtualenv

```bash
cd ~
git clone --depth 1 https://github.com/winrx20/GhostIntel.git
cd GhostIntel

python -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
```

Virtualenv **wajib**: Termux memblokir `pip install` ke Python sistem
(PEP 668 — `externally-managed-environment`).

### 3.4 Dependensi Python

Set minimal yang terbukti cukup untuk kelima modul dan keempat format report:

```bash
pip install aiohttp aiodns aiofiles beautifulsoup4 rich \
            dnspython phonenumbers jinja2 flask flask-cors
```

Opsional, tidak dipakai GhostIntel tetapi berguna untuk skrip sendiri:

```bash
pip install lxml        # butuh libxml2 + libxslt, kompilasi lama
```

> **Paket yang sengaja dilewati:** `tldextract`, `colorama`, `fake-useragent`,
> `python-whois`. Keempatnya ada di `requirements.txt` upstream tetapi
> **tidak diimpor oleh satu file pun** di kode GhostIntel, sehingga hanya
> menambah waktu instalasi dan risiko gagal build.

### 3.5 Bila `pycares` gagal dikompilasi

Ini kejadian umum di Android. Dua pilihan:

**A. Coba header tambahan**

```bash
pkg install -y libcares
export CFLAGS="-Wno-error=implicit-function-declaration"
pip install --no-cache-dir pycares aiodns
```

**B. Pakai patch (teruji)**

```bash
bash termux/patch-no-aiodns.sh ~/GhostIntel
```

Patch mengubah `core/engine.py` agar memakai `AsyncResolver` bila `aiodns`
tersedia, dan jatuh ke resolver bawaan `aiohttp` bila tidak.

---

## 4. Menjalankan scan

### 4.1 Modul dasar

```bash
cd ~/GhostIntel && . .venv/bin/activate

python ghostintel.py -u nama_user          # username, 120+ platform
python ghostintel.py -e email@domain.com   # email + MX/SPF/DMARC
python ghostintel.py -p +628123456789      # telepon, 8 negara
python ghostintel.py -d example.com        # domain: DNS/HTTP/TLS/tech
python ghostintel.py -i 8.8.8.8            # IP: geo, ASN, RDAP, risk score
python ghostintel.py example.com           # auto-deteksi tipe target
```

### 4.2 Report

```bash
python ghostintel.py -d example.com --report                  # JSON
python ghostintel.py -d example.com --report --format html
python ghostintel.py -d example.com --report --format md
python ghostintel.py -d example.com --report --format all     # 4 format
python ghostintel.py -d example.com --report --format json --compress
python ghostintel.py -d example.com --report --output-dir ~/hasil
```

Default tersimpan di `./output/ghostintel_<timestamp>.<ext>`.

### 4.3 Batch

```bash
python ghostintel.py --batch targets.txt --report --format all
python ghostintel.py --batch targets.txt --batch-delay 2 --threads 10
```

Format `targets.txt` — satu target per baris, `#` untuk komentar. Tipe target
dideteksi otomatis, jadi domain dan IP boleh dicampur:

```
# klien A
example.com
8.8.8.8
nama_user
```

### 4.4 Flag lain

| Flag | Fungsi | Default |
|---|---|---|
| `--timeout N` | timeout request (detik) | 12 |
| `--threads N` | konkurensi | 25 |
| `--deep` | fan-out multi-modul + korelasi | mati |
| `--no-color` | tanpa warna | mati |
| `--quiet` | senyap, hanya simpan report | mati |
| `--debug` | traceback lengkap | mati |
| `-v`, `--version` | versi | — |
| `-h`, `--help` | bantuan | — |

### 4.5 Scan panjang — pakai wrapper

Android membekukan Termux saat layar terkunci. Untuk scan yang berjalan lebih
dari beberapa detik, gunakan wrapper:

```bash
bash termux/ghostintel-termux-wrapper.sh -d example.com --report --format json
```

Yang dilakukan wrapper:

1. Menjalankan scan di dalam sesi **tmux** (tetap hidup saat app di-background).
2. Mengaktifkan **`termux-wake-lock`** agar CPU tidak tidur.
3. Mencatat seluruh output ke `output.log`.
4. Mengarsipkan hasil ke `~/ghostintel-logs/run_<timestamp>/`.
5. **Meneruskan kode keluar GhostIntel** apa adanya.

Setiap run mendapat direktori dan sesi tmux yang unik, sehingga beberapa run
paralel tidak saling menimpa. Bila `--output-dir` tidak diberikan, wrapper
menyuntikkan direktori privat per-run agar report tidak tercampur.

Variabel lingkungan:

| Variabel | Default |
|---|---|
| `GHOSTINTEL_DIR` | `$HOME/GhostIntel` |
| `GHOSTINTEL_SESSION` | `ghostintel` |
| `GHOSTINTEL_LOGDIR` | `$HOME/ghostintel-logs` |

Kode keluar: `0` sukses, `>0` kode dari GhostIntel, `127` prasyarat gagal.

### 4.6 Peringatan keamanan Web UI

```bash
python ghostintel.py -web --no-browser
```

Web UI mengikat ke **`0.0.0.0`** (`web/server.py:655`) **tanpa autentikasi**,
sehingga dapat diakses semua perangkat di Wi-Fi yang sama. Untuk pemakaian
lokal, batasi ke loopback:

```bash
python -c "
import sys; sys.path.insert(0, '.')
from web.server import app
app.run(host='127.0.0.1', port=7331, debug=False, threaded=True)
"
```

---

## 5. Akses dari perangkat lain

### 5.1 SSH via Wi-Fi lokal

**Di Termux:**

```bash
pkg install -y openssh
passwd              # set password (boleh dikosongkan bila pakai key)
whoami              # catat, mis. u0_a123
sshd
ifconfig | grep -A1 wlan0   # catat IP, mis. 192.168.1.50
```

**Dari komputer (jaringan sama):**

```bash
ssh -p 8022 u0_a123@192.168.1.50
```

> Port SSH Termux adalah **8022**, bukan 22. Ini penyebab kegagalan
> `Connection refused` yang paling sering.

**Login dengan key (disarankan):**

```bash
ssh-keygen -t ed25519 -C "laptop"
ssh-copy-id -p 8022 u0_a123@192.168.1.50
```

### 5.2 Akses dari mana saja — Tailscale

IP Wi-Fi berubah dan jaringan seluler berada di belakang NAT, jadi Tailscale
lebih andal daripada port forwarding.

```bash
# 1. Pasang Tailscale di HP dan di komputer, login akun yang sama
# 2. Di Termux, catat IP Tailscale:
tailscale ip -4        # mis. 100.101.102.103

# 3. Dari komputer:
ssh -p 8022 u0_a123@100.101.102.103
```

Ringkas dengan `~/.ssh/config` di komputer:

```
Host hp
    HostName 100.101.102.103
    Port 8022
    User u0_a123
    ServerAliveInterval 30
```

Cukup `ssh hp`.

### 5.3 Tanpa SSH — ttyd

```bash
pkg install -y ttyd
ttyd -p 7681 -W bash
```

Buka `http://<IP-HP>:7681`. Flag `-W` mengaktifkan input.

### 5.4 sshd otomatis saat Termux dibuka

Tambahkan ke `~/.bashrc`:

```bash
pgrep sshd >/dev/null || sshd
```

Atau pakai Termux:Boot (F-Droid) dengan `~/.termux/boot/ssh.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
sshd
```

`termux-wake-lock` mencegah Android menghentikan sshd saat layar mati.

---

## 6. Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `Connection refused` (SSH) | sshd belum jalan / port salah | `sshd`; gunakan `-p 8022` |
| `Permission denied (publickey)` | Key belum terpasang | Ulangi `ssh-copy-id`; cek `~/.ssh/authorized_keys` |
| SSH putus sendiri | Android membekukan Termux | `termux-wake-lock`; matikan optimasi baterai untuk Termux |
| `externally-managed-environment` | Lupa venv | `. .venv/bin/activate` |
| `Resolver requires aiodns library` | `aiodns` tidak ada | `bash patch-no-aiodns.sh ~/GhostIntel` |
| `aarch64-linux-android-clang failed` | Header/alat build kurang | `pkg install clang make binutils pkg-config libffi openssl` |
| `lxml` gagal build | Butuh libxml2/libxslt | `pkg install libxml2 libxslt`, atau `WITH_LXML=0` |
| Scan terputus saat layar mati | Termux dibekukan | Pakai `ghostintel-termux-wrapper.sh` |
| `has no installation candidate` | Paket tidak ada di Termux | Jangan pakai `python-dev`; header ada di paket `python` |
| `pkg update` gagal | Mirror rusak | `termux-change-repo` |

---

## 7. Referensi teknis

### 7.1 Mengapa patch resolver diperlukan

`core/engine.py` membuat `aiohttp.resolver.AsyncResolver`, yang mewajibkan
`aiodns` → mewajibkan `pycares` (ekstensi C). Tanpa `aiodns`:

```
❌ Fatal: Resolver requires aiodns library
```

Setelah patch:

```python
connector_kwargs = dict(ttl_dns_cache=300)
try:
    import aiodns  # noqa: F401
    resolver = aiohttp.resolver.AsyncResolver(
        nameservers=['8.8.8.8', '1.1.1.1', '8.8.4.4']
    )
    connector_kwargs["resolver"] = resolver
except Exception:
    pass
```

Jaminan patch:

- **Idempoten** — run kedua tidak mengubah apa pun dan tidak menambah backup.
- **Atomik** — tulis ke file sementara lalu `os.replace`; tidak pernah
  meninggalkan `engine.py` setengah jadi.
- **Backup sekali** — dibuat hanya setelah blok kode tervalidasi, sehingga
  kegagalan tidak meninggalkan `.bak` yatim.
- **Aman bila versi berbeda** — keluar dengan kode `2` tanpa mengubah file.

Kode keluar patch: `0` sukses/sudah dipatch, `1` error, `2` kode tidak cocok.

### 7.2 Mengapa lxml opsional

`lxml` ada di `requirements.txt` upstream tetapi **tidak diimpor GhostIntel**.
Installer memasangnya sebagai best-effort: bila kompilasi gagal, instalasi
inti tetap berhasil. Matikan dengan `WITH_LXML=0`.

### 7.3 Catatan `pipefail` dan SIGPIPE

Di bawah `set -euo pipefail`, pola seperti `cmd | head -1` dapat
menghentikan skrip: `head` menutup pipe lebih awal, `cmd` menerima `SIGPIPE`,
dan `pipefail` membuat pipeline gagal. Skrip di paket ini menghindari pola
tersebut.

---

## 8. Status verifikasi

Tiga suite uji, **74 pemeriksaan, semuanya lulus** (dijalankan pada Linux
x86_64 dengan Python 3.12; bukan perangkat Android).

| Suite | Cakupan | Hasil |
|---|---|---|
| `test_wrapper.sh` | 19 | 19 PASS |
| `test_patch.sh` | 30 | 30 PASS |
| `test_setup.sh` | 25 | 25 PASS |

Kualitas kode: ketiga skrip **`bash -n` bersih** dan **ShellCheck 0.11.0
CLEAN** (severity `style`).

Yang diuji mencakup: idempotensi, kegagalan pip, kode tidak cocok, path
berisi spasi dan tanda kutip, argumen metakarakter (uji injeksi), exit code
propagasi, run paralel, `WITH_LXML=0`, `NO_COLOR`, dan kondisi repo asli
tetap tidak tersentuh.

**Yang belum diverifikasi:** eksekusi pada perangkat Android/Termux asli —
`pkg`, kompilasi `pycares` dengan clang Android, `termux-wake-lock`, dan
`tmux attach` interaktif. Sandbox uji adalah x86_64, sehingga kegagalan build
clang Android tidak dapat direproduksi di sana. Jalur patch disediakan justru
untuk keadaan tersebut dan telah diuji pada kondisi `aiodns` absen.
