import os, sys
OUT = sys.argv[1]
VIO1, VIO2 = '#9B80FF', '#5B3CEB'
INK = '#1C1838'

def body(extra_top=''):
    return f'''
<defs>
 <linearGradient id="b" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="{VIO1}"/><stop offset="1" stop-color="{VIO2}"/></linearGradient>
 <radialGradient id="hl" cx="0.35" cy="0.25" r="0.5"><stop offset="0" stop-color="#fff" stop-opacity=".45"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
 <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE08A"/><stop offset="1" stop-color="#F2A91F"/></linearGradient>
</defs>
<ellipse cx="256" cy="470" rx="150" ry="18" fill="#000" opacity=".12"/>
<path d="M150 96 H362 Q430 96 430 164 V318 Q430 386 362 386 H226 L150 452 L164 386 H150 Q82 386 82 318 V164 Q82 96 150 96 Z" fill="url(#b)"/>
<path d="M150 96 H362 Q430 96 430 164 V318 Q430 386 362 386 H226 L150 452 L164 386 H150 Q82 386 82 318 V164 Q82 96 150 96 Z" fill="url(#hl)"/>
<path d="M314 112 L414 112 Q414 112 414 150 Z" fill="#fff" opacity=".18"/>
'''

def cheeks():
    return '<ellipse cx="160" cy="290" rx="26" ry="16" fill="#FF8FB8" opacity=".75"/><ellipse cx="352" cy="290" rx="26" ry="16" fill="#FF8FB8" opacity=".75"/>'

def eyes(kind='open'):
    if kind == 'open':
        return ('<ellipse cx="200" cy="228" rx="30" ry="38" fill="#fff"/><ellipse cx="312" cy="228" rx="30" ry="38" fill="#fff"/>'
                f'<circle cx="206" cy="236" r="18" fill="{INK}"/><circle cx="318" cy="236" r="18" fill="{INK}"/>'
                '<circle cx="213" cy="226" r="7" fill="#fff"/><circle cx="325" cy="226" r="7" fill="#fff"/>')
    if kind == 'happy':
        return f'<path d="M172 236 Q200 200 228 236" stroke="{INK}" stroke-width="14" fill="none" stroke-linecap="round"/><path d="M284 236 Q312 200 340 236" stroke="{INK}" stroke-width="14" fill="none" stroke-linecap="round"/>'
    if kind == 'closed':
        return f'<path d="M172 232 Q200 252 228 232" stroke="{INK}" stroke-width="12" fill="none" stroke-linecap="round"/><path d="M284 232 Q312 252 340 232" stroke="{INK}" stroke-width="12" fill="none" stroke-linecap="round"/>'
    if kind == 'hearts':
        h = lambda x: f'<path d="M{x} 250 C{x-46} 216 {x-30} 186 {x} 206 C{x+30} 186 {x+46} 216 {x} 250Z" fill="#FF4D8D"/>'
        return h(200) + h(312)
    if kind == 'stars':
        st = lambda x: f'<path d="M{x} 192 l11 24 l26 3 l-19 18 l5 26 l-23 -13 l-23 13 l5 -26 l-19 -18 l26 -3z" fill="url(#gold)" stroke="#fff" stroke-width="4"/>'
        return st(200) + st(312)
    if kind == 'wide':
        return ('<ellipse cx="200" cy="224" rx="34" ry="44" fill="#fff"/><ellipse cx="312" cy="224" rx="34" ry="44" fill="#fff"/>'
                f'<circle cx="200" cy="228" r="13" fill="{INK}"/><circle cx="312" cy="228" r="13" fill="{INK}"/>')
    if kind == 'sad':
        return (eyes('open') + f'<path d="M168 184 L226 198" stroke="{INK}" stroke-width="10" stroke-linecap="round"/><path d="M344 184 L286 198" stroke="{INK}" stroke-width="10" stroke-linecap="round"/>'
                '<path d="M176 268 Q166 296 176 306 Q188 296 176 268Z" fill="#7FD3FF"/>')
    if kind == 'angry':
        return (eyes('open') + f'<path d="M166 186 L228 210" stroke="{INK}" stroke-width="12" stroke-linecap="round"/><path d="M346 186 L284 210" stroke="{INK}" stroke-width="12" stroke-linecap="round"/>')
    if kind == 'wink':
        return ('<ellipse cx="200" cy="228" rx="30" ry="38" fill="#fff"/>'
                f'<circle cx="206" cy="236" r="18" fill="{INK}"/><circle cx="213" cy="226" r="7" fill="#fff"/>'
                f'<path d="M284 236 Q312 212 340 236" stroke="{INK}" stroke-width="14" fill="none" stroke-linecap="round"/>')
    if kind == 'look_up':
        return ('<ellipse cx="200" cy="228" rx="30" ry="38" fill="#fff"/><ellipse cx="312" cy="228" rx="30" ry="38" fill="#fff"/>'
                f'<circle cx="212" cy="212" r="17" fill="{INK}"/><circle cx="324" cy="212" r="17" fill="{INK}"/>'
                '<circle cx="218" cy="204" r="6" fill="#fff"/><circle cx="330" cy="204" r="6" fill="#fff"/>')
    return ''

def mouth(kind='smile'):
    m = {
        'smile': f'<path d="M222 300 Q256 330 290 300" stroke="{INK}" stroke-width="12" fill="none" stroke-linecap="round"/>',
        'open': f'<path d="M214 292 Q256 360 298 292 Z" fill="{INK}"/><path d="M234 322 Q256 340 278 322 Q256 312 234 322Z" fill="#FF6B8E"/>',
        'o': f'<ellipse cx="256" cy="312" rx="20" ry="26" fill="{INK}"/>',
        'frown': f'<path d="M226 320 Q256 296 286 320" stroke="{INK}" stroke-width="12" fill="none" stroke-linecap="round"/>',
        'flat': f'<path d="M232 312 H280" stroke="{INK}" stroke-width="12" stroke-linecap="round"/>',
        'tongue': f'<path d="M222 298 Q256 330 290 298" stroke="{INK}" stroke-width="12" fill="none" stroke-linecap="round"/><path d="M262 312 Q286 312 284 336 Q270 350 258 332Z" fill="#FF6B8E"/>',
        'small': f'<path d="M240 306 Q256 318 272 306" stroke="{INK}" stroke-width="10" fill="none" stroke-linecap="round"/>',
    }
    return m[kind]

def hands(kind='down'):
    if kind == 'down':
        return '<ellipse cx="78" cy="300" rx="26" ry="34" fill="#6E52F2"/><ellipse cx="434" cy="300" rx="26" ry="34" fill="#6E52F2"/>'
    if kind == 'wave':
        return '<ellipse cx="78" cy="300" rx="26" ry="34" fill="#6E52F2"/><g transform="rotate(-25 450 150)"><ellipse cx="450" cy="150" rx="28" ry="38" fill="#6E52F2"/></g><path d="M478 92 q14 10 6 26 M494 120 q16 6 14 24" stroke="#6E52F2" stroke-width="8" fill="none" stroke-linecap="round"/>'
    if kind == 'cheeks':
        return '<ellipse cx="120" cy="320" rx="26" ry="32" fill="#6E52F2"/><ellipse cx="392" cy="320" rx="26" ry="32" fill="#6E52F2"/>'
    if kind == 'chin':
        return '<ellipse cx="78" cy="300" rx="26" ry="34" fill="#6E52F2"/><ellipse cx="300" cy="372" rx="30" ry="24" fill="#6E52F2"/>'
    return ''

def text_tag(txt, y=58, size=62, fill='#FFFFFF', bg='#FF4D8D', w=None):
    w = w or (len(txt) * size * (0.8 if txt.isupper() else 0.62) + 50)
    x = 256 - w / 2
    return (f'<g transform="rotate(-6 256 {y})"><rect x="{x}" y="{y-size*0.85}" width="{w}" height="{size*1.25}" rx="{size*0.6}" fill="{bg}" stroke="#fff" stroke-width="8"/>'
            f'<text x="256" y="{y+size*0.18}" text-anchor="middle" font-family="Arial Black, Arial, sans-serif" font-weight="900" font-size="{size}" fill="{fill}">{txt}</text></g>')

def heart(x, y, s=1, c='#FF4D8D'):
    return f'<path transform="translate({x} {y}) scale({s})" d="M0 26 C-40 -4 -26 -34 0 -16 C26 -34 40 -4 0 26Z" fill="{c}" stroke="#fff" stroke-width="5"/>'

P = {}
P['hi'] = ('👋😊', body() + eyes('open') + cheeks() + mouth('open') + hands('wave') + text_tag('Hi!', y=62))
P['salam'] = ('🤝😊🙏', body() + eyes('happy') + cheeks() + mouth('smile') + hands('down') + text_tag('Salam', y=62, bg='#12B89C'))
P['love'] = ('❤️😍🥰', body() + eyes('hearts') + cheeks() + mouth('smile') + hands('cheeks') + heart(430, 80, 1.3) + heart(92, 70, .9) + heart(470, 190, .7))
P['lol'] = ('😂🤣😆', body() + eyes('happy') + cheeks() + mouth('open') + hands('down') + '<path d="M150 252 q-12 26 4 34 q12 -10 -4 -34z M362 252 q12 26 -4 34 q-12 -10 4 -34z" fill="#7FD3FF"/>' + text_tag('LOL', y=62, bg='#F2A91F'))
P['thanks'] = ('🙏😊💜', body() + eyes('happy') + cheeks() + mouth('smile') + '<ellipse cx="256" cy="372" rx="40" ry="28" fill="#6E52F2"/>' + text_tag('Thanks!', y=62, bg='#6D4AFF', size=56))
P['ok'] = ('👍👌✅', body() + eyes('wink') + cheeks() + mouth('smile') + hands('down') +
    '<g transform="translate(430 120)"><circle r="56" fill="#12B89C" stroke="#fff" stroke-width="8"/><path d="M-24 0 L-6 20 L28 -18" stroke="#fff" stroke-width="14" fill="none" stroke-linecap="round" stroke-linejoin="round"/></g>')
P['wow'] = ('😮🤩✨', body() + eyes('stars') + cheeks() + mouth('o') + hands('cheeks') + text_tag('WOW', y=62, bg='#FF7A45'))
P['sad'] = ('😢😔💔', body() + eyes('sad') + mouth('frown') + hands('down'))
P['angry'] = ('😠😡💢', body().replace(VIO1, '#FF7A9A').replace(VIO2, '#D6336C') + eyes('angry') + mouth('flat') + hands('down') +
    '<g transform="translate(420 96)" stroke="#D6336C" stroke-width="12" stroke-linecap="round"><path d="M-30 -30 L-8 -8 M30 -30 L8 -8 M-30 30 L-8 8 M30 30 L8 8"/></g>')
P['sleep'] = ('😴💤🌙', body() + eyes('closed') + cheeks() + mouth('small') + hands('down') +
    '<text x="380" y="110" font-family="Arial Black, Arial" font-weight="900" font-size="70" fill="#9B80FF" stroke="#fff" stroke-width="6" paint-order="stroke">Z</text><text x="440" y="60" font-family="Arial Black, Arial" font-weight="900" font-size="48" fill="#9B80FF" stroke="#fff" stroke-width="5" paint-order="stroke">z</text>')
P['party'] = ('🥳🎉🎊', body() + eyes('happy') + cheeks() + mouth('open') + hands('wave') +
    '<path d="M196 104 L250 6 L292 104 Z" fill="#FFB547" stroke="#fff" stroke-width="8" stroke-linejoin="round"/><circle cx="250" cy="10" r="16" fill="#FF4D8D" stroke="#fff" stroke-width="5"/>'
    '<g fill="#12B89C"><rect x="60" y="80" width="16" height="16" transform="rotate(20 68 88)"/><rect x="420" y="60" width="14" height="14" transform="rotate(40 427 67)"/></g><g fill="#FF4D8D"><circle cx="110" cy="40" r="9"/><circle cx="390" cy="20" r="8"/><circle cx="470" cy="210" r="9"/></g>')
P['cool'] = ('😎🔥👌', body() + cheeks() + mouth('smile') + hands('down') +
    f'<path d="M150 200 H362 V224 Q362 262 318 262 Q282 262 274 224 H238 Q230 262 194 262 Q150 262 150 224 Z" fill="{INK}"/><path d="M168 212 L196 212" stroke="#fff" stroke-width="8" stroke-linecap="round" opacity=".6"/>')
P['think'] = ('🤔💭❓', body() + eyes('look_up') + mouth('flat') + hands('chin') +
    '<g fill="#fff" stroke="#9B80FF" stroke-width="6"><circle cx="440" cy="120" r="16"/><circle cx="470" cy="76" r="24"/></g><text x="452" y="94" text-anchor="middle" font-family="Arial Black, Arial" font-weight="900" font-size="34" fill="#6D4AFF">?</text>')
P['gm'] = ('☀️🌅😊', body() + eyes('happy') + cheeks() + mouth('smile') + hands('wave') +
    '<g transform="translate(96 92)"><circle r="44" fill="url(#gold)" stroke="#fff" stroke-width="8"/>' + ''.join(f'<rect x="-5" y="-78" width="10" height="22" rx="5" fill="#F2A91F" transform="rotate({a})"/>' for a in range(0, 360, 45)) + '</g>'
    + text_tag('Good morning', y=486, size=44, bg='#F2A91F', w=360))
P['gn'] = ('🌙😴✨', body().replace(VIO1, '#6C5FD6').replace(VIO2, '#2E2470') + eyes('closed') + cheeks() + mouth('small') + hands('down') +
    '<path d="M420 40 A56 56 0 1 0 470 120 A44 44 0 1 1 420 40Z" fill="url(#gold)" stroke="#fff" stroke-width="6"/>'
    '<g fill="#FFE08A"><circle cx="90" cy="70" r="6"/><circle cx="140" cy="36" r="4"/><circle cx="60" cy="140" r="4"/></g>'
    + text_tag('Good night', y=486, size=44, bg='#2E2470', w=320))
P['eid'] = ('🌙🕌🎉', body().replace(VIO1, '#3FD8A0').replace(VIO2, '#0E8A6A') + eyes('happy') + cheeks() + mouth('open') + hands('wave') +
    '<path d="M86 30 A54 54 0 1 0 136 110 A42 42 0 1 1 86 30Z" fill="url(#gold)" stroke="#fff" stroke-width="6"/><path d="M150 70 l6 14 l15 2 l-11 10 l3 15 l-13 -7 l-13 7 l3 -15 l-11 -10 l15 -2z" fill="#FFE08A"/>'
    + text_tag('Eid Mubarak', y=486, size=44, bg='#0E8A6A', w=330))

os.makedirs(OUT, exist_ok=True)
for k, (emoji, inner) in P.items():
    open(f'{OUT}/{k}.svg', 'w').write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -40 532 560" width="512" height="512">{inner}</svg>')
open(f'{OUT}/emoji.txt', 'w').write('\n'.join(f'{k}\t{e}' for k, (e, _) in P.items()))
print(len(P))
