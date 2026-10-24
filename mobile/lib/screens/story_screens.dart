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
  const StoryViewerScreen({super.key, required this.groups, required this.startGroup, this.highlightTitle});
  final List<StoryGroup> groups;
  final int startGroup;

  /// Watching a profile highlight (old stories): no replies, no "seen".
  final String? highlightTitle;

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
  bool get _highlight => widget.highlightTitle != null;
  bool _showReactions = false;
  String? _burst; // the emoji flying up after a reaction

  static const reactions = ['❤️', '😂', '😮', '😢', '👏', '🔥', '😍', '🎉'];

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
      } else if (!_showReactions) {
        _progress.forward();
      }
      if (mounted) setState(() {});
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
        if (!mounted) return;
      } else {
        _progress.duration = const Duration(seconds: 6);
      }
      setState(() {
        _file = f;
        _loading = false;
      });
      _progress.forward();
      if (!_highlight) _store.markStoryViewed(story).catchError((_) {});
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

  Future<void> _react(String emoji) async {
    final story = _story;
    setState(() {
      _showReactions = false;
      _burst = emoji;
    });
    _replyFocus.unfocus();
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _burst == emoji) setState(() => _burst = null);
    });
    if (!_progress.isAnimating) _progress.forward();
    try {
      await _store.reactToStory(story, emoji);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Owner: put this story in a highlight on the profile (stays after the 24 hours).
  Future<void> _addToHighlight() async {
    _progress.stop();
    _video?.pause();
    final story = _story;
    try {
      final list = await _store.highlightsOf(_store.myId!);
      if (!mounted) return;
      final pick = await showModalBottomSheet<Object>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const ListTile(title: Text('Add to highlight', style: TextStyle(fontWeight: FontWeight.w700))),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Brand.primary, child: Icon(Icons.add_rounded, color: Colors.white)),
              title: const Text('New highlight'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            for (final h in list)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.auto_awesome_rounded)),
                title: Text(h.title),
                subtitle: Text('${h.count} ${h.count == 1 ? 'story' : 'stories'}'),
                onTap: () => Navigator.pop(ctx, h),
              ),
          ]),
        ),
      );
      if (!mounted || pick == null) return;
      if (pick is StoryHighlight) {
        await _store.addToHighlight(pick.id, pick.title, story.id);
        if (mounted) showInfo(context, 'Added to “${pick.title}”');
      } else {
        final title = await promptText(context, 'New highlight', hint: 'Name (e.g. Travel)', max: 32);
        if (title == null || !mounted) return;
        await _store.saveHighlight(title: title.trim().isEmpty ? 'Highlights' : title.trim(), storyIds: [story.id]);
        if (mounted) showInfo(context, 'Highlight created — it’s on your profile');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        _progress.forward();
        _video?.play();
      }
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
                  Text(_isMine && !_highlight ? 'My story' : _group.user.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  Text(_highlight ? '${widget.highlightTitle} · ${chatListTime(story.createdAt)}' : chatListTime(story.createdAt),
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
              if (_isMine && !_highlight)
                IconButton(tooltip: 'Add to highlight', icon: const Icon(Icons.bookmark_add_outlined, color: Colors.white), onPressed: _addToHighlight),
              if (_isMine && !_highlight) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.white), onPressed: _delete),
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
                if (_highlight)
                  const SizedBox.shrink()
                else if (_isMine)
                  TextButton.icon(
                    onPressed: _showViewers,
                    icon: const Icon(Icons.visibility, color: Colors.white),
                    label: Text('${story.viewsCount} views', style: const TextStyle(color: Colors.white)),
                  )
                else ...[
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _showReactions || _replyFocus.hasFocus
                        ? Padding(
                            key: const ValueKey('r'),
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(30)),
                              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                                for (final e in reactions)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(20),
                                    onTap: () => _react(e),
                                    child: Padding(padding: const EdgeInsets.all(6), child: Text(e, style: const TextStyle(fontSize: 26))),
                                  ),
                              ]),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('n')),
                  ),
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
                    GestureDetector(
                      onLongPress: () {
                        _progress.stop();
                        setState(() => _showReactions = true);
                      },
                      child: IconButton(
                        tooltip: 'Tap ❤️ · hold for more',
                        icon: const Icon(Icons.favorite_border, color: Colors.white),
                        onPressed: () => _react('❤️'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Reactions',
                      icon: Icon(_showReactions ? Icons.close_rounded : Icons.add_reaction_outlined, color: Colors.white),
                      onPressed: () => setState(() {
                        _showReactions = !_showReactions;
                        _showReactions ? _progress.stop() : _progress.forward();
                      }),
                    ),
                    IconButton(icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white), onPressed: _sendReply),
                  ]),
                ],
              ]),
            ),
          ),
          if (_burst != null)
            Positioned.fill(
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_burst),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 850),
                  builder: (_, t, __) => Align(
                    alignment: Alignment(0, 0.6 - t * 0.9),
                    child: Opacity(
                      opacity: t < 0.75 ? 1 : (1 - t) / 0.25,
                      child: Transform.scale(scale: 0.6 + Curves.elasticOut.transform(t.clamp(0.0, 1.0)) * 1.4, child: Text(_burst!, style: const TextStyle(fontSize: 72))),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// ================================================================== highlights on profiles
/// Round thumbnail of a story picture (videos show a play icon).
class StoryThumb extends StatelessWidget {
  const StoryThumb({super.key, required this.media, this.size = 60});
  final MediaInfo? media;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = media;
    final icon = (size.isFinite ? size : 90.0) * 0.4;
    Widget fallback(IconData i) => Container(
          color: Brand.faint.withValues(alpha: 0.25),
          alignment: Alignment.center,
          child: Icon(i, color: Colors.white, size: icon),
        );
    return SizedBox(
      width: size,
      height: size,
      child: m == null
          ? fallback(Icons.auto_awesome_rounded)
          : m.kind == 'video'
              ? Container(color: Colors.black87, alignment: Alignment.center, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: icon))
              : FutureBuilder<File>(
                  future: context.read<AppServices>().media.get(m),
                  builder: (_, snap) => snap.hasData ? Image.file(snap.data!, fit: BoxFit.cover) : fallback(Icons.photo_rounded),
                ),
    );
  }
}

/// Highlight circles on a profile. On my own profile there is a "New" circle and long-press to edit.
class HighlightsRow extends StatefulWidget {
  const HighlightsRow({super.key, required this.userId, this.mine = false});
  final int userId;
  final bool mine;

  @override
  State<HighlightsRow> createState() => _HighlightsRowState();
}

class _HighlightsRowState extends State<HighlightsRow> {
  List<StoryHighlight>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await context.read<ChatStore>().highlightsOf(widget.userId);
      if (mounted) setState(() => _list = l);
    } catch (_) {
      if (mounted) setState(() => _list = const []);
    }
  }

  Future<void> _open(StoryHighlight h) async {
    final store = context.read<ChatStore>();
    try {
      final (group, title, _) = await store.openHighlight(h.id);
      if (!mounted || group.stories.isEmpty) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryViewerScreen(groups: [group], startGroup: 0, highlightTitle: title)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit([StoryHighlight? h]) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => HighlightEditorScreen(highlight: h)));
    if (changed == true) _load();
  }

  Future<void> _menu(StoryHighlight h) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.edit_rounded), title: const Text('Edit highlight'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
            title: const Text('Delete highlight', style: TextStyle(color: Colors.red)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (a == 'edit') _edit(h);
    if (a == 'delete' && await confirm(context, 'Delete “${h.title}”?', 'The stories stay in your archive.', ok: 'Delete', danger: true)) {
      try {
        if (!mounted) return;
        await context.read<ChatStore>().deleteHighlight(h.id);
        _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  Widget _circle({required Widget child, required String label, required VoidCallback onTap, VoidCallback? onLongPress, bool dashed = false}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 76,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: dashed ? null : Brand.aurora,
              border: dashed ? Border.all(color: Brand.muted.withValues(alpha: 0.5), width: 1.5) : null,
            ),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, shape: BoxShape.circle),
              child: ClipOval(child: SizedBox(width: 58, height: 58, child: child)),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: dark ? Colors.white70 : Brand.ink)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null || (list.isEmpty && !widget.mine)) return const SizedBox.shrink();
    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          if (widget.mine)
            _circle(
              dashed: true,
              label: 'New',
              onTap: () => _edit(),
              child: const Icon(Icons.add_rounded, size: 28, color: Brand.primary),
            ),
          for (final h in list)
            _circle(
              label: h.title,
              onTap: () => _open(h),
              onLongPress: widget.mine ? () => _menu(h) : null,
              child: StoryThumb(media: h.cover, size: 58),
            ),
        ],
      ),
    );
  }
}

/// Pick stories from my archive (also expired ones) and name the highlight.
class HighlightEditorScreen extends StatefulWidget {
  const HighlightEditorScreen({super.key, this.highlight});
  final StoryHighlight? highlight;

  @override
  State<HighlightEditorScreen> createState() => _HighlightEditorScreenState();
}

class _HighlightEditorScreenState extends State<HighlightEditorScreen> {
  late final _title = TextEditingController(text: widget.highlight?.title ?? '');
  List<StoryItem>? _archive;
  final Set<int> _picked = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<ChatStore>();
    try {
      final archive = await store.storyArchive();
      final ids = widget.highlight == null ? <int>[] : await store.highlightStoryIds(widget.highlight!.id);
      if (!mounted) return;
      setState(() {
        _archive = archive;
        _picked.addAll(ids);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _archive = const []);
        showError(context, e);
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_picked.isEmpty) {
      showInfo(context, 'Pick at least one story');
      return;
    }
    setState(() => _busy = true);
    try {
      final t = _title.text.trim();
      await context.read<ChatStore>().saveHighlight(id: widget.highlight?.id, title: t.isEmpty ? 'Highlights' : t, storyIds: _picked.toList());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final archive = _archive;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.highlight == null ? 'New highlight' : 'Edit highlight'),
        actions: [
          TextButton(onPressed: _busy || archive == null ? null : _save, child: Text(_picked.isEmpty ? 'Save' : 'Save (${_picked.length})')),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _title,
            maxLength: 32,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Travel, Family, Food…', prefixIcon: Icon(Icons.auto_awesome_rounded)),
          ),
        ),
        Expanded(
          child: archive == null
              ? const Center(child: CircularProgressIndicator())
              : archive.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Your stories show up here, also after 24 hours. Share a story first.', textAlign: TextAlign.center),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 0.66),
                      itemCount: archive.length,
                      itemBuilder: (_, i) {
                        final s = archive[i];
                        final on = _picked.contains(s.id);
                        return GestureDetector(
                          onTap: () => setState(() => on ? _picked.remove(s.id) : _picked.add(s.id)),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Stack(fit: StackFit.expand, children: [
                              StoryThumb(media: s.media, size: double.infinity),
                              Positioned(
                                left: 6,
                                bottom: 6,
                                child: Text(shortDate(s.createdAt), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4)])),
                              ),
                              if (on) Container(color: Brand.primary.withValues(alpha: 0.25)),
                              Positioned(
                                right: 6,
                                top: 6,
                                child: Icon(on ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: on ? Brand.primary : Colors.white),
                              ),
                            ]),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}


/// Settings → Story highlights.
class MyHighlightsScreen extends StatelessWidget {
  const MyHighlightsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me;
    return Scaffold(
      appBar: AppBar(title: const Text('Story highlights')),
      body: me == null
          ? const SizedBox.shrink()
          : ListView(children: [
              const SizedBox(height: 8),
              HighlightsRow(userId: me.id, mine: true),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  'Highlights stay on your profile after the 24 hours. Tap “New” to pick stories, hold a highlight to edit or delete it. '
                  'You can also tap 🔖 while watching your story. Each story keeps the privacy it was shared with.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ]),
    );
  }
}
