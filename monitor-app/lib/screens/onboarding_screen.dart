import 'package:flutter/material.dart';
import '../theme.dart';

// Layar tutorial/onboarding INTERAKTIF ala game: pengguna TIDAK cuma
// membaca, tapi PRAKTEK langsung di dalam simulator (mockup yang beneran
// bisa di-tap) sambil diarahkan langkah demi langkah. Tiap "level" baru
// terbuka setelah task di level sebelumnya diselesaikan -- seperti
// tutorial game yang memaksa pemain mencoba aksi sebelum lanjut.
//
// Semua interaksi di sini SIMULASI (tidak menyentuh server/device asli),
// tujuannya cuma membiasakan jari & mata pengguna dengan alur app.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;
  // Level yang SUDAH diselesaikan task-nya. Mengunci "Lanjut" sampai aksi
  // di level ini benar-benar dicoba.
  final Set<int> _done = {};

  // Level dibangun saat init supaya tiap task bisa menerima callback
  // onComplete (tidak bisa const karena butuh closure).
  late final List<_Level> _levels;

  @override
  void initState() {
    super.initState();
    _levels = [
      _Level(
        icon: Icons.eco_outlined,
        title: 'Level 1 · Kenalan dulu',
        body: 'Ini layar utamamu. Di sini semua alat yang dipantau akan '
            'muncul sebagai kartu. Geser ke kiri untuk belajar tiap langkah.',
        task: (_) => const _IntroTask(),
      ),
      _Level(
        icon: Icons.login_outlined,
        title: 'Level 2 · Coba Login',
        body: 'Ketik username & password (coba apa saja), lalu tekan "Masuk". '
            'Di app asli, ini menyambung ke server. Di sini cuma latihan.',
        task: (onDone) => _LoginTask(onComplete: onDone),
      ),
      _Level(
        icon: Icons.add_circle_outline,
        title: 'Level 3 · Tambah Device',
        body: 'Tekan tombol "+ Tambah Device", lalu "Sambungkan" ke gateway. '
            'Cobalah sekarang supaya tahu alurnya.',
        task: (onDone) => _AddDeviceTask(onComplete: onDone),
      ),
      _Level(
        icon: Icons.show_chart_outlined,
        title: 'Level 4 · Lihat Grafik',
        body: 'Ketuk kartu device untuk lihat grafik. Geser slider "Patokan" '
            'untuk menandai batas aman. Coba di sini.',
        task: (onDone) => _DetailTask(onComplete: onDone),
      ),
      _Level(
        icon: Icons.tune_outlined,
        title: 'Level 5 · Kalibrasi',
        body: 'Buka "Kalibrasi", tekan "Simpan Kering" LALU "Simpan Basah". '
            'Itu yang membuat sensor jadi akurat. Coba urutannya.',
        task: (onDone) => _CalibTask(onComplete: onDone),
      ),
      _Level(
        icon: Icons.bedtime_outlined,
        title: 'Level 6 · Mode Hemat',
        body: 'Tekan "Hemat Node" untuk memperlambat kirim data (baterai tahan '
            'lama). Colok ulang listrik untuk menyalakan kembali. Coba sekarang.',
        task: (onDone) => _HematTask(onComplete: onDone),
      ),
    ];
  }

  bool get _canAdvance => _done.contains(_page);

  void _completeLevel(int page) => setState(() => _done.add(page));

  void _goNext() {
    if (_page < _levels.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onDone();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = _levels.length;
    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            // --- Progress level (bar + counter) ala game ---
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.spa_outlined, color: AppColors.leaf, size: 20),
                      const SizedBox(width: AppSpacing.xs),
                      Text('Petualangan TrimHarvest',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: AppColors.leaf)),
                      const Spacer(),
                      Text('Level ${_page + 1}/$total',
                          style: const TextStyle(
                              color: AppColors.inkMuted,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusSm),
                    child: LinearProgressIndicator(
                      value: (_page + (_canAdvance ? 1 : 0)) / total,
                      minHeight: 8,
                      backgroundColor: cs.onSurface.withValues(alpha: 0.12),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(AppColors.leaf),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: total,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, index) {
                  final lv = _levels[index];
                  final task = lv.task(() => _completeLevel(index));
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppColors.leaf.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(lv.icon, size: 38, color: AppColors.leaf),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(lv.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                            textAlign: TextAlign.center),
                        const SizedBox(height: AppSpacing.sm),
                        Text(lv.body,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: AppColors.inkMuted),
                            textAlign: TextAlign.center),
                        const SizedBox(height: AppSpacing.md),
                        // Task interaktif -- "praktek" yang diarahkan
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _done.contains(index)
                              ? const _DoneChip(text: 'Hebat! Level ini beres 🌱')
                              : task,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Tombol navigasi -- terkunci sampai task selesai ( seperti game)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
              child: Row(
                children: [
                  TextButton(
                    onPressed: widget.onDone,
                    child: const Text('Lewati'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _canAdvance ? _goNext : null,
                    icon: Icon(_canAdvance
                        ? Icons.arrow_forward
                        : Icons.lock_outline),
                    label: Text(_page < total - 1
                        ? (_canAdvance ? 'Lanjut' : 'Selesaikan dulu')
                        : 'Selesai'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Model level: task adalah builder yg menerima onComplete ---
class _Level {
  final IconData icon;
  final String title;
  final String body;
  final Widget Function(VoidCallback onComplete) task;
  const _Level({
    required this.icon,
    required this.title,
    required this.body,
    required this.task,
  });
}

// ============================ TASK-TASK INTERAKTIF ============================

class _IntroTask extends StatelessWidget {
  const _IntroTask();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// Level 2: simulasi login
class _LoginTask extends StatefulWidget {
  final VoidCallback onComplete;
  const _LoginTask({required this.onComplete});
  @override
  State<_LoginTask> createState() => _LoginTaskState();
}

class _LoginTaskState extends State<_LoginTask> {
  final _u = TextEditingController();
  final _p = TextEditingController();
  bool _loggedIn = false;
  @override
  void dispose() {
    _u.dispose();
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loggedIn) {
      // panggil onComplete saat muncul pertama kali
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete());
      return const _DoneChip(text: 'Login berhasil (simulasi)');
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          TextField(
            controller: _u,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _p,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: () {
              if (_u.text.isNotEmpty && _p.text.isNotEmpty) {
                setState(() => _loggedIn = true);
              }
            },
            child: const Text('Masuk (coba)'),
          ),
        ],
      ),
    );
  }
}

// Level 3: tambah device simulasi
class _AddDeviceTask extends StatefulWidget {
  final VoidCallback onComplete;
  const _AddDeviceTask({required this.onComplete});
  @override
  State<_AddDeviceTask> createState() => _AddDeviceTaskState();
}

class _AddDeviceTaskState extends State<_AddDeviceTask> {
  int _step = 0;
  @override
  Widget build(BuildContext context) {
    if (_step >= 2) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => widget.onComplete());
      return const _DoneChip(text: 'Device terdaftar (simulasi)');
    }
    return Column(
      children: [
        if (_step == 0)
          FilledButton.icon(
            onPressed: () => setState(() => _step = 1),
            icon: const Icon(Icons.add),
            label: const Text('+ Tambah Device'),
          )
        else
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                const Text('WiFi: Gateway-Setup-XXX',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                FilledButton(
                  onPressed: () => setState(() => _step = 2),
                  child: const Text('Sambungkan'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// Level 4: detail + slider patokan
class _DetailTask extends StatefulWidget {
  final VoidCallback onComplete;
  const _DetailTask({required this.onComplete});
  @override
  State<_DetailTask> createState() => _DetailTaskState();
}

class _DetailTaskState extends State<_DetailTask> {
  double _patokan = 500;
  bool _tapped = false;
  @override
  Widget build(BuildContext context) {
    if (_tapped) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => widget.onComplete());
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Grafik TDS',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SizedBox(
            height: 50,
            child: CustomPaint(
              painter: _PatokanPainter(patokan: _patokan),
              child: Container(),
            ),
          ),
          const SizedBox(height: 8),
          Text('Patokan: ${_patokan.round()}'),
          Slider(
            value: _patokan,
            min: 0,
            max: 1000,
            divisions: 20,
            onChanged: (v) => setState(() {
              _patokan = v;
              _tapped = true;
            }),
          ),
        ],
      ),
    );
  }
}

// Level 5: kalibrasi urutan kering -> basah
class _CalibTask extends StatefulWidget {
  final VoidCallback onComplete;
  const _CalibTask({required this.onComplete});
  @override
  State<_CalibTask> createState() => _CalibTaskState();
}

class _CalibTaskState extends State<_CalibTask> {
  bool _kering = false;
  bool _basah = false;
  @override
  Widget build(BuildContext context) {
    final ok = _kering && _basah;
    if (ok) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => widget.onComplete());
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              ElevatedButton(
                onPressed: _kering ? null : () => setState(() => _kering = true),
                child: Text(_kering ? '✓ Kering' : 'Simpan Kering'),
              ),
              ElevatedButton(
                onPressed: (!_kering || _basah)
                    ? null
                    : () => setState(() => _basah = true),
                child: Text(_basah ? '✓ Basah' : 'Simpan Basah'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Level 6: mode hemat toggle
class _HematTask extends StatefulWidget {
  final VoidCallback onComplete;
  const _HematTask({required this.onComplete});
  @override
  State<_HematTask> createState() => _HematTaskState();
}

class _HematTaskState extends State<_HematTask> {
  bool _hemat = false;
  @override
  Widget build(BuildContext context) {
    if (_hemat) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => widget.onComplete());
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hemat Node'),
            subtitle: const Text('Perlambat kirim data, baterai tahan lama'),
            value: _hemat,
            onChanged: (v) => setState(() => _hemat = v),
          ),
        ],
      ),
    );
  }
}

// --- Chip "selesai" ---
class _DoneChip extends StatelessWidget {
  final String text;
  const _DoneChip({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.okGreen.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: AppColors.okGreen, size: 16),
          const SizedBox(width: 6),
          Text(text,
              style:
                  const TextStyle(color: AppColors.okGreen, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// --- Garis tiruan grafik + batas patokan ---
class _PatokanPainter extends CustomPainter {
  final double patokan;
  const _PatokanPainter({required this.patokan});
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = AppColors.leaf..strokeWidth = 2;
    final path = Path();
    path.moveTo(0, size.height * 0.7);
    path.lineTo(size.width * 0.25, size.height * 0.4);
    path.lineTo(size.width * 0.5, size.height * 0.55);
    path.lineTo(size.width * 0.75, size.height * 0.3);
    path.lineTo(size.width, size.height * 0.45);
    canvas.drawPath(path, line);
    final tY = size.height * (1 - patokan / 1000);
    final dash = Paint()..color = AppColors.berry..strokeWidth = 1.5;
    final dp = Path();
    double x = 0;
    while (x < size.width) {
      final x2 = (x + 6 < size.width) ? x + 6 : size.width;
      dp.moveTo(x, tY);
      dp.lineTo(x2, tY);
      x += 11;
    }
    canvas.drawPath(dp, dash);
  }

  @override
  bool shouldRepaint(covariant _PatokanPainter old) => old.patokan != patokan;
}
