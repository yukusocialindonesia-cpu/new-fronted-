# YUKU SOCIAL — Implementasi Hybrid Talent Management

## Yang ditambahkan

- Tab **Layanan Saya** di Talent Dashboard.
- Talent dapat mengajukan kategori layanan baru; pengajuan berstatus `pending` dan belum tampil/terbookable.
- Layanan yang sudah disetujui dapat diaktifkan/nonaktifkan dan diubah tarif khususnya melalui RPC `update_own_talent_service`.
- Talent dapat mengajukan perubahan nama tampilan; nama baru hanya diterapkan setelah Admin menyetujui.
- Tab **Review Talent** di Admin Dashboard untuk menyetujui/menolak layanan baru, meninjau perubahan nama, menonaktifkan layanan aktif, dan melihat riwayat perubahan layanan.
- Migration 40 mempertahankan layanan lama sebagai `approved` dan `active`.
- RLS membatasi pembacaan publik pada layanan `approved` dan `active`; Talent hanya dapat membaca layanan miliknya.
- Trigger `BEFORE INSERT` pada bookings menolak booking untuk layanan yang belum disetujui, nonaktif, atau kategori yang tidak aktif. Ini menjadi lapisan pengaman tambahan untuk RPC booking SECURITY DEFINER.

## File berubah

- `src/pages/TalentDashboardPage.tsx`
- `src/pages/AdminPage.tsx`
- `supabase/migrations/40_talent_management_hybrid.sql` (baru)
- `supabase/migrations/README.md`

## Aturan perilaku

- Jadwal tetap diatur bebas oleh Talent melalui fitur jadwal yang sudah ada.
- Perubahan layanan dan tarif hanya memengaruhi booking baru. Baris booking lama tidak diperbarui oleh migration ini.
- Nama tampilan memerlukan persetujuan Admin. Nama legal/KTP tidak diubah melalui fitur ini.
- Layanan lama tidak diminta persetujuan ulang.

## Pemasangan

1. Commit/cadangkan branch Codespaces terlebih dahulu.
2. Salin file source yang berubah ke lokasi yang sama.
3. Review `40_talent_management_hybrid.sql`.
4. Terapkan migration pada Supabase **staging** terlebih dahulu.
5. Uji pendaftaran Talent baru, pengajuan layanan, approve/reject Admin, aktif/nonaktif, perubahan tarif, perubahan nama, dan booking pada layanan pending/nonaktif.
6. Baru pertimbangkan penerapan ke production setelah semua tes lulus.

## Batas verifikasi

- Source TSX lolos transpile/syntax check menggunakan TypeScript compiler yang tersedia.
- `npm ci` tidak selesai dalam batas waktu lingkungan ini; karena dependency tidak terpasang, `tsc --noEmit` dan `vite build` belum dapat dijalankan.
- Migration SQL belum dijalankan di PostgreSQL/Supabase. Belum boleh disebut production-ready.
