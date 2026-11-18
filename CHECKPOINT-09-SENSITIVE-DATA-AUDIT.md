# YUKU SOCIAL — Checkpoint 09: Audit Data Sensitif (NIK, KTP, Rekening)

Tanggal audit: 17 November 2026  
Basis audit: `YUKU-2.0-SECURITY-HARDENED.zip`  
Status: **AUDIT STATIS SELESAI — PERBAIKAN BELUM DITERAPKAN**

> Dokumen ini tidak menyatakan sistem sudah aman/production-ready. Audit ini membaca migrasi, RLS, Storage, dan pemanggilan Supabase dari frontend. Migrasi belum dijalankan pada database staging.

## 1. Ringkasan temuan

| Area | Yang ditemukan | Risiko / tindak lanjut |
|---|---|---|
| NIK dan identitas legal | `user_identities` memuat `ktp_number`, nama legal, tanggal lahir, path KTP, alasan penolakan, dan kontak darurat. SELECT dibatasi RLS ke pemilik atau Admin. | Pembatasan baris sudah ada, tetapi seluruh kolom tetap dapat dibaca oleh pemilik/Admin. Belum ada pemisahan kolom sensitif atau enkripsi kolom aplikasi. |
| Foto KTP & selfie | Bucket `ktp-documents` dibuat private, batas 5 MB, tipe JPEG/PNG/WebP. Storage SELECT hanya pemilik folder atau Admin; INSERT dibatasi prefix UID. | Dasar privasi baik. Perlu uji langsung signed URL, akses UID lain, nama file/path, MIME spoofing, file size, dan akses Admin. Tidak ditemukan kebijakan UPDATE/DELETE eksplisit pada cuplikan migrasi; perilaku final perlu diverifikasi dari database staging. |
| Rekening payout | `payout_requests` menyimpan `bank_account_number` dan `bank_account_holder_name` sebagai kolom teks biasa. SELECT RLS untuk Talent pemilik atau Admin. | Tidak terlihat ke publik melalui policy yang ada, tetapi Talent dan Admin membaca nomor rekening penuh. Belum ada enkripsi kolom atau masking UI. |
| Akses frontend Talent | `TalentDashboardPage.tsx` membaca kolom rekening penuh pada riwayat payout dan mengirim nomor rekening langsung saat INSERT payout. | Data rekening tersedia di browser Talent sendiri. Ubah ke RPC server-side dan tampilkan rekening tersamarkan setelah migrasi kompatibel. |
| Akses frontend Admin | `AdminPage.tsx` membaca `user_identities` untuk antrean verifikasi dan `payout_requests` untuk proses payout; UI menampilkan NIK dan rekening penuh. | Admin berwenang memang perlu verifikasi, tetapi akses baca/lihat data sensitif belum tampak dicatat secara terpisah per tindakan. Tambahkan audit log akses PII dan pembatasan peran Admin/Finance. |
| Pendaftaran Talent / KTP | `BecomeTalentPage.tsx` menulis ke `user_identities`; `VerifyKtpPage.tsx` membaca dan mengubah data identitas langsung dari client. | Alur langsung client membuat perubahan enkripsi server-side tidak bisa dipasang hanya dengan menambah kolom. Harus migrasi bertahap ke RPC/Edge Function dan perbarui semua pemanggil. |

## 2. Kontrol yang memang sudah ada

1. `user_identities` memiliki RLS `user_identities_owner_or_admin_select`, `...insert`, dan `...update`.
2. `payout_requests` memiliki RLS SELECT untuk `talent_id = auth.uid()` atau Admin, dan INSERT hanya untuk Talent pemilik.
3. Bucket KTP bersifat private; Storage policy memeriksa UID pada folder pertama path.
4. Trigger identitas melindungi perubahan status verifikasi dan membatasi perubahan legal identity pada status tertentu.
5. `is_admin()` mengambil role dari `public.users`, bukan dari metadata signup yang dikirim pengguna.

Kontrol tersebut berguna, tetapi RLS bukan enkripsi. RLS juga tidak menggantikan audit akses Admin.

## 3. Temuan prioritas

### P0 — Nomor rekening dan NIK masih plaintext di tabel

Skema `user_identities.ktp_number`, `payout_requests.bank_account_number`, dan `bank_account_holder_name` belum menggunakan enkripsi tingkat kolom aplikasi. Enkripsi storage/database milik penyedia tidak sama dengan enkripsi kolom yang kuncinya terpisah.

**Rencana aman:** gunakan enkripsi sisi server dengan kunci rahasia di Supabase Vault/secret manager, bukan di React, bukan di `VITE_*`, dan bukan disimpan bersama ciphertext. Simpan ciphertext, versi kunci, serta fingerprint/HMAC terpisah untuk kebutuhan pencocokan unik NIK. Jangan membuat indeks UNIQUE langsung atas ciphertext acak.

### P0 — Frontend masih membaca/menulis langsung kolom sensitif

File yang perlu dimigrasikan bersama-sama:
- `src/pages/BecomeTalentPage.tsx`
- `src/pages/VerifyKtpPage.tsx`
- `src/pages/AdminPage.tsx`
- `src/pages/TalentDashboardPage.tsx`
- `src/types/database.ts`

Jangan mencabut GRANT SELECT/INSERT/UPDATE sebelum seluruh pemanggil diganti RPC/Edge Function; hal itu akan memutus verifikasi dan payout.

### P1 — Audit akses data sensitif belum memadai

Tabel `admin_audit_logs` sudah ada dalam skema, tetapi audit ini belum menemukan alur yang konsisten mencatat setiap pembukaan NIK/foto KTP/rekening oleh Admin. Log harus dibuat server-side dan tidak boleh dapat dimanipulasi/dihapus oleh client. Catat actor, target user/payout, jenis data, tindakan, waktu, dan alasan/tiket; hindari menyalin NIK/rekening mentah ke log.

### P1 — Masking dan minimisasi data di UI

- Talent hanya perlu melihat nama bank, 3–4 digit terakhir rekening, jumlah dan status payout pada riwayat.
- Admin Finance dapat membuka detail rekening melalui tindakan eksplisit yang dicatat.
- Admin verifikasi KTP hanya membuka NIK/foto saat menangani antrean, bukan memuat semua NIK secara default.
- Jangan mengirim seluruh objek identitas ke state frontend jika hanya status yang dibutuhkan.

## 4. Rencana implementasi bertahap

1. Buat migrasi baru khusus data sensitif; jangan mengubah migrasi lama yang sudah menjadi riwayat.
2. Tambahkan struktur ciphertext + key version + HMAC/fingerprint untuk NIK dan rekening. Pastikan strategi rotasi kunci dan constraint unik dipikirkan sebelum backfill.
3. Buat RPC/Edge Function terotorisasi untuk submit identitas, mengambil status verifikasi, mengambil detail KTP Admin, membuat permintaan payout, mengambil riwayat payout tersamarkan, dan mengambil detail rekening oleh Finance.
4. Perbarui empat halaman frontend di atas dan tipe database; hilangkan select/insert langsung untuk kolom sensitif.
5. Setelah semua pemanggil berpindah dan tes lolos, cabut GRANT kolom sensitif dari `authenticated`; jangan mencabut akses sebelum itu.
6. Tambahkan audit log server-side untuk akses Admin/Finance dan kebijakan retensi.
7. Uji role matrix: anon, customer lain, pemilik, Talent lain, Admin verifikasi, Admin Finance, service role.
8. Backfill/enkripsi data hanya setelah backup, uji pemulihan, dan rencana rollback tersedia.

## 5. Tes wajib sebelum dianggap selesai

- User A tidak dapat membaca identitas, foto KTP, atau rekening User B.
- Customer tidak dapat membaca data Talent; Talent tidak dapat membaca data Talent lain.
- Anon/public API tidak dapat membaca tabel identitas atau payout.
- Pemilik hanya menerima status verifikasi dan rekening tersamarkan di layar umum.
- Admin yang tidak berwenang tidak dapat membuka rekening/NIK; akses Finance dan Verifikasi dipisah sesuai role.
- Setiap pembukaan detail PII oleh Admin menghasilkan audit log server-side.
- Signed URL KTP berumur pendek; URL tidak dapat dipakai setelah kedaluwarsa dan tidak bocor ke log publik.
- Input NIK/rekening tidak muncul di console, analytics, error tracking, atau log aplikasi.
- Uji signup, verifikasi KTP, review Admin, request payout, penolakan payout, dan payout selesai tidak merusak ledger/saldo.
- Build TypeScript/Vite, migrasi staging, dan SQL security tests seluruhnya lulus.

## 6. Batas audit

- Tidak ada koneksi ke Supabase staging/production pada audit ini.
- Tidak ada SQL migration yang dieksekusi.
- Tidak ada data KTP/NIK/rekening asli yang digunakan.
- Tidak dilakukan klaim bahwa enkripsi atau audit log sudah aktif.

**Keputusan:** jangan aktifkan produksi atau masukkan data identitas/rekening nyata sebelum P0 dan tes role matrix diselesaikan.
