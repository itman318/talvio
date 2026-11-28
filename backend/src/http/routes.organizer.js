'use strict';
const router = require('express').Router({ mergeParams: true });
const db = require('../db');
const chats = require('../services/chat.service');
const moderation = require('../services/moderation.service');
const limits = require('../utils/rateLimit');
const { id } = require('../utils/validate');
const { forbidden, badRequest } = require('../utils/errors');
const { asyncHandler: h } = require('./middleware');

router.use(h(async (req, res, next) => {
  req.room = await chats.requireMember(req.params.id, req.userId);
  next();
}));

router.get('/saved', h(async (req, res) => {
  const chat = req.room;
  if (chat.private_key !== req.userId + ':' + req.userId) throw forbidden('not_saved', 'Open your own Saved Messages');
  const args = [chat.id, chat.cleared_before_id || 0, req.userId];
  const visible = 'm.chat_id=$1 AND m.id>$2 AND m.deleted_at IS NULL AND (m.expires_at IS NULL OR m.expires_at>now()) AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id=$3 AND h.message_id=m.id)';
  if (req.query.tag) {
    args.push(String(req.query.tag),req.query.before ? id(req.query.before,'before') : Number.MAX_SAFE_INTEGER);
    const rows = await db.many(`SELECT id,type,text,saved_tag FROM messages m WHERE ${visible} AND saved_tag=$4 AND id<$5 ORDER BY id DESC LIMIT 50`,args);
    return res.json({rows});
  }
  if (req.query.source === undefined) {
    const rows = await db.many(`SELECT coalesce(groups.saved_source_chat, 0) AS id,
        latest.saved_source_title AS title, groups.count
      FROM (
        SELECT saved_source_chat, max(m.id) AS latest_id, count(*) AS count
        FROM messages m WHERE ${visible} GROUP BY saved_source_chat
      ) groups JOIN messages latest ON latest.id = groups.latest_id
      ORDER BY groups.latest_id DESC`, args);
    const tags = await db.many(`SELECT DISTINCT saved_tag AS title FROM messages m WHERE ${visible} AND saved_tag IS NOT NULL ORDER BY title`,args);
    return res.json({rows,tags});
  }
  args.push(req.query.source === '0' ? 0 : id(req.query.source,'source'), req.query.before ? id(req.query.before,'before') : Number.MAX_SAFE_INTEGER);
  const rows = await db.many(`SELECT id,type,text,saved_tag FROM messages m WHERE ${visible} AND coalesce(saved_source_chat,0)=$4 AND m.id<$5 ORDER BY id DESC LIMIT 50`,args);
  res.json({rows});
}));

router.post('/saved/:message/tag', h(async (req,res) => {
  if(req.room.private_key !== req.userId + ':' + req.userId) throw forbidden('not_saved','Open your own Saved Messages');
  const tag = req.body.tag;
  if(typeof tag !== 'string' || tag.trim().length>40) throw badRequest('invalid_tag','Use up to 40 characters');
  const result = await db.query('UPDATE messages m SET saved_tag=$1 WHERE chat_id=$2 AND id=$3 AND id>$4 AND deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM message_hidden h WHERE h.user_id=$5 AND h.message_id=m.id)',[tag.trim() || null,req.room.id,id(req.params.message,'message'),req.room.cleared_before_id || 0,req.userId]);
  if(!result.rowCount) throw badRequest('unavailable','Message is unavailable');
  res.json({ok:true});
}));

router.use('/inbox', (req,res,next) => {
  if (req.room.type !== 'channel') return next(badRequest('not_channel','Open a channel'));
  req.staff = chats.ADMIN_ROLES.includes(req.room.my_role);
  next();
});
router.post('/inbox/settings', h(async (req,res) => {
  if (req.room.my_role !== 'owner') throw forbidden('owner_only','Only the owner can change the inbox');
  if (typeof req.body.enabled !== 'boolean') throw badRequest('invalid_input','Choose enabled or disabled');
  await db.query('UPDATE chats SET inbox_enabled=$2 WHERE id=$1',[req.room.id, req.body.enabled]);
  res.json({ok:true});
}));
router.get('/inbox', h(async (req,res) => {
  const rows = req.staff ? await db.many(`SELECT latest.subscriber_id AS id, u.first_name AS title, latest.text
    FROM (
      SELECT DISTINCT ON (subscriber_id) subscriber_id, id, text
      FROM channel_inbox_messages WHERE channel_id=$1 ORDER BY subscriber_id, id DESC
    ) latest JOIN users u ON u.id=latest.subscriber_id ORDER BY latest.id DESC`,[req.room.id]) : [];
  res.json({user_id:req.userId,enabled:req.room.inbox_enabled, staff:req.staff, owner:req.room.my_role==='owner',rows});
}));
router.use('/inbox/:subscriber', (req,res,next) => {
  const subscriber = id(req.params.subscriber,'subscriber');
  if (!req.staff && subscriber !== req.userId) return next(forbidden('private_thread','This conversation is private'));
  req.subscriber = subscriber;
  next();
});
router.get('/inbox/:subscriber', h(async (req,res) => {
  const before=req.query.before ? id(req.query.before,'before') : Number.MAX_SAFE_INTEGER;
  const rows=await db.many('SELECT id,from_channel,text FROM channel_inbox_messages WHERE channel_id=$1 AND subscriber_id=$2 AND id<$3 ORDER BY id DESC LIMIT 50',[req.room.id,req.subscriber,before]);
  res.json({rows, enabled:req.room.inbox_enabled});
}));
router.post('/inbox/:subscriber', h(async (req,res) => {
  if (!req.room.inbox_enabled) throw forbidden('inbox_closed','Channel inbox is closed');
  const text=typeof req.body.text==='string' ? req.body.text.trim() : '';
  if (!text || text.length>4000) throw badRequest('invalid_text','Enter up to 4000 characters');
  moderation.assertNotRestricted(await db.one('SELECT * FROM users WHERE id=$1',[req.userId]));
  if(req.room.my_restricted_until && new Date(req.room.my_restricted_until)>new Date()) throw forbidden('restricted','Messaging is restricted');
  if(req.staff && !(await db.one('SELECT 1 FROM channel_inbox_messages WHERE channel_id=$1 AND subscriber_id=$2 LIMIT 1',[req.room.id,req.subscriber]))) throw forbidden('no_thread','Reply to an existing conversation');
  limits.enforce('channel-inbox:'+req.userId,30,60000,'Please try again in a minute');
  await db.query('INSERT INTO channel_inbox_messages(channel_id,subscriber_id,from_channel,text) VALUES ($1,$2,$3,$4)',[req.room.id,req.subscriber,req.staff,text]);
  res.json({ok:true});
}));
module.exports = router;
