import React, { useEffect, useState } from 'react';
import { MailCheck } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { translateAuthError } from '../../lib/authErrors';

const COOLDOWN_SECONDS = 60;

interface ResendConfirmationProps {
  email: string;
  /** Mulai cooldown langsung (dipakai setelah pendaftaran, karena email baru saja terkirim). */
  startCooldown?: boolean;
}

export const ResendConfirmation: React.FC<ResendConfirmationProps> = ({
  email,
  startCooldown = false,
}) => {
  const [cooldown, setCooldown] = useState(startCooldown ? COOLDOWN_SECONDS : 0);
  const [sending, setSending] = useState(false);
  const [info, setInfo] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    if (cooldown <= 0) return;
    const timer = setTimeout(() => setCooldown((c) => c - 1), 1000);
    return () => clearTimeout(timer);
  }, [cooldown]);

  const handleResend = async () => {
    if (!email || sending || cooldown > 0) return;
    setSending(true);
    setInfo('');
    setError('');
    try {
      const { error: resendError } = await supabase.auth.resend({
        type: 'signup',
        email: email.trim(),
      });
      if (resendError) {
        setError(translateAuthError(resendError));
      } else {
        setInfo(`Email konfirmasi dikirim ulang ke ${email.trim()}. Cek inbox dan folder Spam.`);
        setCooldown(COOLDOWN_SECONDS);
      }
    } catch (err: any) {
      setError(translateAuthError(err));
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="space-y-2">
      <button
        type="button"
        onClick={handleResend}
        disabled={sending || cooldown > 0 || !email}
        className="w-full py-2.5 border border-purple-300 text-purple-800 bg-purple-50 hover:bg-purple-100 font-bold text-xs rounded-xl transition-all flex items-center justify-center gap-2 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
      >
        <MailCheck className="w-4 h-4" />
        <span>
          {sending
            ? 'Mengirim...'
            : cooldown > 0
            ? `Kirim ulang email konfirmasi (${cooldown}d)`
            : 'Kirim ulang email konfirmasi'}
        </span>
      </button>
      {info && <p className="text-[11px] text-emerald-700 leading-relaxed">{info}</p>}
      {error && <p className="text-[11px] text-rose-700 leading-relaxed">{error}</p>}
    </div>
  );
};
