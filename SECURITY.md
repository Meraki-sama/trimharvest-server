# TrimHarvest — Panduan Keamanan

Dokumen ini melengkapi `/PROTOCOL.md` (yang menjelaskan APA skema
keamanannya) dengan BAGAIMANA cara mengoperasikannya dengan benar:
membangkitkan kunci, mengatur TLS, dan apa yang masih jadi tanggung jawab
manual kamu sebagai operator sistem ini.

## 1. Kunci & secret yang WAJIB kamu bangkitkan sendiri

Jangan pernah memakai nilai contoh/placeholder di repo ini apa adanya di
unit produksi. Semua kompilasi firmware akan GAGAL kalau placeholder
belum diganti (lihat `static_assert` di tiap `config.h`) -- ini bukan
bug, itu memang sengaja dirancang begitu.

| Nilai | Dipakai di | Cara bangkitkan |
|---|---|---|
| `LORA_PSK` | `node-sawah/src/config.h` **dan** `gateway-rumah/src/config.h` (harus SAMA PERSIS di keduanya, beda per pasangan node+gateway) | `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET` | `server/.env` (harus beda satu sama lain) | `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"` |
| `device_secret` | Otomatis dibangkitkan server saat `POST /api/devices` (lihat `server/src/lib/crypto.js`) | Tidak perlu manual |
| Password operator app | Postgres `operators/{username}` (bcrypt) | `npm run create-operator` di folder `/server` |

## 2. TLS (HTTPS) antara gateway dan server

Gateway berbicara ke server lewat `WiFiClientSecure` (lihat
`gateway-rumah/src/http_client.cpp`). Ada 2 mode:

- **`SERVER_ROOT_CA_PEM` kosong** (default): TLS TIDAK memvalidasi
  sertifikat server sama sekali (`setInsecure()`). Cocok untuk
  development/testing di jaringan lokal yang kamu percaya, TIDAK untuk
  produksi (rentan man-in-the-middle) -- firmware akan mencetak
  peringatan ke Serial tiap boot selama ini masih kosong.
- **Produksi**: deploy server kamu di belakang domain dengan sertifikat
  TLS sungguhan (mis. lewat reverse proxy [Caddy](https://caddyserver.com/)
  yang otomatis mengurus Let's Encrypt, atau langsung pakai HTTPS bawaan
  platform kalau deploy ke Cloud Run/Render/Railway/dst). Lalu isi
  `SERVER_ROOT_CA_PEM` di `gateway-rumah/src/config.h` dengan root CA yang
  menerbitkan sertifikat itu (untuk Let's Encrypt, itu "ISRG Root X1" --
  cari "ISRG Root X1 PEM" dan tempel sebagai raw string literal C++:
  ```cpp
  #define SERVER_ROOT_CA_PEM \
  "-----BEGIN CERTIFICATE-----\n" \
  "...(isi sertifikat, tiap baris diakhiri \\n)...\n" \
  "-----END CERTIFICATE-----\n"
  ```

## 3. Kredensial database (PostgreSQL)

`server/.env` memuat `DATABASE_URL` (connection string PostgreSQL, mis.
`postgres://user:***@host:5432/db`) yang memberi akses ke database
TrimHarvest. Perlakukan seperti password root:
- JANGAN commit ke git (sudah ada di `.gitignore`).
- JANGAN taruh di storage publik (bucket public, repo publik, dst).
- Kalau server kamu di-deploy ke platform cloud (Cloud Run, dst),
  pertimbangkan pakai Workload Identity / Secret Manager platform itu
  alih-alih file JSON di disk, kalau platformnya mendukung.

## 4. Kenapa `device_secret` & `LORA_PSK` disimpan PLAINTEXT di NVS ESP32?

Ini bukan kelalaian -- skema HMAC di `/PROTOCOL.md` (bagian 1 & 2)
mengharuskan kedua sisi (node+gateway, atau gateway+server) menyimpan
secret yang SAMA dan bisa dipakai ulang untuk menghitung HMAC di setiap
pesan/request. Ini beda dengan password login manusia (yang cukup
disimpan sebagai hash satu arah) -- device credential di sini memang
harus reversibel dipakai berulang kali oleh firmware.

NVS (flash) ESP32 secara default TIDAK terenkripsi -- siapa pun yang
punya akses fisik ke chip (lewat programmer SPI flash) bisa membaca
`LORA_PSK`/`device_secret` mentah-mentah. Untuk perlindungan terhadap
skenario ini (pencurian fisik unit), ESP32 punya 2 fitur hardware:

- **Flash Encryption**: mengenkripsi seluruh isi flash (termasuk NVS)
  dengan kunci yang tersimpan di eFuse (tidak bisa dibaca lewat software
  setelah eFuse dikunci).
- **Secure Boot V2**: memastikan hanya firmware yang ditandatangani
  kriptografis oleh kamu yang bisa berjalan di chip itu (mencegah
  penyerang mem-flash firmware jahat).

**INI SENGAJA TIDAK diotomatisasi lewat kode di repo ini.** Kedua fitur
ini membakar eFuse fisik yang **TIDAK BISA DIBALIK** -- salah konfigurasi
bisa mem-brick unit secara permanen, dan prosedurnya beda-beda tergantung
revisi chip ESP32 kamu. Kalau kamu memang butuh perlindungan level ini
(mis. unit dipasang di lokasi yang mudah dicuri orang), ikuti dokumentasi
resmi Espressif langkah demi langkah DI UNIT TESTING dulu sebelum di unit
produksi:
- Flash Encryption: https://docs.espressif.com/projects/esp-idf/en/stable/esp32/security/flash-encryption.html
- Secure Boot V2: https://docs.espressif.com/projects/esp-idf/en/stable/esp32/security/secure-boot-v2.html

Catatan: PlatformIO dengan framework Arduino murni (yang dipakai kedua
firmware di repo ini) punya dukungan terbatas untuk mengatur opsi
`sdkconfig` ESP-IDF secara langsung dibanding project ESP-IDF native --
kalau kamu serius mengaktifkan ini, pertimbangkan migrasi ke framework
`espidf` di `platformio.ini` atau ke ESP-IDF native untuk kontrol penuh
atas opsi keamanan ini.

## 5. Rotasi kredensial

- **`device_secret` bocor/dicurigai**: pakai tombol "Rekey Device" di app
  (lihat `/PROTOCOL.md` bagian 3) -- tidak perlu flash ulang apa pun.
- **`LORA_PSK` bocor**: TIDAK ADA mekanisme rotasi jarak jauh (secara
  desain -- kalau LORA_PSK bocor, penyerang bisa membaca/memalsukan
  paket radio langsung, jadi rotasi HARUS lewat flash ulang fisik kedua
  firmware dengan PSK baru).
- **Password operator app bocor / HP hilang**: ganti password lewat app
  (Pengaturan → Ganti Password), atau `npm run create-operator -- <username>`
  lagi di server. Keduanya menaikkan `operators.token_version`, sehingga
  SEMUA sesi lama di perangkat mana pun langsung dicabut (access token
  MAUPUN refresh token yang berumur 30 hari) -- perangkat itu tidak bisa
  lagi menerbitkan token baru dan harus login ulang dengan password baru.
  Lihat PROTOCOL.md bagian 3.1.
- **JWT secret bocor**: ganti di `.env` server lalu restart server --
  efeknya SEMUA access/refresh token yang beredar langsung tidak valid
  (semua operator harus login ulang).

## 6. Yang TIDAK dicakup ancaman modelnya oleh sistem ini

Supaya ekspektasi jelas:
- **Jamming radio LoRa**: sistem ini tidak punya mekanisme anti-jamming.
  Penyerang yang cukup dekat bisa membuat radio tidak bisa
  berkomunikasi (denial of service), meski tidak bisa membaca/memalsukan
  isi datanya.
- **Kompromi fisik penuh terhadap gateway/node yang sedang menyala**:
  kalau penyerang punya akses fisik ke board yang sedang aktif (bukan
  cuma mencuri lalu membongkar chip-nya belakangan), banyak proteksi
  software jadi kurang relevan -- ini di luar cakupan proyek skala
  rumahan seperti ini, biasanya perlu proteksi fisik (kotak
  terkunci/tersembunyi) sebagai mitigasi utama.
- **Kompromi terhadap server itu sendiri** (mis. lewat kerentanan
  Node.js/dependency yang belum di-patch): jaga `npm audit` &
  dependency tetap update, dan jalankan server dengan user non-root serta
  firewall yang membatasi port masuk hanya ke yang perlu (443/80 lewat
  reverse proxy).
