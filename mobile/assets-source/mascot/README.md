# Hushavia mascot (animated)

`rig.html` is the whole character: an SVG puppet plus one small function per scene
(wave, search, hide, nocontacts, contacts, cool, sleep, delete, settings, secure).
Open `rig.html#cool` in a browser to see a pose; `render.js` (Playwright) writes the frames:

    node render.js $PWD/rig.html $PWD/frames 24 wave,cool all 360

The frames are then packed into the animated WebP files in `mobile/assets/mascot/` (42 ms a frame, quality 62).
Original artwork — not based on any other app's stickers.
