-- YUKU SOCIAL — Hybrid Talent Management
-- Existing services are grandfathered as approved/active. New service rows are pending.

ALTER TABLE public.talent_services
  ADD COLUMN IF NOT EXISTS approval_status TEXT NOT NULL DEFAULT 'approved'
    CHECK (approval_status IN ('pending','approved','rejected','disabled_by_admin')),
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS review_note TEXT,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Keep all existing live service mappings available; new inserts must be pending.
ALTER TABLE public.talent_services ALTER COLUMN approval_status SET DEFAULT 'pending';
UPDATE public.talent_services
SET approval_status = 'approved', is_active = TRUE
WHERE approval_status IS NULL;

CREATE TABLE IF NOT EXISTS public.talent_service_change_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  talent_service_id UUID NOT NULL REFERENCES public.talent_services(id) ON DELETE CASCADE,
  talent_id UUID NOT NULL REFERENCES public.talent_profiles(id) ON DELETE CASCADE,
  changed_by UUID NOT NULL REFERENCES auth.users(id),
  change_type TEXT NOT NULL CHECK (change_type IN ('activated','deactivated','price_changed','approved','rejected','disabled_by_admin')),
  old_value JSONB,
  new_value JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.talent_identity_change_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  talent_id UUID NOT NULL REFERENCES public.talent_profiles(id) ON DELETE CASCADE,
  field_name TEXT NOT NULL CHECK (field_name IN ('display_name')),
  old_value TEXT,
  requested_value TEXT NOT NULL CHECK (char_length(trim(requested_value)) BETWEEN 2 AND 60),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  review_note TEXT,
  reviewed_by UUID REFERENCES auth.users(id),
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_talent_services_review ON public.talent_services(approval_status, created_at);
CREATE INDEX IF NOT EXISTS idx_talent_identity_requests_status ON public.talent_identity_change_requests(status, created_at);

ALTER TABLE public.talent_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.talent_service_change_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.talent_identity_change_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS talent_services_select_public ON public.talent_services;
DROP POLICY IF EXISTS talent_services_owner_all ON public.talent_services;
DROP POLICY IF EXISTS talent_services_select_scoped ON public.talent_services;
DROP POLICY IF EXISTS talent_services_insert_pending_owner ON public.talent_services;
DROP POLICY IF EXISTS talent_services_admin_update ON public.talent_services;
CREATE POLICY talent_services_select_scoped ON public.talent_services
  FOR SELECT USING ((approval_status = 'approved' AND is_active = TRUE) OR auth.uid() = talent_id OR public.is_admin());
CREATE POLICY talent_services_insert_pending_owner ON public.talent_services
  FOR INSERT WITH CHECK (auth.uid() = talent_id AND approval_status = 'pending' AND is_active = TRUE);
CREATE POLICY talent_services_admin_update ON public.talent_services
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS talent_service_change_log_owner_read ON public.talent_service_change_log;
CREATE POLICY talent_service_change_log_owner_read ON public.talent_service_change_log
  FOR SELECT USING (auth.uid() = talent_id OR public.is_admin());
DROP POLICY IF EXISTS talent_service_change_log_admin_insert ON public.talent_service_change_log;
CREATE POLICY talent_service_change_log_admin_insert ON public.talent_service_change_log
  FOR INSERT WITH CHECK (public.is_admin() OR auth.uid() = talent_id);

DROP POLICY IF EXISTS talent_identity_requests_owner_read ON public.talent_identity_change_requests;
CREATE POLICY talent_identity_requests_owner_read ON public.talent_identity_change_requests
  FOR SELECT USING (auth.uid() = talent_id OR public.is_admin());
DROP POLICY IF EXISTS talent_identity_requests_owner_insert ON public.talent_identity_change_requests;
CREATE POLICY talent_identity_requests_owner_insert ON public.talent_identity_change_requests
  FOR INSERT WITH CHECK (auth.uid() = talent_id AND status = 'pending');
DROP POLICY IF EXISTS talent_identity_requests_admin_update ON public.talent_identity_change_requests;
CREATE POLICY talent_identity_requests_admin_update ON public.talent_identity_change_requests
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

GRANT SELECT, INSERT ON public.talent_services TO authenticated;
GRANT SELECT, INSERT ON public.talent_identity_change_requests TO authenticated;
GRANT SELECT ON public.talent_service_change_log TO authenticated;
GRANT UPDATE ON public.talent_services, public.talent_identity_change_requests TO authenticated;

-- Talent can only change rate / active flag through this guarded RPC.
CREATE OR REPLACE FUNCTION public.update_own_talent_service(
  p_service_id UUID,
  p_is_active BOOLEAN DEFAULT NULL,
  p_custom_rate_override BIGINT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_row public.talent_services%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_row FROM public.talent_services WHERE id = p_service_id AND talent_id = auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Layanan tidak ditemukan'; END IF;
  IF v_row.approval_status <> 'approved' THEN RAISE EXCEPTION 'Layanan belum disetujui Admin'; END IF;
  IF p_custom_rate_override IS NOT NULL AND p_custom_rate_override < 50000 THEN
    RAISE EXCEPTION 'Tarif layanan minimal Rp50.000';
  END IF;
  UPDATE public.talent_services SET
    is_active = COALESCE(p_is_active, is_active),
    custom_rate_override = CASE WHEN p_custom_rate_override IS NULL THEN custom_rate_override ELSE p_custom_rate_override END,
    updated_at = NOW()
  WHERE id = p_service_id;
  INSERT INTO public.talent_service_change_log(talent_service_id,talent_id,changed_by,change_type,old_value,new_value)
  VALUES (v_row.id,v_row.talent_id,auth.uid(),
    CASE WHEN p_is_active IS NOT NULL AND p_is_active <> v_row.is_active THEN CASE WHEN p_is_active THEN 'activated' ELSE 'deactivated' END
         ELSE 'price_changed' END,
    jsonb_build_object('is_active',v_row.is_active,'custom_rate_override',v_row.custom_rate_override),
    jsonb_build_object('is_active',COALESCE(p_is_active,v_row.is_active),'custom_rate_override',COALESCE(p_custom_rate_override,v_row.custom_rate_override)));
END; $$;
REVOKE ALL ON FUNCTION public.update_own_talent_service(UUID,BOOLEAN,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_own_talent_service(UUID,BOOLEAN,BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_talent_service(
  p_service_id UUID, p_decision TEXT, p_note TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_row public.talent_services%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_decision NOT IN ('approved','rejected','disabled_by_admin') THEN RAISE EXCEPTION 'Keputusan tidak valid'; END IF;
  SELECT * INTO v_row FROM public.talent_services WHERE id=p_service_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pengajuan layanan tidak ditemukan'; END IF;
  UPDATE public.talent_services SET approval_status=p_decision,
    is_active=(p_decision='approved'), reviewed_by=auth.uid(), reviewed_at=NOW(), review_note=NULLIF(trim(COALESCE(p_note,'')),''), updated_at=NOW()
  WHERE id=p_service_id;
  INSERT INTO public.talent_service_change_log(talent_service_id,talent_id,changed_by,change_type,old_value,new_value)
  VALUES(v_row.id,v_row.talent_id,auth.uid(),p_decision,jsonb_build_object('approval_status',v_row.approval_status),jsonb_build_object('approval_status',p_decision,'note',p_note));
END; $$;
REVOKE ALL ON FUNCTION public.review_talent_service(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_talent_service(UUID,TEXT,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.request_talent_display_name(p_requested_name TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_old TEXT; v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF char_length(trim(COALESCE(p_requested_name,''))) NOT BETWEEN 2 AND 60 THEN RAISE EXCEPTION 'Nama tampilan harus 2–60 karakter'; END IF;
  SELECT display_name INTO v_old FROM public.talent_profiles WHERE id=auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil Talent tidak ditemukan'; END IF;
  IF EXISTS (SELECT 1 FROM public.talent_identity_change_requests WHERE talent_id=auth.uid() AND field_name='display_name' AND status='pending') THEN
    RAISE EXCEPTION 'Masih ada permintaan perubahan nama yang menunggu Admin';
  END IF;
  INSERT INTO public.talent_identity_change_requests(talent_id,field_name,old_value,requested_value)
  VALUES(auth.uid(),'display_name',v_old,trim(p_requested_name)) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
REVOKE ALL ON FUNCTION public.request_talent_display_name(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_talent_display_name(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_talent_identity_change(p_request_id UUID,p_decision TEXT,p_note TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_req public.talent_identity_change_requests%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF p_decision NOT IN ('approved','rejected') THEN RAISE EXCEPTION 'Keputusan tidak valid'; END IF;
  SELECT * INTO v_req FROM public.talent_identity_change_requests WHERE id=p_request_id FOR UPDATE;
  IF NOT FOUND OR v_req.status <> 'pending' THEN RAISE EXCEPTION 'Permintaan tidak ditemukan atau sudah diproses'; END IF;
  IF p_decision='approved' AND v_req.field_name='display_name' THEN
    UPDATE public.talent_profiles SET display_name=v_req.requested_value,updated_at=NOW() WHERE id=v_req.talent_id;
  END IF;
  UPDATE public.talent_identity_change_requests SET status=p_decision,review_note=NULLIF(trim(COALESCE(p_note,'')),''),reviewed_by=auth.uid(),reviewed_at=NOW() WHERE id=p_request_id;
END; $$;
REVOKE ALL ON FUNCTION public.review_talent_identity_change(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_talent_identity_change(UUID,TEXT,TEXT) TO authenticated;

-- Defense in depth: even SECURITY DEFINER booking RPCs cannot book pending/inactive services.
CREATE OR REPLACE FUNCTION public.enforce_approved_talent_service_for_booking()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.talent_services ts
    JOIN public.activity_categories ac ON ac.id=ts.activity_category_id
    WHERE ts.talent_id=NEW.talent_id AND ts.activity_category_id=NEW.activity_category_id
      AND ts.approval_status='approved' AND ts.is_active=TRUE AND ac.is_active=TRUE
  ) THEN RAISE EXCEPTION 'Layanan Talent belum disetujui atau sedang tidak aktif'; END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_enforce_approved_talent_service_for_booking ON public.bookings;
CREATE TRIGGER trg_enforce_approved_talent_service_for_booking
BEFORE INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.enforce_approved_talent_service_for_booking();

COMMENT ON TABLE public.talent_services IS 'Approved services are visible/bookable; new Talent inserts default to pending and require Admin review.';

CREATE OR REPLACE FUNCTION public.request_talent_service(
  p_activity_category_id VARCHAR(50), p_custom_rate_override BIGINT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_existing public.talent_services%ROWTYPE; v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_custom_rate_override IS NOT NULL AND p_custom_rate_override < 50000 THEN RAISE EXCEPTION 'Tarif khusus minimal Rp50.000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.activity_categories WHERE id=p_activity_category_id AND is_active=TRUE) THEN RAISE EXCEPTION 'Kategori layanan tidak tersedia'; END IF;
  SELECT * INTO v_existing FROM public.talent_services WHERE talent_id=auth.uid() AND activity_category_id=p_activity_category_id FOR UPDATE;
  IF FOUND THEN
    IF v_existing.approval_status IN ('pending','approved') THEN RAISE EXCEPTION 'Layanan ini sudah diajukan atau sudah tersedia'; END IF;
    UPDATE public.talent_services SET approval_status='pending',is_active=TRUE,custom_rate_override=p_custom_rate_override,
      review_note=NULL,reviewed_by=NULL,reviewed_at=NULL,updated_at=NOW() WHERE id=v_existing.id RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.talent_services(talent_id,activity_category_id,custom_rate_override,approval_status,is_active)
    VALUES(auth.uid(),p_activity_category_id,p_custom_rate_override,'pending',TRUE) RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END; $$;
REVOKE ALL ON FUNCTION public.request_talent_service(VARCHAR,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_talent_service(VARCHAR,BIGINT) TO authenticated;
