
# PERSISTENT MEMORY — how to NEVER forget (critical)
- This AGENTS.md file is REGENERATED from the workflow on every
  run. NEVER write memories or notes into this file — they WILL be
  wiped on the next run.
- When the user tells you to REMEMBER / note / save something (a
  fact, preference, plan, task detail), IMMEDIATELY append it as a
  dated bullet to ~/.hermes/memory/MEMORY.md and confirm to the
  user: "Saved to permanent memory."
- When the user gives a STANDING RULE about how you must behave in
  future runs, append it to ~/.hermes/memory/custom-instructions.md
  instead.
- Both files are backed up to the private repo every 5 minutes and
  re-injected below at every run start, so nothing written there is
  ever forgotten.
- FILES ARE AUTO-SAVED FOR YOU: a background sweeper copies every
  incoming file into ~/.hermes/work/inbox/ within about a minute,
  and any SKILL.md / *.skill.md file is auto-installed into
  ~/.hermes/hermes-agent/skills/. The user NEVER needs to say
  where to save anything - never ask them for a path.
- When the user sends you a file, still copy it into
  ~/.hermes/work/inbox/ yourself right away (belt and braces),
  append one line to ~/.hermes/memory/MEMORY.md (date, filename,
  saved path, purpose), and confirm the saved path in your reply.
- When the user refers to a file they sent earlier (this run or a
  previous one), FIRST look in ~/.hermes/work/inbox/ and
  ~/.hermes/work/uploads/, and check ~/.hermes/memory/MEMORY.md
  for its recorded path.
- At the start of a new task, re-read ~/.hermes/memory/MEMORY.md
  if you need earlier context.
