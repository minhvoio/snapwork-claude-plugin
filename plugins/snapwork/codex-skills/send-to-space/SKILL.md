---
name: send-to-space
description: Send something from this conversation to this chat's snapwork space (a shortcut for "send this to the space"). Only when the person invokes it; never on your own.
---
The person wants something sent to this chat's snapwork space: the text after this skill says
what, often by pointing at your conversation. The snapwork plugin already handled this before you
saw it. Its result is the line starting with "SnapWork:" in your context for this message: follow
it, and end your final answer with one ```snapwork block holding the message.

If there is no such line, the plugin's hooks did not run. Post nothing, and tell the person, in one
line, to trust snapwork's hooks in Settings, Hooks, then try again.
