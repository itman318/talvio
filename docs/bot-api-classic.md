# Talvio Bot API — Classic

Many bots are written with ready-made bot libraries (for example aiogram or python-telegram-bot in
Python, grammY or Telegraf in Node.js). The Classic API lets those bots run on Talvio **without
rewriting them**: you only point the library at Talvio's address and use your Talvio token.

## What you need

| | Value |
|---|---|
| Server address | `http://<your-talvio-server>/api/classic` |
| Token | the **Classic token** shown when you create a bot (Settings → My bots), written `<id>:<secret>` |

Create the bot in the app first (Settings → My bots → New bot) and copy both values.

## Examples

**Python · aiogram 3**

```python
from aiogram import Bot
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer

session = AiohttpSession(api=TelegramAPIServer.from_base("http://<server>/api/classic"))
bot = Bot(token="<classic token>", session=session)
```

**Python · python-telegram-bot 20+**

```python
app = (Application.builder().token("<classic token>")
       .base_url("http://<server>/api/classic/bot")
       .base_file_url("http://<server>/api/classic/file/bot")
       .build())
```

**Node.js · grammY**

```js
const bot = new Bot('<classic token>', { client: { apiRoot: 'http://<server>/api/classic' } });
```

Everything else in your bot stays the same.

## Request and response

- `POST {address}/bot<token>/<method>` — JSON, form or multipart (files in any field).
- Success: `{ "ok": true, "result": … }`
- Error: `{ "ok": false, "error_code": 400, "description": "Bad Request: …" }` (429 adds `parameters.retry_after`).
- Files: `getFile` returns `file_path`; download it from `{address}/file/bot<token>/<file_path>`.

## Supported methods

getMe · getUpdates · setWebhook · deleteWebhook · getWebhookInfo · sendMessage · sendPhoto ·
sendDocument · sendVideo · sendAudio · sendVoice · sendAnimation · sendSticker · sendPoll ·
sendLocation · sendChatAction · editMessageText · editMessageReplyMarkup · deleteMessage ·
deleteMessages · forwardMessage · copyMessage · pinChatMessage · unpinChatMessage ·
answerCallbackQuery · answerInlineQuery · setMyCommands · getMyCommands · deleteMyCommands ·
setMyName · setMyDescription · setMyShortDescription · setChatMenuButton · getChat ·
getChatMember · getChatMemberCount · getFile · logOut · close

Updates: `message` (text, photos, files, locations, mini-app data), `callback_query`, `inline_query`.

Formatting: `parse_mode` HTML, MarkdownV2 and Markdown are converted to Talvio's formatting
(bold, italic, strikethrough, code, spoiler). Links become "text (url)". Underline isn't
available in Talvio and is shown as plain text.

Files: send them as uploads, by `file_id` from an earlier message, or by a public http(s) URL
(up to 20 MB).

Webhooks: `setWebhook` needs an https URL. If you pass `secret_token`, it is sent back in the
header your library already checks.

## Not available (yet)

Payments, games, stories, business connections, forum-topic management, chat administration
methods (ban/restrict/promote), inline_message_id editing. Calling them returns 404 "not available".

Users and chats are Talvio's own: people have to open your bot on Talvio (or add it to a Talvio
group) before it can message them.
