'use strict';

/**
 * Built-in texts for Terms, Privacy Policy, FAQ and About. They show until an admin edits a page
 * (Admin → Pages & FAQ). Format the app understands:
 *   "# Heading", "## Subheading", "• bullet" lines, "Q: …" followed by "A: …" (FAQ), blank line = new paragraph.
 */
const UPDATED = '13 November 2026';

const privacy = `Last updated: ${UPDATED}

This Privacy Policy explains what information Hushavia collects, why we collect it, how we protect it and the choices you have. It applies to the Hushavia app for Android, the Hushavia web app and our website (together, "Hushavia" or "the service"). By using Hushavia you agree to this policy.

We built Hushavia to be useful without collecting more than it needs. We do not sell your personal data, and we never use the content of your messages to show you ads.

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
If you allow access to your contacts, Hushavia compares phone numbers from your address book with Hushavia accounts so you can see which of your contacts use Hushavia. We use them for this matching and to keep your contact list in Hushavia up to date. You can turn off who can find you by your number in Settings → Privacy.

## Location (optional)
Hushavia only uses your location when you choose to:
• share a location or live location in a chat (shared with that chat only, for the time you pick), or
• use Prayer times — the location is used on your phone to calculate times and is not sent to other people.

## Payments
If you buy Hushavia Plus or Hushavia Coins, we keep the order, what was bought, the amount, currency and status. For a payment made with USDT we also keep the public transaction ID and the network, so we can confirm it on the blockchain. For manual payments we keep the receipt you upload. Card and mobile-wallet details, where those methods are offered, are entered with the payment provider; we never see or store them.

## Hushavia Wallet
The wallet is non-custodial. Your 12-word recovery phrase and your private keys are created and kept only on your phone, protected by the phone's secure storage. They are never sent to Hushavia, and we cannot see, copy or restore them.
• We do not keep your wallet balances or your list of transactions.
• If you switch on "share my addresses", the public addresses you choose are stored so the people you chat with can pay you. You can switch this off at any time.
• A crypto card you send in a chat (amount, coin, address, transaction ID) is stored like any other message.
• To show balances, prices and to send transactions, your phone talks directly to public blockchain services (for example TronGrid, public network nodes, mempool.space, BlockCypher and CoinGecko). Those services can see your IP address and the public addresses you ask about. Blockchains are public: anyone can see the transactions of an address.

## Hushavia Coins
We keep your coin balance and a record of every change to it (deposits and packs bought, gifts and tips sent or received and with whom, channel subscriptions, giveaway entries and prizes, coins spent, adjustments by our team), so the balance is always correct and disputes can be checked.
• Your deposit address: when you open "Add coins", we create your own USDT address and remember that it is yours. We read the public blockchain to see the USDT that arrives at it, and keep each deposit's transaction ID, amount and time. Anyone can see the payments to an address on the blockchain.
• Giveaways: if you join one, the channel's admins and members can see the winners' names when it ends.
• Paid channels: the channel's owner receives your coins for the subscription; we keep when it started and ends.

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
• To keep Hushavia safe: detect spam, scams and abuse, enforce our Terms, review reports and protect users.
• To support you: answer your requests and fix problems.
• To improve Hushavia: understand which features work well and where the app crashes, using technical data rather than the content of your chats.
• To communicate with you: login codes, security alerts and important service notices.
• To meet legal obligations.

# 4. Calls
Voice and video calls connect directly between devices when possible. When a direct connection is not possible, the call is relayed through our relay server. Calls are encrypted in transit and are not recorded.

# 5. Bots, channels and groups
• Public channels and groups can be seen by anyone, including their posts, member counts and public links.
• When you send a message to a bot or use it in a group, that bot's owner receives what you send to it. Bots are made by other people, not by Hushavia, so only use bots you trust.
• Group and channel admins can see what members post and can manage the group according to the rights they were given.

# 6. Sponsored messages
Public channels with many subscribers may show clearly labelled sponsored messages. They are chosen by channel topic, not by your private messages, contacts or personal profile.

# 7. Who we share information with
We do not sell or rent your personal data. We share information only:
• With service providers who help us run Hushavia, under obligations to protect it: our hosting provider (servers in the European Union), Google Firebase (push notifications), our email/SMS delivery provider (login codes) and payment providers. Payments in USDT are read from the public blockchain; no personal data is sent with them.
• With the people you choose to communicate with, and in public groups and channels with their members and viewers.
• When required by law, a court order or a valid request from authorities, and only to the extent required.
• To protect the rights, safety and property of our users, the public or Hushavia, for example to stop fraud or threats.
• If Hushavia is reorganised or transferred, in which case this policy continues to apply to your information.

# 8. How long we keep information
• Your messages and media stay until you or the other side delete them, or until your account is deleted.
• If you do not use Hushavia for the period you choose (12 months by default, Settings → Privacy & security), your account and its data are deleted automatically.
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
We use encrypted connections (HTTPS/TLS) between the app and our servers, end-to-end encryption for vault chats, hashed passwords and login codes, limits against brute-force attempts, two-step verification, passkeys, login alerts and automatic logout of inactive devices. No system is perfectly secure, so please keep your phone locked, do not share login codes with anyone (Hushavia staff will never ask for them) and turn on two-step verification.

# 11. Children
Hushavia is not meant for children under 13. If you are under the age required by the law of your country to agree to this policy on your own, you may use Hushavia only with permission from a parent or guardian. If we learn that a child under 13 has an account, we will delete it.

# 12. International use
Our servers are located in the European Union. If you use Hushavia from another country, your information is transferred to and processed there, protected as described in this policy.

# 13. Changes to this policy
We may update this policy as Hushavia changes. We will post the new version here and update the date at the top. For important changes we will also tell you in the app.

# 14. Contact us
For any question about privacy or this policy, contact us from the app: Settings → Help & support.`;

const terms = `Last updated: ${UPDATED}

Welcome to Hushavia. These Terms of Service ("Terms") are an agreement between you and Hushavia ("we", "us") and apply to the Hushavia app, web app, website and any related services. Please read them carefully. By creating an account or using Hushavia you agree to these Terms and to our Privacy Policy. If you do not agree, please do not use Hushavia.

# 1. Who can use Hushavia
• You must be at least 13 years old, or older if the law of your country requires it.
• To use the Hushavia Wallet, buy or use Hushavia Coins, or pay for Hushavia Plus, you must be at least 18 years old (or the age of majority where you live).
• You must give a phone number or email address that belongs to you and keep your login codes and passwords private.
• You are responsible for everything done with your account. Tell us right away if you think someone else has access to it.
• You may not use Hushavia if we have previously banned you, or if the law forbids you from using it.

# 2. Your account
• One person may run several accounts (up to the limit shown in the app), but you may not create accounts to get around a ban or limit.
• Usernames must not impersonate another person, brand or Hushavia staff. Some names are reserved and cannot be taken.
• We may reclaim usernames that are inactive, misleading or that infringe someone's rights.

# 3. Acceptable use
You agree not to use Hushavia to:
• send spam, bulk unsolicited messages, chain messages or automated messages without the recipients' consent;
• scam, defraud or mislead people, including fake investment, trading, crypto, lottery or job offers, or asking anyone for their wallet recovery phrase, login code or password;
• harass, bully, threaten, stalk or intimidate anyone, or encourage violence or self-harm;
• share content that sexualises minors, non-consensual intimate images, or content that exploits or endangers children in any way;
• promote terrorism or violent extremism, or sell illegal goods, weapons or drugs;
• share malware, phishing links or anything designed to damage devices or steal information;
• impersonate other people, organisations or Hushavia, or misrepresent your identity;
• collect other users' personal data, scrape the service, or access it with unauthorised tools;
• attack, overload, reverse-engineer or interfere with Hushavia, its servers or its security;
• break any law or infringe anyone's rights, including copyright and trademarks.

# 4. Your content
• You own what you send. You give Hushavia a limited, worldwide licence to store, process and deliver your content only to provide the service (for example to deliver a message, show it on your other devices or make a public post visible).
• You are responsible for the content you send and for having the right to share it.
• Content in public groups and channels can be seen, forwarded and saved by others.

# 5. Groups, channels and bots
• Owners and admins are responsible for their groups and channels, for the rules they set and for the content they publish.
• Admins may only use the tools Hushavia gives them for managing their communities, not to harass members.
• If you create a bot, you are responsible for what it does, for keeping its key secret, and for handling the messages it receives in line with the law and our Privacy Policy. You must tell users what data your bot collects.

# 6. Safety, reports and enforcement
• You can report users, messages, groups, channels and bots from inside the app.
• We review reports and may remove content, limit features, restrict sending messages, suspend groups or channels, or ban accounts that break these Terms — with or without notice, depending on how serious the case is.
• If your account is banned you can send an appeal from the app. We review appeals in good faith.
• We may report illegal activity to the authorities and cooperate with lawful requests.

# 7. Hushavia Plus and payments
• Hushavia is free to use. Hushavia Plus (when available) adds optional extra features for a fee. Prices are shown in the app in US dollars (USD) unless the app shows another currency.
• You can pay with the methods shown in the app: USDT sent from your Hushavia Wallet, Hushavia Coins, or another method we offer where you live. Your plan starts when the payment is confirmed.
• A USDT payment must be sent from the payment screen, for exactly the amount and to exactly the address shown for your order, on the network you chose. A payment with a different amount, on a different network, in a different token or sent long after the order may not be matched automatically; contact support and we will check it, but we cannot promise to recover money sent in a way the app did not ask for.
• Network fees are charged by the blockchain, not by Hushavia, and are not refundable.
• Unless the law requires otherwise, payments are not refundable once the plan has started. If a payment was taken but Plus did not start, contact support and we will fix it.
• We may change prices or features of Plus for future periods; we will not change a plan you have already paid for.

# 8. Hushavia Wallet
The Hushavia Wallet is a non-custodial wallet: a tool on your phone that lets you hold and send supported cryptocurrencies yourself. Hushavia is not a bank, an exchange, a broker or a payment institution, and never holds your crypto for you.

## Your 12 words are your wallet
• When you create a wallet the app shows a 12-word recovery phrase. These words are the only key to your funds.
• The phrase and your private keys are stored only on your phone. Hushavia does not have them, cannot see them and cannot give them back to you.
• Write the 12 words down and keep them somewhere safe and private. Do not keep them in a screenshot, a chat, a note or an email.
• Never share them with anyone. Hushavia, its staff and its support team will never ask for your recovery phrase — not in a chat, by email or by phone. Anyone who asks for it is trying to steal from you.
• If you lose your phone, delete the app or remove the wallet and you do not have your 12 words, your funds are lost for good. Nobody, including Hushavia, can recover them.
• Anyone who gets your 12 words, or your unlocked phone, can take everything in the wallet.

## Your transactions are your responsibility
• You alone decide and confirm every transaction. Hushavia cannot see, approve, stop, freeze, reverse or refund a transaction.
• Transactions on a blockchain are final. Crypto sent to a wrong address, on a wrong network or to a scammer cannot be returned.
• Always check the address, the network and the amount before you confirm. The warnings the app shows (first-time address, look-alike address, scam warnings) are a help, not a guarantee.
• Network fees are set by each blockchain and can change at any moment. A transaction may be slow, or fail, when a network is busy or you do not hold enough of its coin for the fee.
• Prices and charts come from third-party data and may be late or wrong. Nothing in Hushavia is financial, investment, legal or tax advice. Crypto prices can fall sharply; you can lose all the money you put in.
• Custom tokens you add yourself are not checked by Hushavia. A token can be worthless or built to deceive.

## What Hushavia is not responsible for
To the fullest extent allowed by law, Hushavia is not responsible or liable for any loss caused by:
• a lost, forgotten, stolen, copied or shared recovery phrase, phone or screen lock;
• a transaction sent to a wrong address or network, or sent to a person who deceived you;
• delays, failures, fees, forks, attacks or changes on any blockchain network, or problems with the third-party services the wallet connects to;
• changes in the price or availability of any coin or token;
• malware, a modified copy of the app, or a phone that has been rooted or tampered with.

## Following the law
• You are responsible for knowing and following the laws that apply to you, including rules on holding or sending crypto and paying any tax you owe.
• You may not use the wallet for anything illegal, including fraud, money laundering, financing of terrorism or avoiding sanctions.
• We may switch the wallet feature on or off in the app, or limit it in some countries. Because the wallet is non-custodial, your funds stay on the blockchain and can always be reached with your 12 words in any compatible wallet app.

## Crypto in chats
You can send a crypto payment or a payment request as a card in a chat. The card is only a message: the payment itself happens on the blockchain between your wallet and the other person's address. Hushavia is not a party to payments between users and does not settle disputes about them. A card that shows "confirmed" means the app found that transaction on the network; it does not mean the other person will deliver what they promised.

# 9. Hushavia Coins
• Hushavia Coins are a digital balance for use only inside Hushavia. They are not money, not a cryptocurrency or token, not a deposit and not an investment, and they earn no interest.

## Getting coins
• Deposit: in Coins → "Add coins" you get your own USDT address on BNB Smart Chain (BEP-20). USDT that arrives there is turned into coins at the rate shown in the app (now 1 USDT = 100 coins) after the network confirms it.
• Only USDT on BNB Smart Chain counts. Other coins, tokens or networks sent to that address are lost and cannot be returned. Deposits below the minimum shown in the app give no coins.
• If an exchange or wallet takes a fee from the amount, you get coins for what actually arrives.
• Card: where offered, coin packs can be bought by card on a payment page run by Stripe. Hushavia never sees or stores your card number. Coins arrive when Stripe confirms the payment; a charge that is reversed or disputed removes the coins it gave.
• You can also get coins as a gift from another user, as a tip or subscription income, as a giveaway prize, or from Hushavia. Bonus coins are free extras and have no cash value.

## Using coins
• You can pay for Hushavia Plus with coins, send gifts in private chats, tip channel posts, subscribe to paid channels and start giveaways.
• Gifts and tips go to the other person or channel and cannot be taken back.
• Tips and channel subscriptions: the channel's owner receives the share shown in the app (now 90%); the rest is Hushavia's fee.
• Paid channels: the price is set by the channel's owner, not by Hushavia. A subscription lasts 30 days and renews from your balance; if your balance is too low, it ends and you leave the channel. Hushavia does not check or guarantee what a channel posts — choose channels you trust.
• Giveaways: the prize coins are taken from the creator when the giveaway starts. Winners are picked at random by the app among people who joined and are still members when it ends. Prizes nobody could win go back to the creator. Giveaways must not be used for gambling, selling entries or anything illegal.

## Rules
• Coins cannot be withdrawn, exchanged for money or crypto, or sold or traded outside Hushavia. Buying and selling coins or accounts for money outside the app is not allowed.
• Deposits, purchases and anything paid for with coins are final and not refundable, unless the law requires otherwise.
• If your account is banned for breaking these Terms, or you delete it, the coins in it are lost. We may remove coins that were obtained by fraud, a mistake, a bug or a reversed payment.
• We may change the coin rate and the coin price of things in the app for the future, and we may end the coins feature. If we end it we will tell you in the app at least 30 days before, so you can use your coins.

# 10. Sponsored messages and advertising
• Public channels with enough subscribers may show one clearly labelled sponsored message at the end. Hushavia Plus members see no ads. Ads are chosen by the channel's topic and the viewer's country — never by the content of private messages.
• Anyone 18 or older can advertise in Settings → Advertise. You pay in coins: the budget is held when you make the ad, each counted view costs your price per 1,000 views, and unspent coins come back when the ad ends, is stopped or is not approved. A person is counted at most once per ad per day.
• Every ad is reviewed before it runs and may be removed at any time. Not allowed: scams and fake offers, investment or trading promises, gambling, adult content, weapons, drugs, hate, misleading claims, copying another brand, and anything illegal where it is shown. You are responsible for your ad, your link and what you offer.
• Channel owners earn the share shown in the app (now 50%) of the coins spent on views in their channel — once the channel is monetized — and can turn ads off in the channel's settings.

## Channel monetization
• A channel earns (ad share, tips, paid subscription) only after its owner turns on monetization, which is possible when the channel meets the requirements shown in the app (for example a minimum number of subscribers, the age of the channel and of the owner's account, regular posts, two-step verification, and no limits on the channel or account).
• We may turn monetization off and remove earnings obtained by fake subscribers or views, scams, stolen or illegal content, or by breaking these Terms. A suspended channel does not earn.
• Hushavia does not promise a number of views, clicks or sales. Coins spent on views that were shown are not refunded.

# 11. Third-party services
Hushavia works with other services, such as Google Firebase for notifications, Google Drive for your own backups, payment providers, public blockchain networks and the data services the wallet reads them through, and bots or mini apps made by other people. Their own terms and privacy policies apply to them, and we are not responsible for them.

# 12. Availability and changes
We work hard to keep Hushavia fast and available, but we cannot promise it will always be uninterrupted or error-free. We may change, add or remove features, and may need to pause the service for maintenance. Please keep backups of anything important.

# 13. Intellectual property
Hushavia, its name, logo, its mascots and stickers, design and software belong to us and are protected by law. You may not copy, modify or reuse them without our written permission, except as allowed by these Terms.

# 14. Disclaimers
Hushavia is provided "as is" and "as available". To the fullest extent allowed by law, we make no warranties of any kind, express or implied, including fitness for a particular purpose. We do not check every message, and we are not responsible for content sent by users, groups, channels or bots. Trading signals, investment advice or offers you see in chats or channels come from other users, not from Hushavia — always do your own research. The scam warnings and stranger protection in the app are there to help you, but they cannot catch everything; you remain responsible for whom you trust and pay.

# 15. Limitation of liability
To the fullest extent allowed by law, Hushavia will not be liable for indirect, incidental, special or consequential damages, loss of profits, data or goodwill, arising from your use of the service. This includes any loss of cryptocurrency held in or sent from the Hushavia Wallet, which only you control (see section 8). Our total liability for any claim is limited to the amount you paid us for Hushavia Plus and Hushavia Coins in the 12 months before the claim, or USD 20 if you paid nothing. Nothing in these Terms limits liability that cannot be limited by law.

# 16. Ending your use
You can stop using Hushavia and delete your account at any time from Settings. We may suspend or end your access if you break these Terms, if the law requires it, or to protect users or the service. Sections that by their nature should continue (for example content licences needed to finish delivering messages, the wallet and coins sections, disclaimers and limitation of liability) continue after your account ends.

# 17. Governing law and disputes
These Terms are governed by the laws of Pakistan. Before going to court, please contact us so we can try to resolve the problem informally. Any dispute that cannot be resolved this way will be handled by the competent courts of Pakistan, unless the law of your country gives you the right to bring a claim where you live.

# 18. Changes to these Terms
We may update these Terms from time to time. We will post the new version here and change the date at the top, and tell you in the app about important changes. If you keep using Hushavia after the changes take effect, you accept the new Terms.

# 19. Contact
Questions about these Terms? Contact us from the app: Settings → Help & support.`;

const faq = `# Getting started

Q: How do I create an account?
A: Open Hushavia, enter your phone number (or choose "Continue with email"), then type the one-time code we send you. Add your name and, if you like, a photo — that's it.

Q: Why didn't my login code arrive?
A: Check that the number or email is correct, wait a minute and tap "Resend". For email, look in your Spam or Promotions folder. Never share your code with anyone — Hushavia staff will never ask for it.

Q: Can I use Hushavia on more than one device?
A: Yes. Your regular chats sync on all your devices. To log in on a computer, open the Hushavia web app and scan the QR code from Settings → Devices. You can see and log out any device there.

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
A: Yes. Voice and video calls use your internet connection (Wi-Fi or mobile data); Hushavia does not charge for them.

Q: What is a voice chat?
A: A live audio room inside a group or channel that many people can join at once. Admins can start one from the chat menu.

# Wallet and coins

Q: What is the Hushavia Wallet?
A: Your own crypto wallet inside the app (Settings → Wallet). It holds Bitcoin, Ethereum, BNB, TRON, Solana, Litecoin, Dogecoin, USDT, USDC and more. It is non-custodial: the keys stay on your phone and only you control the money.

Q: What are the 12 words?
A: Your recovery phrase — the only key to your wallet. Write the words on paper and keep them safe. With them you can bring your wallet back on any phone; without them nobody can, not even Hushavia.

Q: I lost my phone. Is my money gone?
A: Not if you have your 12 words. Install Hushavia (or any compatible wallet), choose "I already have a wallet" and type them in. If you do not have the words, the wallet cannot be recovered.

Q: Will Hushavia ever ask for my 12 words?
A: Never. Not in a chat, by email or by phone. Anyone who asks for them — even if they say they are support — is a scammer. Report and block them.

Q: I sent crypto to the wrong address. Can you get it back?
A: No. Blockchain payments are final and Hushavia cannot reverse, freeze or refund them. Always check the address and the network before you confirm.

Q: What are Hushavia Coins?
A: A balance for use inside Hushavia (Settings → Coins). Use them for Hushavia Plus, gifts, tips, paid channels and giveaways. Coins are not crypto and cannot be withdrawn or turned back into money.

Q: How do I add coins?
A: Settings → Coins → "Add coins with USDT". You get your own address: send USDT on BNB Smart Chain (BEP-20) from any exchange or wallet — 1 USDT = 100 coins. They arrive about a minute after the network confirms the payment. Sending from an exchange needs no BNB; sending from your Hushavia Wallet needs a little BNB for the network fee.

Q: I sent USDT but no coins came.
A: Open "Add coins" and tap "I've sent it — check now". Make sure you sent USDT on BNB Smart Chain (not TRON or Ethereum) and at least the minimum amount. Still missing? Contact Help & support with the transaction ID.

Q: How do gifts and tips work?
A: In a private chat, tap the attachment button → Gift: your friend gets the coins of the gift. In a channel, long-press a post → Tip coins: the coins go to the channel's owner.

Q: What is a paid channel?
A: A channel whose owner set a price in coins for 30 days. You pay when you join and it renews from your balance. Owners set it in the channel info → Paid subscription.

Q: How do giveaways work?
A: An admin starts one from the attachment button → Giveaway, with a prize for each winner. Members tap Join; when the time is up the app picks winners at random and the coins go straight to them.

Q: How do I pay for Hushavia Plus?
A: Open Settings → Hushavia Plus, pick a plan and pay with USDT from your wallet or with your coins. Plus starts by itself as soon as the payment is confirmed — usually about a minute.

Q: I paid but Plus or my coins did not arrive.
A: Wait a few minutes — the network may be busy — then open the page again. If it still has not arrived, contact Settings → Help & support with the transaction ID.

# Privacy and security

Q: Who can see my phone number?
A: You decide in Settings → Privacy → Phone number: everybody, only your contacts or nobody. The same goes for your photo, last seen, bio and birthday.

Q: Are my messages encrypted?
A: All messages travel over encrypted connections. Vault chats are also end-to-end encrypted, so only you and the other person can read them — not even Hushavia.

Q: How do I protect my account?
A: Turn on Two-step verification and a Passkey, lock the app with a PIN or fingerprint, and check Settings → Security checkup for quick tips. You will get an alert whenever someone logs in to your account.

Q: How do I block or report someone?
A: Open their profile and tap Block, or Report. You can also report any message from its menu. Blocked people cannot message or call you.

# Notifications

Q: I'm not getting notifications. What can I do?
A: Make sure notifications are allowed for Hushavia in your phone's settings and in Settings → Notifications. On many phones (Xiaomi, Oppo, Vivo, Infinix, Tecno) also allow Hushavia to run in the background / turn off battery optimisation for it. Check that the chat is not muted.

Q: Can I hide message text on the lock screen?
A: Yes. Settings → Notifications → turn off "Show message text". You will only see who sent a message.

# Bots

Q: What are bots and how do I make one?
A: Bots are small programs that chat with people — for news, tools, signals, support and more. Create one in Settings → My bots or by chatting with BotForge. You get a key to use with the Hushavia Bot API on your own server.

# Data and storage

Q: Hushavia is using a lot of storage or data. What can I do?
A: Open Settings → Data & storage to clear the cache, choose what downloads automatically on Wi-Fi and mobile data, and turn on Data saver.

Q: How do I back up my chats?
A: Settings → Chat backup saves a copy to your Google Drive or your phone that you can restore later.

Q: Hushavia doesn't work on my network. What can I do?
A: You can connect through a proxy: Settings → Proxy → Add proxy, or open a proxy link someone shared with you.

# Account

Q: How do I delete my account?
A: Settings → Delete my account. Your profile, messages and memberships are removed. This cannot be undone.

Q: My account was banned. What can I do?
A: If you think it was a mistake, try to log in and tap "Appeal" to tell us what happened. We review every appeal.

Q: How do I contact support?
A: Settings → Help & support → New request. Add a screenshot if it helps — we reply right there in the app.`;

const about = `# Hushavia — talk, share, belong

Hushavia is a fast, secure messaging app made for everyday conversations and growing communities. Chat one-to-one, talk in groups, follow channels, make voice and video calls and build bots — all in one clean, friendly app.

# What you can do
• Chats: text, photos, videos, files, voice messages and video notes, with replies, reactions, editing and scheduled messages.
• Groups: communities with admins and moderators, granular rights, topics, polls, slow mode and strong spam protection.
• Channels: broadcast to unlimited subscribers with views, comments, reactions and post approvals.
• Calls: free voice and video calls, plus live voice chats in groups and channels.
• Vault chats: end-to-end encrypted conversations only you and the other person can read.
• Stories and highlights: share moments with the people you choose.
• Bots and BotForge: create bots, connect them with the Hushavia Bot API and reach people in chats and inline.
• Wallet: your own crypto wallet for Bitcoin, Ethereum, BNB, TRON, Solana, USDT, USDC and more — the keys stay on your phone.
• Coins: gifts for friends, tips for channels, paid channels and giveaways.
• Hushavia Plus: extra features, bigger uploads and no ads.
• Our own animated mascot and sticker packs, made just for Hushavia.
• Prayer times with Qibla, Suhoor and Iftar reminders.

# Privacy first
You decide who sees your phone number, photo and last seen. Your account is protected with two-step verification, passkeys, login alerts and app lock. We never sell your data and never read your chats to show ads.

# Built for everyone
Hushavia works well on any phone and any connection: it is light on data, supports proxies and keeps working on slow networks. It is available on Android and on the web.

# Contact
Questions, ideas or problems? We'd love to hear from you: Settings → Help & support.

Thank you for being part of Hushavia. 💜`;

module.exports = {
  privacy: { title: 'Privacy Policy', body: privacy },
  terms: { title: 'Terms of Service', body: terms },
  faq: { title: 'Frequently Asked Questions', body: faq },
  about: { title: 'About Hushavia', body: about },
};
