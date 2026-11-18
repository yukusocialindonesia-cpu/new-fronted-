-- YUKU SOCIAL — Migration 41: Talent Management security hardening
-- Apply after migration 40 on STAGING first. Do not run on production before validation.
-- Direct table writes are removed; all state transitions go through SECURITY DEFINER RPCs.

-- 1) Remove direct client write access to service rows and request/audit tables.
REVOKE ALL PRIVILEGES ON TABLE public.talent_services FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.talent_services TO anon, authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.talent_service_change_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.talent_service_change_log TO authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.talent_identity_change_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.talent_identity_change_requests TO authenticated;

DROP POLICY IF EXISTS talent_services_insert_pending_owner ON public.talent_services;
DROP POLICY IF EXISTS talent_services_admin_update ON public.talent_services;
DROP POLICY IF EXISTS talent_service_change_log_admin_insert ON public.talent_service_change_log;
DROP POLICY IF EXISTS talent_identity_requests_owner_insert ON public.talent_identity_change_requests;
DROP POLICY IF EXISTS talent_identity_requests_admin_update ON public.talent_identity_change_requests;

-- Recreate explicit read policies. No client INSERT/UPDATE/DELETE policy exists.
DROP POLICY IF EXISTS talent_services_select_scoped ON public.talent_services;
CREATE POLICY talent_services_select_scoped ON public.talent_services
  FOR SELECT TO anon, authenticated
  USING (
    (approval_status = 'approved' AND is_active = TRUE)
    OR auth.uid() = talent_id
    OR public.is_admin()
  );

DROP POLICY IF EXISTS talent_service_change_log_owner_read ON public.talent_service_change_log;
CREATE POLICY talent_service_change_log_owner_read ON public.talent_service_change_log
  FOR SELECT TO authenticated
  USING (auth.uid() = talent_id OR public.is_admin());

DROP POLICY IF EXISTS talent_identity_requests_owner_read ON public.talent_identity_change_requests;
CREATE POLICY talent_identity_requests_owner_read ON public.talent_identity_change_requests
  FOR SELECT TO authenticated
  USING (auth.uid() = talent_id OR public.is_admin());

-- 2) Talent may edit ordinary profile fields, but display_name changes only via Admin review RPC.
REVOKE UPDATE ON TABLE public.talent_profiles FROM authenticated;
REVOKE UPDATE (display_name) ON TABLE public.talent_profiles FROM authenticated;
GRANT UPDATE (
  avatar_url, city, gender, headline, bio, hourly_rate, online_chat_rate,
  service_mode, languages, interests, updated_at
) ON TABLE public.talent_profiles TO authenticated;

-- Public profile visibility must require Talent role, active account, 18+,
-- verified KTP, and explicit Admin approval (not only account_status).
CREATE OR REPLACE FUNCTION public.is_talent_publicly_visible(p_talent_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.user_identities ui ON ui.id = u.id
    JOIN public.talent_profiles tp ON tp.id = u.id
    WHERE u.id = p_talent_id
      AND u.role = 'talent'::public.user_role_type
      AND u.account_status = 'active'::public.account_status_type
      AND u.is_verified_18 IS TRUE
      AND ui.ktp_verification_status = 'verified'::public.ktp_status_type
      AND tp.is_approved IS TRUE
  );
$$;
REVOKE ALL ON FUNCTION public.is_talent_publicly_visible(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_talent_publicly_visible(UUID) TO anon, authenticated, service_role;

-- 3) Enforce a minimum service override in the database for all future writes.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'talent_services_custom_rate_min_check'
      AND conrelid = 'public.talent_services'::regclass
  ) THEN
    ALTER TABLE public.talent_services
      ADD CONSTRAINT talent_services_custom_rate_min_check
      CHECK (custom_rate_override IS NULL OR custom_rate_override >= 50000) NOT VALID;
  END IF;
END $$;

-- 4) Add a submission event to the audit history, then replace request RPC.
ALTER TABLE public.talent_service_change_log
  DROP CONSTRAINT IF EXISTS talent_service_change_log_change_type_check;
ALTER TABLE public.talent_service_change_log
  ADD CONSTRAINT talent_service_change_log_change_type_check
  CHECK (change_type IN ('submitted','activated','deactivated','price_changed','approved','rejected','disabled_by_admin'));

-- Require Talent role and an existing profile; only rejected requests can be resubmitted.
-- Admin-disabled services cannot be re-enabled by Talent.
CREATE OR REPLACE FUNCTION public.request_talent_service(
  p_activity_category_id VARCHAR(50),
  p_custom_rate_override BIGINT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_existing public.talent_services%ROWTYPE;
  v_id UUID;
  v_old_status TEXT := 'new';
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'talent'::public.user_role_type
  ) THEN
    RAISE EXCEPTION 'Hanya akun Talent yang dapat mengajukan layanan';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.talent_profiles tp WHERE tp.id = auth.uid()) THEN
    RAISE EXCEPTION 'Profil Talent belum tersedia';
  END IF;
  IF p_activity_category_id IS NULL OR trim(p_activity_category_id) = '' THEN
    RAISE EXCEPTION 'Kategori layanan wajib dipilih';
  END IF;
  IF p_custom_rate_override IS NOT NULL AND p_custom_rate_override < 50000 THEN
    RAISE EXCEPTION 'Tarif khusus minimal Rp50.000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.activity_categories ac
    WHERE ac.id = p_activity_category_id AND ac.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Kategori layanan tidak tersedia';
  END IF;

  SELECT * INTO v_existing
  FROM public.talent_services
  WHERE talent_id = auth.uid() AND activity_category_id = p_activity_category_id
  FOR UPDATE;

  IF FOUND THEN
    v_old_status := v_existing.approval_status;
    IF v_existing.approval_status <> 'rejected' THEN
      RAISE EXCEPTION 'Layanan ini sudah diajukan, tersedia, atau dinonaktifkan Admin';
    END IF;
    UPDATE public.talent_services
    SET approval_status = 'pending', is_active = TRUE,
        custom_rate_override = p_custom_rate_override,
        review_note = NULL, reviewed_by = NULL, reviewed_at = NULL,
        updated_at = NOW()
    WHERE id = v_existing.id
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.talent_services(
      talent_id, activity_category_id, custom_rate_override, approval_status, is_active
    ) VALUES (
      auth.uid(), p_activity_category_id, p_custom_rate_override, 'pending', TRUE
    ) RETURNING id INTO v_id;
  END IF;

  INSERT INTO public.talent_service_change_log(
    talent_service_id, talent_id, changed_by, change_type, old_value, new_value
  ) VALUES (
    v_id, auth.uid(), auth.uid(), 'submitted',
    jsonb_build_object('approval_status', v_old_status),
    jsonb_build_object('approval_status', 'pending', 'activity_category_id', p_activity_category_id)
  );
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.request_talent_service(VARCHAR, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_talent_service(VARCHAR, BIGINT) TO authenticated;

-- Atomic onboarding: all selected services are submitted in one transaction.
CREATE OR REPLACE FUNCTION public.request_talent_services(
  p_activity_category_ids VARCHAR(50)[],
  p_custom_rate_override BIGINT DEFAULT NULL
) RETURNS UUID[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_category_id VARCHAR(50);
  v_ids UUID[] := ARRAY[]::UUID[];
  v_id UUID;
BEGIN
  IF p_activity_category_ids IS NULL OR cardinality(p_activity_category_ids) = 0 THEN
    RAISE EXCEPTION 'Pilih minimal satu layanan';
  END IF;
  IF cardinality(p_activity_category_ids) > 30 THEN
    RAISE EXCEPTION 'Jumlah layanan melebihi batas';
  END IF;
  IF (SELECT count(*) FROM unnest(p_activity_category_ids)) <>
     (SELECT count(DISTINCT category_id) FROM unnest(p_activity_category_ids) AS x(category_id)) THEN
    RAISE EXCEPTION 'Daftar layanan mengandung kategori duplikat';
  END IF;
  FOREACH v_category_id IN ARRAY p_activity_category_ids LOOP
    v_id := public.request_talent_service(v_category_id, p_custom_rate_override);
    v_ids := array_append(v_ids, v_id);
  END LOOP;
  RETURN v_ids;
END;
$$;
REVOKE ALL ON FUNCTION public.request_talent_services(VARCHAR[], BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_talent_services(VARCHAR[], BIGINT) TO authenticated;

-- 5) Guard service update RPC against non-Talent callers and empty/no-op requests.
CREATE OR REPLACE FUNCTION public.update_own_talent_service(
  p_service_id UUID,
  p_is_active BOOLEAN DEFAULT NULL,
  p_custom_rate_override BIGINT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_row public.talent_services%ROWTYPE;
  v_change_type TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'talent'::public.user_role_type
  ) THEN RAISE EXCEPTION 'Hanya akun Talent yang dapat mengubah layanan'; END IF;
  IF p_is_active IS NULL AND p_custom_rate_override IS NULL THEN
    RAISE EXCEPTION 'Tidak ada perubahan layanan yang dikirim';
  END IF;
  IF p_custom_rate_override IS NOT NULL AND p_custom_rate_override < 50000 THEN
    RAISE EXCEPTION 'Tarif layanan minimal Rp50.000';
  END IF;

  SELECT * INTO v_row
  FROM public.talent_services
  WHERE id = p_service_id AND talent_id = auth.uid()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Layanan tidak ditemukan'; END IF;
  IF v_row.approval_status <> 'approved' THEN
    RAISE EXCEPTION 'Hanya layanan yang sudah disetujui Admin yang dapat diubah';
  END IF;
  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_row.is_active
     AND p_custom_rate_override IS NULL THEN
    v_change_type := CASE WHEN p_is_active THEN 'activated' ELSE 'deactivated' END;
  ELSE
    v_change_type := 'price_changed';
  END IF;

  UPDATE public.talent_services SET
    is_active = COALESCE(p_is_active, is_active),
    custom_rate_override = COALESCE(p_custom_rate_override, custom_rate_override),
    updated_at = NOW()
  WHERE id = p_service_id;

  INSERT INTO public.talent_service_change_log(
    talent_service_id, talent_id, changed_by, change_type, old_value, new_value
  ) VALUES (
    v_row.id, v_row.talent_id, auth.uid(), v_change_type,
    jsonb_build_object('is_active', v_row.is_active, 'custom_rate_override', v_row.custom_rate_override),
    jsonb_build_object(
      'is_active', COALESCE(p_is_active, v_row.is_active),
      'custom_rate_override', COALESCE(p_custom_rate_override, v_row.custom_rate_override)
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.update_own_talent_service(UUID, BOOLEAN, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_own_talent_service(UUID, BOOLEAN, BIGINT) TO authenticated;

-- 6) Validate Admin decisions against current service state; log writes remain server-side.
CREATE OR REPLACE FUNCTION public.review_talent_service(
  p_service_id UUID, p_decision TEXT, p_note TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_row public.talent_services%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected', 'disabled_by_admin') THEN
    RAISE EXCEPTION 'Keputusan tidak valid';
  END IF;
  SELECT * INTO v_row FROM public.talent_services WHERE id = p_service_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pengajuan layanan tidak ditemukan'; END IF;
  IF p_decision IN ('approved', 'rejected') AND v_row.approval_status NOT IN ('pending', 'disabled_by_admin', 'rejected') THEN
    RAISE EXCEPTION 'Layanan tidak berada pada status yang dapat ditinjau';
  END IF;
  IF p_decision = 'disabled_by_admin' AND v_row.approval_status <> 'approved' THEN
    RAISE EXCEPTION 'Hanya layanan yang disetujui yang dapat dinonaktifkan Admin';
  END IF;

  UPDATE public.talent_services SET
    approval_status = p_decision,
    is_active = (p_decision = 'approved'),
    reviewed_by = auth.uid(), reviewed_at = NOW(),
    review_note = NULLIF(trim(COALESCE(p_note, '')), ''), updated_at = NOW()
  WHERE id = p_service_id;

  INSERT INTO public.talent_service_change_log(
    talent_service_id, talent_id, changed_by, change_type, old_value, new_value
  ) VALUES (
    v_row.id, v_row.talent_id, auth.uid(), p_decision,
    jsonb_build_object('approval_status', v_row.approval_status, 'is_active', v_row.is_active),
    jsonb_build_object('approval_status', p_decision, 'is_active', (p_decision = 'approved'), 'note', p_note)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.review_talent_service(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_talent_service(UUID, TEXT, TEXT) TO authenticated;

-- 7) Display-name requests are created only by RPC, and only a Talent can request them.
CREATE OR REPLACE FUNCTION public.request_talent_display_name(p_requested_name TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_old TEXT;
  v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.role = 'talent'::public.user_role_type
  ) THEN RAISE EXCEPTION 'Hanya akun Talent yang dapat mengajukan perubahan nama'; END IF;
  IF char_length(trim(COALESCE(p_requested_name, ''))) NOT BETWEEN 2 AND 60 THEN
    RAISE EXCEPTION 'Nama tampilan harus 2–60 karakter';
  END IF;
  SELECT tp.display_name INTO v_old
  FROM public.talent_profiles tp WHERE tp.id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil Talent tidak ditemukan'; END IF;
  IF trim(p_requested_name) = COALESCE(v_old, '') THEN
    RAISE EXCEPTION 'Nama tampilan sama dengan nama saat ini';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.talent_identity_change_requests r
    WHERE r.talent_id = auth.uid() AND r.field_name = 'display_name' AND r.status = 'pending'
  ) THEN RAISE EXCEPTION 'Masih ada permintaan perubahan nama yang menunggu Admin'; END IF;
  INSERT INTO public.talent_identity_change_requests(
    talent_id, field_name, old_value, requested_value
  ) VALUES (auth.uid(), 'display_name', v_old, trim(p_requested_name))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.request_talent_display_name(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_talent_display_name(TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.review_talent_identity_change(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_talent_identity_change(UUID, TEXT, TEXT) TO authenticated;

-- 8) Defense-in-depth: make sure these write RPCs are SECURITY DEFINER with locked search_path.


-- 9) Re-check service eligibility on booking inserts and any later reassignment.
CREATE OR REPLACE FUNCTION public.enforce_approved_talent_service_for_booking()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.talent_services ts
    JOIN public.activity_categories ac ON ac.id = ts.activity_category_id
    WHERE ts.talent_id = NEW.talent_id
      AND ts.activity_category_id = NEW.activity_category_id
      AND ts.approval_status = 'approved'
      AND ts.is_active = TRUE
      AND ac.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Layanan Talent belum disetujui atau sedang tidak aktif';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_enforce_approved_talent_service_for_booking ON public.bookings;
CREATE TRIGGER trg_enforce_approved_talent_service_for_booking
BEFORE INSERT OR UPDATE OF talent_id, activity_category_id ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.enforce_approved_talent_service_for_booking();
REVOKE ALL ON FUNCTION public.enforce_approved_talent_service_for_booking() FROM PUBLIC, anon, authenticated;
