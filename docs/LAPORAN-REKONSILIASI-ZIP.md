# Laporan Rekonsiliasi ZIP YUKU SOCIAL

Tanggal pemeriksaan: 17 November 2026

## Sumber yang dibandingkan
- `YUKU-2.0-clean-rapi.zip` (basis rekonsiliasi, sekitar 3.1 MB).
- `new-15-nov-main (17).zip` (sekitar 17 MB), yang berisi folder proyek aktif, satu arsip proyek bersarang, dan arsip referensi checkpoint Claude.

## Keputusan basis
Folder `YUKU-2.0-clean` dari ZIP 3.1 MB dipakai sebagai basis utama karena berisi migrasi lanjutan 36 sampai 39, komponen Branding dan Hero Slides, serta perbaikan QRIS yang lebih baru dibanding snapshot proyek bersarang pada ZIP 17 MB.

## Perbedaan penting yang diverifikasi
- ZIP 17 MB memuat dua snapshot proyek: folder `yuku-project/YUKU-2.0-clean` dan arsip `YUKU-2.0-clean (6).zip`. Keduanya tidak identik.
- Basis 3.1 MB memiliki `.env.example`, `package-lock.json`, `BrandingAdminPanel.tsx`, `HeroSlidesAdminPanel.tsx`, `TalentQuickFilter.tsx`, `branding.ts`, dan migration 36-39.
- Pada versi QRIS, basis 3.1 MB memiliki alur dialog verifikasi Admin, pemisahan bukti booking aktif/tidak aktif, dan validasi/kompresi bukti pembayaran yang tidak terdapat pada snapshot bersarang yang lebih lama.
- `37_hero_slides.sql` di root proyek ZIP 17 MB tidak dibawa ke basis final karena konflik nomor dengan `37_optimize_rls_auth_initplan.sql`. Migrasi Hero Slides yang dirujuk oleh basis utama adalah `supabase/migrations/38_hero_slides.sql`.
- `supabase/ops/schedule_escrow_release.sql` dari ZIP 17 MB tidak disalin karena basis utama mendokumentasikan penggunaan migration 33 sebagai jalur scheduler.
- Folder `docs/claude-checkpoint-05-reference/` merupakan arsip referensi/snapshot lama, bukan source proyek aktif, sehingga tidak digabung ke source aktif.

## Batasan verifikasi
- Pemeriksaan integritas ZIP berhasil dilakukan setelah paket dibuat.
- `npm ci --ignore-scripts --no-audit --no-fund` tidak selesai dalam batas waktu sesi; karena itu build TypeScript/Vite belum dapat dinyatakan lulus.
- Tidak ada migrasi yang dijalankan ke Supabase dan tidak ada database produksi yang diubah.
- Paket ini adalah rekonsiliasi source berdasarkan perbandingan file, bukan klaim siap produksi.

## Pekerjaan berikutnya
1. Buka paket ini di branch kerja Codespaces, bukan menimpa branch utama tanpa backup.
2. Jalankan `npm ci`, lalu `npm run lint` dan `npm run build`.
3. Audit dan implementasikan Talent Management hybrid sebagai pekerjaan terpisah: layanan baru harus melalui persetujuan Admin; Talent boleh mengubah status layanan yang telah disetujui dan jadwal; booking lama tetap memakai snapshot.
4. Terapkan migration hanya pada staging setelah urutan dan kondisi database staging diverifikasi.
