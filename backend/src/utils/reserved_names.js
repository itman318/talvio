'use strict';

/**
 * Usernames nobody can take (users, groups, channels, bots). People simply see "already taken".
 * Admins can still give one of these to an account from the admin panel; the admin "Reserved usernames"
 * setting adds more on top of this list.
 */
const WORDS = `
admin administrator administration admins root superuser sysadmin webmaster hostmaster postmaster master owner owners
support supports supporter helpdesk help helper helpline helpcenter helpcentre faq faqs contact contactus contacts
info information enquiry inquiry feedback report reports abuse spam security secure safety privacy legal law lawyer
moderator moderators mod mods modteam staff team teams crew official officials verified verify verification
system systems service services server servers status uptime notice notices notification notifications alert alerts
news newsroom update updates announcement announcements broadcast press media blog
account accounts billing payment payments pay payout payouts refund refunds invoice invoices wallet wallets bank banking
finance finances money cash coin coins crypto exchange trade trading premium plus pro vip gold diamond
api apis dev devs developer developers docs documentation sdk app apps application mobile android ios iphone web
bot bots botfather botforge robot official_bot support_bot help_bot admin_bot
test tests tester testing demo example sample null undefined none nobody everyone all here channel channels group groups
user users username usernames member members guest guests anonymous unknown deleted removed banned
talvio talvioapp talvioteam talviosupport talvioofficial talviohelp talvionews talviobot talvioplus tavi tavibot
ceo cto cfo coo founder cofounder director manager president chairman chief executive
customer customers customercare customer_care customerservice customer_service care client clients
police government gov govt ministry army navy airforce military pta fia nadra
pakistan islamabad karachi lahore
google facebook meta whatsapp telegram instagram twitter tiktok snapchat youtube linkedin microsoft apple amazon
netflix paypal stripe visa mastercard jazz jazzcash easypaisa telenor zong ufone sadapay nayapay
login logout signin signup register password passwords reset recovery
home settings setting profile profiles search explore discover trending
`;

const EXACT = new Set(WORDS.split(/\s+/).filter(Boolean));

// look-alikes of staff accounts: "admin_ali", "support_pk", "official.news", "talvio_x"…
const PREFIXES = ['admin', 'support', 'official', 'talvio', 'moderator', 'helpdesk', 'customercare', 'customer_care', 'verified', 'verify', 'security', 'sysadmin'];
const SUFFIXES = ['admin', 'support', 'official', 'moderator', 'helpdesk', 'customercare', 'verified'];

function isReservedName(name) {
  const n = String(name || '').toLowerCase().replace(/^@/, '');
  if (!n) return false;
  if (EXACT.has(n)) return true;
  if (n.includes('talvio')) return true;
  const plain = n.replace(/[_.\d]+$/, '').replace(/^[_.\d]+/, '');
  if (EXACT.has(plain)) return true;
  return PREFIXES.some((p) => n.startsWith(p)) || SUFFIXES.some((s) => n.endsWith(s) || plain.endsWith(s));
}

module.exports = { isReservedName, RESERVED_WORDS: EXACT };
