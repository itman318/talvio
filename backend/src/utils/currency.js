'use strict';

/** Country → currency for Talvio Plus prices, and how to show amounts. */
const EURO = ['DE', 'FR', 'IT', 'ES', 'NL', 'BE', 'AT', 'IE', 'PT', 'FI', 'GR', 'SK', 'SI', 'LT', 'LV', 'EE', 'LU', 'MT', 'CY', 'HR'];
const BY_COUNTRY = {
  PK: 'PKR', US: 'USD', GB: 'GBP', AE: 'AED', SA: 'SAR', IN: 'INR', BD: 'BDT', CA: 'CAD', AU: 'AUD', TR: 'TRY', MY: 'MYR',
  ...Object.fromEntries(EURO.map((c) => [c, 'EUR'])),
};
const SYMBOL = { PKR: 'Rs ', USD: '$', EUR: '€', GBP: '£', AED: 'AED ', SAR: 'SAR ', INR: '₹', BDT: '৳', CAD: 'CA$', AUD: 'A$', TRY: '₺', MYR: 'RM ' };

// calling codes → country (longest prefix wins)
const CALLING = [
  ['+92', 'PK'], ['+1', 'US'], ['+44', 'GB'], ['+971', 'AE'], ['+966', 'SA'], ['+91', 'IN'], ['+880', 'BD'], ['+61', 'AU'],
  ['+90', 'TR'], ['+60', 'MY'], ['+49', 'DE'], ['+33', 'FR'], ['+39', 'IT'], ['+34', 'ES'], ['+31', 'NL'], ['+32', 'BE'],
  ['+43', 'AT'], ['+353', 'IE'], ['+351', 'PT'], ['+358', 'FI'], ['+30', 'GR'],
].sort((a, b) => b[0].length - a[0].length);

function countryFromPhone(phone) {
  if (!phone) return null;
  const hit = CALLING.find(([p]) => String(phone).startsWith(p));
  return hit ? hit[1] : null;
}

/** "en-US,en;q=0.9" or "en_US" → "US" */
function countryFromLocale(raw) {
  const m = String(raw || '').match(/[-_]([A-Za-z]{2})\b/);
  return m ? m[1].toUpperCase() : null;
}

function currencyFor(country) {
  return BY_COUNTRY[String(country || '').toUpperCase()] || 'USD';
}

function format(amount, currency) {
  const n = Number(amount);
  const whole = Number.isInteger(n) || n >= 1000;
  const text = whole ? Math.round(n).toLocaleString('en-US') : n.toFixed(2);
  return `${SYMBOL[currency] || `${currency} `}${text}`;
}

module.exports = { countryFromPhone, countryFromLocale, currencyFor, format };
