# monitor-app (TrimHarvest)

App Flutter untuk memantau & mengendalikan sistem TrimHarvest. Bicara
HANYA ke Server Node.js (`/server`) lewat HTTPS+JWT, dan ke gateway lewat
WiFi Access Point setup-nya sendiri saat provisioning (lihat
`/PROTOCOL.md` bagian 3 & 4 di root repo untuk arsitektur lengkap).

## ⚠️ WAJIB dilakukan sebelum `flutter run` (sekali saja)

Folder ini SENGAJA hanya berisi kode Dart (`lib/`, `pubspec.yaml`,
`analysis_options.yaml`) — folder proyek native `android/` dan `ios/`
(project Gradle/Xcode yang sangat panjang & spesifik-versi-toolchain)
BELUM disertakan, supaya tidak ada risiko file native yang tidak cocok
dengan versi Flutter SDK yang kamu pakai. Bangkitkan sendiri sekali di
komputer kamu (perintah ini AMAN, tidak akan menimpa `lib/` atau
`pubspec.yaml` yang sudah ada):

```bash
cd monitor-app
flutter create . --platforms=android,ios --org com.trimharvest --project-name trimharvest_monitor
flutter pub get
```

Setelah itu baru jalankan seperti biasa:

```bash
flutter run
```

## Struktur kode

```
lib/
  main.dart                    Entry point + gerbang setup server/login.
  models/
    reading.dart                Model GENERIK Reading/ReadingSnapshot (JSON-driven, lihat /PROTOCOL.md 4).
    device.dart                 Model Device (ringkasan device + status online).
  services/
    api_client.dart             Klien HTTP ke Server Node.js (login, devices, readings, commands, rekey).
    provisioning_service.dart   Klien HTTP ke Access Point setup gateway (192.168.4.1).
    secure_storage_service.dart Wrapper flutter_secure_storage (token, URL server).
  widgets/
    reading_card.dart           Kartu metrik generik, render berdasarkan `unit` (bukan `id`).
    sparkline.dart               Grafik garis sederhana (custom painter, tanpa dependency tambahan).
  screens/
    server_setup_screen.dart    Layar pertama kali: atur URL server.
    login_screen.dart           Login operator.
    dashboard_screen.dart       Daftar device + ringkasan data terkini.
    device_detail_screen.dart   Detail device: semua reading, riwayat grafik, kontrol (interval/restart/rekey).
    calibration_screen.dart     Kalibrasi Fork/Capacitive/TDS dengan data raw live.
    add_device_screen.dart      Alur provisioning device baru (server + WiFi gateway sekaligus).
```

## Alur pertama kali pakai

1. Buka app → masukkan URL Server (`/server` yang sudah kamu deploy).
2. Login pakai akun operator (dibuat lewat `npm run create-operator` di
   folder `/server` — app ini SENGAJA tidak punya layar signup publik).
3. Dashboard kosong → tombol "Tambah Device" → ikuti 3 langkah:
   daftarkan ke server → sambungkan HP ke WiFi setup gateway → pilih WiFi
   rumah & kirim konfigurasi.

## Kenapa tidak pakai package chart pihak ketiga?

Grafik riwayat (`widgets/sparkline.dart`) sengaja ditulis manual pakai
`CustomPainter` bawaan Flutter, bukan package seperti `fl_chart`/`charts_flutter`
— mengurangi risiko ketidakcocokan versi API package chart pihak ketiga
dengan versi Flutter SDK yang kamu pakai. Kalau butuh grafik lebih
canggih (zoom, multi-axis, dst), silakan ganti dengan package favoritmu —
titik integrasinya hanya di satu file itu.
