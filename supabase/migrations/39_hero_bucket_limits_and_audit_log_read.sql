-- MIGRATION 39: batas bucket 'hero' + akses baca admin_audit_logs untuk Admin.
-- Sudah diterapkan ke yuku-staging sebagai 'yuku_39_hero_bucket_limits_and_audit_log_read'
-- (17 Nov 2026). Idempoten; aman dijalankan ulang. Bergantung pada migration 38 dan public.is_admin().

-- 1) Batasi bucket 'hero' seperti bucket gambar lainnya.
UPDATE storage.buckets
SET file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp']
WHERE id = 'hero';

-- 2) Admin dapat membaca admin_audit_logs. Non-admin tetap tidak melihat baris apa pun.
GRANT SELECT ON public.admin_audit_logs TO authenticated;

DROP POLICY IF EXISTS "admin_audit_logs_select_admin" ON public.admin_audit_logs;
CREATE POLICY "admin_audit_logs_select_admin" ON public.admin_audit_logs
  FOR SELECT TO authenticated
  USING ((SELECT public.is_admin()));
