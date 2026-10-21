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
  final bool isVerified;
  final bool deleted;
  bool online;
  DateTime? lastSeen;
  final bool lastSeenHidden;
  final bool isContact;
  final bool blocked;
  final Map<String, String>? privacy; // only for "me"

  AppUser({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.username,
    this.bio = '',
    this.avatarUrl,
    this.phone,
    this.isVerified = false,
    this.deleted = false,
    this.online = false,
    this.lastSeen,
    this.lastSeenHidden = false,
    this.isContact = false,
    this.blocked = false,
    this.privacy,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: _int(j['id']),
        firstName: (j['first_name'] ?? '') as String,
        lastName: (j['last_name'] ?? '') as String,
        username: j['username'] as String?,
        bio: (j['bio'] ?? '') as String,
        avatarUrl: j['avatar_url'] as String?,
        phone: j['phone'] as String?,
        isVerified: j['is_verified'] == true,
        deleted: j['deleted'] == true,
        online: j['online'] == true,
        lastSeen: _date(j['last_seen']),
        lastSeenHidden: j['last_seen_hidden'] == true,
        isContact: j['is_contact'] == true,
        blocked: j['blocked'] == true,
        privacy: j['privacy'] == null ? null : Map<String, String>.from(j['privacy'] as Map),
      );

  String get name {
    if (deleted) return 'Deleted Account';
    final n = '$firstName $lastName'.trim();
    if (n.isNotEmpty) return n;
    return username != null ? '@$username' : 'User';
  }

  String? get avatarAbsolute => avatarUrl == null ? null : AppConfig.absolute(avatarUrl!);
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
      );

  bool get voted => myVotes.isNotEmpty;
  bool get showResults => voted || closed;

  /// Applies counts from a realtime update without losing this user's own votes.
  void mergeCounts(PollInfo other) {
    for (var i = 0; i < options.length && i < other.options.length; i++) {
      options[i].votes = other.options[i].votes;
    }
    totalVoters = other.totalVoters;
    closed = other.closed;
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
  final PollInfo? poll;
  List<ReactionCount> reactions;
  String? myReaction;
  int views;
  final Map<String, dynamic>? meta;
  final String? clientId;
  DateTime? editedAt;
  final DateTime createdAt;

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
    this.poll,
    List<ReactionCount>? reactions,
    this.myReaction,
    this.views = 0,
    this.meta,
    this.clientId,
    this.editedAt,
    required this.createdAt,
    this.sendState = SendState.sent,
    this.localFilePath,
    this.uploadProgress = 0,
    this.outbox,
    this.uploadKind,
  }) : reactions = reactions ?? [];

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
      poll: j['poll'] == null ? null : PollInfo.fromJson(Map<String, dynamic>.from(j['poll'] as Map)),
      reactions: ReactionCount.listFrom(j['reactions']),
      myReaction: j['my_reaction'] as String?,
      views: _int(j['views'] ?? 0),
      meta: j['meta'] == null ? null : Map<String, dynamic>.from(j['meta'] as Map),
      clientId: j['client_id'] as String?,
      editedAt: _date(j['edited_at']),
      createdAt: _date(j['created_at']) ?? DateTime.now(),
    );
  }

  bool get isSystem => type == 'system';
  bool get isLocal => id < 0;

  /// Short text used in the chat list and notifications.
  String get preview {
    switch (type) {
      case 'image':
        return text.isNotEmpty ? '📷 $text' : '📷 Photo';
      case 'video':
        return text.isNotEmpty ? '🎬 $text' : '🎬 Video';
      case 'voice':
        return '🎤 Voice message';
      case 'file':
        return '📎 ${media?.name ?? 'File'}';
      case 'poll':
        return '📊 $text';
      default:
        return text;
    }
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
  int unreadCount;
  int readUpTo;
  int deliveredUpTo;
  DateTime? mutedUntil;
  bool isMuted;
  bool isPinned;
  bool isArchived;
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
    this.unreadCount = 0,
    this.readUpTo = 0,
    this.deliveredUpTo = 0,
    this.mutedUntil,
    this.isMuted = false,
    this.isPinned = false,
    this.isArchived = false,
    this.lastMessage,
    this.lastMessageAt,
    required this.createdAt,
  });

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
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
        unreadCount: _int(j['unread_count'] ?? 0),
        readUpTo: _int(j['read_up_to'] ?? 0),
        deliveredUpTo: _int(j['delivered_up_to'] ?? 0),
        mutedUntil: _date(j['muted_until']),
        isMuted: j['is_muted'] == true,
        isPinned: j['is_pinned'] == true,
        isArchived: j['is_archived'] == true,
        lastMessage: j['last_message'] == null ? null : Message.fromJson(Map<String, dynamic>.from(j['last_message'] as Map)),
        lastMessageAt: _date(j['last_message_at']),
        createdAt: _date(j['created_at']) ?? DateTime.now(),
      );

  bool get isGroup => type == 'group';
  bool get isChannel => type == 'channel';
  bool get isMulti => type == 'group' || type == 'channel';
  bool get isAdmin => myRole == 'owner' || myRole == 'admin';
  bool get isOwner => myRole == 'owner';
  String? get avatarAbsolute => avatarUrl == null ? null : AppConfig.absolute(avatarUrl!);
  DateTime get sortTime => lastMessage?.createdAt ?? lastMessageAt ?? createdAt;
}

class GroupMember {
  final AppUser user;
  String role;
  final DateTime joinedAt;

  GroupMember({required this.user, required this.role, required this.joinedAt});

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        user: AppUser.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
        role: j['role'] as String,
        joinedAt: _date(j['joined_at']) ?? DateTime.now(),
      );
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

  StoryItem({
    required this.id,
    required this.userId,
    required this.media,
    required this.caption,
    required this.privacy,
    required this.createdAt,
    required this.viewed,
    required this.viewsCount,
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
