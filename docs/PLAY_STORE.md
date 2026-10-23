# Publishing Talvio on Google Play

## 1. One-time: the upload key (signing)
1. GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**
   - Name `ANDROID_KEY_PASSWORD`, value: a strong password (12+ characters). **Write it down** — every release needs it.
2. **Actions → Create Android upload key → Run workflow.** It creates the key, encrypts it with that password
   and saves it as `mobile/signing/upload-keystore.jks.enc` (+ `fingerprints.txt` with SHA-1/SHA-256 for Firebase).
3. From now on every build of **Android APK** is signed with it and also produces **`talvio-playstore.aab`**
   in Releases → `android-latest`.

Play Console uses *Play App Signing*: Google keeps the real app signing key, this is only the upload key
(Google can reset it if it is ever lost).

## 2. Play Console
1. Create a developer account at play.google.com/console (one-time $25).
2. **Create app** → name `Talvio`, default language English, App, Free.
3. Upload `talvio-playstore.aab` to **Testing → Internal testing** first, then Production.
4. Application id: `com.talvio.app` (cannot be changed after the first upload).

## 3. Store listing (copy/paste)
**App name:** Talvio
**Short description (80):** Fast, private chats, calls & channels — with vault chats and prayer times.
**Full description:**
Talvio is a fast, beautiful messenger made for everyday life.

• Chats & groups — photos, videos, files, voice notes, polls, reactions, replies and pinned messages
• Voice & video calls — clear calls, also on slow networks
• Vault chats — end-to-end encrypted, only on your two phones
• Channels — share news and updates with unlimited subscribers, with comments
• Stories, chat folders, scheduled messages and disappearing messages
• Stickers, GIFs and link previews
• Live location and contact sharing
• Prayer times, Qibla direction and Sehri/Iftar timer
• Data-saver mode for slow or expensive internet
• Use Talvio on your computer — scan a QR code at /web
• Talvio Plus — bigger uploads, more folders and no sponsored messages

Log in with your email address — no SMS needed.

**Category:** Communication · **Contact email:** your support address · **Privacy policy URL:** `https://YOUR-DOMAIN/p/privacy`
**Graphics:** `mobile/branding/store/icon-512.png`, `mobile/branding/store/feature-graphic-1024x500.png`,
phone screenshots from the `ci-app` branch (the emulator test saves them on every run).

## 4. Data safety form (what Talvio does)
- Collected: email or phone (account), name/photo (profile), messages & media (app functionality, stored on the server
  except vault chats), contacts (optional, matching only), approximate/precise location (only when the user shares it),
  device IDs/push token, crash logs (diagnostics).
- Encrypted in transit: **Yes** (HTTPS). Users can request deletion: **Yes** (in-app Delete account).
- Not sold, not used for ads.

## 5. Content rating & permissions
- Content rating questionnaire: messaging app with user-generated content and user interaction.
- Permissions are explained in-app when first needed: camera, microphone, contacts, location, notifications.
