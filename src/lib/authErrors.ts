export type AuthErrorLike = { message?: string; code?: string; status?: number } | null | undefined;

export const isEmailNotConfirmed = (error: AuthErrorLike): boolean => {
  if (!error) return false;
  if (error.code === 'email_not_confirmed') return true;
  return /email not confirmed/i.test(error.message || '');
};

/** Terjemahkan error Supabase Auth ke pesan Bahasa Indonesia yang ramah. */
export const translateAuthError = (error: AuthErrorLike): string => {
  if (!error) return 'Terjadi kesalahan. Silakan coba lagi.';
  const message = error.message || '';

  if (isEmailNotConfirmed(error)) {
    return 'Email kamu belum dikonfirmasi. Cek inbox (dan folder Spam) lalu klik link konfirmasi dari YUKU.';
  }
  if (error.code === 'invalid_credentials' || /invalid login credentials/i.test(message)) {
    return 'Email atau kata sandi salah. Periksa kembali penulisan email kamu, atau gunakan "Lupa kata sandi".';
  }
  if (error.code === 'over_email_send_rate_limit' || /rate limit|too many/i.test(message)) {
    return 'Terlalu banyak percobaan. Tunggu beberapa saat lalu coba lagi.';
  }
  if (error.code === 'user_already_exists' || /already registered/i.test(message)) {
    return 'Email ini sudah terdaftar. Silakan masuk, atau konfirmasi emailnya jika belum.';
  }
  return message || 'Terjadi kesalahan. Silakan coba lagi.';
};
