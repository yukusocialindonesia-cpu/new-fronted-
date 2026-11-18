# YUKU SOCIAL — Checkpoint 08: Talent Management Security Hardening

## Ringkasan perubahan

Checkpoint ini memperbaiki beberapa celah yang ditemukan pada implementasi Talent Management di checkpoint sebelumnya. Perubahan dilakukan pada source project, tanpa menjalankan migration ke Supabase.

### Perubahan source code

- `src/pages/BecomeTalentPage.tsx`
  - Menghapus operasi langsung `DELETE` dan `INSERT` ke `talent_services`.
  - Pengajuan semua layanan awal kini memakai satu RPC atomik `request_talent_services`.
  - Layanan baru berstatus `pending` sampai Admin menyetujui.

### Migration baru

- `supabase/migrations/41_talent_management_security_hardening.sql`
  - Mencabut hak tulis langsung client ke `talent_services`.
  - Mencabut INSERT/UPDATE langsung ke `talent_service_change_log` dan `talent_identity_change_requests`.
  - Mempertahankan akses baca sesuai RLS.
  - Mencabut hak UPDATE langsung kolom `talent_profiles.display_name`; perubahan nama harus melalui RPC review Admin.
  - Memvalidasi role Talent pada RPC pengajuan layanan dan perubahan layanan.
  - Membatasi Talent agar tidak dapat mengaktifkan kembali layanan yang dinonaktifkan Admin.
  - Mencatat event pengajuan layanan (`submitted`) di audit log melalui RPC tepercaya.
  - Memeriksa kembali status approved/active layanan pada INSERT booking dan perubahan talent/kategori booking.
  - Memperketat visibilitas profil publik: role Talent, akun aktif, 18+, KTP verified, dan `talent_profiles.is_approved = TRUE` wajib terpenuhi.
  - Menambahkan constraint minimum tarif khusus Rp50.000 untuk penulisan baru (NOT VALID agar data lama tidak menggagalkan deployment; validasi data lama tetap perlu dilakukan terpisah).

### Test dan dokumentasi

- `supabase/tests/stage_e_talent_management_security_tests.sql`
- `supabase/migrations/README.md`

## Pemeriksaan yang dilakukan

- ZIP sumber berhasil diekstrak dan file project dipertahankan.
- 61 file TypeScript/TSX berhasil diparse menggunakan TypeScript transpile (tanpa pemeriksaan tipe penuh); tidak ditemukan diagnostic sintaks.
- Pemeriksaan penuh `tsc --noEmit` belum bisa dilakukan karena dependency `vite/client` tidak tersedia.
- `npm ci --ignore-scripts --prefer-offline` melewati batas waktu; build Vite belum dapat dijalankan.
- Migration 41 belum dijalankan atau divalidasi pada PostgreSQL/Supabase staging.

## Hal yang masih wajib diuji

1. Jalankan migration 41 setelah migration 40 di database staging yang sudah menjalankan migration sebelumnya secara berurutan.
2. Jalankan `stage_e_talent_management_security_tests.sql`.
3. Uji dengan akun Customer, Talent, dan Admin terpisah: pengajuan layanan, review Admin, perubahan harga, toggle aktif, permintaan nama, dan upaya write langsung yang harus ditolak.
4. Uji booking untuk layanan pending, rejected, disabled, inactive, dan approved-active.
5. Jalankan seluruh test suite finansial dan QRIS yang sudah ada; checkpoint ini tidak mengubah alur pembayaran.
6. Jalankan `npm ci`, `npm run lint`, dan `npm run build` di Codespaces dengan koneksi dependency yang tersedia.

**Status rilis: belum siap produksi.** Ini adalah hardening source/migration yang belum diuji terhadap database staging maupun provider pembayaran nyata.
