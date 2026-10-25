import '../config.dart';

int _int(dynamic v) => v is int ? v : (v as num?)?.toInt() ?? int.parse('$v');
int? _intOrNull(dynamic v) => v == null ? null : _int(v);
DateTime? _date(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();

class AppUser {
  final int id;
  final String firstName;
  final String lastName;
  final String? username;
  final String bio;
  final String? avatarUrl;
  final String? phone;
  final String? email; // only for yourself
  final bool isVerified;
  final bool deleted;
  bool online;
  DateTime? lastSeen;
  final bool lastSeenHidden;
  final bool isContact;
  final bool blocked;
  final Map<String, String>? privacy; // only for "me"
  final bool isBot;
  final bool isPremium;
  final DateTime? premiumUntil; // only for "me"
  final Map<String, dynamic>? limits; // only for "me": {premium, upload_mb, folders, ads}
  final Birthday? birthday; // when they share it with me
  final Map<String, dynamic>? security; // only for "me": default timer, auto-logout, account TTL, search
  final bool hasPassword; // only for "me": two-step verification is on

  AppUser({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.username,
    this.bio = '',
    this.avatarUrl,
    this.phone,
    this.email,
    this.isVerified = false,
    this.deleted = false,
    this.online = false,
    this.lastSeen,
    this.lastSeenHidden = false,
    this.isContact = false,
    this.blocked = false,
    this.privacy,
    this.isBot = false,
    this.isPremium = false,
    this.premiumUntil,
    this.limits,
    this.birthday,
    this.security,
    this.hasPassword = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: _int(j['id']),
        firstName: (j['first_name'] ?? '') as String,
        lastName: (j['last_name'] ?? '') as String,
        username: j['username'] as String?,
        bio: (j['bio'] ?? '') as String,
        avatarUrl: j['avatar_url'] as String?,
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        isVerified: j['is_verified'] == true,
        deleted: j['deleted'] == true,
        online: j['online'] == true,
        lastSeen: _date(j['last_seen']),
        lastSeenHidden: j['last_seen_hidden'] == true,
        isContact: j['is_contact'] == true,
        blocked: j['blocked'] == true,
        privacy: j['privacy'] == null ? null : Map<String, String>.from(j['privacy'] as Map),
        isBot: j['is_bot'] == true,
        isPremium: j['is_premium'] == true,
        premiumUntil: _date(j['premium_until']),
        limits: j['limits'] == null ? null : Map<String, dynamic>.from(j['limits'] as Map),
        birthday: j['birthday'] is Map ? Birthday.fromJson(Map<String, dynamic>.from(j['birthday'] as Map)) : null,
        security: j['security'] is Map ? Map<String, dynamic>.from(j['security'] as Map) : null,
        hasPassword: j['has_password'] == true,
      );

  String get name {
    if (deleted) return 'Deleted Account';
    final n = '$firstName $lastName'.trim();
    if (n.isNotEmpty) return n;
    return username != null ? '@$username' : 'User';
  }

  String? get avatarAbsolute => avatarUrl == null ? null : AppConfig.absolute(avatarUrl!);
}

class Birthday {
  Birthday(this.day, this.month, [this.year]);
  final int day;
  final int month;
  final int? year; // only on my own profile

  factory Birthday.fromJson(Map<String, dynamic> j) => Birthday(_int(j['day']), _int(j['month']), j['year'] == null ? null : _int(j['year']));

  static const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  String get label => '$day ${months[(month - 1).clamp(0, 11)]}${year != null ? ' $year' : ''}';

  /// "1995-08-21" or "08-21" for the server.
  String get api => '${year != null ? '$year-' : ''}${'$month'.padLeft(2, '0')}-${'$day'.padLeft(2, '0')}';

  bool get isToday {
    final n = DateTime.now();
    return n.month == month && n.day == day;
  }
}

class MediaInfo {
  final int id;
  final String kind;
  final String mime;
  final int size;
  final String name;
  final int? duration;
  final int? width;
  final int? height;
  final String url;

  MediaInfo({
    required this.id,
    required this.kind,
    required this.mime,
    required this.size,
    required this.name,
    this.duration,
    this.width,
    this.height,
    required this.url,
  });

  factory MediaInfo.fromJson(Map<String, dynamic> j) => MediaInfo(
        id: _int(j['id']),
        kind: j['kind'] as String,
        mime: j['mime'] as String,
        size: _int(j['size']),
        name: (j['name'] ?? '') as String,
        duration: _intOrNull(j['duration']),
        width: _intOrNull(j['width']),
        height: _intOrNull(j['height']),
        url: j['url'] as String,
      );
}

class ReplyInfo {
  final int id;
  final int? senderId;
  final String senderName;
  final String type;
  final String text;
  final bool deleted;

  ReplyInfo({required this.id, this.senderId, required this.senderName, required this.type, required this.text, this.deleted = false});

  factory ReplyInfo.fromJson(Map<String, dynamic> j) => ReplyInfo(
        id: _int(j['id']),
        senderId: _intOrNull(j['sender_id']),
        senderName: (j['sender_name'] ?? '') as String,
        type: j['type'] as String,
        text: (j['text'] ?? '') as String,
        deleted: j['deleted'] == true,
      );
}

class PollOption {
  final String text;
  int votes;
  PollOption(this.text, this.votes);
}

class PollInfo {
  final int id;
  final String question;
  final List<PollOption> options;
  int totalVoters;
  final bool anonymous;
  final bool multiple;
  final bool quiz;
  bool closed;
  List<int> myVotes;
  int? correctOption;
  String? explanation;
  DateTime? closeAt; // closes by itself at this time

  PollInfo({
    required this.id,
    required this.question,
    required this.options,
    required this.totalVoters,
    required this.anonymous,
    required this.multiple,
    required this.quiz,
    required this.closed,
    required this.myVotes,
    this.correctOption,
    this.explanation,
    this.closeAt,
  });

  factory PollInfo.fromJson(Map<String, dynamic> j) => PollInfo(
        id: _int(j['id']),
        question: (j['question'] ?? '') as String,
        options: (j['options'] as List)
            .map((o) => PollOption((o as Map)['text'] as String, _int(o['votes'] ?? 0)))
            .toList(),
        totalVoters: _int(j['total_voters'] ?? 0),
        anonymous: j['anonymous'] != false,
        multiple: j['multiple'] == true,
        quiz: j['quiz'] == true,
        closed: j['closed'] == true,
        myVotes: ((j['my_votes'] as List?) ?? []).map(_int).toList(),
        correctOption: _intOrNull(j['correct_option']),
        explanation: j['explanation'] as String?,
        closeAt: _date(j['close_at']),
      );

  /// Closed by hand, or its deadline passed (the server closes it within seconds).
  bool get isClosed => closed || (closeAt != null && DateTime.now().isAfter(closeAt!));

  bool get voted => myVotes.isNotEmpty;
  bool get showResults => voted || isClosed;

  /// Applies counts from a realtime update without losing this user's own votes.
  void mergeCounts(PollInfo other) {
    for (var i = 0; i < options.length && i < other.options.length; i++) {
      options[i].votes = other.options[i].votes;
    }
    totalVoters = other.totalVoters;
    closed = other.closed;
    closeAt = other.closeAt;
    if (other.correctOption != null) correctOption = other.correctOption;
    if (other.explanation != null) explanation = other.explanation;
  }
}

class ReactionCount {
  final String emoji;
  final int count;
  ReactionCount(this.emoji, this.count);

  static List<ReactionCount> listFrom(dynamic raw) => ((raw as List?) ?? [])
      .map((r) => ReactionCount((r as Map)['emoji'] as String, _int(r['count'])))
      .toList();
}

enum SendState { sent, sending, failed }

class Message {
  final int id; // negative for local, not-yet-sent messages
  final int chatId;
  final int? senderId;
  final AppUser? sender;
  final String type; // text | image | video | voice | file | system
  String text;
  final MediaInfo? media;
  final ReplyInfo? replyTo;
  final String? forwardedFromName;
  final String? authorSignature;
  final Map<String, dynamic>? senderBadge; // groups: {kind: owner|admin|tag, text}
  final String? viaBot; // sent with a bot's inline mode: its @username
  final PollInfo? poll;
  List<ReactionCount> reactions;
  String? myReaction;
  int views;
  final bool silent;
  final List<int> mentions;
  final Map<String, dynamic>? meta;
  final String? clientId;
  final int? threadId; // channel comment → id of the post
  final int? topicId; // forum topic
  final String? albumId; // photos sent together
  int commentsCount;
  Map<String, dynamic>? replyMarkup; // bot inline keyboard
  Map<String, dynamic>? linkPreview; // {url, site, title, description, image}
  DateTime? editedAt;
  final DateTime createdAt;

  /// View once: the other side can open it a single time.
  final bool viewOnce;
  bool played; // voice / round video: someone listened (shown to the sender)
  List<int> openedBy;

  // local-only (optimistic sending)
  SendState sendState;
  String? localFilePath;
  double uploadProgress;
  Map<String, dynamic>? outbox; // payload to (re)send
  String? uploadKind; // media kind still to upload
  String? errorText;

  Message({
    required this.id,
    required this.chatId,
    this.senderId,
    this.sender,
    required this.type,
    this.text = '',
    this.media,
    this.replyTo,
    this.forwardedFromName,
    this.authorSignature,
    this.senderBadge,
    this.viaBot,
    this.poll,
    List<ReactionCount>? reactions,
    this.myReaction,
    this.views = 0,
    this.silent = false,
    this.mentions = const [],
    this.meta,
    this.clientId,
    this.threadId,
    this.topicId,
    this.albumId,
    this.commentsCount = 0,
    this.replyMarkup,
    this.linkPreview,
    this.editedAt,
    required this.createdAt,
    this.sendState = SendState.sent,
    this.localFilePath,
    this.uploadProgress = 0,
    this.outbox,
    this.uploadKind,
    this.viewOnce = false,
    this.played = false,
    List<int>? openedBy,
  })  : reactions = reactions ?? [],
        openedBy = openedBy ?? [];

  factory Message.fromJson(Map<String, dynamic> j) {
    final s = j['sender'];
    return Message(
      id: _int(j['id']),
      chatId: _int(j['chat_id']),
      senderId: _intOrNull(j['sender_id']),
      sender: s == null
          ? null
          : AppUser(
              id: _int(s['id']),
              firstName: (s['first_name'] ?? '') as String,
              lastName: (s['last_name'] ?? '') as String,
              username: s['username'] as String?,
              avatarUrl: s['avatar_url'] as String?,
              deleted: s['deleted'] == true,
            ),
      type: j['type'] as String,
      text: (j['text'] ?? '') as String,
      media: j['media'] == null ? null : MediaInfo.fromJson(Map<String, dynamic>.from(j['media'] as Map)),
      replyTo: j['reply_to'] == null ? null : ReplyInfo.fromJson(Map<String, dynamic>.from(j['reply_to'] as Map)),
      forwardedFromName: j['forwarded_from'] == null ? null : (j['forwarded_from']['name'] as String?),
      authorSignature: j['author_signature'] as String?,
      senderBadge: j['sender_badge'] is Map ? Map<String, dynamic>.from(j['sender_badge'] as Map) : null,
      viaBot: j['via_bot'] is Map ? (j['via_bot'] as Map)['username'] as String? : null,
      poll: j['poll'] == null ? null : PollInfo.fromJson(Map<String, dynamic>.from(j['poll'] as Map)),
      reactions: ReactionCount.listFrom(j['reactions']),
      myReaction: j['my_reaction'] as String?,
      views: _int(j['views'] ?? 0),
      silent: j['silent'] == true,
      mentions: ((j['mentions'] as List?) ?? []).map(_int).toList(),
      meta: j['meta'] == null ? null : Map<String, dynamic>.from(j['meta'] as Map),
      clientId: j['client_id'] as String?,
      threadId: _intOrNull(j['thread_id']),
      topicId: _intOrNull(j['topic_id']),
      albumId: j['album_id'] as String?,
      commentsCount: _int(j['comments_count'] ?? 0),
      replyMarkup: j['reply_markup'] == null ? null : Map<String, dynamic>.from(j['reply_markup'] as Map),
      linkPreview: j['link_preview'] == null ? null : Map<String, dynamic>.from(j['link_preview'] as Map),
      editedAt: _date(j['edited_at']),
      createdAt: _date(j['created_at']) ?? DateTime.now(),
      viewOnce: j['view_once'] == true,
      played: j['played'] == true,
      openedBy: ((j['opened_by'] as List?) ?? const []).map(_int).toList(),
    );
  }

  bool get isSystem => type == 'system';

  /// Private reply: the group message this one answers ({chat_id, chat_title, message_id, sender_name, text, type}).
  Map<String, dynamic>? get quote => meta?['quote'] is Map ? Map<String, dynamic>.from(meta!['quote'] as Map) : null;

  /// In a discussion group: the channel post this message came from ({chat_id, message_id}).
  /// Reply / reaction to a story: {id, owner_id, kind, media, caption, reaction?}
  Map<String, dynamic>? get storyRef => meta?['story'] is Map ? Map<String, dynamic>.from(meta!['story'] as Map) : null;
  Map<String, dynamic>? get channelPost => meta?['channel_post'] is Map ? Map<String, dynamic>.from(meta!['channel_post'] as Map) : null;

  /// Full-screen effect sent with the message (confetti, hearts, balloons, fireworks).
  String? get effect => meta?['effect'] as String?;

  /// Rows of inline buttons sent by a bot: each {text, callback_data | url | web_app:{url}}.
  List<List<Map<String, dynamic>>> get inlineKeyboard {
    final rows = replyMarkup?['inline_keyboard'];
    if (rows is! List) return const [];
    return rows.whereType<List>().map((r) => r.whereType<Map>().map((b) => Map<String, dynamic>.from(b)).toList()).toList();
  }

  /// Bot reply keyboard (big buttons replacing the phone keyboard), if this message carries one.
  Map<String, dynamic>? get replyKeyboard => replyMarkup != null && replyMarkup!['keyboard'] is List ? replyMarkup : null;
  bool get removesKeyboard => replyMarkup?['remove_keyboard'] == true;

  /// {lat, lng, title} for location messages.
  Map<String, dynamic>? get location =>
      meta != null && meta!['location'] is Map ? Map<String, dynamic>.from(meta!['location'] as Map) : null;
  bool get isLocal => id < 0;

  /// {id, video, status, duration_sec, reason} for call log messages.
  Map<String, dynamic>? get callMeta =>
      meta != null && meta!['call'] is Map ? Map<String, dynamic>.from(meta!['call'] as Map) : null;

  /// Short text used in the chat list and notifications.
  String get preview {
    if (viewOnce) return type == 'voice' ? '🎤 View once voice message' : (type == 'video' ? '🎬 View once video' : '📷 View once photo');
    switch (type) {
      case 'image':
        return text.isNotEmpty ? '📷 $text' : '📷 Photo';
      case 'video':
        return text.isNotEmpty ? '🎬 $text' : '🎬 Video';
      case 'voice':
        return '🎤 Voice message';
      case 'video_note':
        return '📹 Video message';
      case 'file':
        return '📎 ${media?.name ?? 'File'}';
      case 'poll':
        return '📊 $text';
      case 'location':
        if (meta?['live'] != null) return '📍 Live location';
        return text.isNotEmpty ? '📍 $text' : '📍 Location';
      case 'sticker':
        return '${(meta?['sticker'] as Map?)?['emoji'] ?? '🙂'} Sticker';
      case 'gif':
        return text.isNotEmpty ? 'GIF · $text' : 'GIF';
      case 'contact':
        return '👤 ${(meta?['contact'] as Map?)?['name'] ?? 'Contact'}';
      case 'call':
        final c = callMeta ?? const {};
        final icon = c['video'] == true ? '📹' : '📞';
        final st = '${c['status'] ?? ''}';
        if (st == 'missed' || st == 'busy') return '$icon Missed call';
        if (st == 'declined') return '$icon Declined call';
        final sec = (c['duration_sec'] as num?)?.toInt() ?? 0;
        return sec > 0 ? '$icon Call (${formatCallDuration(sec)})' : '$icon Call';
      default:
        return stripFormatting(text).replaceAll(RegExp('[\uE900-\uE9FF]'), '🦊');
    }
  }
}

/// 75 → "1:15", 3725 → "1:02:05".
String formatCallDuration(int sec) {
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  final s = (sec % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// A call as the server sends it (history, incoming call, call:start result).
class CallInfo {
  final int id;
  final int? chatId;
  final bool video;
  final String status; // ringing | accepted | ended | missed | declined | busy | failed
  final bool outgoing;
  final String? endReason;
  final AppUser? peer;
  final int peerId;
  final int durationSec;
  final DateTime createdAt;
  final bool waiting; // the other person is on another call (call waiting)

  CallInfo({
    required this.id,
    this.chatId,
    required this.video,
    required this.status,
    required this.outgoing,
    this.endReason,
    this.peer,
    required this.peerId,
    this.durationSec = 0,
    required this.createdAt,
    this.waiting = false,
  });

  factory CallInfo.fromJson(Map<String, dynamic> j) => CallInfo(
        id: _int(j['id']),
        chatId: _intOrNull(j['chat_id']),
        video: j['video'] == true,
        status: (j['status'] ?? 'ended') as String,
        outgoing: j['direction'] == 'outgoing',
        waiting: j['waiting'] == true,
        endReason: j['end_reason'] as String?,
        peer: j['peer'] == null ? null : AppUser.fromJson(Map<String, dynamic>.from(j['peer'] as Map)),
        peerId: _int(j['peer_id'] ?? (j['peer'] is Map ? j['peer']['id'] : 0)),
        durationSec: _int(j['duration_sec'] ?? 0),
        createdAt: _date(j['created_at']) ?? DateTime.now(),
      );

  bool get missed => !outgoing && (status == 'missed' || status == 'busy');

  String get label {
    if (missed) return video ? 'Missed video call' : 'Missed call';
    if (status == 'declined') return outgoing ? 'Call declined' : 'Declined';
    if (outgoing && (status == 'missed' || status == 'busy')) return status == 'busy' ? 'Line busy' : 'Cancelled call';
    if (status == 'failed') return 'Call failed';
    return outgoing ? (video ? 'Outgoing video call' : 'Outgoing call') : (video ? 'Incoming video call' : 'Incoming call');
  }
}

class Chat {
  final int id;
  final String type; // private | group
  String title;
  String description;
  String? avatarUrl;
  AppUser? peer;
  final bool isSavedMessages;
  int memberCount;
  String myRole;
  String? inviteCode;
  String? username;
  bool isPublic;
  bool signatures;
  bool isVerified;
  bool canPost;
  bool isSuspended;
  int slowModeSec;
  int disappearAfterSec; // 0 = off
  bool joinApproval;
  int pendingRequests;
  bool commentsEnabled;
  bool isForum;
  final bool isBot;
  final BotInfo? bot;
  bool markedUnread;
  int unreadMentions;
  Message? pinnedMessage;
  int pinnedCount;
  int unreadCount;
  int readUpTo;
  int deliveredUpTo;
  DateTime? mutedUntil;
  bool isMuted;
  bool isPinned;
  bool isArchived;
  bool isRequest; // message from someone not in my contacts (waits in Requests)
  bool isLocked; // behind the fingerprint (Locked chats)
  /// Newer settings straight from the server (rights, rules, welcome, reactions, linked chat…), see getters below.
  final Map<String, dynamic> extra;
  Message? lastMessage;
  DateTime? lastMessageAt;
  final DateTime createdAt;

  Chat({
    required this.id,
    required this.type,
    required this.title,
    this.description = '',
    this.avatarUrl,
    this.peer,
    this.isSavedMessages = false,
    this.memberCount = 0,
    this.myRole = 'member',
    this.inviteCode,
    this.username,
    this.isPublic = false,
    this.signatures = false,
    this.isVerified = false,
    this.canPost = true,
    this.isSuspended = false,
    this.slowModeSec = 0,
    this.disappearAfterSec = 0,
    this.joinApproval = false,
    this.pendingRequests = 0,
    this.commentsEnabled = false,
    this.isForum = false,
    this.isBot = false,
    this.bot,
    this.markedUnread = false,
    this.unreadMentions = 0,
    this.pinnedMessage,
    this.pinnedCount = 0,
    this.unreadCount = 0,
    this.readUpTo = 0,
    this.deliveredUpTo = 0,
    this.mutedUntil,
    this.isMuted = false,
    this.isPinned = false,
    this.isArchived = false,
    this.isRequest = false,
    this.isLocked = false,
    Map<String, dynamic>? extra,
    this.lastMessage,
    this.lastMessageAt,
    required this.createdAt,
  }) : extra = extra ?? {};

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
        extra: j,
        id: _int(j['id']),
        type: j['type'] as String,
        title: (j['title'] ?? '') as String,
        description: (j['description'] ?? '') as String,
        avatarUrl: j['avatar_url'] as String?,
        peer: j['peer'] == null ? null : AppUser.fromJson(Map<String, dynamic>.from(j['peer'] as Map)),
        isSavedMessages: j['is_saved_messages'] == true,
        memberCount: _int(j['member_count'] ?? 0),
        myRole: (j['my_role'] ?? 'member') as String,
        inviteCode: j['invite_code'] as String?,
        username: j['username'] as String?,
        isPublic: j['is_public'] == true,
        signatures: j['signatures'] == true,
        isVerified: j['is_verified'] == true,
        canPost: j['can_post'] != false,
        isSuspended: j['is_suspended'] == true,
        slowModeSec: _int(j['slow_mode_sec'] ?? 0),
        disappearAfterSec: _int(j['disappear_after_sec'] ?? 0),
        joinApproval: j['join_approval'] == true,
        pendingRequests: _int(j['pending_requests'] ?? 0),
        commentsEnabled: j['comments_enabled'] == true,
        isForum: j['is_forum'] == true,
        isBot: j['is_bot'] == true,
        bot: j['bot'] == null ? null : BotInfo.fromJson(Map<String, dynamic>.from(j['bot'] as Map)),
        markedUnread: j['marked_unread'] == true,
        unreadMentions: _int(j['unread_mentions'] ?? 0),
        pinnedMessage: j['pinned_message'] == null ? null : Message.fromJson(Map<String, dynamic>.from(j['pinned_message'] as Map)),
        pinnedCount: _int(j['pinned_count'] ?? 0),
        unreadCount: _int(j['unread_count'] ?? 0),
        readUpTo: _int(j['read_up_to'] ?? 0),
        deliveredUpTo: _int(j['delivered_up_to'] ?? 0),
        mutedUntil: _date(j['muted_until']),
        isMuted: j['is_muted'] == true,
        isPinned: j['is_pinned'] == true,
        isArchived: j['is_archived'] == true,
        isRequest: j['is_request'] == true,
        isLocked: j['is_locked'] == true,
        lastMessage: j['last_message'] == null ? null : Message.fromJson(Map<String, dynamic>.from(j['last_message'] as Map)),
        lastMessageAt: _date(j['last_message_at']),
        createdAt: _date(j['created_at']) ?? DateTime.now(),
      );

  bool get isGroup => type == 'group';
  bool get isChannel => type == 'channel';
  bool get isMulti => type == 'group' || type == 'channel';
  bool get isAdmin => myRole == 'owner' || myRole == 'admin';
  bool get isOwner => myRole == 'owner';

  /// Admin rights: change_info, delete_messages, ban_users, invite_users, pin_messages, post_messages.
  bool can(String right) {
    if (isOwner) return true;
    if (!isAdmin) return false;
    final r = extra['my_rights'];
    return r is! Map || r[right] != false;
  }

  String? get myTitle => extra['my_title'] as String?;
  DateTime? get restrictedUntil => _date(extra['restricted_until']);
  bool get isRestricted => restrictedUntil != null && restrictedUntil!.isAfter(DateTime.now());
  String get welcomeText => '${extra['welcome_text'] ?? ''}';
  String get rules => '${extra['rules'] ?? ''}';
  bool get newMemberLimits => extra['new_member_limits'] == true;
  bool get protectedContent => extra['protected_content'] == true;
  bool get joinCaptcha => extra['join_captcha'] == true;
  bool get antiFlood => extra['anti_flood'] == true;
  bool get antiLinks => extra['anti_links'] == true;
  bool get hideService => extra['hide_service'] == true;
  bool get needsCaptcha => extra['needs_captcha'] == true;

  /// Live voice chat going on here: {id, title, count}, or null.
  Map<String, dynamic>? get voiceChat => extra['voice_chat'] is Map ? Map<String, dynamic>.from(extra['voice_chat'] as Map) : null;
  List<String> get bannedWords => extra['banned_words'] is List ? (extra['banned_words'] as List).map((e) => '$e').toList() : const [];

  /// What ordinary members may send: media, links, polls, stickers, voice.
  Map<String, bool> get memberPerms {
    final p = extra['member_perms'];
    const keys = ['media', 'links', 'polls', 'stickers', 'voice'];
    return {for (final k in keys) k: p is Map ? p[k] != false : true};
  }

  /// Reactions allowed here (null = all, empty = none).
  List<String>? get allowedReactions => extra['allowed_reactions'] is List ? (extra['allowed_reactions'] as List).map((e) => '$e').toList() : null;
  String? get category => extra['category'] as String?;
  ({int id, String title})? get linkedChat {
    final l = extra['linked_chat'];
    return l is Map ? (id: _int(l['id']), title: '${l['title'] ?? ''}') : null;
  }

  int? get linkedChannelId => _intOrNull(extra['linked_channel_id']);
  int get queueCount => _int(extra['queue_count'] ?? 0);
  String get serverDraft => '${extra['draft'] ?? ''}';

  /// Copying / forwarding is off for people who aren't admins.
  bool get noForwards => protectedContent && !isAdmin;
  String? get avatarAbsolute => avatarUrl == null ? null : AppConfig.absolute(avatarUrl!);
  DateTime get sortTime => lastMessage?.createdAt ?? lastMessageAt ?? createdAt;
}

class GroupMember {
  final AppUser user;
  String role;
  final DateTime joinedAt;
  final String? title; // custom admin title ("Moderator")
  final String? tag; // member tag set by admins ("Mentor")
  final Map<String, bool>? rights;
  final DateTime? restrictedUntil;

  GroupMember({required this.user, required this.role, required this.joinedAt, this.title, this.tag, this.rights, this.restrictedUntil});

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        user: AppUser.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
        role: j['role'] as String,
        joinedAt: _date(j['joined_at']) ?? DateTime.now(),
        title: j['title'] as String?,
        tag: j['tag'] as String?,
        rights: j['rights'] is Map ? (j['rights'] as Map).map((k, v) => MapEntry('$k', v == true)) : null,
        restrictedUntil: _date(j['restricted_until']),
      );

  bool get isRestricted => restrictedUntil != null && restrictedUntil!.isAfter(DateTime.now());
}

class DeviceSession {
  final int id;
  final String deviceName;
  final String platform;
  final String appVersion;
  final String? ip;
  final DateTime? lastActiveAt;
  final bool current;

  DeviceSession({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    this.ip,
    this.lastActiveAt,
    required this.current,
  });

  factory DeviceSession.fromJson(Map<String, dynamic> j) => DeviceSession(
        id: _int(j['id']),
        deviceName: (j['device_name'] ?? '') as String,
        platform: (j['platform'] ?? '') as String,
        appVersion: (j['app_version'] ?? '') as String,
        ip: j['ip'] as String?,
        lastActiveAt: _date(j['last_active_at']),
        current: j['current'] == true,
      );
}

class ChatFolder {
  final int id;
  String name;
  List<int> chatIds;
  bool includePrivate;
  bool includeGroups;
  bool includeChannels;
  bool unreadOnly;

  ChatFolder({
    required this.id,
    required this.name,
    required this.chatIds,
    this.includePrivate = false,
    this.includeGroups = false,
    this.includeChannels = false,
    this.unreadOnly = false,
  });

  factory ChatFolder.fromJson(Map<String, dynamic> j) => ChatFolder(
        id: _int(j['id']),
        name: j['name'] as String,
        chatIds: ((j['chat_ids'] as List?) ?? []).map(_int).toList(),
        includePrivate: j['include_private'] == true,
        includeGroups: j['include_groups'] == true,
        includeChannels: j['include_channels'] == true,
        unreadOnly: j['include_unread_only'] == true,
      );

  bool matches(Chat c) {
    final inFolder = chatIds.contains(c.id) ||
        (includePrivate && c.type == 'private') ||
        (includeGroups && c.type == 'group') ||
        (includeChannels && c.type == 'channel');
    return inFolder && (!unreadOnly || c.unreadCount > 0);
  }
}

class StoryItem {
  final int id;
  final int userId;
  final MediaInfo media;
  final String caption;
  final String privacy;
  final DateTime createdAt;
  bool viewed;
  final int viewsCount;
  final List<AppUser> mentions; // people tagged in this story

  StoryItem({
    required this.id,
    required this.userId,
    required this.media,
    required this.caption,
    required this.privacy,
    required this.createdAt,
    required this.viewed,
    required this.viewsCount,
    this.mentions = const [],
  });

  factory StoryItem.fromJson(Map<String, dynamic> j) => StoryItem(
        id: _int(j['id']),
        userId: _int(j['user_id']),
        media: MediaInfo.fromJson(Map<String, dynamic>.from(j['media'] as Map)),
        caption: (j['caption'] ?? '') as String,
        privacy: (j['privacy'] ?? 'contacts') as String,
        createdAt: _date(j['created_at']) ?? DateTime.now(),
        viewed: j['viewed'] == true,
        viewsCount: _int(j['views_count'] ?? 0),
        mentions: [for (final u in (j['mentions'] as List? ?? const [])) AppUser.fromJson(Map<String, dynamic>.from(u as Map))],
      );
}

class StoryHighlight {
  StoryHighlight({required this.id, required this.title, required this.count, this.cover});
  final int id;
  final String title;
  final int count;
  final MediaInfo? cover;

  factory StoryHighlight.fromJson(Map<String, dynamic> j) => StoryHighlight(
        id: _int(j['id']),
        title: (j['title'] ?? '') as String,
        count: _int(j['count']),
        cover: j['cover'] is Map ? MediaInfo.fromJson(Map<String, dynamic>.from(j['cover'] as Map)) : null,
      );
}

class StoryGroup {
  final AppUser user;
  final List<StoryItem> stories;
  bool hasUnseen;

  StoryGroup({required this.user, required this.stories, required this.hasUnseen});

  factory StoryGroup.fromJson(Map<String, dynamic> j) => StoryGroup(
        user: AppUser.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
        stories: (j['stories'] as List).map((s) => StoryItem.fromJson(Map<String, dynamic>.from(s as Map))).toList(),
        hasUnseen: j['has_unseen'] == true,
      );
}

class Announcement {
  final int id;
  final String title;
  final String body;
  Announcement({required this.id, required this.title, required this.body});

  factory Announcement.fromJson(Map<String, dynamic> j) =>
      Announcement(id: _int(j['id']), title: j['title'] as String, body: j['body'] as String);
}

class SupportTicket {
  final int id;
  final String subject;
  final String category;
  final String status;
  final String priority;
  final bool unread;
  final String? lastMessage;
  final DateTime? updatedAt;

  SupportTicket({
    required this.id,
    required this.subject,
    required this.category,
    required this.status,
    required this.priority,
    required this.unread,
    this.lastMessage,
    this.updatedAt,
  });

  factory SupportTicket.fromJson(Map<String, dynamic> j) => SupportTicket(
        id: _int(j['id']),
        subject: j['subject'] as String,
        category: (j['category'] ?? 'other') as String,
        status: (j['status'] ?? 'open') as String,
        priority: (j['priority'] ?? 'normal') as String,
        unread: j['unread'] == true,
        lastMessage: j['last_message'] as String?,
        updatedAt: _date(j['updated_at']),
      );
}

class SupportMessage {
  final int id;
  final bool fromUser;
  final String text;
  final DateTime createdAt;

  SupportMessage({required this.id, required this.fromUser, required this.text, required this.createdAt});

  factory SupportMessage.fromJson(Map<String, dynamic> j) => SupportMessage(
        id: _int(j['id']),
        fromUser: j['from_user'] == true,
        text: j['text'] as String,
        createdAt: _date(j['created_at']) ?? DateTime.now(),
      );
}


/// Public info about a bot (shown in its chat).
class BotInfo {
  final String about;
  final List<(String, String)> commands; // (command, description)
  final String? menuUrl;
  BotInfo({this.about = '', this.commands = const [], this.menuUrl});

  factory BotInfo.fromJson(Map<String, dynamic> j) => BotInfo(
        about: (j['about'] ?? '') as String,
        commands: ((j['commands'] as List?) ?? [])
            .whereType<Map>()
            .map((c) => ('${c['command']}', '${c['description'] ?? ''}'))
            .toList(),
        menuUrl: j['menu_url'] as String?,
      );
}

/// A bot I own (Settings → My bots).
class MyBot {
  final int id;
  String name;
  final String username;
  String about;
  List<Map<String, dynamic>> commands;
  String? menuUrl;
  bool groupPrivacy;
  final String status;
  final String? webhookUrl;
  final String? webhookError;
  final int pendingUpdates;

  MyBot({
    required this.id,
    required this.name,
    required this.username,
    this.about = '',
    this.commands = const [],
    this.menuUrl,
    this.groupPrivacy = true,
    this.status = 'active',
    this.webhookUrl,
    this.webhookError,
    this.pendingUpdates = 0,
  });

  factory MyBot.fromJson(Map<String, dynamic> j) => MyBot(
        id: _int(j['id']),
        name: (j['name'] ?? '') as String,
        username: (j['username'] ?? '') as String,
        about: (j['about'] ?? '') as String,
        commands: ((j['commands'] as List?) ?? []).whereType<Map>().map((c) => Map<String, dynamic>.from(c)).toList(),
        menuUrl: j['menu_url'] as String?,
        groupPrivacy: j['group_privacy'] != false,
        status: (j['status'] ?? 'active') as String,
        webhookUrl: j['webhook_url'] as String?,
        webhookError: j['webhook_error'] as String?,
        pendingUpdates: _int(j['pending_updates'] ?? 0),
      );
}

/// A forum topic in a group.
class Topic {
  final int id; // 0 = General
  final String title;
  final int iconColor;
  bool isClosed;
  bool isPinned;
  final int messageCount;
  final Message? lastMessage;

  Topic({required this.id, required this.title, this.iconColor = 0, this.isClosed = false, this.isPinned = false, this.messageCount = 0, this.lastMessage});

  factory Topic.fromJson(Map<String, dynamic> j) => Topic(
        id: _int(j['id'] ?? 0),
        title: (j['title'] ?? 'General') as String,
        iconColor: _int(j['icon_color'] ?? 0),
        isClosed: j['is_closed'] == true,
        isPinned: j['is_pinned'] == true,
        messageCount: _int(j['message_count'] ?? 0),
        lastMessage: j['last_message'] == null ? null : Message.fromJson(Map<String, dynamic>.from(j['last_message'] as Map)),
      );
}

/// **bold**, _italic_, ~strike~, `code`, ||spoiler|| (one line each, not nested).
final formatRe = RegExp(r'\*\*([^\n]+?)\*\*|(?<![\w\\])_([^\n_]+?)_(?![\w])|(?<![\w~])~([^\n~]+?)~(?![\w~])|`([^`\n]+)`|\|\|([^\n]+?)\|\|');

/// Text without the formatting marks (chat list, notifications, copy).
String stripFormatting(String s) => s.replaceAllMapped(formatRe, (m) {
      if (m.group(5) != null) return '▒▒▒▒';
      return m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    });

/// Effect that fits a text by itself ("Happy birthday" → balloons), or null.
String? autoEffectFor(String text) {
  final t = text.toLowerCase();
  if (RegExp(r'happy\s*birthday|\bhbd\b').hasMatch(t)) return 'balloons';
  if (RegExp(r'congrat|well done|🎉|🥳').hasMatch(t)) return 'confetti';
  if (RegExp(r'happy new year|🎆|🎇').hasMatch(t)) return 'fireworks';
  if (RegExp(r'^\s*(i love you|love you|❤️+|💕+|😍+)\s*$').hasMatch(t)) return 'hearts';
  return null;
}
