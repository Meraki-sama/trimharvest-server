import 'package:flutter/material.dart';
import '../theme.dart';

// Layar pembuka (splash) ber-branding TrimHarvest -- menggantikan
// spinner polos saat app memutuskan rute awal (onboarding/login/dashboard).
// Memberi kesan "produk jadi" di detik pertama, bukan layar kosong/abu.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ikon brand di dalam lingkaran lembut (warna tanah/daun).
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.leaf.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.agriculture,
                size: 52,
                color: AppColors.leaf,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'TrimHarvest',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AppColors.leaf,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Pantau sawah, panen pasti',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.inkMuted,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: AppColors.leaf,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
