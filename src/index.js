// ============================================================================
// index.js — Entry point server (dijalankan lewat `npm start` -> `node
// src/index.js`). Menyusun semua middleware & route Express jadi satu
// aplikasi HTTP. Lihat /PROTOCOL.md di root repo untuk peta arsitektur
// lengkap. Server ini SATU-SATUNYA pihak yang bicara ke database
// (Postgres) -- lihat src/lib/db.js.
// ============================================================================
const express = require('express');
// ^ Framework HTTP server minimalis untuk Node.js -- menyediakan routing,
//   middleware chain, parsing body, dst.
const helmet = require('helmet');
// ^ Middleware keamanan: pasang header HTTP pelindung (X-Content-Type-Options,
//   X-Frame-Options, HSTS, dst). Di bawah ini kita TAMBAH Content-Security-
//   Policy yang ketat (karena app Flutter web/desktop bisa dibuka di browser).
const morgan = require('morgan');
// ^ Middleware logging HTTP request (mencatat method, path, status code,
//   waktu respons setiap request ke stdout) -- dipakai untuk observability/
//   debugging di production.
const cors = require('cors');
// ^ Middleware CORS. SEKARANG di-lock ke daftar origin tertentu
//   (config.allowedOrigins) bukan `*` -- lihat setup di bawah. Untuk app
//   Flutter MOBILE (Android/iOS) aturan CORS browser tidak berlaku, tapi
//   mengunci origin tetap praktik baik supaya API tidak bisa dipanggil
//   sembarangan dari web origin asing.
const rateLimit = require('express-rate-limit');
// ^ Middleware pembatas jumlah request per IP dalam jendela waktu tertentu
//   -- mencegah brute-force/flooding.

const config = require('./config');
const logger = require('./lib/logger');
// ^ Structured logger (pino) -- menggantikan console.* mentah supaya log
//   terstruktur & mudah di-aggregasi di Railway/production.
const audit = require('./lib/audit');
// Memuat db (Postgres) di sini (bukan di dalam route) supaya server GAGAL
// START cepat dengan pesan jelas kalau DATABASE_URL belum dikonfigurasi
// dengan benar -- lihat komentar di lib/db.js. Schema otomatis dibuat
// (CREATE TABLE IF NOT EXISTS) saat start, jadi tidak perlu migrasi manual.
const db = require('./lib/db');
// ^ Di-require TANPA menyimpan hasilnya ke variabel -- tujuannya HANYA agar
//   kode inisialisasi module itu dieksekusi SEKARANG (saat index.js start),
//   bukan nanti pas route pertama butuh database. File lain yang butuh
//   `query` akan require('../lib/db') lagi secara terpisah -- Node meng-cache
//   module, jadi tidak akan diinisialisasi dua kali.

const deviceAuth = require('./middleware/deviceAuth');
const errorHandler = require('./middleware/errorHandler');
const authRoutes = require('./routes/auth');
const ingestRoutes = require('./routes/ingest');
const deviceRoutes = require('./routes/devices');
const { validate, schemas } = require('./lib/validate');

const app = express();
// ^ Buat instance aplikasi Express -- objek inilah yang dikonfigurasi
//   dengan middleware & route di bawah, lalu di-listen di port tertentu
//   di baris paling akhir file ini.

// --- Trust proxy ---
// Railway (dan kebanyakan PaaS) berada di balik load balancer/reverse proxy,
// sehingga alamat IP asli client ada di header X-Forwarded-For. Tanpa ini,
// express-rate-limit akan melihat IP proxy (bukan client) dan bisa salah
// mengidentifikasi user (warning ERR_ERL_UNEXPECTED_X_FORWARDED_FOR).
app.set('trust proxy', true);

// --- Helmet: header keamanan + CSP ketat ---
// Karena app Flutter bisa dijalankan sebagai WEB APP, kita pasang CSP yang
// membatasi sumber script/style/connection hanya ke yang kita butuhkan.
// (App mobile tidak terpengaruh CSP, tapi ini standar defense-in-depth.)
app.use(
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'", "'unsafe-inline'"], // Flutter web butuh inline style
        imgSrc: ["'self'", 'data:'],
        connectSrc: ["'self'"],
        frameAncestors: ["'none'"], // cegah clickjacking
        objectSrc: ["'none'"],
        baseUri: ["'self'"],
      },
    },
    crossOriginOpenerPolicy: { policy: 'same-origin' },
  })
);
// ^ Catatan: HSTS di-set otomatis oleh helmet bila di belakang HTTPS
//   (Railway termination). Kalau ingin HSTS eksplisit, tambah
//   `strictTransportSecurity` di atas.

// --- CORS: LOCK ke origin tertentu ---
// config.allowedOrigins adalah string dipisah koma (mis.
// "https://app.trimharvest.id,https://web.trimharvest.id"). Kalau kosong,
// web origin ASING DITOLAK (mobile app tanpa header Origin tetap lolos).
// Production WAJIB diisi dengan origin web kalau ada client browser.
const allowedOrigins = (config.allowedOrigins || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const corsOptions = {
  origin: (origin, cb) => {
    // `origin` undefined -> request non-browser (app mobile, curl) -> selalu
    // diizinkan. Request browser HARUS berasal dari origin terdaftar;
    // list kosong SEKARANG MENOLAK web origin asing (bukan lagi allow-all,
    // lihat bug #5) -- mobile tetap lolos lewat cabang `!origin` di atas.
    if (!origin) return cb(null, true);
    if (allowedOrigins.length > 0 && allowedOrigins.includes(origin)) {
      return cb(null, true);
    }
    logger.warn({ origin }, 'CORS: origin tidak diizinkan ditolak');
    return cb(null, false);
  },
  optionsSuccessStatus: 204,
};
app.use(cors(corsOptions));
// ^ Mengizinkan request lintas-origin HANYA dari origin yang terdaftar di
//   config.allowedOrigins. App mobile (tanpa header Origin) tetap lolos.
//   Keamanan sesungguhnya tetap dijaga HMAC (device) & JWT (operator).

// Request log terstruktur (pino via morgan stream) -- menggantikan log
// morgan mentah. Di production menulis JSON per baris.
app.use(
  morgan('combined', {
    stream: { write: (msg) => logger.info(msg.trim()) },
    // skip health-check biar log tidak berisik
    skip: (req) => req.path === '/health',
  })
);

// `verify` di sini menyimpan byte body PERSIS seperti yang diterima ke
// req.rawBody -- WAJIB untuk deviceAuth.js (HMAC dihitung atas byte body
// asli, bukan hasil re-serialize req.body yang urutan key-nya bisa
// berbeda). Batas 32kb jauh di atas kebutuhan nyata (body ingest terbesar
// jauh di bawah 1kb, lihat /PROTOCOL.md) -- sekadar proteksi dasar
// terhadap body raksasa yang tidak masuk akal.
app.use(
  express.json({
    // ^ Middleware bawaan Express untuk mem-parsing body request yang
    //   Content-Type-nya application/json, hasilnya diisi ke req.body
    //   sebagai object JavaScript.
    limit: '32kb',
    // ^ Body yang lebih besar dari ini akan otomatis ditolak Express dengan
    //   error 413 (Payload Too Large) SEBELUM masuk ke middleware/route
    //   manapun -- proteksi murah terhadap payload raksasa yang tidak
    //   mungkin valid untuk protokol ini (bandingkan dengan estimasi paket
    //   sensor ~140-165 byte di /PROTOCOL.md).
    verify: (req, _res, buf) => {
      // ^ Callback opsional express.json() yang dipanggil dengan BUFFER
      //   MENTAH body SEBELUM di-parse jadi object -- inilah satu-satunya
      //   cara mengakses byte asli body, karena setelah di-parse jadi
      //   req.body (object JS), urutan key JSON aslinya sudah HILANG (object
      //   JS tidak menjamin urutan key seperti string JSON aslinya, dan
      //   kalau di-JSON.stringify() ulang hasilnya bisa beda string persis
      //   walau secara semantik sama) -- padahal HMAC di deviceAuth.js harus
      //   dihitung atas STRING BYTE PERSIS yang dikirim gateway.
      req.rawBody = buf.toString('utf8');
      // ^ Simpan sebagai string UTF-8 di req.rawBody, supaya
      //   middleware/deviceAuth.js bisa memakainya untuk menghitung ulang
      //   HMAC dan membandingkannya dengan header X-Signature.
    },
  })
);

// Proteksi dasar terhadap banjir request ke /api/ingest -- di atas HMAC
// (yang sudah menolak request tanpa signature valid) ini cuma lapisan
// tambahan terhadap penyalahgunaan bandwidth/compute kalau device_secret
// suatu saat bocor.
const ingestLimiter = rateLimit({
  windowMs: 60 * 1000, // Jendela waktu: 60.000 ms = 1 menit.
  limit: 60, // jauh di atas kebutuhan wajar (ingest tiap >=5 detik = maks 12/menit)
  // ^ Maksimum 60 request per menit per IP -- device asli hanya butuh
  //   sekitar 12/menit (kalau interval kirim 5 detik), jadi angka 60 masih
  //   memberi ruang longgar tanpa terlalu ketat, sambil tetap membatasi
  //   penyalahgunaan skala besar.
  standardHeaders: true, // Kirim header RateLimit-* standar (RFC) ke response.
  legacyHeaders: false,  // Jangan kirim header X-RateLimit-* versi lama (redundan).
});

app.get('/health', (_req, res) => res.json({ ok: true }));
// ^ Endpoint sederhana tanpa autentikasi apa pun -- dipakai platform hosting
//   (Railway/Render/dst) atau monitoring eksternal untuk mengecek server
//   masih hidup ("health check"), TIDAK membocorkan informasi sensitif apa
//   pun (hanya {"ok":true}).

app.use('/api/auth', authRoutes);
// ^ Semua endpoint di bawah /api/auth/* (login, refresh) -- TIDAK dipasangi
//   deviceAuth/operatorAuth di sini karena route ini JUSTRU yang menerbitkan
//   token itu sendiri (endpoint login tidak mungkin mensyaratkan token yang
//   belum dimiliki).
app.use('/api/ingest', ingestLimiter, deviceAuth, validate(schemas.ingest), ingestRoutes);
// ^ Urutan middleware PENTING & disengaja: ingestLimiter (rate limit) DULU
//   lebih murah secara komputasi, jadi request yang jelas berlebihan
//   ditolak paling awal SEBELUM membuang resource untuk query Postgres di
//   deviceAuth. Baru SETELAH lolos rate limit, deviceAuth memverifikasi
//   HMAC (perlu query Postgres untuk ambil device.secret). Baru setelah
//   keduanya lolos, validate(schemas.ingest) memastikan body sesuai skema
//   (tolak payload anomali sebelum masuk logika bisnis), barulah diteruskan
//   ke ingestRoutes (routes/ingest.js).
app.use('/api/devices', deviceRoutes);
// ^ operatorAuth dipasang DI DALAM deviceRoutes sendiri lewat
//   `router.use(operatorAuth)` (lihat routes/devices.js), bukan di sini --
//   pola yang sedikit berbeda dari /api/ingest di atas, tapi efeknya sama:
//   semua endpoint di bawah /api/devices/* butuh JWT operator yang valid.

app.use((_req, res) => {
  // ^ Middleware "catch-all" TANPA path spesifik, dipasang SETELAH semua
  //   route terdaftar -- kalau request tidak cocok dengan route mana pun
  //   di atas, akan "jatuh" ke sini.
  res.status(404).json({ ok: false, error: 'not_found' });
});
app.use(errorHandler);
// ^ HARUS dipasang PALING TERAKHIR -- Express memanggil middleware sesuai
//   urutan app.use(), dan error handler (dikenali dari 4 parameternya,
//   lihat errorHandler.js) hanya akan "menangkap" error yang terjadi di
//   middleware/route yang terdaftar SEBELUM baris ini.

// --- Graceful shutdown (standar di platform seperti Railway) ---
// Railway mengirim SIGTERM sebelum mematikan container. Kita berhenti
// menerima koneksi baru, menyelesaikan request yang sedang jalan, lalu
// exit bersih -- mencegah request tengah jalan terpotong (data hilang).

// Inisialisasi skema DB (CREATE TABLE IF NOT EXISTS) SEBELUM mulai listen,
// supaya tabel sudah ada saat request pertama masuk. Fail-fast: kalau DB
// tidak bisa dihubungi, server akan error di sini (bukan di request pertama).
(async () => {
  try {
    await db.initSchema();
    logger.info('Schema database siap (Postgres).');
  } catch (err) {
    logger.error({ err: err.message }, 'Gagal inisialisasi schema database');
    process.exit(1);
  }

  const server = app.listen(config.port, () => {
    logger.info(`TrimHarvest API Gateway berjalan di port ${config.port}`);
  });

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.warn({ signal }, 'Menerima sinyal shutdown, menutup server...');
  server.close(() => {
    logger.info('Server berhenti bersih.');
    process.exit(0);
  });
  // Fallback: kalau ada connection yang gantung, paksa exit setelah 10s.
  setTimeout(() => {
    logger.error('Force exit setelah timeout shutdown.');
    process.exit(1);
  }, 10000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
// ^ Di Railway, SIGTERM = deploy baru / scale-down. Tangani supaya tidak
//   ada data sensor yang terpotong di tengah pengiriman.
})();
