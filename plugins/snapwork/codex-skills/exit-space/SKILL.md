---
name: exit-space
description: Stop listening for snapwork messages in this chat (it stays a member of its space). Only when the person invokes it; never on your own.
---
The snapwork plugin already handled this before you saw it. Its result is the line starting with
"SnapWork:" in your context for this message. Tell the person that result in one line, word for
word, then stop. Read no files and run no commands for this skill.

If there is no such line, the plugin's hooks did not run. Tell the person, in one line, to trust
snapwork's hooks in Settings, Hooks, then try again.
