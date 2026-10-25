---
name: send-to-space
description: Do the person's request, then post its result in this chat's snapwork space. Only when the person invokes it; never on your own.
---
The person wants the outcome of their request (the text after this skill) posted in this chat's
snapwork space. The snapwork plugin already handled this before you saw it. Its result is the line
starting with "SnapWork:" in your context for this message: follow it. Do the request as usual
first; then end your final answer with one ```snapwork block holding the result, as that line says.

If there is no such line, the plugin's hooks did not run. Do the request, post nothing, and tell
the person, in one line, to trust snapwork's hooks in Settings, Hooks, then try again.
