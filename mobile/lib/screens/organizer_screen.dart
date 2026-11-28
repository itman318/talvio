import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/services.dart';

class OrganizerScreen extends StatefulWidget {
  const OrganizerScreen({super.key, required this.chatId, required this.saved});
  final int chatId;
  final bool saved;
  @override
  State<OrganizerScreen> createState() => _OrganizerScreenState();
}

class _OrganizerScreenState extends State<OrganizerScreen> {
  final draft = TextEditingController();
  List<Map> rows = [];
  int? selected;
  String? title, error, tag;
  List<String> tags = [];
  bool busy = true, sending = false, enabled = false, owner = false, staff = false, more = false;
  int generation = 0;
  String get root => '/chats/${widget.chatId}/organizer';
  @override
  void initState() {
    super.initState();
    reload();
  }
  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  Future<void> reload({bool append = false}) async {
    final ticket = ++generation;
    final api = context.read<AppServices>().api;
    setState(() { busy = true; error = null; });
    try {
      var path = widget.saved ? '$root/saved' : '$root/inbox';
      final query = <String,String>{};
      if (selected != null) {
        if (widget.saved) {
          if (tag == null) { query['source'] = selected.toString(); } else { query['tag'] = tag!; }
        } else {
          path += '/$selected';
        }
        if (append) query['before'] = rows.last['id'].toString();
      }
      final result = await api.get(path, query: query) as Map;
      if (!mounted || ticket != generation) return;
      if (!widget.saved && selected == null) {
        enabled = result['enabled'] == true;
        owner = result['owner'] == true;
        staff = result['staff'] == true;
        if (!staff) {
          selected = result['user_id'] as int;
          await reload();
          return;
        }
      }
      if (!widget.saved && selected != null && result['enabled'] is bool) {
        enabled = result['enabled'] as bool;
      }
      if (widget.saved && selected == null) tags = [for(final item in result['tags'] as List) item['title'] as String];
      final items = List<Map>.from(result['rows'] as List);
      setState(() { rows = append ? [...rows,...items] : items; more = selected != null && items.length == 50; busy = false; });
    } catch (e) {
      if (mounted && ticket == generation) setState(() { error = e.toString(); busy = false; });
    }
  }

  Future<void> write({bool? toggle}) async {
    if (sending) return;
    final text = draft.text.trim();
    if (toggle == null && text.isEmpty) return;
    setState(() => sending = true);
    try {
      final api = context.read<AppServices>().api;
      if (toggle != null) {
        await api.post('$root/inbox/settings', {'enabled':toggle});
      } else {
        await api.post('$root/inbox/$selected', {'text':text});
        if (mounted) draft.clear();
      }
      if (mounted) await reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> editTag(Map row) async {
    var value = row['saved_tag']?.toString() ?? '';
    final result = await showDialog<String>(context:context,builder:(ctx) => AlertDialog(
      title:const Text('Message tag'),
      content:TextFormField(initialValue:value,autofocus:true,maxLength:40,onChanged:(v) => value=v),
      actions:[TextButton(onPressed:() => Navigator.pop(ctx),child:const Text('Cancel')),
        TextButton(onPressed:() => Navigator.pop(ctx,value.trim()),child:const Text('Save'))]));
    if(result == null || !mounted) return;
    try {
      await context.read<AppServices>().api.post("$root/saved/${row['id']}/tag",{'tag':result});
      if(mounted) await reload();
    } catch(e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = selected == null;
    final name = title ?? (widget.saved ? 'Saved by source' : 'Channel inbox');
    return Scaffold(
      appBar: AppBar(title: Text(name), actions: [
        IconButton(tooltip:'Refresh', icon:const Icon(Icons.refresh), onPressed: busy || sending ? null : () => reload()),
      ]),
      body: SafeArea(child: Column(children: [
        if (overview && widget.saved && tags.isNotEmpty) SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[
          for(final label in tags) Padding(padding:const EdgeInsets.all(4),child:ActionChip(label:Text(label),onPressed:(){
            setState(() { tag=label; selected=-1; title=label; rows=[]; more=false; }); reload();
          })),
        ])),
        if (overview && owner) SwitchListTile(title: const Text('Accept subscriber messages'), value:enabled, onChanged:sending ? null : (v) => write(toggle:v)),
        if (!overview && (staff || widget.saved)) Align(alignment:Alignment.centerLeft, child:TextButton.icon(icon:const Icon(Icons.arrow_back), label:Text(widget.saved ? 'All sources' : 'All conversations'), onPressed:sending ? null : () {
          selected = null; tag = null; title = null; rows = []; draft.clear(); reload();
        })),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          Text(error!, textAlign: TextAlign.center),
          TextButton(onPressed: busy ? null : () => reload(), child: const Text('Try again')),
        ])),
        if (!busy && error == null && rows.isEmpty) Expanded(child:Center(child:Text(widget.saved ? 'No saved messages here yet.' : enabled ? 'No messages yet.' : 'The channel inbox is closed.'))),
        if (rows.isNotEmpty || busy || error != null) Expanded(child:ListView.builder(
          itemCount: rows.length + (more ? 1 : 0),
          itemBuilder:(context,index) {
            if(index == rows.length) return TextButton(onPressed:busy ? null : () => reload(append:true),child:const Text('Load older messages'));
            final row = rows[index];
            if (overview) {
              final label = row['title']?.toString() ?? (widget.saved ? 'Notes and earlier saves' : 'Subscriber');
              return ListTile(title:Text(label),subtitle:Text(widget.saved ? "${row['count']} saved" : row['text'].toString(), maxLines:1,overflow:TextOverflow.ellipsis),
                trailing:const Icon(Icons.chevron_right),onTap:() {
                  selected = row['id'] as int; title = label; rows = []; more = false; reload();
                });
            }
            final body = row['text']?.toString() ?? '';
            return ListTile(title:Text(body.isEmpty ? row['type'].toString() : body),
              trailing:widget.saved ? IconButton(tooltip:'Edit tag',icon:const Icon(Icons.label_outline),onPressed:() => editTag(row)) : null,
              subtitle:widget.saved ? (row['saved_tag'] == null ? null : Text(row['saved_tag'].toString())) : Text(row['from_channel'] == true ? 'Channel' : 'Subscriber'),
              onTap:widget.saved ? () => Navigator.pop(context,row['id'] as int) : null);
          })),
        if (!widget.saved && !overview && enabled) Padding(padding:const EdgeInsets.all(12),child:Row(children:[
          Expanded(child:TextField(controller:draft,enabled:!sending,maxLength:4000,decoration:const InputDecoration(hintText:'Write a private message'))),
          IconButton(tooltip:'Send',icon:const Icon(Icons.send),onPressed:sending ? null : () => write()),
        ])),
      ])),
    );
  }
}
