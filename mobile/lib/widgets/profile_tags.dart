import 'package:flutter/material.dart';

/// How a profile tag looks. Warning tags come first, then trust tags.
class TagLook {
  const TagLook(this.label, this.icon, this.color, this.about, {this.warning = false, this.strong = false});
  final String label;
  final IconData icon;
  final Color color;
  final String about;
  final bool warning;
  final bool strong; // scam / fake: confirmed by Hushavia

  static const _red = Color(0xFFE5484D);
  static const _orange = Color(0xFFE08A1E);

  static const all = <String, TagLook>{
    'scam': TagLook('Scam reports confirmed', Icons.gpp_bad_rounded, _red,
        'Hushavia checked reports and evidence and confirmed this account cheated people. Don’t send money, codes or personal details.',
        warning: true, strong: true),
    'fake': TagLook('Fake account', Icons.no_accounts_rounded, _red,
        'Hushavia confirmed this account pretends to be someone else (a person, a company or a bank).', warning: true, strong: true),
    'spam': TagLook('Spam', Icons.report_rounded, _orange, 'This account was confirmed to send unwanted ads or links in bulk.', warning: true),
    'harassment': TagLook('Harassment', Icons.do_not_disturb_on_rounded, _orange, 'This account was confirmed to bother or threaten people.', warning: true),
    'reported': TagLook('Many reports', Icons.flag_rounded, _orange,
        'Several Hushavia users blocked or reported this account in the last 30 days. Not checked by Hushavia yet — be careful.', warning: true),
    'new_account': TagLook('New account', Icons.fiber_new_rounded, Color(0xFF8A93B4), 'This account was made less than a week ago.'),
    'verified_business': TagLook('Verified business', Icons.storefront_rounded, Color(0xFF3C83DE), 'Hushavia checked that this business is real.'),
    'official': TagLook('Official', Icons.verified_user_rounded, Color(0xFF6D4AFF), 'An official Hushavia account.'),
    'trusted_seller': TagLook('Trusted seller', Icons.thumb_up_alt_rounded, Color(0xFF12A150), '10 or more sales through the catalog and no confirmed reports.'),
  };

  static List<String> sorted(Iterable<String> tags) {
    final known = tags.where(all.containsKey).toSet().toList();
    known.sort((a, b) => all.keys.toList().indexOf(a).compareTo(all.keys.toList().indexOf(b)));
    return known;
  }
}

/// A row of tag pills (tap one to read what it means).
class ProfileTags extends StatelessWidget {
  const ProfileTags(this.tags, {super.key, this.center = false});
  final Iterable<String> tags;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final list = TagLook.sorted(tags);
    if (list.isEmpty) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      alignment: center ? WrapAlignment.center : WrapAlignment.start,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final t in list)
          Material(
            color: TagLook.all[t]!.color.withValues(alpha: dark ? 0.22 : 0.12),
            shape: StadiumBorder(side: BorderSide(color: TagLook.all[t]!.color.withValues(alpha: 0.35))),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  icon: Icon(TagLook.all[t]!.icon, color: TagLook.all[t]!.color, size: 34),
                  title: Text(TagLook.all[t]!.label),
                  content: Text(TagLook.all[t]!.about),
                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(TagLook.all[t]!.icon, size: 15, color: TagLook.all[t]!.color),
                  const SizedBox(width: 5),
                  Text(TagLook.all[t]!.label, style: TextStyle(color: TagLook.all[t]!.color, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}
