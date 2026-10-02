// Set verified production URLs only after seller onboarding and release signing.
export const release = {
  downloadURL: import.meta.env.VITE_DOWNLOAD_URL || '',
  accountURL: import.meta.env.VITE_ACCOUNT_URL || '',
  supportEmail: import.meta.env.VITE_SUPPORT_EMAIL || '',
};
