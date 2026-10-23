import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../theme/brand.dart';

/// Horizontal row of story avatars at the top of the chat list.
class StoryBar extends StatelessWidget {
  const StoryBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final me = context.watch<AuthState>().me;
    if (me == null) return const SizedBox.shrink();
    final groups = store.stories;
    final mine = groups.where((g) => g.user.id == me.id).toList();
    final others = groups.where((g) => g.user.id != me.id).toList();

    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          _StoryAvatar(
            user: me,
            label: 'My story',
            ring: mine.isNotEmpty ? Brand.faint : null,
            badge: mine.isEmpty,
            onTap: () {
              if (mine.isEmpty) {
                addStory(context);
              } else {
                openStories(context, groups, groups.indexOf(mine.first));
              }
            },
            onLongPress: () => addStory(context),
          ),
          ...others.map((g) => _StoryAvatar(
                user: g.user,
                label: g.user.firstName.isEmpty ? g.user.name : g.user.firstName,
                ring: g.hasUnseen ? Brand.primary : Brand.faint,
                onTap: () => openStories(context, groups, groups.indexOf(g)),
              )),
        ],
      ),
    );
  }
}

class _StoryAvatar extends StatelessWidget {
  const _StoryAvatar({required this.user, required this.label, this.ring, this.badge = false, required this.onTap, this.onLongPress});
  final AppUser user;
  final String label;
  final Color? ring;
  final bool badge;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 70,
        child: Column(children: [
          Stack(children: [
            Container(
              padding: const EdgeInsets.all(2.5),
              // Unseen stories get the Ember gradient ring; seen ones a quiet outline.
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: ring == Brand.primary ? Brand.storyGradient : null,
                border: ring == null || ring == Brand.primary ? null : Border.all(color: ring!, width: 2),
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(20)),
                child: Avatar(id: user.id, name: user.name, url: user.avatarAbsolute, size: 50),
              ),
            ),
            if (badge)
              const Positioned(
                right: 0,
                bottom: 0,
                child: CircleAvatar(radius: 10, backgroundColor: Brand.primary, child: Icon(Icons.add, size: 14, color: Colors.white)),
              ),
          ]),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}

Future<void> addStory(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(children: [
        ListTile(leading: const Icon(Icons.photo), title: const Text('Photo from gallery'), onTap: () => Navigator.pop(ctx, 'photo')),
        ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Take a photo'), onTap: () => Navigator.pop(ctx, 'camera')),
        ListTile(leading: const Icon(Icons.videocam), title: const Text('Video'), onTap: () => Navigator.pop(ctx, 'video')),
      ]),
    ),
  );
  if (choice == null) return;
  final picker = ImagePicker();
  final XFile? x = choice == 'video'
      ? await picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60))
      : await picker.pickImage(source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 2048, imageQuality: 85);
  if (x == null || !context.mounted) return;

  final caption = TextEditingController();
  String privacy = 'contacts';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Share story'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (choice != 'video') ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(x.path), height: 180, fit: BoxFit.cover)),
          TextField(controller: caption, maxLength: 500, decoration: const InputDecoration(hintText: 'Add a caption…')),
          DropdownButton<String>(
            value: privacy,
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'contacts', child: Text('My contacts')),
              DropdownMenuItem(value: 'everyone', child: Text('Everyone I chat with')),
            ],
            onChanged: (v) => setState(() => privacy = v!),
          ),
          const Text('Disappears after 24 hours', style: TextStyle(fontSize: 12, color: Brand.muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Share')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  showInfo(context, 'Uploading story…');
  try {
    await context.read<ChatStore>().postStory(
          x.path,
          type: choice == 'video' ? 'video' : 'image',
          caption: caption.text.trim(),
          privacy: privacy,
          mime: lookupMimeType(x.path),
        );
    if (context.mounted) showInfo(context, 'Story shared');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

void openStories(BuildContext context, List<StoryGroup> groups, int start) {
  if (start < 0) return;
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryViewerScreen(groups: groups, startGroup: start)));
}

/// Full-screen story player: tap right/left to move, hold to pause, auto-advance.
class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({super.key, required this.groups, required this.startGroup});
  final List<StoryGroup> groups;
  final int startGroup;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> with SingleTickerProviderStateMixin {
  late int _g;
  int _i = 0;
  late final AnimationController _progress;
  File? _file;
  VideoPlayerController? _video;
  bool _loading = true;
  final _reply = TextEditingController();
  final _replyFocus = FocusNode();

  late final ChatStore _store;
  StoryGroup get _group => widget.groups[_g];
  StoryItem get _story => _group.stories[_i];
  bool get _isMine => _group.user.id == _store.myId;

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _g = widget.startGroup;
    // start from the first unseen story of this person
    final firstUnseen = _group.stories.indexWhere((s) => !s.viewed);
    _i = firstUnseen < 0 || _isMineAtStart() ? 0 : firstUnseen;
    _progress = AnimationController(vsync: this, duration: const Duration(seconds: 6))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _next();
      });
    _replyFocus.addListener(() {
      if (_replyFocus.hasFocus) {
        _progress.stop();
      } else {
        _progress.forward();
      }
    });
    _load();
  }

  bool _isMineAtStart() => widget.groups[widget.startGroup].user.id == _store.myId;

  @override
  void dispose() {
    _progress.dispose();
    _video?.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    _store.refreshStoryRings();
    super.dispose();
  }

  Future<void> _load() async {
    _progress.stop();
    _progress.reset();
    final old = _video;
    _video = null;
    old?.dispose();
    setState(() {
      _loading = true;
      _file = null;
    });
    final story = _story;
    try {
      final f = await context.read<AppServices>().media.get(story.media);
      if (!mounted || story != _story) return;
      if (story.media.kind == 'video') {
        final c = VideoPlayerController.file(f);
        await c.initialize();
        if (!mounted || story != _story) {
          await c.dispose();
          return;
        }
        _video = c;
        _progress.duration = c.value.duration.inMilliseconds > 0 ? c.value.duration : const Duration(seconds: 15);
        await c.play();
      } else {
        _progress.duration = const Duration(seconds: 6);
      }
      setState(() {
        _file = f;
        _loading = false;
      });
      _progress.forward();
      _store.markStoryViewed(story).catchError((_) {});
    } catch (_) {
      if (mounted) {
        showInfo(context, 'Could not load this story');
        _next();
      }
    }
  }

  void _next() {
    if (_i < _group.stories.length - 1) {
      setState(() => _i++);
      _load();
    } else if (_g < widget.groups.length - 1) {
      setState(() {
        _g++;
        _i = 0;
      });
      _load();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_i > 0) {
      setState(() => _i--);
    } else if (_g > 0) {
      setState(() {
        _g--;
        _i = 0;
      });
    }
    _load();
  }

  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    _reply.clear();
    _replyFocus.unfocus();
    try {
      await _store.replyToStory(_story, text);
      if (mounted) showInfo(context, 'Reply sent');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _showViewers() async {
    _progress.stop();
    try {
      final viewers = await _store.storyViewers(_story);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text('${viewers.length} views', style: const TextStyle(fontWeight: FontWeight.w600))),
            ...viewers.map((v) {
              final u = AppUser.fromJson(Map<String, dynamic>.from(v['user'] as Map));
              return ListTile(
                leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 40),
                title: Text(u.name),
                subtitle: Text(chatListTime(DateTime.parse(v['viewed_at'] as String).toLocal())),
                trailing: v['emoji'] == null ? null : Text('${v['emoji']}', style: const TextStyle(fontSize: 22)),
              );
            }),
          ]),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) _progress.forward();
  }

  Future<void> _delete() async {
    _progress.stop();
    if (!await confirm(context, 'Delete story?', 'It will disappear for everyone.', ok: 'Delete', danger: true)) {
      _progress.forward();
      return;
    }
    try {
      await _store.deleteStory(_story);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final story = _story;
    final width = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onTapUp: (d) {
                if (d.globalPosition.dx < width / 3) {
                  _prev();
                } else {
                  _next();
                }
              },
              onLongPressStart: (_) {
                _progress.stop();
                _video?.pause();
              },
              onLongPressEnd: (_) {
                _progress.forward();
                _video?.play();
              },
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 300) Navigator.pop(context);
              },
              child: Center(
                child: _loading || _file == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : (_video != null
                        ? AspectRatio(aspectRatio: _video!.value.aspectRatio, child: VideoPlayer(_video!))
                        : Image.file(_file!, fit: BoxFit.contain)),
              ),
            ),
          ),
          // progress bars
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(
              children: List.generate(_group.stories.length, (k) {
                return Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    height: 3,
                    child: k == _i
                        ? AnimatedBuilder(
                            animation: _progress,
                            builder: (_, __) => LinearProgressIndicator(value: _progress.value, color: Colors.white, backgroundColor: Colors.white30),
                          )
                        : LinearProgressIndicator(value: k < _i ? 1 : 0, color: Colors.white, backgroundColor: Colors.white30),
                  ),
                );
              }),
            ),
          ),
          Positioned(
            top: 18,
            left: 8,
            right: 8,
            child: Row(children: [
              Avatar(id: _group.user.id, name: _group.user.name, url: _group.user.avatarAbsolute, size: 36),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_isMine ? 'My story' : _group.user.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  Text(chatListTime(story.createdAt), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
              if (_isMine) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.white), onPressed: _delete),
              IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (story.caption.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(story.caption, style: const TextStyle(color: Colors.white, fontSize: 15), textAlign: TextAlign.center),
                  ),
                if (_isMine)
                  TextButton.icon(
                    onPressed: _showViewers,
                    icon: const Icon(Icons.visibility, color: Colors.white),
                    label: Text('${story.viewsCount} views', style: const TextStyle(color: Colors.white)),
                  )
                else
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _reply,
                        focusNode: _replyFocus,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Reply…',
                          hintStyle: const TextStyle(color: Colors.white60),
                          filled: true,
                          fillColor: Colors.white12,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                        ),
                        onSubmitted: (_) => _sendReply(),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.favorite_border, color: Colors.white),
                      onPressed: () {
                        _store.markStoryViewed(story, emoji: '❤️').catchError((_) {});
                        showInfo(context, '❤️ sent');
                      },
                    ),
                    IconButton(icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white), onPressed: _sendReply),
                  ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
