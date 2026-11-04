# hris-hotel-bootstrap

Bootstrap installer **publik** untuk repositori aplikasi **privat**
[`it-avp-bali/hris-hotel`](https://github.com/it-avp-bali/hris-hotel).

Server Linux baru tidak dapat meng-clone repositori privat sebelum punya
kredensial. Repositori ini hanya berisi skrip kecil, sehingga server dapat
mengunduhnya lewat HTTPS, membuat **SSH deploy key read-only**, lalu meng-clone
repositori privat. Tidak ada token GitHub yang disimpan di server.

```
Server  --curl-->  repo publik ini (hanya skrip)
   |
   |  buat deploy key, tunggu ditambahkan di GitHub
   v
GitHub  --clone (deploy key read-only)-->  repo aplikasi privat
   |
   v
install.sh  (Nginx, MariaDB, PHP, .env, build aset, wizard web)
```

## Yang dilakukan skrip

1. Memasang `git` dan `openssh-client` bila belum ada.
2. Membuat `~/.ssh/hris_deploy` (Ed25519, tanpa passphrase).
3. Menampilkan public key dan menunggu sampai Anda menambahkannya di GitHub.
4. Menyimpan host key `github.com` dan menambahkan alias SSH `github-hris`.
5. Menguji kunci dengan `ssh -T git@github-hris`.
6. Meng-clone branch `uiux/phase-1.1` ke `/opt/hris-hotel` (root) atau
   `~/hris-hotel` (pengguna biasa).
7. Menjalankan `install.sh` dari repositori aplikasi, kecuali `--clone-only`.

`install.sh` di repositori aplikasi menangani Nginx, MariaDB, PHP 8.2+,
Composer, Node.js, `.env`, migrasi, seeding referensi, build aset, queue
worker, dan cron scheduler.

## Persyaratan

- Ubuntu 22.04+ / Debian 12+ (root atau pengguna dengan `sudo`).
- Akses keluar HTTPS dan SSH (port 22) ke GitHub.
- Akses **Settings → Deploy keys** pada repositori privat.
- `curl`, `tar`, dan `sha256sum` (tersedia standar di kedua distro).

## Mulai cepat

```bash
curl -fsSL -o /tmp/deploy-server.sh \
  https://raw.githubusercontent.com/it-avp-bali/hris-hotel-bootstrap/main/deploy-server.sh

curl -fsSL -o /tmp/deploy-server.sh.sha256 \
  https://raw.githubusercontent.com/it-avp-bali/hris-hotel-bootstrap/main/deploy-server.sh.sha256

cd /tmp && sha256sum -c deploy-server.sh.sha256

sudo bash /tmp/deploy-server.sh
```

Jangan memakai `curl ... | sudo bash`: unduh dulu, verifikasi checksum, baru
jalankan.

Tanpa interaksi (nilai lain menyusul dari `install.sh`):

```bash
sudo env DOMAIN=hris.example.com \
  DB_DATABASE=hotel_hris \
  DB_USERNAME=hotel_hris \
  DB_PASSWORD='GantiPasswordKuat123' \
  bash /tmp/deploy-server.sh
```

Nilai `DOMAIN`, `APP_URL`, `DB_*`, `SETUP_TOKEN`, `NODE_MAJOR`, dan `APP_USER`
diteruskan ke `install.sh`.

### Versi yang dipatok (disarankan)

Patok commit agar push berikutnya tidak mengubah skrip yang dijalankan server:

```bash
BOOTSTRAP_SHA=<sha-commit-40-karakter>
BASE="https://raw.githubusercontent.com/it-avp-bali/hris-hotel-bootstrap/${BOOTSTRAP_SHA}"

curl -fsSL -o /tmp/deploy-server.sh "${BASE}/deploy-server.sh"
curl -fsSL -o /tmp/deploy-server.sh.sha256 "${BASE}/deploy-server.sh.sha256"
cd /tmp && sha256sum -c deploy-server.sh.sha256

sudo bash /tmp/deploy-server.sh
```

Ambil SHA terbaru:

```bash
git ls-remote https://github.com/it-avp-bali/hris-hotel-bootstrap.git refs/heads/main
```

## Menambahkan deploy key

Saat skrip berhenti, salin baris `ssh-ed25519 ...` yang dicetak, lalu buka:

**Repositori privat → Settings → Deploy keys → Add deploy key**

- Title: `hris-server` (atau nama host server)
- Key: tempel public key
- **Allow write access: OFF**
- Klik **Add key**

Kembali ke server dan tekan **Enter**.

Kunci yang sama dapat dipakai ulang saat instalasi di server lain? Tidak —
buat kunci baru per server agar dapat dicabut sendiri-sendiri.

## Setelah instalasi

Skrip menampilkan alamat aplikasi. Buka:

```
http://<IP-server-atau-domain>
```

Anda akan diarahkan ke wizard setup sekali pakai:

1. masukkan **Kode Setup** yang dicetak `install.sh` (nilai `SETUP_TOKEN` di `.env`);
2. isi nama, email, dan kata sandi Super Admin;
3. klik **Buat Super Admin & Selesai**.

Wizard langsung terkunci dan tidak dapat diputar ulang. Setelah aplikasi
berjalan, pasang HTTPS:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d hris.example.com
sudo sed -i 's#^APP_URL=.*#APP_URL=https://hris.example.com#' .env
sudo sed -i 's#^SESSION_SECURE_COOKIE=.*#SESSION_SECURE_COOKIE=true#' .env
sudo php artisan config:cache
```

## Update berikutnya

Simpan skrip installer di lokasi tetap agar tidak hilang saat `/tmp` dibersihkan:

```bash
sudo install -m 755 /tmp/deploy-server.sh /usr/local/sbin/hris-bootstrap
```

Lalu untuk setiap update:

```bash
sudo /usr/local/sbin/hris-bootstrap --update
```

Perintah ini memastikan working tree bersih, membuat backup database
(`php artisan app:backup`), menarik commit terbaru, lalu mengulang `install.sh`.
`install.sh` bersifat idempoten: tidak pernah menjalankan `migrate:fresh`,
mempertahankan `APP_KEY`, dan hanya menambah migrasi baru.

Gunakan `--skip-backup` hanya bila backup terbaru sudah dipastikan ada.

## Opsi

| Opsi | Fungsi |
| --- | --- |
| `--repo-dir=DIR` | Direktori clone/instalasi |
| `--repo-url=URL` | Ganti remote repositori privat |
| `--branch=NAME` | Branch yang dipasang (default `uiux/phase-1.1`) |
| `--key=PATH` | Lokasi deploy key (default `~/.ssh/hris_deploy`) |
| `--ssh-alias=NAME` | Alias SSH (default `github-hris`) |
| `--update` | Wajib sudah ada clone; backup, tarik update, jalankan `install.sh` |
| `--skip-backup` | Lewati backup database sebelum update |
| `--clone-only` | Hanya clone; jangan jalankan `install.sh` |
| `--print-key` | Cetak public key lalu keluar |
| `--keep-remote` | Jangan ubah `origin` yang sudah ada |
| `--yes`, `-y` | Lewati konfirmasi deploy key |

## Model keamanan

- Repositori ini publik dan **tidak berisi rahasia**, hanya installer.
- Private key dibuat di server dan tidak pernah keluar dari server (mode `600`).
- Deploy key **read-only** dan hanya berlaku untuk satu repositori aplikasi.
- Skrip diunduh lewat HTTPS dan diverifikasi dengan SHA-256 sebelum dijalankan.
- Host key diambil dengan `ssh-keyscan`; cocokkan fingerprint-nya dengan
  [fingerprint resmi GitHub](https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
- Aktifkan 2FA pada akun pemilik repositori ini: siapa pun yang dapat push ke
  sini dapat menjalankan kode sebagai root di server yang memasangnya.
- Untuk mencabut akses: hapus deploy key di GitHub, hapus
  `~/.ssh/hris_deploy*` di server, lalu ulangi instalasi.

## Menjaga skrip tetap sinkron

`deploy-server.sh` adalah skrip mandiri di repositori ini; `install.sh` tetap
berada di repositori aplikasi. Setelah mengubah `install.sh`:

```bash
cd /opt/hris-hotel
sudo bash deploy-server.sh --update
```

Tidak ada salinan `install.sh` di repo ini, sehingga tidak ada dua versi yang
bisa berbeda.

Setiap kali `deploy-server.sh` di repo ini diubah, perbarui checksum pada commit
yang sama:

```bash
sha256sum deploy-server.sh > deploy-server.sh.sha256
git add deploy-server.sh deploy-server.sh.sha256
git commit -m "perbarui installer"
```

## Pemecahan masalah

| Gejala | Pemeriksaan |
| --- | --- |
| `sha256sum: no such file` | Unduh kedua file ke direktori yang sama |
| `checksum mismatch` | Unduh ulang; jangan mengedit skrip |
| `Permission denied (publickey)` | Deploy key belum ditambahkan, atau ditambahkan ke repositori lain |
| `Could not reach github.com` | DNS/firewall memblokir port 22 atau HTTPS |
| `install.sh` berhenti di paket PHP | Pastikan distro Ubuntu/Debian dan apt tidak terkunci proses lain |
| `Repository not found` | Branch salah, deploy key salah repo, atau repo dipindahkan |
| Wizard tidak muncul | Sudah ada akun Super Admin; wizard memang terkunci |

## Lisensi

Peralatan instalasi internal. Tidak ada lisensi yang diberikan untuk pemakaian
ulang di luar organisasi pemilik.
