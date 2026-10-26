'use strict';

/**
 * Built-in texts for Terms, Privacy Policy, FAQ and About. They show until an admin edits a page
 * (Admin → Pages & FAQ). Format the app understands:
 *   "# Heading", "## Subheading", "• bullet" lines, "Q: …" followed by "A: …" (FAQ), blank line = new paragraph.
 */
const UPDATED = '26 October 2026';

const privacy = `Last updated: ${UPDATED}

This Privacy Policy explains what information Talvio collects, why we collect it, how we protect it and the choices you have. It applies to the Talvio app for Android, the Talvio web app and our website (together, "Talvio" or "the service"). By using Talvio you agree to this policy.

We built Talvio to be useful without collecting more than it needs. We do not sell your personal data, and we never use the content of your messages to show you ads.

# 1. Information you give us

## Account information
• Phone number or email address — used to create your account and to log you in with a one-time code.
• Name, optional username, bio, birthday and profile photo — you choose what to add and who can see it.
• Two-step verification password (optional) — stored only as a secure hash, never in readable form.
• Passkeys (optional) — your phone keeps the private key; we only store the public part.

## Your messages and media
• Regular chats, groups and channels are stored on our servers so they stay in sync on all your devices and you can log in on a new phone without losing them. They travel over encrypted connections.
• Vault chats (secret chats) are end-to-end encrypted. Only you and the other person hold the keys. Our servers pass on encrypted data they cannot read and delete it once it is delivered.
• Photos, videos, voice messages and files you send are stored so the people in the chat can open them.
• "View once" media can be opened one time by the recipient and is then no longer available to them.
• Messages you delete "for everyone" are removed from our servers. Clearing a chat history removes it for you (or for both sides when you choose that option).

## Contacts (optional)
If you allow access to your contacts, Talvio compares phone numbers from your address book with Talvio accounts so you can see which of your contacts use Talvio. We use them for this matching and to keep your contact list in Talvio up to date. You can turn off who can find you by your number in Settings → Privacy.

## Location (optional)
Talvio only uses your location when you choose to:
• share a location or live location in a chat (shared with that chat only, for the time you pick), or
• use Prayer times — the location is used on your phone to calculate times and is not sent to other people.

## Payments
If Talvio Plus is offered and you buy it, we keep the order, plan, amount, currency, status and, for manual payments, the receipt you upload. Card and mobile-wallet details are entered with the payment provider (for example JazzCash or Easypaisa); we never see or store them.

## Support requests
When you contact support we keep your messages, any screenshots you attach and, if you allow it, your phone model and app version.

# 2. Information collected automatically
• Devices and sessions: device name, platform, app version, IP address, and when each device was last active — so you can see and log out your devices (Settings → Devices).
• Login activity: successful logins and blocked attempts, to protect your account and to alert you about new logins.
• Push notification token: an identifier from Google Firebase Cloud Messaging that lets us wake your phone when a message arrives.
• Online status and "last seen": shown to others according to your privacy settings.
• Crash reports and error logs: technical details that help us fix problems. They do not include the content of your messages.

# 3. How we use information
• To provide the service: create your account, deliver messages, calls and notifications, and sync your chats.
• To keep Talvio safe: detect spam, scams and abuse, enforce our Terms, review reports and protect users.
• To support you: answer your requests and fix problems.
• To improve Talvio: understand which features work well and where the app crashes, using technical data rather than the content of your chats.
• To communicate with you: login codes, security alerts and important service notices.
• To meet legal obligations.

# 4. Calls
Voice and video calls connect directly between devices when possible. When a direct connection is not possible, the call is relayed through our relay server. Calls are encrypted in transit and are not recorded.

# 5. Bots, channels and groups
• Public channels and groups can be seen by anyone, including their posts, member counts and public links.
• When you send a message to a bot or use it in a group, that bot's owner receives what you send to it. Bots are made by other people, not by Talvio, so only use bots you trust.
• Group and channel admins can see what members post and can manage the group according to the rights they were given.

# 6. Sponsored messages
Public channels with many subscribers may show clearly labelled sponsored messages. They are chosen by channel topic, not by your private messages, contacts or personal profile.

# 7. Who we share information with
We do not sell or rent your personal data. We share information only:
• With service providers who help us run Talvio, under obligations to protect it: our hosting provider (servers in the European Union), Google Firebase (push notifications), our email/SMS delivery provider (login codes) and payment providers.
• With the people you choose to communicate with, and in public groups and channels with their members and viewers.
• When required by law, a court order or a valid request from authorities, and only to the extent required.
• To protect the rights, safety and property of our users, the public or Talvio, for example to stop fraud or threats.
• If Talvio is reorganised or transferred, in which case this policy continues to apply to your information.

# 8. How long we keep information
• Your messages and media stay until you or the other side delete them, or until your account is deleted.
• If you do not use Talvio for the period you choose (12 months by default, Settings → Privacy & security), your account and its data are deleted automatically.
• Devices you have not used for a set time (6 months by default) are logged out automatically.
• Login records, reports and moderation records are kept for as long as they are needed for security and legal reasons, then deleted.
• Backups you make with Chat backup are stored in your own Google Drive or on your phone, not on our servers.

# 9. Your choices and rights
• See and change your profile at any time.
• Control who can see your phone number, photo, last seen, bio and birthday, who can call you, add you to groups and find you by your number (Settings → Privacy).
• Turn notifications on or off and hide message text on the lock screen (Settings → Notifications).
• See all logged-in devices and log any of them out (Settings → Devices).
• Lock the app or individual chats with a PIN or fingerprint.
• Ask for a copy of your data or correct it by contacting support.
• Delete your account at any time (Settings → Delete my account). This removes your profile, your messages and your memberships from our servers. Messages you sent in groups may remain visible to members as "Deleted Account".

# 10. Security
We use encrypted connections (HTTPS/TLS) between the app and our servers, end-to-end encryption for vault chats, hashed passwords and login codes, limits against brute-force attempts, two-step verification, passkeys, login alerts and automatic logout of inactive devices. No system is perfectly secure, so please keep your phone locked, do not share login codes with anyone (Talvio staff will never ask for them) and turn on two-step verification.

# 11. Children
Talvio is not meant for children under 13. If you are under the age required by the law of your country to agree to this policy on your own, you may use Talvio only with permission from a parent or guardian. If we learn that a child under 13 has an account, we will delete it.

# 12. International use
Our servers are located in the European Union. If you use Talvio from another country, your information is transferred to and processed there, protected as described in this policy.

# 13. Changes to this policy
We may update this policy as Talvio changes. We will post the new version here and update the date at the top. For important changes we will also tell you in the app.

# 14. Contact us
For any question about privacy or this policy, contact us from the app: Settings → Help & support.`;

const terms = `Last updated: ${UPDATED}

Welcome to Talvio. These Terms of Service ("Terms") are an agreement between you and Talvio ("we", "us") and apply to the Talvio app, web app, website and any related services. Please read them carefully. By creating an account or using Talvio you agree to these Terms and to our Privacy Policy. If you do not agree, please do not use Talvio.

# 1. Who can use Talvio
• You must be at least 13 years old, or older if the law of your country requires it.
• You must give a phone number or email address that belongs to you and keep your login codes and passwords private.
• You are responsible for everything done with your account. Tell us right away if you think someone else has access to it.
• You may not use Talvio if we have previously banned you, or if the law forbids you from using it.

# 2. Your account
• One person may run several accounts (up to the limit shown in the app), but you may not create accounts to get around a ban or limit.
• Usernames must not impersonate another person, brand or Talvio staff. Some names are reserved and cannot be taken.
• We may reclaim usernames that are inactive, misleading or that infringe someone's rights.

# 3. Acceptable use
You agree not to use Talvio to:
• send spam, bulk unsolicited messages, chain messages or automated messages without the recipients' consent;
• scam, defraud or mislead people, including fake investment, trading, lottery or job offers;
• harass, bully, threaten, stalk or intimidate anyone, or encourage violence or self-harm;
• share content that sexualises minors, non-consensual intimate images, or content that exploits or endangers children in any way;
• promote terrorism or violent extremism, or sell illegal goods, weapons or drugs;
• share malware, phishing links or anything designed to damage devices or steal information;
• impersonate other people, organisations or Talvio, or misrepresent your identity;
• collect other users' personal data, scrape the service, or access it with unauthorised tools;
• attack, overload, reverse-engineer or interfere with Talvio, its servers or its security;
• break any law or infringe anyone's rights, including copyright and trademarks.

# 4. Your content
• You own what you send. You give Talvio a limited, worldwide licence to store, process and deliver your content only to provide the service (for example to deliver a message, show it on your other devices or make a public post visible).
• You are responsible for the content you send and for having the right to share it.
• Content in public groups and channels can be seen, forwarded and saved by others.

# 5. Groups, channels and bots
• Owners and admins are responsible for their groups and channels, for the rules they set and for the content they publish.
• Admins may only use the tools Talvio gives them for managing their communities, not to harass members.
• If you create a bot, you are responsible for what it does, for keeping its key secret, and for handling the messages it receives in line with the law and our Privacy Policy. You must tell users what data your bot collects.

# 6. Safety, reports and enforcement
• You can report users, messages, groups, channels and bots from inside the app.
• We review reports and may remove content, limit features, restrict sending messages, suspend groups or channels, or ban accounts that break these Terms — with or without notice, depending on how serious the case is.
• If your account is banned you can send an appeal from the app. We review appeals in good faith.
• We may report illegal activity to the authorities and cooperate with lawful requests.

# 7. Talvio Plus and payments
• Talvio is free to use. Talvio Plus (when available) adds optional extra features for a fee, described in the app with its price in your currency.
• Payments are handled by the payment methods shown in the app. Your plan starts when payment is confirmed.
• Unless the law requires otherwise, payments are not refundable once the plan has started. If a payment was taken but Plus did not start, contact support and we will fix it.
• We may change prices or features of Plus for future periods; we will not change a plan you have already paid for.

# 8. Sponsored messages
Some public channels may show clearly labelled sponsored messages. Advertisers must follow our advertising rules and the law; Talvio may remove any sponsored message.

# 9. Third-party services
Talvio works with other services, such as Google Firebase for notifications, Google Drive for your own backups, payment providers and bots or mini apps made by other people. Their own terms and privacy policies apply to them, and we are not responsible for them.

# 10. Availability and changes
We work hard to keep Talvio fast and available, but we cannot promise it will always be uninterrupted or error-free. We may change, add or remove features, and may need to pause the service for maintenance. Please keep backups of anything important.

# 11. Intellectual property
Talvio, its name, logo, Tavi the mascot, design and software belong to us and are protected by law. You may not copy, modify or reuse them without our written permission, except as allowed by these Terms.

# 12. Disclaimers
Talvio is provided "as is" and "as available". To the fullest extent allowed by law, we make no warranties of any kind, express or implied, including fitness for a particular purpose. We do not check every message, and we are not responsible for content sent by users, groups, channels or bots. Trading signals, investment advice or offers you see in chats or channels come from other users, not from Talvio — always do your own research.

# 13. Limitation of liability
To the fullest extent allowed by law, Talvio will not be liable for indirect, incidental, special or consequential damages, loss of profits, data or goodwill, arising from your use of the service. Our total liability for any claim is limited to the amount you paid us for Talvio Plus in the 12 months before the claim, or PKR 5,000 if you paid nothing. Nothing in these Terms limits liability that cannot be limited by law.

# 14. Ending your use
You can stop using Talvio and delete your account at any time from Settings. We may suspend or end your access if you break these Terms, if the law requires it, or to protect users or the service. Sections that by their nature should continue (for example content licences needed to finish delivering messages, disclaimers and limitation of liability) continue after your account ends.

# 15. Governing law and disputes
These Terms are governed by the laws of Pakistan. Before going to court, please contact us so we can try to resolve the problem informally. Any dispute that cannot be resolved this way will be handled by the competent courts of Pakistan, unless the law of your country gives you the right to bring a claim where you live.

# 16. Changes to these Terms
We may update these Terms from time to time. We will post the new version here and change the date at the top, and tell you in the app about important changes. If you keep using Talvio after the changes take effect, you accept the new Terms.

# 17. Contact
Questions about these Terms? Contact us from the app: Settings → Help & support.`;

const faq = `# Getting started

Q: How do I create an account?
A: Open Talvio, enter your phone number (or choose "Continue with email"), then type the one-time code we send you. Add your name and, if you like, a photo — that's it.

Q: Why didn't my login code arrive?
A: Check that the number or email is correct, wait a minute and tap "Resend". For email, look in your Spam or Promotions folder. Never share your code with anyone — Talvio staff will never ask for it.

Q: Can I use Talvio on more than one device?
A: Yes. Your regular chats sync on all your devices. To log in on a computer, open the Talvio web app and scan the QR code from Settings → Devices. You can see and log out any device there.

Q: Can I have more than one account?
A: Yes. Go to Settings → Add another account. You can switch between accounts in one tap.

# Chats and messages

Q: How do I edit or delete a message?
A: Tap the message to open its menu, then choose Edit or Delete. When you delete, you can remove it for yourself or for everyone in the chat.

Q: How do I clear a chat for both of us?
A: Open the chat → ⋮ menu → Clear history, and tick "Also clear for …". In groups, only admins who can delete messages can clear the history for everyone.

Q: What does "view once" mean?
A: A photo, video or voice message sent as "view once" can be opened one time by the other person and then disappears for them. Use the "1" button before sending.

Q: How do I know someone listened to my voice message?
A: The small microphone under your voice message turns blue when it has been played.

Q: Can I schedule a message?
A: Yes. Type your message, then hold the Send button and pick a time.

Q: How do I send several photos together?
A: Tap 📎 → Gallery and select up to 10 photos. You can look through them, edit any of them, remove or add more and write a caption before sending them as one album.

Q: What is Read later?
A: Tap any message → Read later to save it. Find everything you saved in Settings → Read later, on all your devices.

# Groups and channels

Q: What is the difference between a group and a channel?
A: In a group everyone can talk. In a channel only admins post and subscribers read, comment (if comments are on) and react.

Q: How do I add admins or moderators?
A: Open the group or channel → Manage → Admins & moderators → Add admin or moderator. Pick a ready set (Moderator, Editor, Full admin) or switch each right on or off. They can only do what you allow.

Q: How do I protect my group from spam?
A: Open Manage → Group protection to turn on the human check for new members, anti-flood, link blocking and a list of blocked words. You can also use slow mode and approve new members.

Q: How do I make my group or channel public?
A: As the owner, open Manage → Public link and choose a @username. Anyone can then find and join it.

# Calls

Q: Are calls free?
A: Yes. Voice and video calls use your internet connection (Wi-Fi or mobile data); Talvio does not charge for them.

Q: What is a voice chat?
A: A live audio room inside a group or channel that many people can join at once. Admins can start one from the chat menu.

# Privacy and security

Q: Who can see my phone number?
A: You decide in Settings → Privacy → Phone number: everybody, only your contacts or nobody. The same goes for your photo, last seen, bio and birthday.

Q: Are my messages encrypted?
A: All messages travel over encrypted connections. Vault chats are also end-to-end encrypted, so only you and the other person can read them — not even Talvio.

Q: How do I protect my account?
A: Turn on Two-step verification and a Passkey, lock the app with a PIN or fingerprint, and check Settings → Security checkup for quick tips. You will get an alert whenever someone logs in to your account.

Q: How do I block or report someone?
A: Open their profile and tap Block, or Report. You can also report any message from its menu. Blocked people cannot message or call you.

# Notifications

Q: I'm not getting notifications. What can I do?
A: Make sure notifications are allowed for Talvio in your phone's settings and in Settings → Notifications. On many phones (Xiaomi, Oppo, Vivo, Infinix, Tecno) also allow Talvio to run in the background / turn off battery optimisation for it. Check that the chat is not muted.

Q: Can I hide message text on the lock screen?
A: Yes. Settings → Notifications → turn off "Show message text". You will only see who sent a message.

# Bots

Q: What are bots and how do I make one?
A: Bots are small programs that chat with people — for news, tools, signals, support and more. Create one in Settings → My bots or by chatting with BotForge. You get a key to use with the Talvio Bot API on your own server.

# Data and storage

Q: Talvio is using a lot of storage or data. What can I do?
A: Open Settings → Data & storage to clear the cache, choose what downloads automatically on Wi-Fi and mobile data, and turn on Data saver.

Q: How do I back up my chats?
A: Settings → Chat backup saves a copy to your Google Drive or your phone that you can restore later.

Q: Talvio doesn't work on my network. What can I do?
A: You can connect through a proxy: Settings → Proxy → Add proxy, or open a proxy link someone shared with you.

# Account

Q: How do I delete my account?
A: Settings → Delete my account. Your profile, messages and memberships are removed. This cannot be undone.

Q: My account was banned. What can I do?
A: If you think it was a mistake, try to log in and tap "Appeal" to tell us what happened. We review every appeal.

Q: How do I contact support?
A: Settings → Help & support → New request. Add a screenshot if it helps — we reply right there in the app.`;

const about = `# Talvio — talk, share, belong

Talvio is a fast, secure messaging app made for everyday conversations and growing communities. Chat one-to-one, talk in groups, follow channels, make voice and video calls and build bots — all in one clean, friendly app.

# What you can do
• Chats: text, photos, videos, files, voice messages and video notes, with replies, reactions, editing and scheduled messages.
• Groups: communities with admins and moderators, granular rights, topics, polls, slow mode and strong spam protection.
• Channels: broadcast to unlimited subscribers with views, comments, reactions and post approvals.
• Calls: free voice and video calls, plus live voice chats in groups and channels.
• Vault chats: end-to-end encrypted conversations only you and the other person can read.
• Stories and highlights: share moments with the people you choose.
• Bots and BotForge: create bots, connect them with the Talvio Bot API and reach people in chats and inline.
• Tavi: our own animated mascot and stickers, made just for Talvio.
• Prayer times with Qibla, Suhoor and Iftar reminders.

# Privacy first
You decide who sees your phone number, photo and last seen. Your account is protected with two-step verification, passkeys, login alerts and app lock. We never sell your data and never read your chats to show ads.

# Built for everyone
Talvio works well on any phone and any connection: it is light on data, supports proxies and keeps working on slow networks. It is available on Android and on the web.

# Contact
Questions, ideas or problems? We'd love to hear from you: Settings → Help & support.

Thank you for being part of Talvio. 💜`;

module.exports = {
  privacy: { title: 'Privacy Policy', body: privacy },
  terms: { title: 'Terms of Service', body: terms },
  faq: { title: 'Frequently Asked Questions', body: faq },
  about: { title: 'About Talvio', body: about },
};
