-- Stage E: static privilege assertions for Talent Management hardening (migration 41).
-- Run after migrations 01-41 on a dedicated staging database.
DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.talent_services', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL: authenticated still has direct INSERT on talent_services';
  END IF;
  IF has_table_privilege('authenticated', 'public.talent_services', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: authenticated still has direct UPDATE on talent_services';
  END IF;
  IF has_table_privilege('authenticated', 'public.talent_services', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: authenticated still has direct DELETE on talent_services';
  END IF;
  IF has_table_privilege('authenticated', 'public.talent_service_change_log', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL: authenticated can forge service audit-log rows';
  END IF;
  IF has_table_privilege('authenticated', 'public.talent_identity_change_requests', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL: authenticated can directly forge identity change requests';
  END IF;
  IF has_table_privilege('authenticated', 'public.talent_identity_change_requests', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can directly update identity review requests';
  END IF;
  IF has_column_privilege('authenticated', 'public.talent_profiles', 'display_name', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can directly change talent display_name';
  END IF;
  IF NOT has_function_privilege('anon', 'public.is_talent_publicly_visible(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: public visibility helper is not executable by anon';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.request_talent_service(character varying, bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: Talent service request RPC is not executable by authenticated';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.request_talent_services(character varying[], bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: atomic onboarding service RPC is not executable by authenticated';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.review_talent_service(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: Admin review RPC is not executable by authenticated';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.request_talent_display_name(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: display-name request RPC is not executable by authenticated';
  END IF;
  RAISE NOTICE 'PASS: Stage E privilege assertions completed';
END $$;
