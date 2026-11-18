-- Tutup otomatis bukti QRIS 'pending_review' saat booking tidak lagi menunggu pembayaran.
-- Aman dijalankan di staging. Jalankan sekali di Supabase SQL Editor.

-- 1) Tambah status baru 'closed' dan longgarkan CHECK:
--    'closed' ditutup oleh sistem, jadi admin_user_id boleh kosong (reviewed_at tetap wajib).
ALTER TABLE public.qris_payment_submissions
  DROP CONSTRAINT IF EXISTS qris_payment_submissions_status_check;
ALTER TABLE public.qris_payment_submissions
  ADD CONSTRAINT qris_payment_submissions_status_check
  CHECK (status = ANY (ARRAY['pending_review','approved','rejected','closed']));

ALTER TABLE public.qris_payment_submissions
  DROP CONSTRAINT IF EXISTS qris_payment_submissions_check;
ALTER TABLE public.qris_payment_submissions
  ADD CONSTRAINT qris_payment_submissions_check
  CHECK (
    (status = 'pending_review' AND admin_user_id IS NULL AND reviewed_at IS NULL)
    OR (status IN ('approved','rejected') AND admin_user_id IS NOT NULL AND reviewed_at IS NOT NULL)
    OR (status = 'closed' AND reviewed_at IS NOT NULL)
  );

-- 2) Fungsi + trigger: saat booking keluar dari 'pending_payment' bukan karena disetujui,
--    bukti yang masih menunggu otomatis ditutup.
CREATE OR REPLACE FUNCTION public.close_qris_submissions_on_booking_inactive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF OLD.status = 'pending_payment'
     AND NEW.status IN ('cancelled_by_customer','cancelled_by_talent','expired') THEN
    UPDATE public.qris_payment_submissions
       SET status = 'closed',
           admin_notes = COALESCE(admin_notes, 'Ditutup otomatis: booking ' || NEW.status::text),
           reviewed_at = NOW()
     WHERE booking_id = NEW.id
       AND status = 'pending_review';

    -- Beri tahu Customer alasannya jika ada bukti yang ikut ditutup.
    -- Dibatalkan sendiri oleh Customer: tidak perlu notifikasi (ia sudah tahu).
    IF FOUND AND NEW.status IN ('expired','cancelled_by_talent') THEN
      PERFORM public.create_in_app_notification(
        NEW.customer_id,
        'Bukti Pembayaran Tidak Diproses',
        'Booking ' || NEW.booking_code || CASE WHEN NEW.status = 'expired'
            THEN ' telah kedaluwarsa'
            ELSE ' dibatalkan oleh Talent' END
          || ', sehingga bukti pembayaran yang Anda kirim tidak diproses. '
          || 'Jika Anda sudah terlanjur membayar, segera hubungi Admin YUKU untuk pengembalian dana.',
        'payment_status'::public.notification_type,
        jsonb_build_object('booking_id', NEW.id, 'booking_code', NEW.booking_code, 'route', '/riwayat-booking')
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_close_qris_submissions_on_booking_inactive ON public.bookings;
CREATE TRIGGER trg_close_qris_submissions_on_booking_inactive
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.close_qris_submissions_on_booking_inactive();

-- 3) Rapikan data lama (bukti yang tertinggal dari booking yang sudah tidak aktif).
UPDATE public.qris_payment_submissions s
   SET status = 'closed',
       admin_notes = COALESCE(s.admin_notes, 'Ditutup otomatis: booking ' || b.status::text),
       reviewed_at = NOW()
  FROM public.bookings b
 WHERE b.id = s.booking_id
   AND s.status = 'pending_review'
   AND b.status IN ('cancelled_by_customer','cancelled_by_talent','expired');

-- 4) Fungsi trigger tidak boleh bisa dipanggil lewat API (/rest/v1/rpc/...).
REVOKE EXECUTE ON FUNCTION public.close_qris_submissions_on_booking_inactive() FROM PUBLIC, anon, authenticated;
