# Screen Capture (inbuilt)

Screenshot and screen-record the shared virtual desktop (DISPLAY :99 -
the same desktop where the headed browser and every GUI app run, the one
shown in the live view).

## Commands

    cap shot [--out FILE]          # full-screen .png screenshot
    cap clip <seconds> [--fps 12]  # record N seconds -> .mp4 (blocks until done)
    cap start [--fps 12]           # start a background recording
    cap stop                       # stop + finalize, prints the .mp4 path
    cap status                     # running? file, elapsed, size + recent captures

## Rules for the agent

1. Files are saved in ~/.hermes/work/captures/ - ALWAYS send the saved
   file to the user in chat right after capturing.
2. For "record while I do X": run `cap start`, do the task, then
   `cap stop`, then send the .mp4.
3. Keep clips short (max 600 seconds). Recordings capture the WHOLE
   desktop, including every open window.
4. This captures display :99 only. To screenshot a web page through the
   Zedge VPN, use `zedge shot <url> -i N` instead.
5. Never hand-roll ffmpeg/x11grab/scrot commands - use `cap`.
