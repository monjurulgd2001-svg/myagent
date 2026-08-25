# ringtone-generator - Stable Audio ringtone / music / sound generator

Generates an mp3 from a text prompt using Stable Audio, then auto-trims
silence with ffmpeg. Use this skill for ANY ringtone / short music /
sound-effect generation task. Do NOT write new code for these tasks.

## EXACT commands (run as-is, only change the option values)

cd "__WORKSPACE__"
node ringtone_generator.js -p "<text prompt of the sound>" -d <seconds> -o <output>.mp3

Options:
- -p / --prompt: description of the sound (e.g. "soft acoustic marimba ringtone")
- -d / --duration: length in seconds (default 6)
- -o / --output: output mp3 filename
- --trim-silence true|false (default true), --silence-threshold <dB> (default -45)
- --normalize: loudness normalization
- --token <bearer>: manual token (normally NOT needed - STABLE_AUDIO_TOKEN is already in env)

## HARD RULES - NEVER violate these
- NEVER fabricate or fake the audio. Do NOT synthesize sine waves, beeps,
  noise or "placeholder" tones with ffmpeg/sox/node, and do NOT send a
  silent or made-up mp3 while claiming it is the generated sound. If real
  generation fails, STOP and report the exact error message to the user.
- Do NOT rewrite this skill as your own script (no custom run.js etc.).
  ringtone_generator.js already handles token capture, auto account
  creation, retries, silence trim and normalization. Always use it as-is.
- Success check before sending: the output mp3 must exist, be > 20 KB and
  come from ringtone_generator.js printing its success line. Otherwise it
  is a failure - say so honestly.

## If `node ringtone_generator.js` fails to start
- "Cannot find package ..." / ERR_MODULE_NOT_FOUND means node_modules is
  not visible from the current dir. Fix it, do not work around it:
  cd "__WORKSPACE__"   # node_modules lives here
  # or, if that dir is missing them:
  npm install playwright playwright-extra puppeteer-extra-plugin-stealth ffmpeg-static fluent-ffmpeg
- The script runs headless by default; DISPLAY is not required.

## Notes
- MUST run from "__WORKSPACE__" - node_modules (playwright, ffmpeg-static) live there.
- After generating, copy the mp3 to ~/.hermes/work/outputs/ so it is backed up:
  cp <output>.mp3 ~/.hermes/work/outputs/
- If the token is invalid the script auto-creates a temp account (can take a minute).
