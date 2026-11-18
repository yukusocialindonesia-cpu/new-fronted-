# CHECKPOINT 10 — Sensitive Data Remediation (Pre-Implementation)

Date: 2026-11-17
Base: YUKU-2.0-clean / security-hardened source snapshot
Status: AUDIT CONFIRMED; implementation and database deployment NOT yet performed.

## Confirmed frontend access paths

1. `src/pages/VerifyKtpPage.tsx`
   - Reads `user_identities.ktp_number` directly from the browser (loadIdentityData).
   - Uploads KTP/selfie directly to the private `ktp-documents` bucket.
   - Writes identity data directly to `user_identities` (submission flow).
   - This is not yet compatible with column-level encryption or removing direct table access.

2. `src/pages/BecomeTalentPage.tsx`
   - Writes legal identity fields and `ktp_number` directly to `user_identities`.
   - Must be moved to a server-side submission RPC/Edge Function before restricting grants.

3. `src/pages/TalentDashboardPage.tsx`
   - Reads identity metadata directly from `user_identities`.
   - Reads `bank_account_number` and `bank_account_holder_name` from `payout_requests` for its own history.
   - Inserts full bank details directly into `payout_requests`.
   - Displays the full account number in payout history.

4. `src/pages/AdminPage.tsx`
   - Reads payout rows with `.select('*')` from `payout_requests` (over-fetches sensitive columns).
   - Reads KTP identity rows including `ktp_number` directly from `user_identities`.
   - Admin role currently appears to be a single broad role in the existing UI/database model; separate Verification and Finance permissions are not yet implemented.

## Database schema findings

- `supabase/migrations/01_initial_schema_and_enums.sql`: `user_identities.ktp_number` is a regular `VARCHAR(30)` column.
- `supabase/migrations/04_financial_ledgers_and_referrals.sql`: payout bank account number and holder name are regular columns on `payout_requests`.
- `supabase/migrations/08_grant_additional_features.sql`: authenticated users receive SELECT on `payout_requests` and INSERT column grants including bank details. RLS is therefore a key boundary; column-level grants and RPC transition need to be coordinated.
- `supabase/migrations/09_admin_management_rpcs.sql` and `18_security_and_payout_guardrails.sql`: existing payout/identity workflows depend on current schema and must be preserved while migrating.
- Migrations 01–41 exist in this snapshot. No sensitive-data encryption migration has been added or executed.

## Required remediation sequence (do not skip)

### Phase A — Access model
- Introduce explicit capabilities for `admin_verification` and `admin_finance` (or an equivalent trusted role/permission mapping).
- Never trust a frontend role flag or user-editable JWT metadata as authorization. Resolve permissions from protected database records/functions.
- Add append-only audit events for privileged reads of identity documents and bank account details (actor, subject, purpose, timestamp, request correlation ID; never log the secret values themselves).

### Phase B — Server-side data access
- Create authenticated submission functions for identity/KTP and payout requests.
- Create narrow read functions: owner sees their own status and masked account number; Verification staff can access only the minimum KTP fields/documents required; Finance staff can access payout details only for payout processing.
- Replace the direct browser table reads/writes in the four files listed above.
- Remove `.select('*')` from Admin payout loading and use a fixed, non-sensitive projection for list views.

### Phase C — Encryption and storage
- Choose and document a key-management method before encrypting existing data. Preferred: application-level encryption in a trusted server/Edge Function using a secret stored outside the repository and outside browser environment variables, with key versioning and rotation plan.
- Never place encryption keys in `VITE_*`, frontend bundles, SQL migration literals, Git, or downloadable ZIPs.
- Add encrypted columns and a backfill/verification procedure. Preserve old columns until ciphertext is verified and all readers/writers have migrated; only then remove direct access and later retire plaintext columns under a separately reviewed migration.
- Consider keyed HMAC/deterministic lookup for duplicate-NIK checks; do not create a plain hash of NIK because the input space is predictable.
- Keep KTP/selfie objects in a private bucket, enforce owner/authorized-role access, short-lived signed URLs, MIME/size validation, and audit privileged access.

### Phase D — Validation
- Test owner A cannot read owner B identity or payout details.
- Test Talent cannot read another Talent's payout details.
- Test Verification Admin cannot access bank account details; Finance Admin cannot access KTP/NIK unless explicitly required and separately authorized.
- Test ordinary Admin/customer/Talent cannot invoke privileged RPCs.
- Test KTP submission, rejection/resubmission, talent onboarding, payout request, payout review, and payout history end-to-end.
- Run migrations only on a new staging Supabase project first; verify backups and rollback plan before production.

## Release blockers

- No Supabase staging project credentials or schema state are available in this work session; migration compatibility cannot be verified against a live database.
- The frontend still uses direct reads/writes listed above. Revoking grants now would break identity and payout flows.
- No encryption key has been provisioned; generating or embedding one in this source archive would be unsafe.
- Build, integration tests, RLS tests against Supabase, and real role-boundary tests remain outstanding.

## Safety decision

This checkpoint intentionally does not add a partial encryption migration or revoke existing grants. A partial change could lock users out of KTP verification or corrupt payout processing while leaving plaintext data behind. Proceed with a coordinated frontend + SQL + server-function migration on staging.
