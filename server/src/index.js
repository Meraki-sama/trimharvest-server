// index.js — Entry point server (npm start → node src/index.js). Menyusun semua middleware & route Express jadi satu aplikasi HTTP. Server satu-satunya yang bicara ke Postgres (lihat lib/db.js). Lihat PROTOCOL.md untuk arsitektur.
const express = require('express');
// Framework HTTP minimalis: routing, middleware chain, parsing body.
const helmet = require('helmet');
// Pasang header keamanan (X-Content-Type-Options, HSTS, dll) + CSP ketat di bawah.
const morgan = require('morgan');
// Logging HTTP request ke stdout untuk observability/debugging.
const cors = require('cors');
// CORS di-lock ke origin tertentu (config.allowedOrigins), bukan '*'.
const rateLimit = require('express-rate-limit');
// Batasi jumlah request per IP per jendela → cegah brute-force/flooding.

const config = require('./config');
const logger = require('./lib/logger');
// Config & logger terpusat (logger menggantikan console.* mentah).
const audit = require('./lib/audit');
const { startRetentionJob } = require('./lib/retention');
// Pembersih berkala readings kedaluwarsa (Postgres tak punya TTL otomatis). Schema dibuat saat start (CREATE TABLE IF NOT EXISTS) → tak perlu migrasi manual.
const db = require('./lib/db');
// Di-require tanpa menyimpan hasil: tujuannya menjalankan inisialisasi modul SEKARANG (fail-fast kalau DATABASE_URL salah), bukan saat route pertama butuh DB. Node cache modul → tak diinisialisasi dua kali.

const deviceAuth = require('./middleware/deviceAuth');
const errorHandler = require('./middleware/errorHandler');
const authRoutes = require('./routes/auth');
const ingestRoutes = require('./routes/ingest');
const deviceRoutes = require('./routes/devices');
const { validate, schemas } = require('./lib/validate');

const app = express();
// Instance aplikasi Express yang dikonfigurasi & di-listen di akhir.

// trust proxy = 1: percaya SATU hop (load balancer Railway) agar IP client benar & rate-limit login tak bisa dilewati via header X-Forwarded-For palsu.
app.set('trust proxy', 1);

// CSP ketat: batasi sumber script/style/connection (app Flutter bisa jadi web app). App mobile tak terpengaruh (defense-in-depth).
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
// HSTS otomatis di-set helmet bila di belakang HTTPS (Railway).

// CORS: lock ke origin terdaftar. Web origin asing ditolak; app mobile (tanpa header Origin) lolos. Production wajib isi allowedOrigins kalau ada client browser.
const allowedOrigins = (config.allowedOrigins || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const corsOptions = {
  origin: (origin, cb) => {
    // origin undefined → request non-browser (mobile/curl) selalu diizinkan; browser harus dari origin terdaftar.
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
// Hanya izinkan origin terdaftar; keamanan utama tetap HMAC (device) & JWT (operator).

// Log request terstruktur (pino) per baris; skip /health biar tak berisik.
app.use(
  morgan('combined', {
    stream: { write: (msg) => logger.info(msg.trim()) },
    skip: (req) => req.path === '/health', // lewati health-check
  })
);

// verify menyimpan byte body mentah ke req.rawBody — WAJIB untuk deviceAuth (HMAC dihitung atas byte asli, bukan hasil re-serialize yang urutan key-nya bisa beda). limit 32kb mencegah payload raksasa.
app.use(
  express.json({
    limit: '32kb', // body > 32kb ditolak 413 sebelum masuk route (proteksi murah).
    verify: (req, _res, buf) => {
      // verify dipanggil dengan buffer mentah SEBELUM di-parse → satu-satunya cara akses byte asli body (setelah di-parse jadi object, urutan key JSON hilang). Simpan sebagai string UTF-8 di req.rawBody untuk deviceAuth.
      req.rawBody = buf.toString('utf8'); // string UTF-8 untuk deviceAuth hitung ulang HMAC.
    },
  })
);

// Proteksi tambahan di atas HMAC untuk /api/ingest (kalau device_secret bocor).
const ingestLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 menit.
  limit: 60, // jauh di atas kebutuhan wajar (ingest ≥5 dtk = maks 12/menit).
  standardHeaders: true,
  legacyHeaders: false,
});

app.get('/health', (_req, res) => res.json({ ok: true }));
// Endpoint tanpa autentikasi untuk health check platform (hanya {"ok":true}, tak bocorkan info).

app.use('/api/auth', authRoutes);
// /api/auth: login & refresh — TIDAK dipasangi auth di sini karena route ini yang menerbitkan token.
app.use('/api/ingest', ingestLimiter, deviceAuth, validate(schemas.ingest), ingestRoutes);
// Urutan middleware disengaja: ingestLimiter (murah) dulu, lalu deviceAuth (HMAC), lalu validate, baru route. Request berlebihan ditolak paling awal.
app.use('/api/devices', deviceRoutes);
// operatorAuth dipasang DI DALAM deviceRoutes (router.use), bukan di sini.

app.use((_req, res) => {
  // Middleware catch-all tanpa path: request yang tak cocok route mana pun → 404.
  res.status(404).json({ ok: false, error: 'not_found' });
});
app.use(errorHandler);
// Error handler HARUS paling terakhir; hanya menangkap error dari middleware/route di atasnya.

// Railway kirim SIGTERM sebelum matikan container; tutup bersih agar request tak terpotong.
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

  // Mulai pembersih retensi SETELAH schema siap; hanya kalau TTL>0 (0 = simpan selamanya).
  if (config.readingsTtlDays > 0) {
    startRetentionJob();
    logger.info(
      { ttlDays: config.readingsTtlDays },
      'Pembersih retensi readings aktif (tiap 6 jam)'
    );
  } else {
    logger.warn('READINGS_TTL_DAYS=0: histori readings disimpan selamanya (tabel akan terus tumbuh)');
  }

  let shuttingDown = false;
  async function shutdown(signal) {
    // Tutup server bersih: selesaikan request berjalan, fallback force-exit 10s kalau ada koneksi gantung.
    if (shuttingDown) return;
    shuttingDown = true;
    logger.warn({ signal }, 'Menerima sinyal shutdown, menutup server...');
    server.close(() => {
      logger.info('Server berhenti bersih.');
      process.exit(0);
    });
    setTimeout(() => {
      logger.error('Force exit setelah timeout shutdown.');
      process.exit(1);
    }, 10000).unref();
  }
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  // Tangani SIGTERM (deploy baru/scale-down) & SIGINT agar data sensor tak terpotong.
})();
