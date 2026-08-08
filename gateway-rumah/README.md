# iot-gateway-rumah

Firmware gateway rumah (ESP32 DevKit + modul LoRa SX1276). Menjembatani
node sensor sawah (`iot-node-sawah`, radio LoRa saja tanpa internet) ke
server (`/server`, Node.js) lewat WiFi/HTTPS.

**Baca `/PROTOCOL.md` dan `/SECURITY.md` di root repo dulu.**

## Menjalankan

1. Buka folder ini sebagai project PlatformIO.
2. Edit `src/config.h`:
   - `LORA_PSK` — WAJIB sama persis dengan `iot-node-sawah/src/config.h`.
     Compile GAGAL kalau masih placeholder.
   - `DEFAULT_SERVER_BASE_URL` — URL server Node.js kamu (lihat `/server`).
   - `SERVER_ROOT_CA_PEM` — kosongkan untuk testing lokal (lihat peringatan
     di komentar file), isi untuk produksi.
   - `DEVICE_ID`/`DEVICE_SECRET` boleh dibiarkan placeholder — akan diisi
     lewat provisioning app saat pertama kali setup (lihat di bawah).
3. `pio run --target upload`, lalu `pio device monitor`.
4. Nyalakan unit. Karena belum ada WiFi tersimpan, gateway otomatis
   membuka WiFi Access Point bernama `Gateway-Setup-<DEVICE_ID>` (password
   acak dicetak ke Serial saat boot pertama).
5. Di app Flutter: menu **Tambah Device Baru** akan (a) meminta server
   membuatkan `device_id`+`device_secret` baru, (b) membimbingmu connect
   HP ke AP setup gateway, (c) mengirim WiFi rumah + identitas baru
   sekaligus ke gateway. Gateway restart otomatis setelah itu.

## Struktur kode

```
src/
  main.cpp             Entry point: setup()/loop(), teruskan data node <-> server.
  config.h              Semua konstanta yang bisa diubah.
  device_identity.h/.cpp Penyimpanan device_id/secret/server_url di NVS.
  wifi_provision.h/.cpp  Mode Access Point + web server setup awal.
  http_client.h/.cpp     Klien HTTPS ke server (HMAC-signed, lihat /PROTOCOL.md 2).
  lora_gateway.h/.cpp    Terima/kirim paket LoRa ke node.
  lora_security.h/.cpp   AES-128-CTR + HMAC-SHA256 + anti-replay (identik
                          dengan modul yang sama di iot-node-sawah).
```

## Tombol reset WiFi

Tahan pin `WIFI_RESET_BUTTON_PIN` (default GPIO 4) ke GND saat gateway
baru menyala untuk menghapus WiFi tersimpan & masuk mode setup lagi
(berguna kalau gateway dipindah ke lokasi dengan WiFi berbeda). Identitas
device (device_id/secret/server_url) TIDAK ikut terhapus oleh tombol ini.

## Kalau gateway tidak pernah "online" di app

Cek urutan berikut di Serial Monitor:
1. `LoRa Gateway GAGAL` → cek wiring modul LoRa (SS/RST/DIO0 di config.h
   harus cocok dengan wiring fisik).
2. `waktu NTP belum sinkron` terus-menerus → gateway tidak bisa akses
   internet ke server NTP (`pool.ntp.org`) — cek firewall/router.
3. `server membalas kode 401/403` → `LORA_PSK`/`device_secret` tidak
   cocok dengan yang terdaftar di server, atau jam device terlalu jauh
   meleset dari jam server (lihat jendela toleransi di `/PROTOCOL.md` 2.1).
4. `gagal memulai koneksi HTTPS` → cek `server_url` (harus termasuk
   `https://` dan tanpa trailing slash).
