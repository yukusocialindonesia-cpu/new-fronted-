-- Optimasi RLS: bungkus auth.uid() dan is_admin() dengan (SELECT ...) agar dihitung
-- satu kali per query, bukan per baris. Perilaku akses TIDAK berubah.
-- Sudah diterapkan ke yuku-staging; file ini agar repo sama dengan database.

ALTER POLICY booking_messages_update_read_recipient ON public.booking_messages
  USING (
    sender_id <> (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = booking_messages.booking_id
        AND (b.customer_id = (SELECT auth.uid()) OR b.talent_id = (SELECT auth.uid()))
    )
  )
  WITH CHECK (
    sender_id <> (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.id = booking_messages.booking_id
        AND (b.customer_id = (SELECT auth.uid()) OR b.talent_id = (SELECT auth.uid()))
    )
  );

ALTER POLICY customer_cancellation_case_customer_or_admin_select ON public.customer_cancellation_cases
  USING (customer_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

ALTER POLICY qris_submissions_read_owner_or_admin ON public.qris_payment_submissions
  USING (customer_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));
